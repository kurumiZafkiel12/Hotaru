param([Parameter(Mandatory=$true)][string]$Guardian)
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true') { throw 'Registry smoke test requires isolated CI account' }
$key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Internet Settings',$true)
$saved = @{}
foreach ($name in @('ProxyEnable','ProxyServer','ProxyOverride')) {
  $exists = $key.GetValueNames() -contains $name
  $saved[$name] = @{exists=$exists;value=$key.GetValue($name);kind=if ($exists) {$key.GetValueKind($name)} else {$null}}
}
$children = @()
function Set-Baseline {
  $key.SetValue('ProxyEnable',0,[Microsoft.Win32.RegistryValueKind]::DWord)
  $key.SetValue('ProxyServer','previous.example:8080')
  $key.SetValue('ProxyOverride','previous-bypass')
}
function Set-Owned {
  $key.SetValue('ProxyServer','127.0.0.1:17890')
  $key.SetValue('ProxyEnable',1,[Microsoft.Win32.RegistryValueKind]::DWord)
  $key.SetValue('ProxyOverride','hotaru-bypass')
}
function Wait-Value([string]$Expected) {
  $until = [DateTime]::UtcNow.AddSeconds(8)
  while ([DateTime]::UtcNow -lt $until) {
    if ($key.GetValue('ProxyServer') -eq $Expected) { return }
    Start-Sleep -Milliseconds 50
  }
  throw "Guardian did not restore $Expected"
}
try {
  foreach ($scenario in @('parent-crash','normal-stop','foreign-change','cancel','absent-values')) {
    Set-Baseline
    if ($scenario -eq 'absent-values') {
      foreach ($name in @('ProxyEnable','ProxyServer','ProxyOverride')) { $key.DeleteValue($name,$false) }
    }
    $parent = Start-Process powershell.exe -ArgumentList '-NoProfile -NonInteractive -Command "Start-Sleep -Seconds 120"' -WindowStyle Hidden -PassThru
    $children += $parent
    $token = [guid]::NewGuid().ToString('N')
    & $Guardian arm $token $parent.Id $parent.Id '127.0.0.1:17890'
    if ($LASTEXITCODE -ne 0) { throw 'Guardian failed to arm' }
    Set-Owned
    $done = [Threading.EventWaitHandle]::OpenExisting("Local\HotaruGuard-$token-done")
    if ($scenario -eq 'cancel') {
      & $Guardian cancel $token
      if ($LASTEXITCODE -ne 0 -or $key.GetValue('ProxyServer') -ne '127.0.0.1:17890') { throw 'Cancel changed proxy' }
    } else {
      if ($scenario -eq 'foreign-change') { $key.SetValue('ProxyServer','foreign.example:9090') }
      if ($scenario -eq 'normal-stop') {
        $restore = [Threading.EventWaitHandle]::OpenExisting("Local\HotaruGuard-$token-restore")
        $restore.Set() | Out-Null
        $restore.Dispose()
      } else { $parent.Kill() }
      if (-not $done.WaitOne(8000)) { throw 'Guardian completion timeout' }
      if ($scenario -eq 'absent-values') {
        foreach ($name in @('ProxyEnable','ProxyServer','ProxyOverride')) {
          if ($key.GetValueNames() -contains $name) { throw "Guardian materialized $name" }
        }
      } elseif ($scenario -eq 'foreign-change') {
        Wait-Value 'foreign.example:9090'
      } else {
        Wait-Value 'previous.example:8080'
        if ($key.GetValue('ProxyEnable') -ne 0 -or $key.GetValue('ProxyOverride') -ne 'previous-bypass') { throw 'Incomplete snapshot restoration' }
      }
    }
    $done.Dispose()
    if (-not $parent.HasExited) { $parent.Kill() }
    Write-Output "PASS: guardian $scenario"
  }
} finally {
  foreach ($child in $children) { if (-not $child.HasExited) { $child.Kill() }; $child.Dispose() }
  foreach ($name in $saved.Keys) {
    $value=$saved[$name]
    if ($value.exists) { $key.SetValue($name,$value.value,$value.kind) } else { $key.DeleteValue($name,$false) }
  }
  $key.Dispose()
}
