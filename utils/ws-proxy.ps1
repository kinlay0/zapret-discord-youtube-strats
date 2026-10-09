param([switch]$Stop)
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$ListFile = Join-Path $Root 'lists\list-proxy.txt'
$LogFile = Join-Path $PSScriptRoot 'ws-proxy.log'
$RegPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'

function Fail([string]$msg) {
    Write-Host "ws-proxy: $msg" -ForegroundColor Red
    try { "$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) $msg" | Out-File $LogFile -Append -Encoding UTF8 } catch { }
    Read-Host 'Press Enter to close'
    exit 1
}
trap { Fail "$($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))" }

$cs = @'
using System;
using System.IO;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.Authentication;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

public class Ws
{
    Stream st;
    TcpClient tcp;
    byte[] pre = new byte[0];
    int preOff;
    SemaphoreSlim wl = new SemaphoreSlim(1, 1);
    static Random rnd = new Random();

    public static async Task<Ws> Connect(Uri u, string ip)
    {
        Ws w = new Ws();
        IPAddress[] addrs = ip != "" ? new[] { IPAddress.Parse(ip) } : await WsProxy.Timeout(Dns.GetHostAddressesAsync(u.Host), 8000, "DNS " + u.Host);
        Array.Sort(addrs, (a, b) => a.AddressFamily.CompareTo(b.AddressFamily));
        string errs = "";
        foreach (IPAddress a in addrs)
        {
            TcpClient c = new TcpClient(a.AddressFamily);
            try { await WsProxy.Timeout(c.ConnectAsync(a, u.Port), 7000, "TCP"); w.tcp = c; break; }
            catch (Exception e) { errs += " " + a + ": " + e.GetBaseException().Message + ";"; c.Close(); }
        }
        if (w.tcp == null) throw new Exception("TCP connect failed:" + errs);
        try
        {
            w.tcp.NoDelay = true;
            w.st = w.tcp.GetStream();
            if (u.Scheme == "wss")
            {
                SslStream ssl = new SslStream(w.st);
                await WsProxy.Timeout(ssl.AuthenticateAsClientAsync(u.Host, null, SslProtocols.Tls12, false), 10000, "TLS " + u.Host);
                w.st = ssl;
            }
            byte[] key = new byte[16];
            lock (rnd) rnd.NextBytes(key);
            await WsProxy.Write(w.st, "GET " + u.PathAndQuery + " HTTP/1.1\r\nHost: " + u.Host + "\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: " +
                Convert.ToBase64String(key) + "\r\nSec-WebSocket-Version: 13\r\n\r\n");
            byte[] hb = new byte[16384];
            int hl = await WsProxy.Timeout(WsProxy.ReadHeader(w.st, hb), 15000, "Server response");
            int he = WsProxy.HeaderEnd(hb, hl);
            string status = Encoding.ASCII.GetString(hb, 0, he).Split('\r')[0];
            if (!status.Contains(" 101"))
                throw new Exception("Server answered '" + status + "' " + Encoding.UTF8.GetString(hb, he, Math.Min(hl - he, 120)).Trim());
            w.pre = new byte[hl - he];
            Buffer.BlockCopy(hb, he, w.pre, 0, w.pre.Length);
            return w;
        }
        catch { w.Close(); throw; }
    }

    async Task Read(byte[] b, int len)
    {
        int off = 0;
        while (off < len)
        {
            int n;
            if (preOff < pre.Length)
            {
                n = Math.Min(len - off, pre.Length - preOff);
                Buffer.BlockCopy(pre, preOff, b, off, n);
                preOff += n;
            }
            else
            {
                n = await st.ReadAsync(b, off, len - off);
                if (n <= 0) throw new EndOfStreamException();
            }
            off += n;
        }
    }

    public async Task Send(byte[] data, int len, int op = 2)
    {
        int h = len < 126 ? 2 : len < 65536 ? 4 : 10;
        byte[] f = new byte[h + 4 + len];
        f[0] = (byte)(0x80 | op);
        if (h == 2) f[1] = (byte)(0x80 | len);
        else if (h == 4) { f[1] = 0x80 | 126; f[2] = (byte)(len >> 8); f[3] = (byte)len; }
        else { f[1] = 0x80 | 127; for (int i = 0; i < 4; i++) f[6 + i] = (byte)(len >> (24 - 8 * i)); }
        byte[] m = new byte[4];
        lock (rnd) rnd.NextBytes(m);
        Buffer.BlockCopy(m, 0, f, h, 4);
        for (int i = 0; i < len; i++) f[h + 4 + i] = (byte)(data[i] ^ m[i & 3]);
        await wl.WaitAsync();
        try { await st.WriteAsync(f, 0, f.Length); } finally { wl.Release(); }
    }

