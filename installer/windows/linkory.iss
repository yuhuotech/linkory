; Inno Setup script. Built in CI:  iscc /DAppVersion=1.2.3 /DSourceDir=... linkory.iss
#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\..\linkory-app\build\windows\x64\runner\Release"
#endif

[Setup]
AppId={{6E1B0C5A-3D0B-4C58-9C0E-5D3F1A7B2E41}
AppName=连信 Linkory
AppVersion={#AppVersion}
AppPublisher=yuhuotech
DefaultDirName={autopf}\Linkory
DefaultGroupName=连信 Linkory
DisableProgramGroupPage=yes
OutputDir=..\..\dist
OutputBaseFilename=Linkory-{#AppVersion}-windows-x64-setup
SetupIconFile=..\..\linkory-app\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\linkory_app.exe
Compression=lzma2
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
WizardStyle=modern
CloseApplications=yes
RestartApplications=no

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式 / Create a desktop shortcut"; GroupDescription: "快捷方式:"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\连信 Linkory"; Filename: "{app}\linkory_app.exe"
Name: "{autodesktop}\连信 Linkory"; Filename: "{app}\linkory_app.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\linkory_app.exe"; Description: "启动连信 Linkory"; Flags: nowait postinstall skipifsilent
