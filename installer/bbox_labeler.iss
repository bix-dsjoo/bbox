#define MyAppName "BBox Labeler"
#define MyAppVersion "1.0.3"
#define MyAppPublisher "BBox Labeler"
#define MyAppExeName "bbox_labeler.exe"

[Setup]
AppId={{9F7AD95F-4169-4D46-A8F0-17F9650C1137}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={localappdata}\Programs\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=..\dist
OutputBaseFilename=bbox_labeler_setup_{#MyAppVersion}
SetupIconFile=bbox_labeler_setup.ico
WizardImageFile=wizard_image.bmp
WizardSmallImageFile=wizard_small_image.bmp
LicenseFile=..\LICENSE.txt
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\{#MyAppExeName}
UninstallDisplayName={#MyAppName}
VersionInfoVersion={#MyAppVersion}
VersionInfoCompany={#MyAppPublisher}
VersionInfoDescription={#MyAppName} Setup
VersionInfoCopyright=Copyright (C) 2026 {#MyAppPublisher}. All rights reserved.

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: unchecked

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Excludes: "*.pdb,Thumbs.db"; Flags: ignoreversion recursesubdirs
Source: "..\LICENSE.txt"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\THIRD_PARTY_NOTICES.txt"; DestDir: "{app}"; Flags: ignoreversion

[InstallDelete]
Type: filesandordirs; Name: "{app}\runtime\python"
Type: files; Name: "{app}\FastSAM-s.pt"
Type: files; Name: "{app}\tools\detectors\fastsam_detector.py"
Type: files; Name: "{app}\tools\detectors\bread_vision_detector.py"
Type: files; Name: "{app}\models\bread_classifier_yolov8n_cls_best.pt"
Type: files; Name: "{app}\models\bread_yolov8n_1class_best.pt"
Type: filesandordirs; Name: "{app}\datasets"
Type: filesandordirs; Name: "{app}\train"
Type: filesandordirs; Name: "{app}\outputs"
Type: filesandordirs; Name: "{app}\qa_samples"
Type: filesandordirs; Name: "{app}\research"

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Launch {#MyAppName}"; Flags: nowait postinstall skipifsilent
