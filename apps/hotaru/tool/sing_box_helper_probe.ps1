param(
  [Parameter(Mandatory = $true)][string]$Binary,
  [string]$HelperPath,
  [switch]$DefinitionsOnly
)
$ErrorActionPreference = 'Stop'
if (-not $IsWindows -or $env:CI -ne 'true') { throw 'Disposable Windows CI only' }

Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.IO.Pipes;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
public static class HotaruPipeProbe {
  [DllImport("kernel32.dll", SetLastError=true)]
  public static extern bool GetNamedPipeClientProcessId(IntPtr pipe, out uint pid);
  static async Task<byte[]> Exact(Stream stream, int length, CancellationToken token) {
    byte[] bytes = new byte[length]; int offset = 0;
    while (offset < length) {
      int count = await stream.ReadAsync(bytes, offset, length-offset, token);
      if (count == 0) throw new EndOfStreamException();
      offset += count;
    }
    return bytes;
  }
  public static async Task<string> ReadFrame(Stream stream) {
    using (var timeout = new CancellationTokenSource(10000)) {
      byte[] header = await Exact(stream, 4, timeout.Token);
      uint size = BitConverter.ToUInt32(header, 0);
      if (size == 0 || size > 16*1024*1024) throw new InvalidDataException();
      return Encoding.UTF8.GetString(await Exact(stream, (int)size, timeout.Token));
    }
  }
  public static async Task WriteFrame(Stream stream, string text) {
    using (var timeout = new CancellationTokenSource(10000)) {
      byte[] payload = Encoding.UTF8.GetBytes(text);
      byte[] header = BitConverter.GetBytes((uint)payload.Length);
      await stream.WriteAsync(header, 0, 4, timeout.Token);
      await stream.WriteAsync(payload, 0, payload.Length, timeout.Token);
      await stream.FlushAsync(timeout.Token);
    }
  }
  public static async Task ExpectEof(Stream stream) {
    using (var timeout = new CancellationTokenSource(10000)) {
      if (await stream.ReadAsync(new byte[1], 0, 1, timeout.Token) != 0)
        throw new InvalidDataException("Trailing host output");
    }
  }
  public static int FreePort() {
    var listener = new TcpListener(IPAddress.Loopback, 0);
    listener.Start(); int port = ((IPEndPoint)listener.LocalEndpoint).Port;
    listener.Stop(); return port;
  }
}
public sealed class HotaruProxyFixture : IDisposable {
  readonly TcpListener listener = new TcpListener(IPAddress.Loopback, 0);
  readonly CancellationTokenSource timeout;
  readonly TaskCompletionSource<bool> release = new TaskCompletionSource<bool>();
  public readonly TaskCompletionSource<string> Target = new TaskCompletionSource<string>();
  public Task Run;
  public int Port { get { return ((IPEndPoint)listener.LocalEndpoint).Port; } }
  public HotaruProxyFixture() : this(30000) { }
  public HotaruProxyFixture(int milliseconds) {
    timeout = new CancellationTokenSource(milliseconds);
    listener.Start(); Run = Serve();
  }
  static async Task<string> Header(NetworkStream stream, CancellationToken token) {
    var text = new StringBuilder(); byte[] b = new byte[1];
    while (text.Length < 8192) {
      if (await stream.ReadAsync(b, 0, 1, token) == 0) throw new EndOfStreamException();
      text.Append((char)b[0]);
      if (text.ToString().EndsWith("\r\n\r\n")) return text.ToString();
    }
    throw new InvalidDataException("Oversized fixture header");
  }
  async Task Serve() {
    using (TcpClient client = await listener.AcceptTcpClientAsync(timeout.Token)) {
      NetworkStream stream = client.GetStream();
      string header = await Header(stream, timeout.Token);
      Target.TrySetResult(header.Split('\r')[0]);
      byte[] response = Encoding.ASCII.GetBytes("HTTP/1.1 200 Connection Established\r\n\r\n");
      await stream.WriteAsync(response, 0, response.Length, timeout.Token);
      await Header(stream, timeout.Token);
      response = Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Length: 16\r\nConnection: close\r\n\r\nh");
      await stream.WriteAsync(response, 0, response.Length, timeout.Token);
      await release.Task.WaitAsync(timeout.Token);
      response = Encoding.ASCII.GetBytes("elper-tun-proof");
      await stream.WriteAsync(response, 0, response.Length, timeout.Token);
    }
  }
  public void Release() { release.TrySetResult(true); }
  public void Dispose() { Release(); timeout.Cancel(); listener.Stop(); timeout.Dispose(); }
}
'@

