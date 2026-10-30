$ErrorActionPreference = 'Stop'
$binary = Join-Path $PWD 'build/windows/x64/runner/Debug/Hotaru.exe'
if (-not (Test-Path $binary)) { throw 'Native ICE executable absent' }
$report = Join-Path $env:RUNNER_TEMP 'hotaru-native-ice.json'
Remove-Item $report -ErrorAction SilentlyContinue
$previousReport = $env:HOTARU_NATIVE_ICE_REPORT
$env:HOTARU_NATIVE_ICE_REPORT = $report
$ownedProcess = $null
try {
    $ownedProcess = Start-Process -FilePath $binary -WorkingDirectory (Split-Path $binary) -PassThru
    Write-Host "Native ICE harness owned PID: $($ownedProcess.Id)"
    for ($attempt = 0; $attempt -lt 90 -and -not (Test-Path $report); $attempt++) {
        Start-Sleep -Milliseconds 500
        $ownedProcess.Refresh()
        if ($ownedProcess.HasExited) { throw "Native ICE harness exited: $($ownedProcess.ExitCode)" }
    }
    if (-not (Test-Path $report)) { throw 'Native ICE harness result timed out' }
    $result = Get-Content -Raw $report | ConvertFrom-Json
    New-Item -ItemType Directory -Force 'native-ice/windows' | Out-Null
    Copy-Item $report 'native-ice/windows/result.json'
    if ($result.source_sha -ne $env:GITHUB_SHA) { throw 'Native ICE source mismatch' }
    if (-not $result.safe_mode -or -not $result.plugin_started) { throw 'Native ICE plugin did not gather actual candidates' }
    if ($result.verdict_without_expected_exit -ne 'inconclusive') { throw 'Native ICE without expected exit incorrectly reported safety' }
    Write-Host "::notice title=Native Windows ICE::$((Get-Content -Raw $report).Trim())"
} finally {
    $env:HOTARU_NATIVE_ICE_REPORT = $previousReport
    if ($null -ne $ownedProcess -and -not $ownedProcess.HasExited) {
        Stop-Process -Id $ownedProcess.Id
    }
}