    public async Task ReceiveTo(Stream to)
    {
        byte[] h = new byte[8], m = new byte[4], buf = new byte[65536];
        while (true)
        {
            await Read(h, 2);
            int op = h[0] & 15;
            bool masked = (h[1] & 128) != 0;
            long len = h[1] & 127;
            if (len == 126) { await Read(h, 2); len = (h[0] << 8) | h[1]; }
            else if (len == 127) { await Read(h, 8); len = 0; for (int i = 0; i < 8; i++) len = (len << 8) | h[i]; }
            if (masked) await Read(m, 4);
            if (len > buf.Length) buf = new byte[len];
            int n = (int)len;
            await Read(buf, n);
            if (masked) for (int i = 0; i < n; i++) buf[i] ^= m[i & 3];
            if (op == 8) return;
            if (op == 9) await Send(buf, n, 10);
            else if (op != 10 && n > 0) await to.WriteAsync(buf, 0, n);
        }
    }

    public void Close()
    {
        try { if (st != null) st.Dispose(); } catch { }
        try { if (tcp != null) tcp.Close(); } catch { }
    }
}

public static class WsProxy
{
    public static string Url = "", Key = "", Ip = "", Pac = "";
    public static int Port = 1080;
    public static bool Verbose;
    public static string[] Domains = new string[0];

    [DllImport("wininet.dll")]
    static extern bool InternetSetOption(IntPtr h, int opt, IntPtr buf, int len);
    public static void RefreshProxy()
    {
        try { InternetSetOption(IntPtr.Zero, 39, IntPtr.Zero, 0); InternetSetOption(IntPtr.Zero, 37, IntPtr.Zero, 0); } catch { }
    }

    static void Log(string s) { Console.WriteLine(DateTime.Now.ToString("HH:mm:ss") + " " + s); }

    public static async Task<T> Timeout<T>(Task<T> t, int ms, string what)
    {
        if (await Task.WhenAny(t, Task.Delay(ms)) != t) throw new TimeoutException(what + " timeout");
        return await t;
    }
    public static async Task Timeout(Task t, int ms, string what)
    {
        if (await Task.WhenAny(t, Task.Delay(ms)) != t) throw new TimeoutException(what + " timeout");
        await t;
    }

    public static Task Write(Stream s, string text)
    {
        byte[] b = Encoding.ASCII.GetBytes(text);
        return s.WriteAsync(b, 0, b.Length);
    }

    public static int HeaderEnd(byte[] b, int len)
    {
        for (int i = 0; i + 3 < len; i++)
            if (b[i] == 13 && b[i + 1] == 10 && b[i + 2] == 13 && b[i + 3] == 10) return i + 4;
        return -1;
    }

    public static async Task<int> ReadHeader(Stream s, byte[] b)
    {
        int len = 0;
        while (HeaderEnd(b, len) < 0)
        {
            if (len == b.Length) throw new Exception("header too big");
            int n = await s.ReadAsync(b, len, b.Length - len);
            if (n <= 0) throw new EndOfStreamException();
            len += n;
        }
        return len;
    }

    static bool Match(string host)
    {
        host = host.ToLowerInvariant().TrimEnd('.');
        foreach (string d in Domains)
            if (host == d || host.EndsWith("." + d)) return true;
        return false;
    }

    static async Task Pump(Stream from, Stream to)
    {
        byte[] buf = new byte[65536];
        int n;
        while ((n = await from.ReadAsync(buf, 0, buf.Length)) > 0) await to.WriteAsync(buf, 0, n);
    }

    static async Task PumpWs(Stream from, Ws ws)
    {
        byte[] buf = new byte[65536];
        int n;
        while ((n = await from.ReadAsync(buf, 0, buf.Length)) > 0) await ws.Send(buf, n);
    }

    public static Task Run()
    {
        ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072;
        TcpListener l = new TcpListener(IPAddress.Loopback, Port);
        l.Start(512);
        return Accept(l);
    }

    static async Task Accept(TcpListener l)
    {
        while (true)
        {
            TcpClient c = await l.AcceptTcpClientAsync();
            Task t = Handle(c);
        }
    }

