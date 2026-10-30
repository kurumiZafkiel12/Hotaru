$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class HotaruWindowCapture {
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr window, out Rect rect);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr window, int command);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr window);
}
'@
function Get-ProxyState {
    if (-not (Test-Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings')) { return 'missing' }
    $values = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    return [ordered]@{ Enabled=$values.ProxyEnable; Server=$values.ProxyServer; Pac=$values.AutoConfigURL } | ConvertTo-Json -Compress
}
$before = Get-ProxyState
$binary = Join-Path $PWD 'build/windows/x64/runner/Debug/Hotaru.exe'
$ownedProcess = $null
New-Item -ItemType Directory -Force 'native-ui/windows' | Out-Null
try {
    $ownedProcess = Start-Process -FilePath $binary -WorkingDirectory (Split-Path $binary) -PassThru
    Write-Host "Safe UI owned PID: $($ownedProcess.Id)"
    $window = [IntPtr]::Zero
    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        Start-Sleep -Milliseconds 500
        $ownedProcess.Refresh()
        if ($ownedProcess.HasExited) { throw "Safe UI exited: $($ownedProcess.ExitCode)" }
        $window = $ownedProcess.MainWindowHandle
        if ($window -ne [IntPtr]::Zero) { break }
    }
    if ($window -eq [IntPtr]::Zero) { throw 'Safe UI window unavailable' }
    [HotaruWindowCapture]::ShowWindow($window, 9) | Out-Null
    [HotaruWindowCapture]::SetForegroundWindow($window) | Out-Null
    Start-Sleep -Seconds 8
    if ([HotaruWindowCapture]::GetForegroundWindow() -ne $window) { throw 'Could not foreground the owned safe UI window' }
    $rect = New-Object HotaruWindowCapture+Rect
    if (-not [HotaruWindowCapture]::GetWindowRect($window, [ref]$rect)) { throw 'Safe UI bounds unavailable' }
    $width = $rect.Right - $rect.Left
    $height = $rect.Bottom - $rect.Top
    if ($width -lt 100 -or $height -lt 100) { throw 'Invalid safe UI dimensions' }
    $image = New-Object System.Drawing.Bitmap($width, $height)
    $graphics = [System.Drawing.Graphics]::FromImage($image)
    try {
        $graphics.CopyFromScreen($rect.Left, $rect.Top, 0, 0, $image.Size)
        $image.Save((Join-Path $PWD 'native-ui/windows/safe-window.png'), [System.Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $graphics.Dispose()
        $image.Dispose()
    }
    if ((Get-ProxyState) -ne $before) { throw 'Safe UI changed system proxy settings' }
    $result = [ordered]@{
        source_sha=$env:GITHUB_SHA; safe_mode_build=$true; owned_pid=$ownedProcess.Id;
        window_width=$width; window_height=$height; dpi=[HotaruWindowCapture]::GetDpiForWindow($window);
        system_proxy_unchanged=$true; scope='Actual Windows app in SAFE_MODE; no connected-node or performance acceptance'
    }
    $result | ConvertTo-Json | Set-Content 'native-ui/windows/result.json'
    Write-Host "::notice title=Native Windows safe UI::$($result | ConvertTo-Json -Compress)"
} finally {
    if ($null -ne $ownedProcess) {
        $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$($ownedProcess.Id)")
        foreach ($child in $children) { Write-Host "Safe UI owned child PID: $($child.ProcessId)" }
        if (-not $ownedProcess.HasExited) { Stop-Process -Id $ownedProcess.Id }
        foreach ($child in $children) {
            $live = Get-CimInstance Win32_Process -Filter "ProcessId=$($child.ProcessId)"
            if ($null -ne $live -and $live.CreationDate -eq $child.CreationDate) { Stop-Process -Id $child.ProcessId -ErrorAction SilentlyContinue }
        }
    }
}
