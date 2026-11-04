param([string]$ExpectedVersion = '0.0.6')
$ErrorActionPreference = 'Stop'
if (@(Get-Process Hotaru,HotaruCore,HotaruHelperService -ErrorAction SilentlyContinue).Count -ne 0) {
    throw 'Installation verification requires an isolated runner without an existing Hotaru process'
}
$setup = @(Get-ChildItem 'dist/*-windows-amd64-setup.exe')
if ($setup.Count -ne 1) { throw 'Expected one Windows setup executable' }
$work = Join-Path $env:RUNNER_TEMP 'hotaru-install-verification'
$destination = Join-Path $work 'app'
$reportDirectory = Join-Path $PWD 'archive-probe/windows-install'
New-Item -ItemType Directory -Force $work,$reportDirectory | Out-Null
$sentinels = @($env:APPDATA,$env:LOCALAPPDATA) | ForEach-Object {
    $directory = Join-Path $_ 'dev.hotaru/Hotaru'
    New-Item -ItemType Directory -Force $directory | Out-Null
    $path = Join-Path $directory 'h006-install-verification.txt'
    if (Test-Path $path) { throw 'Verification sentinel already exists' }
    Set-Content $path 'Hotaru installation preservation check'
    $path
}
function Invoke-Installer([string]$Path, [string]$Label) {
    $log = Join-Path $reportDirectory "$Label.log"
    $process = Start-Process -FilePath $Path -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART',"/DIR=`"$destination`"","/LOG=`"$log`"") -Wait -PassThru
    if ($process.ExitCode -ne 0) { throw "$Label failed: $($process.ExitCode)" }
}
function Assert-Preserved {
    foreach ($path in $sentinels) {
        if (-not (Test-Path $path) -or (Get-Content -Raw $path).Trim() -ne 'Hotaru installation preservation check') {
            throw 'Installation or uninstall removed user data'
        }
    }
}
function Assert-Version {
    $binary = Join-Path $destination 'Hotaru.exe'
    $version = (Get-Item $binary).VersionInfo.ProductVersion
    if ($version -notmatch ('^' + [regex]::Escape($ExpectedVersion) + '(?:[.+]|$)')) { throw "Unexpected installed version: $version" }
    foreach ($file in @('HotaruCore.exe','HotaruHelperService.exe')) {
        if (-not (Test-Path (Join-Path $destination $file))) { throw "Missing installed component: $file" }
    }
    Assert-Preserved
}
function Invoke-Uninstall {
    $uninstaller = Join-Path $destination 'unins000.exe'
    if (-not (Test-Path $uninstaller)) { throw 'Uninstaller missing' }
    $process = Start-Process $uninstaller -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART' -Wait -PassThru
    if ($process.ExitCode -ne 0) { throw "Uninstall failed: $($process.ExitCode)" }
    Assert-Preserved
}
try {
    & gh release download v0.0.5 --repo kurumiZafkiel12/Hotaru --pattern 'Hotaru-0.0.5-windows-amd64-setup.exe' --pattern SHA256SUMS --dir $work
    if ($LASTEXITCODE -ne 0) { throw 'Previous release download failed' }
    $previous = Join-Path $work 'Hotaru-0.0.5-windows-amd64-setup.exe'
    $hash = (Get-FileHash $previous -Algorithm SHA256).Hash.ToLowerInvariant()
    if (-not ((Get-Content (Join-Path $work 'SHA256SUMS')) | Where-Object { $_ -match "^$hash\s+\*?(?:\./)?Hotaru-0\.0\.5-windows-amd64-setup\.exe$" })) {
        throw 'Previous installer does not match published SHA256SUMS'
    }
    Invoke-Installer $previous 'previous-install'
    Assert-Preserved
    Invoke-Installer $setup[0].FullName 'upgrade'
    Assert-Version
    Invoke-Installer $setup[0].FullName 'repeat-install'
    Assert-Version
    Invoke-Uninstall
    Invoke-Installer $setup[0].FullName 'fresh-install'
    Assert-Version
    Invoke-Uninstall
    $report = [ordered]@{
        source_sha=$env:GITHUB_SHA; version=$ExpectedVersion;
        setup_sha256=(Get-FileHash $setup[0].FullName -Algorithm SHA256).Hash;
        upgrade_from='0.0.5'; repeat_install=$true; fresh_install=$true; silent_uninstall_preserves_data=$true;
        scope='Actual installer lifecycle on isolated Windows; application not launched for connected proxy or TUN testing'
    }
    $report | ConvertTo-Json | Set-Content (Join-Path $reportDirectory 'result.json')
    Write-Host "::notice title=Windows installation verification::$($report | ConvertTo-Json -Compress)"
} finally {
    foreach ($path in $sentinels) { Remove-Item $path -ErrorAction SilentlyContinue }
}
