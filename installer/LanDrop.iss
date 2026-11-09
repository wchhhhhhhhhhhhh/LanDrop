#define AppName "LanDrop"
#define AppVersion "2.0.0"
#define AppExe "LanDrop.exe"

[Setup]
AppId={{6C1B2E4A-7F3D-4A62-9E51-2B8C7D0F4A11}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=LanDrop
AppPublisherURL=https://github.com/wchhhhhhhhhhhhh/LanDrop
DefaultDirName={autopf}\LanDrop
DefaultGroupName=LanDrop
DisableProgramGroupPage=yes
OutputDir=dist
OutputBaseFilename=LanDrop-Setup-{#AppVersion}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
SetupIconFile=app.ico
UninstallDisplayIcon={app}\{#AppExe}
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=admin
CloseApplications=yes
RestartApplications=no

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式(&D)"; GroupDescription: "附加快捷方式："

[Files]
Source: "C:\LanDropUser\out\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{group}\卸载 {#AppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "启动 {#AppName}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
Type: filesandordirs; Name: "{app}"
