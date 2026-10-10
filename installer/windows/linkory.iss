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
; Not the Restart Manager: it asks the window to close, and our window hides to the tray instead of exiting, so setup hung on "Closing applications".
; The app is ended in [Code] below instead.
CloseApplications=no
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
; Silent installs are in-app updates: start the new version again when done.
Filename: "{app}\linkory_app.exe"; Flags: nowait; Check: WizardSilent

[Code]
// The app keeps running in the tray after its window is closed, so ask it to quit by ending the process.
// (Ends only this user's instance; any chat state is already on disk or on the server.)
procedure StopApp();
var
  rc: Integer;
begin
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/F /T /IM linkory_app.exe', '', SW_HIDE, ewWaitUntilTerminated, rc);
  Sleep(500); // let Windows release the file handles
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  StopApp();
  Result := '';
end;

function InitializeUninstall(): Boolean;
begin
  StopApp();
  Result := True;
end;
