param([Parameter(Mandatory = $true)][string]$Bundle)
$ErrorActionPreference = 'Stop'
if (-not $IsWindows -or $env:CI -ne 'true') { throw 'Disposable Windows CI only' }
$binary = Join-Path $Bundle 'HotaruCore.exe'
$helper = Join-Path $Bundle 'HotaruHelperService.exe'
. "$PSScriptRoot/sing_box_helper_probe.ps1" -Binary $binary -DefinitionsOnly
if (Get-Service -ErrorAction Stop | Where-Object Name -eq 'HotaruHelperService') {
  throw 'An existing Helper service must not be replaced'
}
if (Get-NetRoute -ErrorAction Stop | Where-Object DestinationPrefix -eq '198.18.8.0/30') {
  throw 'Test subnet already has a route'
}
$baseline = Snapshot
$fixture = [HotaruProxyFixture]::new(600000)
$fixture.Release()
$ruleFixture = [HotaruProxyFixture]::new(600000)
$ruleFixture.Release()
$tunName = 'HotaruFlutter_' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
$installed = $false
$resultPath = Join-Path $Bundle 'native-result.json'
try {
  $installed = $true
  $installer = Start-Process $helper -ArgumentList @('install', '--owner-pid', $PID) -PassThru -Wait
  if ($installer.ExitCode -ne 0) { throw 'Disposable Helper installation failed' }
  $env:HOTARU_NATIVE_HELPER_BUNDLE = $Bundle
  $env:HOTARU_NATIVE_PROXY_PORT = [string]$fixture.Port
  $env:HOTARU_NATIVE_RULE_PROXY_PORT = [string]$ruleFixture.Port
  $env:HOTARU_NATIVE_MIXED_PORT = [string][HotaruPipeProbe]::FreePort()
  $env:HOTARU_NATIVE_API_PORT = [string][HotaruPipeProbe]::FreePort()
  $env:HOTARU_NATIVE_TUN_NAME = $tunName
  $env:HOTARU_NATIVE_HELPER_RESULT = $resultPath
  flutter test test/core/sing_box/helper_native_test.dart --reporter expanded
  if ($LASTEXITCODE -ne 0) { throw 'Native Flutter Helper integration failed' }
  $report = Get-Content -Raw $resultPath | ConvertFrom-Json
  foreach ($field in @('native_ipc', 'configuration_preflight', 'configuration_replacement', 'route_preview_committed_ir', 'route_preview_no_dial', 'route_preview_recovered_configuration', 'node_http_recovered_configuration', 'node_http_factory_recovered_configuration', 'ui_controller_selection_and_modes', 'ui_route_epoch_recovered', 'ui_traffic_rate_and_local_reset', 'native_closed_telemetry', 'profile_traffic_final_persisted', 'failed_activation_restored', 'restored_configuration_payload', 'oversized_config_keeps_session', 'unacknowledged_warning_keeps_session', 'provider_import', 'rule_provider_import', 'ip_rule_provider_import', 'ip_no_resolve_literal_receipt', 'ip_no_resolve_domain_skipped_dns', 'failed_rule_provider_keeps_session', 'failed_provider_keeps_session', 'helper_system', 'tun_payload', 'tun_dns_receipt', 'restart', 'terminal_close', 'digest_mismatch_refused')) {
    if ($report.$field -ne $true) { throw "Missing native proof: $field" }
  }
  if (-not $fixture.Run.Wait(10000)) { throw 'Proxy fixture did not finish' }
  $fixture.Run.GetAwaiter().GetResult()
  if ($fixture.Target.Task.GetAwaiter().GetResult() -ne 'CONNECT 198.18.8.2:80 HTTP/1.1') {
    throw 'Independent native TUN proxy receipt mismatch'
  }
  if (-not $ruleFixture.Run.Wait(10000)) { throw 'Rule proxy fixture did not finish' }
  $ruleFixture.Run.GetAwaiter().GetResult()
  if ($ruleFixture.Target.Task.GetAwaiter().GetResult() -ne 'CONNECT rule-fixture.invalid:80 HTTP/1.1') {
    throw 'Independent rule-set proxy receipt mismatch'
  }
  Assert-NoTun $tunName
  if ((Snapshot) -ne $baseline) { throw 'Native client changed DNS, system proxy or default routes' }
  Write-Output ($report | ConvertTo-Json -Compress)
} finally {
  $fixture.Dispose()
  $ruleFixture.Dispose()
  if ($installed) {
    $uninstall = Start-Process $helper -ArgumentList 'uninstall' -PassThru -Wait
    if ($uninstall.ExitCode -ne 0) { throw 'Owned Helper uninstall failed' }
  }
  foreach ($key in @('HELPER_BUNDLE', 'PROXY_PORT', 'RULE_PROXY_PORT', 'MIXED_PORT', 'API_PORT', 'TUN_NAME', 'HELPER_RESULT')) {
    Remove-Item "Env:HOTARU_NATIVE_$key" -ErrorAction SilentlyContinue
  }
}
