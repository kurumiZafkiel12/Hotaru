$ErrorActionPreference = 'Stop'
$version = [regex]::Match((Get-Content pubspec.yaml -Raw), '(?m)^version: ([0-9]+\.[0-9]+\.[0-9]+)$').Groups[1].Value
if (!$version) { throw 'Missing public version' }
$folder = Join-Path $env:RUNNER_TEMP 'hotaru-candidate'
$installDir = Join-Path $env:RUNNER_TEMP 'hotaru-install-test'
New-Item -ItemType Directory -Force $folder | Out-Null
gh release download "v$version" --pattern '*windows*' --dir $folder
if ($LASTEXITCODE -ne 0) { throw 'Could not fetch Windows candidate' }
$zip = Join-Path $folder "Hotaru-$version-windows-amd64.zip"
$setup = Join-Path $folder "Hotaru-$version-windows-amd64-setup.exe"
Expand-Archive -Path $zip -DestinationPath (Join-Path $folder 'zip')
foreach ($file in @('Hotaru.exe', 'flutter_windows.dll', 'HotaruCore.exe', 'HotaruHelperService.exe')) {
    if (!(Test-Path (Join-Path $folder "zip/$file"))) { throw "Missing ZIP component: $file" }
}
for ($attempt = 0; $attempt -lt 2; $attempt++) {
    $process = Start-Process -FilePath $setup -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/DIR=`"$installDir`"") -Wait -PassThru
    if ($process.ExitCode -ne 0) { throw "Installer failed: $($process.ExitCode)" }
    if (!(Test-Path (Join-Path $installDir 'Hotaru.exe'))) { throw 'Missing installed application' }
}
$uninstaller = Join-Path $installDir 'unins000.exe'
$process = Start-Process -FilePath $uninstaller -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART') -Wait -PassThru
if ($process.ExitCode -ne 0) { throw "Uninstaller failed: $($process.ExitCode)" }
if (Test-Path (Join-Path $installDir 'Hotaru.exe')) { throw 'Application remains after uninstall' }
Write-Output 'WINDOWS_PACKAGE_OK: ZIP, install, reinstall and uninstall; application not launched'
