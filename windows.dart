import 'dart:io';

void main() {
  final versionStr = Platform.environment['VERSION']!;
  final issPath = 'build/windows/nightmail-$versionStr.iss';

  _writeIssFile(issPath, versionStr);
  _compile(issPath);
}

void _writeIssFile(String issPath, String versionStr) {
  final iss = '''
[Setup]
AppName=NightMail
AppVersion=$versionStr
AppPublisher=SharpBlue
AppPublisherURL=https://sharpblue.com.au/
AppSupportURL=https://sharpblue.com.au/
AppUpdatesURL=https://sharpblue.com.au/
DefaultDirName={autopf}\\NightMail
DefaultGroupName=NightMail
OutputDir=.
OutputBaseFilename=nightmail-$versionStr
SetupIconFile=..\\..\\windows\\runner\\resources\\app_icon.ico
Compression=lzma
SolidCompression=yes
WizardStyle=modern

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "x64\\runner\\Release\\nightmail.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "x64\\runner\\Release\\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\\NightMail"; Filename: "{app}\\nightmail.exe"
Name: "{group}\\Uninstall NightMail"; Filename: "{uninstallexe}"
Name: "{autodesktop}\\NightMail"; Filename: "{app}\\nightmail.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\\nightmail.exe"; Description: "{cm:LaunchProgram,NightMail}"; Flags: nowait postinstall skipifsilent
''';

  File(issPath).writeAsStringSync(iss);
}

void _compile(String issPath) {
  try {
    const iscc = 'iscc';
    final result = Process.runSync(iscc, [issPath], runInShell: true);
    stdout.write(result.stdout);
    stderr.write(result.stderr);
    if (result.exitCode != 0) {
      throw ProcessException(iscc, [issPath], 'iscc failed with exit code ${result.exitCode}', result.exitCode);
    }
    print('Done.');
  } catch (e, s) {
    print('Failed: $e\n$s');
  }
}
