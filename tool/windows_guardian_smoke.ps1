param([Parameter(Mandatory=$true)][string]$Guardian)
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true') { throw 'Registry smoke test requires isolated CI account' }
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class HotaruProxyFixture {
  [StructLayout(LayoutKind.Explicit, Size=16)] struct Option {
    [FieldOffset(0)] public uint Kind;
    [FieldOffset(8)] public uint Flags;
    [FieldOffset(8)] public IntPtr Text;
  }
  [StructLayout(LayoutKind.Sequential)] struct Options {
    public uint Size;
    public IntPtr Connection;
    public uint Count;
    public uint Error;
    public IntPtr Values;
  }
  [DllImport("wininet.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  static extern bool InternetSetOptionW(IntPtr session, uint option, ref Options value, uint size);
  [DllImport("wininet.dll", EntryPoint="InternetSetOptionW", SetLastError=true)]
  static extern bool Notify(IntPtr session, uint option, IntPtr value, uint size);
  public static void Set(uint flags, string server, string bypass) {
    var strings=new[] { Marshal.StringToHGlobalUni(server),Marshal.StringToHGlobalUni(bypass) };
    var buffer=Marshal.AllocHGlobal(48);
    try {
      Marshal.StructureToPtr(new Option { Kind=1, Flags=flags },buffer,false);
      Marshal.StructureToPtr(new Option { Kind=2, Text=strings[0] },IntPtr.Add(buffer,16),false);
      Marshal.StructureToPtr(new Option { Kind=3, Text=strings[1] },IntPtr.Add(buffer,32),false);
      var value=new Options { Size=(uint)Marshal.SizeOf<Options>(),Count=3,Values=buffer };
      if (!InternetSetOptionW(IntPtr.Zero,75,ref value,value.Size)) throw new Win32Exception();
      Notify(IntPtr.Zero,39,IntPtr.Zero,0); Notify(IntPtr.Zero,37,IntPtr.Zero,0);
    } finally { foreach(var ptr in strings) Marshal.FreeHGlobal(ptr); Marshal.FreeHGlobal(buffer); }
  }
}
'@
$key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Internet Settings',$true)
$saved = @{}
foreach ($name in @('ProxyEnable','ProxyServer','ProxyOverride')) {
  $exists = $key.GetValueNames() -contains $name
  $saved[$name] = @{exists=$exists;value=$key.GetValue($name);kind=if ($exists) {$key.GetValueKind($name)} else {$null}}
}
$children = @()
function Set-Baseline {
  [HotaruProxyFixture]::Set(1,'previous.example:8080','previous-bypass')
  $key.SetValue('ProxyEnable',0,[Microsoft.Win32.RegistryValueKind]::DWord)
  $key.SetValue('ProxyServer','previous.example:8080')
  $key.SetValue('ProxyOverride','previous-bypass')
}
function Set-Owned {
  [HotaruProxyFixture]::Set(3,'127.0.0.1:17890','hotaru-bypass')
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
      if ($scenario -eq 'foreign-change') { [HotaruProxyFixture]::Set(3,'foreign.example:9090','foreign-bypass') }
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
