[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Archive,
    [Parameter(Mandatory)] [ValidatePattern('^[a-fA-F0-9]{64}$')] [string] $ExpectedSha256,
    [Parameter(Mandatory)] [string] $TargetDir,
    [Parameter(Mandatory)] [int] $AppProcessId,
    [switch] $PrepareOnly
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$work = Split-Path -Parent (Resolve-Path -LiteralPath $Archive).ProviderPath
$target = (Resolve-Path -LiteralPath $TargetDir).ProviderPath.TrimEnd('\')
$stage = Join-Path $work 'payload'
$backup = Join-Path $target ('.chat-update-backup-' + [guid]::NewGuid().ToString('N'))
$changed = [Collections.Generic.List[string]]::new()
$created = [Collections.Generic.List[string]]::new()
$stopped = $false

function Write-UpdateLog([string] $Message) {
    Add-Content -LiteralPath (Join-Path $work 'update.log') -Value $Message -Encoding UTF8
}

try {
    if (!(Test-Path -LiteralPath (Join-Path $target 'localsend_app.exe') -PathType Leaf)) {
        throw 'TargetDir must be an existing LocalSend Chat application directory.'
    }
    if ((Get-Item -LiteralPath $target).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Linked application directory is unsupported.' }
    $sha = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::OpenRead($Archive)
    try { $actualHash = [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '') }
    finally { $stream.Dispose(); $sha.Dispose() }
    if ($actualHash -ne $ExpectedSha256) { throw 'Update SHA-256 mismatch.' }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        $total = 0L
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in $zip.Entries) {
            $name = $entry.FullName.Replace('\', '/')
            if (!$name -or $name.StartsWith('/') -or $name.Contains(':') -or
                @($name.Split('/') | Where-Object { $_ -eq '..' -or $_ -eq '.' -or $_.EndsWith(' ') -or $_.EndsWith('.') }).Count) {
                throw 'Unsafe archive path.'
            }
            if (!$names.Add($name)) { throw 'Duplicate archive path.' }
            $total += $entry.Length
            if ($total -gt 1GB -or $names.Count -gt 10000) { throw 'Update archive is too large.' }
            # Only application files are installed. Portable settings and user data are never extracted.
            if ($name -eq 'settings.json' -or $name.EndsWith('/')) { continue }
            if ($name -notmatch '^(localsend_app\.exe|[^/]+\.dll|LICENSE\.txt|README_CHAT\.md|logo\.ico|data/.+)$') {
                throw "Unexpected application file: $name"
            }
            $destination = [IO.Path]::GetFullPath((Join-Path $stage $name))
            if (!$destination.StartsWith($stage + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Archive escapes staging directory.' }
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination)) | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $destination, $false)
        }
    } finally { $zip.Dispose() }
    foreach ($required in 'localsend_app.exe', 'flutter_windows.dll', 'data/app.so', 'data/flutter_assets/AssetManifest.bin') {
        if (!(Test-Path -LiteralPath (Join-Path $stage $required) -PathType Leaf)) { throw "Incomplete update: $required" }
    }
    # Check write access before the app exits.
    New-Item -ItemType Directory -Path $backup | Out-Null
    $files = @(Get-ChildItem -LiteralPath $stage -File -Recurse)
    foreach ($file in $files) {
        $relative = $file.FullName.Substring($stage.Length + 1)
        $destination = Join-Path $target $relative
        if ((Test-Path -LiteralPath $destination) -and !(Test-Path -LiteralPath $destination -PathType Leaf)) {
            throw 'An application file collides with an existing directory.'
        }
        $ancestor = $destination
        while ($ancestor -and $ancestor -ne $target) {
            if ((Test-Path -LiteralPath $ancestor) -and ((Get-Item -LiteralPath $ancestor).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw 'Linked application files are unsupported.'
            }
            $ancestor = Split-Path -Parent $ancestor
        }
    }
    Set-Content -LiteralPath (Join-Path $work 'ready') -Value 'ready'
    if ($PrepareOnly) { Write-UpdateLog 'Prepared and verified; application files unchanged.'; return }
    $process = Get-Process -Id $AppProcessId -ErrorAction SilentlyContinue
    if ($process -and !$process.WaitForExit(120000)) { throw 'App did not exit; update cancelled.' }
    if (Test-Path -LiteralPath (Join-Path $work 'cancel')) { throw 'Update cancelled by the application.' }
    $stopped = $true
    foreach ($file in $files) {
        $relative = $file.FullName.Substring($stage.Length + 1)
        $destination = Join-Path $target $relative
        if (Test-Path -LiteralPath $destination -PathType Leaf) {
            $saved = Join-Path $backup $relative
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($saved)) | Out-Null
            Copy-Item -LiteralPath $destination -Destination $saved
            $changed.Add($relative)
        } else { $created.Add($relative) }
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination)) | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $destination -Force
    }
    Write-UpdateLog "Updated successfully. Previous application files: $backup"
    Start-Process -FilePath (Join-Path $target 'localsend_app.exe') -WorkingDirectory $target -WindowStyle Hidden
} catch {
    $failure = $_.Exception.Message
    try {
        foreach ($relative in $changed) {
            try { Copy-Item -LiteralPath (Join-Path $backup $relative) -Destination (Join-Path $target $relative) -Force }
            catch { $failure += "; restore $relative`: $($_.Exception.Message)" }
        }
        foreach ($relative in $created) {
            $path = [IO.Path]::GetFullPath((Join-Path $target $relative))
            if (!$path.StartsWith($target + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid rollback path.' }
            if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force }
        }
        if ($stopped) { Start-Process -FilePath (Join-Path $target 'localsend_app.exe') -WorkingDirectory $target -WindowStyle Hidden }
    } catch { $failure += "; rollback: $($_.Exception.Message)" }
    Write-UpdateLog $failure
    Set-Content -LiteralPath (Join-Path $work 'failed') -Value $failure -Encoding UTF8
    exit 1
}
