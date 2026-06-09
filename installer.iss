[Setup]
AppName=News TV
AppVersion=2.0.0
AppPublisher=Mahtab Jack
DefaultDirName={autopf}\News TV
DefaultGroupName=News TV
OutputDir=c:\TV\News\tv_app\Output
OutputBaseFilename=NewsTV_Setup
SetupIconFile=c:\TV\News\tv_app\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\news_tv.exe
Compression=lzma
SolidCompression=yes
ArchitecturesInstallIn64BitMode=x64

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: checkedonce

[Files]
Source: "c:\TV\News\tv_app\build\windows\x64\runner\Release\*"; Excludes: "*.msix"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\News TV"; Filename: "{app}\news_tv.exe"
Name: "{autodesktop}\News TV"; Filename: "{app}\news_tv.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\news_tv.exe"; Description: "{cm:LaunchProgram,News TV}"; Flags: nowait postinstall skipifsilent