    static async Task Handle(TcpClient c)
    {
        string target = "?";
        bool connect = false, ok = false;
        Ws ws = null;
        TcpClient remote = null;
        NetworkStream ns = c.GetStream();
        try
        {
            byte[] hb = new byte[32768];
            int hl = await ReadHeader(ns, hb);
            int he = HeaderEnd(hb, hl);
            string[] rl = Encoding.ASCII.GetString(hb, 0, he).Split('\r')[0].Split(' ');
            if (rl.Length < 3) return;
            string host;
            int port;
            byte[] first;
            if (rl[0] == "CONNECT")
            {
                connect = true;
                int i = rl[1].LastIndexOf(':');
                host = rl[1].Substring(0, i).Trim('[', ']');
                port = int.Parse(rl[1].Substring(i + 1));
                first = new byte[hl - he];
                Buffer.BlockCopy(hb, he, first, 0, first.Length);
            }
            else if (rl[1].StartsWith("/"))
            {
                byte[] body = Encoding.UTF8.GetBytes(rl[1].StartsWith("/proxy.pac") ? Pac : "");
                await Write(ns, (body.Length > 0 ? "HTTP/1.1 200 OK\r\nContent-Type: application/x-ns-proxy-autoconfig" : "HTTP/1.1 404 Not Found") +
                    "\r\nCache-Control: no-cache\r\nConnection: close\r\nContent-Length: " + body.Length + "\r\n\r\n");
                await ns.WriteAsync(body, 0, body.Length);
                return;
            }
            else
            {
                Uri u = new Uri(rl[1]);
                host = u.Host.Trim('[', ']');
                port = u.Port;
                first = new byte[hl];
                Buffer.BlockCopy(hb, 0, first, 0, hl);
            }
            target = host + ":" + port;
            bool tun = Match(host);
            target = (tun ? "PRX  " : "DIR  ") + target;
            Stream rs = null;
            if (tun)
                ws = await Ws.Connect(new Uri(Url + (Url.Contains("?") ? "&" : "?") + "k=" + Uri.EscapeDataString(Key) +
                    "&h=" + Uri.EscapeDataString(host) + "&p=" + port), Ip);
            else
            {
                remote = new TcpClient();
                remote.NoDelay = true;
                await Timeout(remote.ConnectAsync(host, port), 15000, "connect");
                rs = remote.GetStream();
            }
            if (Verbose) Log(target);
            if (connect) await Write(ns, "HTTP/1.1 200 Connection Established\r\n\r\n");
            ok = true;
            if (tun)
            {
                if (first.Length > 0) await ws.Send(first, first.Length);
                await Task.WhenAny(PumpWs(ns, ws), ws.ReceiveTo(ns));
            }
            else
            {
                if (first.Length > 0) await rs.WriteAsync(first, 0, first.Length);
                await Task.WhenAny(Pump(ns, rs), Pump(rs, ns));
            }
        }
        catch (Exception e)
        {
            if (target != "?") Log("ERR  " + target + " : " + e.GetBaseException().Message);
            if (connect && !ok) try { ns.Write(Encoding.ASCII.GetBytes("HTTP/1.1 502 Bad Gateway\r\n\r\n"), 0, 28); } catch { }
        }
        finally
        {
            if (ws != null) ws.Close();
            if (remote != null) remote.Close();
            c.Close();
        }
    }
}
'@

$cfg = @{ port = '1080'; setpac = '1'; verbose = '0' }
$srv = @{ cloudflare = @{ url = ''; key = ''; ip = '' }; deno = @{ url = ''; key = ''; ip = '' } }
$ini = Join-Path $PSScriptRoot 'ws-proxy-settings.txt'
if (Test-Path $ini) {
    $sec = ''
    foreach ($l in Get-Content $ini) {
        if ($l -match '^\s*\[\s*([a-z]+)\s*\]\s*$') { $sec = $Matches[1].ToLower(); continue }
        if ($l -match '^\s*([a-z_]+)\s*=\s*(.*?)\s*$') {
            if ($srv.ContainsKey($sec)) { $srv[$sec][$Matches[1].ToLower()] = $Matches[2] }
            else { $cfg[$Matches[1].ToLower()] = $Matches[2] }
        }
    }
}
$Port = [int]$cfg.port
$PacUrl = "http://127.0.0.1:$Port/proxy.pac"

if (-not ('WsProxy' -as [type])) { Add-Type -TypeDefinition $cs -Language CSharp -IgnoreWarnings }

