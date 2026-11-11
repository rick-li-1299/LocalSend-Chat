[CmdletBinding(DefaultParameterSetName = 'Signed')]
param(
    [Parameter(Mandatory)] [string] $PayloadDir,
    [Parameter(Mandatory)] [string] $OutputDir,
    [Parameter(Mandatory)] [string] $Version,
    [Parameter(Mandatory)] [uri] $FeedUrl,
    [Parameter(Mandatory)] [string] $SdkBin,
    [Parameter(Mandatory, ParameterSetName = 'Signed')]
    [ValidatePattern('^[0-9a-fA-F]{40}$')] [string] $CertificateThumbprint,
    [Parameter(Mandatory, ParameterSetName = 'Signed')] [uri] $TimestampUrl,
    [Parameter(Mandatory, ParameterSetName = 'Preview')] [switch] $UnsignedPreview
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Version -notmatch '^[1-9][0-9]{0,4}(\.(0|[1-9][0-9]{0,4})){3}$' -or
    @($Version.Split('.') | Where-Object { [int] $_ -gt 65535 }).Count -ne 0) {
    throw 'Version must contain four numbers from 0 to 65535, with a nonzero major version.'
}
if (!$FeedUrl.IsAbsoluteUri -or $FeedUrl.Scheme -ne 'https' -or $FeedUrl.UserInfo -or
    $FeedUrl.Query -or $FeedUrl.Fragment -or $FeedUrl.Segments[-1] -notmatch '^[a-zA-Z0-9_.-]+\.appinstaller$') {
    throw 'Provide the permanent HTTPS URL of the .appinstaller file.'
}
$payload = (Resolve-Path -LiteralPath $PayloadDir).ProviderPath.TrimEnd('\')
$sdk = (Resolve-Path -LiteralPath $SdkBin).ProviderPath
$appName = 'LocalSendChat.Lan'
$exe = Join-Path $payload 'localsend_app.exe'
$snapshot = Join-Path $payload 'data/app.so'
if (!(Test-Path -LiteralPath $exe -PathType Leaf) -or !(Test-Path -LiteralPath $snapshot -PathType Leaf)) {
    throw 'PayloadDir must contain the built Windows application and its release data.'
}

if ($UnsignedPreview) {
    $publisher = 'CN=LocalSend Chat Packaging Preview'
} else {
    if (!$TimestampUrl.IsAbsoluteUri -or $TimestampUrl.Scheme -ne 'https') {
        throw 'Provide an HTTPS RFC 3161 timestamp URL.'
    }
    $certificate = Get-Item -LiteralPath "Cert:\CurrentUser\My\$CertificateThumbprint"
    if (!$certificate.HasPrivateKey) { throw 'The certificate must have a code signing private key.' }
    $publisher = $certificate.Subject
}

New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$output = (Resolve-Path -LiteralPath $OutputDir).ProviderPath
$packageName = "LocalSendChat-$Version-x64.msix"
if ($UnsignedPreview) { $packageName = "unsigned-$packageName" }
$packageTarget = Join-Path $output $packageName
$feedName = $FeedUrl.Segments[-1]
if ($UnsignedPreview) { $feedName = "$feedName.preview.xml" }
$feedTarget = Join-Path $output $feedName
$sha = [Security.Cryptography.SHA256]::Create()
try {
    $outputKey = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($output.ToUpperInvariant()))).Replace('-', '')
} finally {
    $sha.Dispose()
}
$lock = [Threading.Mutex]::new($false, "Local\LocalSendChatRelease-$outputKey")
$locked = $false
$work = $null
try {
    try {
        $locked = $lock.WaitOne(0)
    } catch [Threading.AbandonedMutexException] {
        $locked = $true
    }
    if (!$locked) { throw 'Another release is being prepared in this output directory.' }
    if (Test-Path -LiteralPath $packageTarget) { throw "This package version already exists at $packageTarget." }
    if (Test-Path -LiteralPath $feedTarget) {
        [xml] $existing = Get-Content -LiteralPath $feedTarget -Raw
        if ([version] $Version -le [version] $existing.DocumentElement.GetAttribute('Version') -or
            $existing.DocumentElement.GetAttribute('Uri') -ne $FeedUrl.AbsoluteUri -or
            $existing.DocumentElement.MainPackage.Publisher -ne $publisher -or
            $existing.DocumentElement.MainPackage.Name -ne $appName) {
            throw 'Keep the feed URL and publisher identity unchanged, and increase the version.'
        }
    }

    $work = (New-Item -ItemType Directory -Path (Join-Path $output ('.msix-' + [guid]::NewGuid()))).FullName
    $manifest = Join-Path $work 'AppxManifest.xml'
    $publisherXml = [Security.SecurityElement]::Escape($publisher)
    @"
<?xml version="1.0" encoding="utf-8"?>
<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10"
         xmlns:uap="http://schemas.microsoft.com/appx/manifest/uap/windows10"
         xmlns:rescap="http://schemas.microsoft.com/appx/manifest/foundation/windows10/restrictedcapabilities"
         IgnorableNamespaces="uap rescap">
  <Identity Name="$appName" Publisher="$publisherXml" Version="$Version" ProcessorArchitecture="x64" />
  <Properties>
    <DisplayName>LocalSend Chat</DisplayName>
    <PublisherDisplayName>LocalSend Chat</PublisherDisplayName>
    <Logo>Images\StoreLogo.png</Logo>
  </Properties>
  <Dependencies>
    <TargetDeviceFamily Name="Windows.Desktop" MinVersion="10.0.19041.0" MaxVersionTested="10.0.26100.0" />
  </Dependencies>
  <Resources><Resource Language="en-US" /><Resource Language="zh-CN" /></Resources>
  <Applications>
    <Application Id="Chat" Executable="localsend_app.exe" EntryPoint="Windows.FullTrustApplication">
      <uap:VisualElements DisplayName="LocalSend Chat" Description="Local network chat and file transfer"
                          BackgroundColor="transparent" Square150x150Logo="Images\Square150x150Logo.png"
                          Square44x44Logo="Images\Square44x44Logo.png" />
    </Application>
  </Applications>
  <Capabilities><rescap:Capability Name="runFullTrust" /></Capabilities>
</Package>
"@ | Set-Content -LiteralPath $manifest -Encoding UTF8

    $images = Join-Path $PSScriptRoot '../build/msix/content/Images'
    $mapping = Join-Path $work 'mapping.txt'
    $files = @(
        '[Files]'
        '"{0}" "AppxManifest.xml"' -f $manifest
        '"{0}" "localsend_app.exe"' -f $exe
        foreach ($logo in 'StoreLogo', 'Square150x150Logo', 'Square44x44Logo') {
            '"{0}" "Images\{1}.png"' -f (Join-Path $images "$logo.scale-100.png"), $logo
        }
        foreach ($file in Get-ChildItem -LiteralPath $payload -File -Filter '*.dll') {
            '"{0}" "{1}"' -f $file.FullName, $file.Name
        }
        foreach ($file in Get-ChildItem -LiteralPath (Join-Path $payload 'data') -Recurse -File) {
            '"{0}" "{1}"' -f $file.FullName, $file.FullName.Substring($payload.Length + 1)
        }
        foreach ($name in 'LICENSE.txt', 'README_CHAT.md') {
            $file = Join-Path $payload $name
            if (Test-Path -LiteralPath $file -PathType Leaf) { '"{0}" "{1}"' -f $file, $name }
        }
    )
    $files | Set-Content -LiteralPath $mapping -Encoding Unicode
    $package = Join-Path $work $packageName
    & (Join-Path $sdk 'makeappx.exe') pack /f $mapping /p $package
    if ($LASTEXITCODE -ne 0) { throw 'MSIX packaging failed.' }
    if (!$UnsignedPreview) {
        $signTool = Join-Path $sdk 'signtool.exe'
        & $signTool sign /fd SHA256 /sha1 $CertificateThumbprint /tr $TimestampUrl.AbsoluteUri /td SHA256 $package
        if ($LASTEXITCODE -ne 0) { throw 'MSIX signing failed.' }
        & $signTool verify /pa $package
        if ($LASTEXITCODE -ne 0) { throw 'MSIX signature verification failed.' }
    }

    $feedUriXml = [Security.SecurityElement]::Escape($FeedUrl.AbsoluteUri)
    $packageUriXml = [Security.SecurityElement]::Escape([uri]::new($FeedUrl, $packageName).AbsoluteUri)
    $feed = Join-Path $work $feedName
    @"
<?xml version="1.0" encoding="utf-8"?>
<AppInstaller xmlns="http://schemas.microsoft.com/appx/appinstaller/2021" Version="$Version" Uri="$feedUriXml">
  <MainPackage Name="$appName" Publisher="$publisherXml" Version="$Version" ProcessorArchitecture="x64" Uri="$packageUriXml" />
  <UpdateSettings>
    <OnLaunch HoursBetweenUpdateChecks="0" ShowPrompt="false" />
    <AutomaticBackgroundTask />
  </UpdateSettings>
</AppInstaller>
"@ | Set-Content -LiteralPath $feed -Encoding UTF8
    [IO.File]::Move($package, $packageTarget)
    try {
        if (Test-Path -LiteralPath $feedTarget) {
            [IO.File]::Replace($feed, $feedTarget, [NullString]::Value)
        } else {
            [IO.File]::Move($feed, $feedTarget)
        }
    } catch {
        Remove-Item -LiteralPath $packageTarget -Force
        throw
    }
    Write-Output $packageTarget, $feedTarget
} finally {
    try {
        if ($work -and (Split-Path -Parent (Resolve-Path -LiteralPath $work).ProviderPath) -eq $output) {
            Remove-Item -LiteralPath $work -Recurse -Force
        }
    } finally {
        if ($locked) { $lock.ReleaseMutex() }
        $lock.Dispose()
    }
}
