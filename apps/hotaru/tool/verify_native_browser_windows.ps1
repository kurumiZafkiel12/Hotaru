$ErrorActionPreference = 'Stop'
$binary = Join-Path $PWD 'build/windows/x64/runner/Debug/Hotaru.exe'
if (-not (Test-Path $binary)) { throw 'Browser diagnostic harness absent' }
$report = Join-Path $env:RUNNER_TEMP 'hotaru-native-browser.json'
Remove-Item $report -ErrorAction SilentlyContinue
$previousReport = $env:HOTARU_NATIVE_BROWSER_REPORT
$env:HOTARU_NATIVE_BROWSER_REPORT = $report
$ownedProcess = $null
try {
    $ownedProcess = Start-Process -FilePath $binary -WorkingDirectory (Split-Path $binary) -PassThru
    Write-Host "Browser diagnostic harness owned PID: $($ownedProcess.Id)"
    for ($attempt = 0; $attempt -lt 500 -and -not (Test-Path $report); $attempt++) {
        Start-Sleep -Milliseconds 500
        $ownedProcess.Refresh()
        if ($ownedProcess.HasExited) { throw "Browser diagnostic harness exited: $($ownedProcess.ExitCode)" }
    }
    if (-not (Test-Path $report)) { throw 'Browser diagnostic harness timed out' }
    $result = Get-Content -Raw $report | ConvertFrom-Json
    New-Item -ItemType Directory -Force 'native-browser/windows' | Out-Null
    Copy-Item $report 'native-browser/windows/result.json'
    Write-Host "::notice title=Native Windows BrowserLeaks::$((Get-Content -Raw $report).Trim())"
    if ($result.source_sha -ne $env:GITHUB_SHA -or -not $result.safe_mode) { throw 'Browser harness source or safe-mode mismatch' }
    $dns = $result.results | Where-Object kind -eq 'dns'
    $rtc = $result.results | Where-Object kind -eq 'webrtc'
    if (-not $dns.completed -or $dns.resolver_count -lt 1) { throw 'Actual DNS resolver detection did not complete' }
    if (-not $rtc.completed -or -not $rtc.rtc_supported -or $rtc.remote_count -lt 1) { throw 'Actual WebRTC detection did not complete' }
} finally {
    $env:HOTARU_NATIVE_BROWSER_REPORT = $previousReport
    if ($null -ne $ownedProcess -and -not $ownedProcess.HasExited) { Stop-Process -Id $ownedProcess.Id }
}