function Set-Pac([bool]$on) {
    $cur = (Get-ItemProperty $RegPath -Name AutoConfigURL -ErrorAction SilentlyContinue).AutoConfigURL
    if ($on) { Set-ItemProperty $RegPath -Name AutoConfigURL -Value "$PacUrl`?v=$([DateTime]::Now.Ticks)" }
    elseif ($cur -and $cur.StartsWith($PacUrl)) { Remove-ItemProperty $RegPath -Name AutoConfigURL }
    [WsProxy]::RefreshProxy()
}

if ($Stop) {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessId -ne $PID -and ($_.CommandLine -like '*ws-proxy.ps1*' -or $_.CommandLine -like '*-tunnel.ps1*') -and $_.CommandLine -notlike '*-Stop*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    try { Set-Pac $false } catch { }
    Write-Host 'ws-proxy stopped'
    exit 0
}

$Mode = 'cloudflare'
$flag = Join-Path $PSScriptRoot 'ws_proxy.enabled'
if ((Test-Path $flag) -and ((Get-Content $flag -Raw) -match 'deno')) { $Mode = 'deno' }
$TunUrl = $srv[$Mode].url
$TunKey = $srv[$Mode].key
$TunIp = $srv[$Mode].ip
if (-not $TunUrl.StartsWith('wss://')) { Fail "url in [$Mode] section of utils\ws-proxy-settings.txt is empty or not wss:// (now: '$TunUrl')" }
if ($TunKey -eq '' -or $TunKey.StartsWith('CHANGE-ME')) { Fail "set key in [$Mode] section of utils\ws-proxy-settings.txt" }

$mutex = New-Object System.Threading.Mutex($false, 'Local\zapret-ws-proxy')
if (-not $mutex.WaitOne(0)) { Write-Host 'ws-proxy is already running'; Start-Sleep 3; exit 0 }

function Load-List {
    $d = @(Get-Content $ListFile -Encoding UTF8 | ForEach-Object { $_.Trim().ToLower().TrimEnd('.') } |
        Where-Object { $_ -and -not $_.StartsWith('#') } | Select-Object -Unique)
    if ($d.Count -eq 0) { return 0 }
    [WsProxy]::Domains = [string[]]$d
    $js = ($d | ForEach-Object { "`"$_`"" }) -join ','
    [WsProxy]::Pac = "function FindProxyForURL(url, host) {`n  host = host.toLowerCase();`n  var d = [$js];`n  for (var i = 0; i < d.length; i++)`n    if (host == d[i] || dnsDomainIs(host, '.' + d[i])) return 'PROXY 127.0.0.1:$Port; DIRECT';`n  return 'DIRECT';`n}`n"
    return $d.Count
}

if (-not (Test-Path $ListFile)) { Fail "$ListFile not found" }
$count = Load-List
if ($count -eq 0) { Fail 'list-proxy.txt is empty' }
$listTime = (Get-Item $ListFile).LastWriteTime

[WsProxy]::Url = $TunUrl
[WsProxy]::Key = $TunKey
[WsProxy]::Ip = $TunIp
[WsProxy]::Port = $Port
[WsProxy]::Verbose = ($cfg.verbose -eq '1')

try { $task = [WsProxy]::Run() } catch { Fail "cannot listen on 127.0.0.1:$Port - $($_.Exception.GetBaseException().Message)" }
if ($cfg.setpac -eq '1') { Set-Pac $true }

$host.UI.RawUI.WindowTitle = 'zapret: ws-proxy'
Write-Host "ws-proxy running: proxy 127.0.0.1:$Port, PAC $PacUrl"
Write-Host "$Mode`: $TunUrl"
Write-Host "domains via proxy: $count (lists\list-proxy.txt)"
Write-Host 'close this window or run "ws-proxy.ps1 -Stop" to stop'

try {
    while (-not $task.Wait(2000)) {
        $t = (Get-Item $ListFile -ErrorAction SilentlyContinue).LastWriteTime
        if ($t -and $t -ne $listTime) {
            $listTime = $t
            $count = Load-List
            if ($count -gt 0) {
                if ($cfg.setpac -eq '1') { Set-Pac $true }
                Write-Host "$((Get-Date).ToString('HH:mm:ss')) list-proxy.txt reloaded: $count domains"
            }
        }
    }
    if ($task.IsFaulted) { Fail "crashed: $($task.Exception.GetBaseException().Message)" }
} finally {
    if ($cfg.setpac -eq '1') { try { Set-Pac $false } catch { } }
}
