; Unofficial LocalSend Chat MVP. Deliberately unsigned, without upstream MSIX identity.
#ifndef PayloadDir
  #error PayloadDir is required
#endif
#ifndef ResultDir
  #error ResultDir is required
#endif

#define MyAppName "LocalSend Chat"
#define MyAppVersion "1.18.2"
#define MyAppExeName "localsend_app.exe"

[Setup]
AppId={{4C191205-3F67-42A9-B3B9-74CD4E57C610}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher=LocalSend Chat contributors
DefaultDirName={localappdata}\Programs\LocalSend Chat
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir={#ResultDir}
OutputBaseFilename=LocalSend-Chat-windows-x64-unsigned
SetupIconFile={#PayloadDir}\logo.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
LicenseFile={#PayloadDir}\LICENSE.txt
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesInstallIn64BitMode=x64compatible
ArchitecturesAllowed=x64compatible
MinVersion=10.0

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "chinesesimplified"; MessagesFile: "..\build\windows\inno\ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#PayloadDir}\{#MyAppExeName}"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#PayloadDir}\*.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#PayloadDir}\data\*"; DestDir: "{app}\data"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#PayloadDir}\LICENSE.txt"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#PayloadDir}\README_CHAT.md"; DestDir: "{app}"; Flags: ignoreversion
; Do not install portable settings.json: installed builds use independent APPDATA\LocalSendChat.
; No official MSIX helper, upstream signing secrets, firewall modification, or auto-start task.

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent
