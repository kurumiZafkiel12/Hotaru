param([Parameter(Mandatory=$true)][string]$Core)
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true') { throw 'Isolated CI only' }
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.IO.Pipes;
using System.Diagnostics;
using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
public sealed class HotaruCoreSmoke : IDisposable {
  public NamedPipeServerStream Pipe;
  public Process Child;
  public HotaruCoreSmoke(string exe, string name) {
    Pipe = new NamedPipeServerStream(name, PipeDirection.InOut, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous);
    var wait = Pipe.WaitForConnectionAsync();
    Child = Process.Start(new ProcessStartInfo(exe, "\\\\.\\pipe\\" + name) { UseShellExecute=false, CreateNoWindow=true });
    if (!wait.Wait(15000)) throw new Exception("Core IPC connect timeout");
  }
  byte[] Read(int length) {
    var data = new byte[length]; int offset=0;
    using (var timeout = new CancellationTokenSource(30000)) {
      while (offset<length) {
        int count = Pipe.ReadAsync(data, offset, length-offset, timeout.Token).GetAwaiter().GetResult();
        if (count==0) throw new EndOfStreamException();
        offset+=count;
      }
    }
    return data;
  }
  public void Send(string json) {
    var data=Encoding.UTF8.GetBytes(json); var size=BitConverter.GetBytes(data.Length);
    Pipe.Write(size,0,4); Pipe.Write(data,0,data.Length); Pipe.Flush();
  }
  public string Receive() {
    int size=BitConverter.ToInt32(Read(4),0);
    if (size<0 || size>67108864) throw new Exception("Invalid frame size");
    return Encoding.UTF8.GetString(Read(size));
  }
  public void Dispose() {
    Pipe.Dispose();
    if (!Child.WaitForExit(10000)) { Child.Kill(); throw new Exception("Core survived host disconnect"); }
    Child.Dispose();
  }
  public static int FreePort() {
    var listener=new TcpListener(IPAddress.Loopback,0); listener.Start();
    int port=((IPEndPoint)listener.LocalEndpoint).Port; listener.Stop(); return port;
  }
}
public sealed class HotaruHttpFixture : IDisposable {
  public HttpListener Listener = new HttpListener();
  public ManualResetEventSlim Received = new ManualResetEventSlim(false);
  public ManualResetEventSlim Release = new ManualResetEventSlim(false);
  public Task Response;
  public HotaruHttpFixture(int port) {
    Listener.Prefixes.Add("http://127.0.0.1:"+port+"/"); Listener.Start();
    Response=Task.Run(async () => {
      var context=await Listener.GetContextAsync(); Received.Set();
      if (!Release.Wait(30000)) throw new Exception("Response release timeout");
      var bytes=Encoding.UTF8.GetBytes("hotaru-proxy-chain-ok");
      context.Response.ContentLength64=bytes.Length;
      await context.Response.OutputStream.WriteAsync(bytes,0,bytes.Length); context.Response.Close();
    });
  }
  public Task<string> Fetch(int proxyPort,int targetPort) {
    return Task.Run(async () => {
      using(var handler=new HttpClientHandler { Proxy=new WebProxy("http://127.0.0.1:"+proxyPort,false), UseProxy=true })
      using(var client=new HttpClient(handler) { Timeout=TimeSpan.FromSeconds(30) })
        return await client.GetStringAsync("http://127.0.0.1:"+targetPort+"/");
    });
  }
  public void Dispose() { Release.Set(); Listener.Close(); Received.Dispose(); }
}
'@
function Invoke-Core($Client, [string]$Method, $Arguments) {
  $id = [guid]::NewGuid().ToString('N')
  $Client.Send((@{id=$id;method=$Method;arguments=$Arguments} | ConvertTo-Json -Depth 40 -Compress))
  for ($i=0; $i -lt 200; $i++) {
    $response = $Client.Receive() | ConvertFrom-Json
    if ($response.id -eq $id) {
      if ($response.error) { throw ($response.error | ConvertTo-Json -Compress) }
      return $response.result
    }
  }
  throw 'RPC response missing'
}
$root = Join-Path $env:RUNNER_TEMP ('core-smoke-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $root -Force | Out-Null
$ports = @([HotaruCoreSmoke]::FreePort(),[HotaruCoreSmoke]::FreePort(),[HotaruCoreSmoke]::FreePort())
if (($ports | Select-Object -Unique).Count -ne 3) { throw 'Port collision' }
$clients = @()
$fixture = [HotaruHttpFixture]::new($ports[2])
try {
  foreach ($index in 0..1) {
    $home = Join-Path $root "$index"
    New-Item -ItemType Directory $home | Out-Null
    $config = @{'mixed-port'=$ports[$index];'allow-lan'=$false;mode='rule';dns=@{enable=$false};tun=@{enable=$false};rules=@('MATCH,DIRECT')}
    if ($index -eq 1) {
      $config.proxies = @(@{name='HOP';type='socks5';server='127.0.0.1';port=$ports[0]})
      $config.rules = @('MATCH,HOP')
    }
    $config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath "$home/config.yaml" -Encoding utf8
    $client = [HotaruCoreSmoke]::new($Core, ('HotaruSmoke_'+[guid]::NewGuid().ToString('N')))
    $clients += $client
    if (-not (Invoke-Core $client 'initClash' @{'home-dir'=$home;version=1})) { throw 'Core init failed' }
    $setup = Invoke-Core $client 'setupConfig' @{'selected-map'=@{};'test-url'='http://127.0.0.1/'}
    if ($setup) { throw "Config apply: $setup" }
    if (-not (Invoke-Core $client 'startListener' $null)) { throw 'Listener start failed' }
  }
  $fetch = $fixture.Fetch($ports[1],$ports[2])
  if (-not $fixture.Received.Wait(20000)) { throw 'Proxied HTTP did not arrive' }
  $connections = Invoke-Core $clients[1] 'getConnections' $null
  if (($connections | ConvertTo-Json -Depth 40 -Compress) -notmatch 'HOP') { throw 'Proxy chain evidence missing' }
  $fixture.Release.Set()
  if ($fetch.GetAwaiter().GetResult() -ne 'hotaru-proxy-chain-ok') { throw 'Unexpected HTTP response' }
  Write-Output 'PASS: two bundled cores, named-pipe RPC, SOCKS hop, actual HTTP, connection chain'
} finally {
  $fixture.Dispose()
  foreach ($client in $clients) { $client.Dispose() }
}
foreach ($port in $ports[0..1]) {
  $tcp = [Net.Sockets.TcpClient]::new()
  try { $tcp.Connect('127.0.0.1',$port); throw 'Core port survived IPC disconnect' }
  catch [Net.Sockets.SocketException] { }
  finally { $tcp.Dispose() }
}