function Snapshot {
  $defaults = @(Get-NetRoute -ErrorAction Stop | Where-Object { $_.DestinationPrefix -in @('0.0.0.0/0', '::/0') } |
    Sort-Object InterfaceIndex, DestinationPrefix, NextHop | Select-Object InterfaceIndex, DestinationPrefix, NextHop, RouteMetric)
  $dns = @(Get-DnsClientServerAddress -ErrorAction Stop | Sort-Object InterfaceIndex, AddressFamily |
    Select-Object InterfaceIndex, AddressFamily, ServerAddresses)
  $proxy = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
  return (@{ routes = $defaults; dns = $dns; proxy = @($proxy.ProxyEnable, $proxy.ProxyServer, $proxy.AutoConfigURL) } |
    ConvertTo-Json -Depth 12 -Compress)
}
function Assert-NoTun([string]$name) {
  for ($attempt = 0; $attempt -lt 100; $attempt++) {
    $adapters = @(Get-NetAdapter -IncludeHidden -ErrorAction Stop | Where-Object Name -eq $name)
    $addresses = @(Get-NetIPAddress -ErrorAction Stop | Where-Object InterfaceAlias -eq $name)
    $routes = @(Get-NetRoute -ErrorAction Stop | Where-Object DestinationPrefix -eq '198.18.8.0/30')
    if ($adapters.Count -eq 0 -and $addresses.Count -eq 0 -and $routes.Count -eq 0) { return }
    Start-Sleep -Milliseconds 100
  }
  throw 'Owned TUN resources remain after exit'
}

if ($DefinitionsOnly) { return }

$baseline = Snapshot
$pipeName = 'HotaruCore_' + [Guid]::NewGuid().ToString('N')
$tunName = 'HotaruHelper_' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
$stream = [IO.Pipes.NamedPipeServerStream]::new($pipeName, [IO.Pipes.PipeDirection]::InOut, 1,
  [IO.Pipes.PipeTransmissionMode]::Byte, [IO.Pipes.PipeOptions]::Asynchronous)
