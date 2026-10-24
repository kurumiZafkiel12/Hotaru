#ifndef AppVersion
  #define AppVersion "0.4.0"
#endif
#ifndef BuildDir
  #define BuildDir "..\..\apps\hotaru\build\windows\x64\runner\Release"
#endif

[Setup]
AppId={{7DB91803-6D01-4AB3-A19E-5B09F36CA102}
AppName=Hotaru
AppVersion={#AppVersion}
AppPublisher=Hotaru Contributors
AppPublisherURL=https://github.com/kurumiZafkiel12/Hotaru
AppUpdatesURL=https://github.com/kurumiZafkiel12/Hotaru/releases
DefaultDirName={localappdata}\Programs\Hotaru
DefaultGroupName=Hotaru
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir=..\..\dist
OutputBaseFilename=Hotaru-{#AppVersion}-windows-x64-setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
SetupMutex=HotaruSetup
AppMutex=HotaruApplication
UninstallDisplayIcon={app}\hotaru.exe

[Files]
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Hotaru"; Filename: "{app}\hotaru.exe"
Name: "{autodesktop}\Hotaru"; Filename: "{app}\hotaru.exe"; Tasks: desktopicon

[Tasks]
Name: desktopicon; Description: "Create a desktop shortcut"; Flags: unchecked

[Run]
Filename: "{app}\hotaru.exe"; Description: "Launch Hotaru"; Flags: nowait postinstall skipifsilent

; User profiles in %APPDATA%/Hotaru are deliberately kept on upgrade/uninstall.