$handler = [Net.Http.HttpClientHandler]::new()
$handler.UseProxy = $false
$http = [Net.Http.HttpClient]::new($handler)
$http.Timeout = [TimeSpan]::FromSeconds(10)
$fixture = [HotaruProxyFixture]::new()
$ownedProcess = $null
$installed = $false
$helperUrl = $null
$session = [Guid]::NewGuid().ToString('N')
$mixedPort = [HotaruPipeProbe]::FreePort()
$controllerPort = [HotaruPipeProbe]::FreePort()
if ($mixedPort -eq $controllerPort) { throw 'Fixture port collision' }
$secret = [Guid]::NewGuid().ToString('N')
function Helper-Post([string]$path, $body) {
  $content = [Net.Http.StringContent]::new(($body | ConvertTo-Json -Compress), [Text.Encoding]::UTF8, 'application/json')
  try {
    $response = $http.PostAsync("$helperUrl/$path", $content).GetAwaiter().GetResult()
    $response.EnsureSuccessStatusCode() | Out-Null
    return ($response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json)
  } finally { $content.Dispose() }
}
try {
  $accept = $stream.WaitForConnectionAsync()
  if ($HelperPath) {
    if (Get-Service HotaruHelperService -ErrorAction SilentlyContinue) { throw 'Existing Helper service must not be replaced by probe' }
    $installed = $true
    $install = Start-Process $HelperPath -ArgumentList @('install', '--owner-pid', $PID) -PassThru -Wait
    if ($install.ExitCode -ne 0) { throw 'Disposable Helper install failed' }
    $port = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\HotaruHelperService\Runtime').Port
    $helperUrl = "http://127.0.0.1:$port"
    $sha = (Get-FileHash $Binary -Algorithm SHA256).Hash.ToLowerInvariant()
    $ping = $http.GetAsync("$helperUrl/ping?coreSha256=$sha").GetAwaiter().GetResult()
    $ping.EnsureSuccessStatusCode() | Out-Null
    $response = Helper-Post 'start' @{ address = "\\.\pipe\$pipeName"; sessionId = $session }
    $ownedPid = [int]$response.pid
    if ($response.sessionId -ne $session) { throw 'Helper session mismatch' }
    $owner = Get-CimInstance Win32_Process -Filter "ProcessId=$ownedPid" | Invoke-CimMethod -MethodName GetOwnerSid
    if ($owner.ReturnValue -ne 0 -or $owner.Sid -ne 'S-1-5-18') { throw 'Helper host is not running as SYSTEM' }
  } else {
    $ownedProcess = Start-Process $Binary -ArgumentList "\\.\pipe\$pipeName" -PassThru
    $ownedPid = $ownedProcess.Id
  }
  if (-not $accept.Wait(10000)) { throw 'Host did not connect to owned pipe' }
  $accept.GetAwaiter().GetResult()
  [uint32]$peerPid = 0
  if (-not [HotaruPipeProbe]::GetNamedPipeClientProcessId($stream.SafePipeHandle.DangerousGetHandle(), [ref]$peerPid) -or $peerPid -ne $ownedPid) {
    throw 'OS pipe peer PID does not match owned process'
  }
  $config = @{
    log = @{ level = 'error' }
    inbounds = @(
      @{ type = 'mixed'; tag = 'mixed'; listen = '127.0.0.1'; listen_port = $mixedPort },
      @{ type = 'tun'; tag = 'tun'; interface_name = $tunName; address = @('198.18.8.1/30'); auto_route = $false; stack = 'system' }
    )
    outbounds = @(@{ type = 'http'; tag = 'proof'; server = '127.0.0.1'; server_port = $fixture.Port })
    route = @{ final = 'proof' }
    experimental = @{ clash_api = @{ external_controller = "127.0.0.1:$controllerPort"; secret = $secret } }
  }
  [HotaruPipeProbe]::WriteFrame($stream, (@{ protocol = 'hotaru-bootstrap-v1'; config = $config } | ConvertTo-Json -Depth 20 -Compress)).GetAwaiter().GetResult()
  $ready = [HotaruPipeProbe]::ReadFrame($stream).GetAwaiter().GetResult() | ConvertFrom-Json
  if ($ready.event -ne 'ready' -or $ready.pid -ne $ownedPid -or $ready.protocol -ne 'hotaru-stdio-v1') { throw 'Invalid host readiness' }
  $http.DefaultRequestHeaders.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $secret)
  $apiUrl = "http://127.0.0.1:$controllerPort"
  $version = $http.GetStringAsync("$apiUrl/version").GetAwaiter().GetResult() | ConvertFrom-Json
  if ($version.version -ne 'sing-box 1.14.4') { throw 'Unexpected API version' }
  $transfer = $http.GetStringAsync('http://198.18.8.2/')
  for ($attempt = 0; $attempt -lt 100; $attempt++) {
    $connections = $http.GetStringAsync("$apiUrl/connections").GetAwaiter().GetResult() | ConvertFrom-Json
    $trace = @($connections.connections | Where-Object { $_.metadata.destinationIP -eq '198.18.8.2' })
    if ($trace.Count -eq 1 -and $trace[0].download -gt 0) { break }
    Start-Sleep -Milliseconds 50
  }
  if ($trace.Count -ne 1 -or $trace[0].metadata.type -ne 'tun/tun' -or $trace[0].chains -notcontains 'proof' -or $trace[0].download -le 0) {
    throw 'Actual Helper TUN path is absent from API trace'
  }
  if ($fixture.Target.Task.GetAwaiter().GetResult() -ne 'CONNECT 198.18.8.2:80 HTTP/1.1') { throw 'Independent proxy receipt mismatch' }
  $fixture.Release()
  if ($transfer.GetAwaiter().GetResult() -ne 'helper-tun-proof') { throw 'Wrong packet payload' }
  $fixture.Run.GetAwaiter().GetResult()
  [HotaruPipeProbe]::WriteFrame($stream, "stop`n").GetAwaiter().GetResult()
  $stopped = [HotaruPipeProbe]::ReadFrame($stream).GetAwaiter().GetResult() | ConvertFrom-Json
  if ($stopped.event -ne 'stopped' -or $stopped.clean -ne $true -or $stopped.pid -ne $ownedPid) { throw 'Cleanup not acknowledged' }
  [HotaruPipeProbe]::ExpectEof($stream).GetAwaiter().GetResult()
  $stream.Dispose()
  if ($HelperPath) {
    $stop = Helper-Post 'stop' @{ sessionId = $session }
    if ($stop.sessionId -ne $session -or $stop.stopped -ne $true) { throw 'Helper did not confirm process release' }
  } else {
    if (-not $ownedProcess.WaitForExit(10000) -or $ownedProcess.ExitCode -ne 0) { throw 'Host exit not confirmed' }
  }
  Assert-NoTun $tunName
  if ((Snapshot) -ne $baseline) { throw 'System proxy, DNS or default routes changed' }
  Write-Output (@{ pipe_pid_verified = $true; tun_data_path_verified = $true; cleanup_verified = $true; helper_scm = [bool]$HelperPath } | ConvertTo-Json -Compress)
} finally {
  $fixture.Dispose()
  $stream.Dispose()
  $http.DefaultRequestHeaders.Authorization = $null
  if ($helperUrl) { try { Helper-Post 'stop' @{ sessionId = $session } | Out-Null } catch { Write-Warning $_ } }
  if ($installed) {
    $uninstall = Start-Process $HelperPath -ArgumentList 'uninstall' -PassThru -Wait
    if ($uninstall.ExitCode -ne 0) { throw 'Owned Helper uninstall failed' }
  }
  if ($ownedProcess -and -not $ownedProcess.HasExited) { $ownedProcess.Kill(); $ownedProcess.WaitForExit() }
  $http.Dispose()
}
