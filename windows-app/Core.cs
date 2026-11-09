using System.Collections.Concurrent;
using System.Diagnostics;
using System.Globalization;
using System.Net;
using System.Net.Http;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace LanDrop;

public sealed class Peer
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    public string Platform { get; set; } = "unknown";
    public string Host { get; set; } = "";
    public int Port { get; set; } = 47823;
    public bool PinRequired { get; set; }
    public DateTime LastSeen { get; set; } = DateTime.Now;

    public bool Online => (DateTime.Now - LastSeen).TotalSeconds < 30;
    public string Endpoint => $"{Host}:{Port}";
    public string PlatformLabel => Platform switch
    {
        "macos" => "macOS",
        "android" => "Android",
        "harmony" or "harmonyos" or "ohos" => "HarmonyOS",
        "windows" => "Windows",
        _ => "未知设备"
    };
}

public sealed class AppConfig
{
    public string Id { get; set; } = RandomHex(8);
    public string Name { get; set; } = Environment.MachineName;
    public int Port { get; set; } = 47823;
    public bool PinEnabled { get; set; }
    public string Pin { get; set; } = RandomPin();
    public string Inbox { get; set; } = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads", "LanDrop");
    public bool LaunchAtLogin { get; set; }
    public Dictionary<string, string> PeerPins { get; set; } = new();

    private static string ConfigPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "LanDrop", "config.json");

    public static string RandomHex(int bytes) =>
        Convert.ToHexString(RandomNumberGenerator.GetBytes(bytes)).ToLowerInvariant();

    public static string RandomPin() => RandomNumberGenerator.GetInt32(0, 1000000).ToString("000000");

    public static AppConfig Load()
    {
        try
        {
            if (File.Exists(ConfigPath))
            {
                var cfg = JsonSerializer.Deserialize<AppConfig>(File.ReadAllText(ConfigPath));
                if (cfg != null && cfg.Id.Length >= 8)
                {
                    Directory.CreateDirectory(cfg.Inbox);
                    return cfg;
                }
            }
        }
        catch { }
        var fresh = new AppConfig();
        Directory.CreateDirectory(fresh.Inbox);
        fresh.Save();
        return fresh;
    }

    public void Save()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(ConfigPath)!);
            File.WriteAllText(ConfigPath, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
        }
        catch { }
    }
}

public sealed class Discovery : IDisposable
{
    public const int UdpPort = 47824;
    private readonly AppConfig _cfg;
    private readonly Func<int> _port;
    private UdpClient _udp;
    private CancellationTokenSource _cts;

    public event Action<Peer> PeerSeen;

    public Discovery(AppConfig cfg, Func<int> portProvider)
    {
        _cfg = cfg;
        _port = portProvider;
    }

    public void Start()
    {
        if (_udp != null) return;
        _cts = new CancellationTokenSource();
        _udp = new UdpClient { ExclusiveAddressUse = false };
        _udp.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
        _udp.Client.Bind(new IPEndPoint(IPAddress.Any, UdpPort));
        _udp.EnableBroadcast = true;
        var token = _cts.Token;
        _ = Task.Run(() => ReceiveLoop(token));
        _ = Task.Run(async () =>
        {
            while (!token.IsCancellationRequested)
            {
                Probe();
                try { await Task.Delay(15000, token); } catch { break; }
            }
        });
    }

    public void Probe()
    {
        var udp = _udp;
        if (udp == null) return;
        var payload = Encoding.UTF8.GetBytes(Beacon("probe"));
        foreach (var addr in BroadcastAddresses())
        {
            try { udp.Send(payload, payload.Length, new IPEndPoint(addr, UdpPort)); } catch { }
        }
    }

    public void Stop()
    {
        _cts?.Cancel();
        try { _udp?.Close(); } catch { }
        _udp = null;
    }

    private string Beacon(string type) => JsonSerializer.Serialize(new
    {
        app = "landrop",
        v = 1,
        type,
        id = _cfg.Id,
        name = _cfg.Name,
        platform = "windows",
        port = _port(),
        pin_required = _cfg.PinEnabled
    });

    private async Task ReceiveLoop(CancellationToken token)
    {
        var udp = _udp;
        while (!token.IsCancellationRequested && udp != null)
        {
            UdpReceiveResult result;
            try { result = await udp.ReceiveAsync(token); }
            catch { break; }
            try
            {
                using var doc = JsonDocument.Parse(result.Buffer);
                var root = doc.RootElement;
                if (root.GetProperty("app").GetString() != "landrop") continue;
                var id = root.GetProperty("id").GetString() ?? "";
                if (id.Length == 0 || id == _cfg.Id) continue;
                var host = result.RemoteEndPoint.Address.ToString();
                var peer = new Peer
                {
                    Id = id,
                    Name = root.TryGetProperty("name", out var n) ? n.GetString() ?? "未知设备" : "未知设备",
                    Platform = root.TryGetProperty("platform", out var p) ? p.GetString() ?? "unknown" : "unknown",
                    Host = host,
                    Port = root.TryGetProperty("port", out var pt) ? pt.GetInt32() : 47823,
                    PinRequired = root.TryGetProperty("pin_required", out var pin) && pin.GetBoolean(),
                    LastSeen = DateTime.Now
                };
                if (root.TryGetProperty("type", out var t) && t.GetString() == "probe")
                {
                    try
                    {
                        var reply = Encoding.UTF8.GetBytes(Beacon("announce"));
                        await udp.SendAsync(reply, reply.Length, result.RemoteEndPoint);
                    }
                    catch { }
                }
                PeerSeen?.Invoke(peer);
            }
            catch { }
        }
    }

    private static IEnumerable<IPAddress> BroadcastAddresses()
    {
        var set = new HashSet<string> { "255.255.255.255" };
        try
        {
            foreach (var nic in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (nic.OperationalStatus != OperationalStatus.Up) continue;
                foreach (var ua in nic.GetIPProperties().UnicastAddresses)
                {
                    if (ua.Address.AddressFamily != AddressFamily.InterNetwork) continue;
                    var mask = ua.IPv4Mask;
                    if (mask == null) continue;
                    var ip = ua.Address.GetAddressBytes();
                    var m = mask.GetAddressBytes();
                    var b = new byte[4];
                    for (var i = 0; i < 4; i++) b[i] = (byte)(ip[i] | ~m[i]);
                    set.Add(new IPAddress(b).ToString());
                }
            }
        }
        catch { }
        return set.Select(IPAddress.Parse);
    }

    public void Dispose() => Stop();
}

public sealed class InboxItem
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    public string Path { get; set; } = "";
    public long Size { get; set; }
    public DateTime MTime { get; set; }
    public string Kind => System.IO.Path.GetExtension(Name).Equals(".txt", StringComparison.OrdinalIgnoreCase) ? "text" : "file";
    public string SizeText => FormatSize(Size);

    public static string FormatSize(long bytes)
    {
        if (bytes < 1000) return $"{bytes} B";
        string[] units = { "KB", "MB", "GB", "TB" };
        var v = bytes / 1000.0;
        var i = 0;
        while (v >= 1000 && i < units.Length - 1) { v /= 1000; i++; }
        return string.Format(CultureInfo.InvariantCulture, v >= 10 ? "{0:0} {1}" : "{0:0.0} {1}", v, units[i]);
    }
}

public sealed class InboxStore
{
    public string Root { get; }
    public string PartialDir => System.IO.Path.Combine(Root, ".lan-drop-partials");

    public InboxStore(string root)
    {
        Root = root;
        Directory.CreateDirectory(Root);
        Directory.CreateDirectory(PartialDir);
    }

    public static string StableId(string name)
    {
        var hash = 0xcbf29ce484222325UL;
        foreach (var b in Encoding.UTF8.GetBytes(name))
        {
            hash ^= b;
            hash *= 0x100000001b3UL;
        }
        return hash.ToString("x16");
    }

    public static string Sanitize(string name)
    {
        var cleaned = new string(name.Where(ch => !char.IsControl(ch) && ch != '\\' && ch != '/').ToArray()).Trim();
        if (cleaned.Length == 0) cleaned = "file";
        if (cleaned.StartsWith('.')) cleaned = "_" + cleaned;
        if (cleaned.Length > 200) cleaned = cleaned[..200];
        return cleaned;
    }

    public string UniqueName(string name)
    {
        var safe = Sanitize(name);
        var candidate = System.IO.Path.Combine(Root, safe);
        if (!File.Exists(candidate)) return safe;
        var stem = System.IO.Path.GetFileNameWithoutExtension(safe);
        var ext = System.IO.Path.GetExtension(safe);
        for (var i = 1; i < 1000; i++)
        {
            var next = $"{stem} ({i}){ext}";
            if (!File.Exists(System.IO.Path.Combine(Root, next))) return next;
        }
        return $"{stem}-{DateTime.Now.Ticks}{ext}";
    }

    public List<InboxItem> List()
    {
        var items = new List<InboxItem>();
        try
        {
            foreach (var path in Directory.GetFiles(Root))
            {
                var info = new FileInfo(path);
                if (info.Name.StartsWith('.')) continue;
                items.Add(new InboxItem
                {
                    Id = StableId(info.Name),
                    Name = info.Name,
                    Path = path,
                    Size = info.Length,
                    MTime = info.LastWriteTime
                });
            }
        }
        catch { }
        return items.OrderByDescending(i => i.MTime).ToList();
    }

    public string PathForId(string id) => List().FirstOrDefault(i => i.Id == id)?.Path;
}

public enum UploadOutcome { Done, PinRequired, Failed, Cancelled }

public sealed class PeerClient
{
    public string Pin { get; set; }
    private readonly HttpClient _http = new() { Timeout = TimeSpan.FromMinutes(10) };

    private HttpRequestMessage Request(HttpMethod method, Peer peer, string path)
    {
        var req = new HttpRequestMessage(method, $"http://{peer.Host}:{peer.Port}{path}");
        if (!string.IsNullOrEmpty(Pin)) req.Headers.TryAddWithoutValidation("X-Pin", Pin);
        return req;
    }

    public async Task<JsonDocument> InfoAsync(Peer peer, CancellationToken ct = default)
    {
        using var resp = await _http.SendAsync(Request(HttpMethod.Get, peer, "/v1/info"), ct);
        var text = await resp.Content.ReadAsStringAsync(ct);
        if (!resp.IsSuccessStatusCode) throw new HttpRequestException(text);
        return JsonDocument.Parse(text);
    }

    public async Task<List<(string id, string name, long size)>> ListFilesAsync(Peer peer, CancellationToken ct = default)
    {
        using var resp = await _http.SendAsync(Request(HttpMethod.Get, peer, "/v1/files"), ct);
        using var doc = JsonDocument.Parse(await resp.Content.ReadAsStringAsync(ct));
        var list = new List<(string, string, long)>();
        if (doc.RootElement.TryGetProperty("files", out var files))
        {
            foreach (var f in files.EnumerateArray())
            {
                list.Add((
                    f.GetProperty("id").GetString() ?? "",
                    f.GetProperty("name").GetString() ?? "file",
                    f.TryGetProperty("size", out var s) ? s.GetInt64() : 0));
            }
        }
        return list;
    }

    public async Task<UploadOutcome> UploadAsync(Peer peer, string filePath, string fileId,
        Action<long, long> progress, CancellationToken ct)
    {
        var total = new FileInfo(filePath).Length;
        var name = Uri.EscapeDataString(Path.GetFileName(filePath));
        long offset = 0;
        var retries = 0;
        const int chunk = 4 * 1024 * 1024;

        while (offset < total)
        {
            ct.ThrowIfCancellationRequested();
            var want = (int)Math.Min(chunk, total - offset);
            var buffer = new byte[want];
            using (var fs = new FileStream(filePath, FileMode.Open, FileAccess.Read, FileShare.Read))
            {
                fs.Seek(offset, SeekOrigin.Begin);
                var got = 0;
                while (got < want)
                {
                    var n = await fs.ReadAsync(buffer.AsMemory(got, want - got), ct);
                    if (n <= 0) break;
                    got += n;
                }
                if (got != want) return UploadOutcome.Failed;
            }

            using var req = Request(HttpMethod.Post, peer, "/v1/upload");
            req.Headers.TryAddWithoutValidation("X-File-Name", name);
            req.Headers.TryAddWithoutValidation("X-File-Id", fileId);
            req.Headers.TryAddWithoutValidation("X-File-Size", total.ToString());
            req.Headers.TryAddWithoutValidation("X-Offset", offset.ToString());
            req.Content = new ByteArrayContent(buffer);
            req.Content.Headers.ContentType = new System.Net.Http.Headers.MediaTypeHeaderValue("application/octet-stream");

            HttpResponseMessage resp;
            string body;
            try
            {
                resp = await _http.SendAsync(req, ct);
                body = await resp.Content.ReadAsStringAsync(ct);
            }
            catch (OperationCanceledException) { return UploadOutcome.Cancelled; }
            catch
            {
                if (++retries > 6) return UploadOutcome.Failed;
                await Task.Delay(700, ct);
                continue;
            }

            using (resp)
            {
                if (resp.StatusCode == HttpStatusCode.Unauthorized) return UploadOutcome.PinRequired;
                if (resp.StatusCode == HttpStatusCode.Conflict)
                {
                    try
                    {
                        using var doc = JsonDocument.Parse(body);
                        offset = doc.RootElement.GetProperty("actual_offset").GetInt64();
                    }
                    catch { return UploadOutcome.Failed; }
                    if (++retries > 8) return UploadOutcome.Failed;
                    continue;
                }
                if (!resp.IsSuccessStatusCode)
                {
                    if (++retries > 6) return UploadOutcome.Failed;
                    await Task.Delay(700, ct);
                    continue;
                }
            }

            offset += want;
            retries = 0;
            progress(offset, total);
        }
        return UploadOutcome.Done;
    }

    public async Task<bool> SendTextAsync(Peer peer, string text, string name, CancellationToken ct)
    {
        using var req = Request(HttpMethod.Post, peer, "/v1/text");
        var json = JsonSerializer.Serialize(new { text, name });
        req.Content = new StringContent(json, Encoding.UTF8, "application/json");
        using var resp = await _http.SendAsync(req, ct);
        return resp.IsSuccessStatusCode;
    }

    public async Task CancelAsync(Peer peer, string fileId, CancellationToken ct)
    {
        try
        {
            using var req = Request(HttpMethod.Post, peer, "/v1/cancel");
            req.Headers.TryAddWithoutValidation("X-File-Id", fileId);
            req.Content = new ByteArrayContent(Array.Empty<byte>());
            using var resp = await _http.SendAsync(req, ct);
        }
        catch { }
    }
}

public sealed class Transfer
{
    public string Id { get; } = Guid.NewGuid().ToString("N");
    public string FileId { get; set; } = Guid.NewGuid().ToString("N");
    public string FileName { get; set; } = "";
    public string PeerName { get; set; } = "";
    public bool Send { get; set; }
    public long Total { get; set; }
    public long Sent { get; set; }
    public string State { get; set; } = "running";   // preparing|running|paused|done|failed|cancelled
    public string Error { get; set; }
    public DateTime Started { get; set; } = DateTime.Now;
    public string LocalPath { get; set; }
    public double Speed { get; set; }
    public CancellationTokenSource Cts { get; set; }

    public double Progress => Total <= 0 ? 0 : Math.Min(1, (double)Sent / Total);
    public string SpeedText
    {
        get
        {
            if (State == "preparing") return "准备中…";
            if (Speed > 1) return InboxItem.FormatSize((long)Speed) + "/s";
            var elapsed = Math.Max(0.2, (DateTime.Now - Started).TotalSeconds);
            return InboxItem.FormatSize((long)(Sent / elapsed)) + "/s";
        }
    }
}

public sealed class HttpServer : IDisposable
{
    private readonly AppConfig _cfg;
    private readonly InboxStore _inbox;
    private TcpListener _listener;
    private volatile bool _running;
    private readonly ConcurrentDictionary<string, byte> _cancelled = new();

    public int Port { get; private set; }
    public bool Running => _running;
    public event Action<InboxItem, string> Received;
    public event Action<string, string, long, long, string> Progress;
    public event Action<string> Aborted;

    public HttpServer(AppConfig cfg, InboxStore inbox)
    {
        _cfg = cfg;
        _inbox = inbox;
    }

    public bool Start()
    {
        if (_running) return true;
        for (var port = _cfg.Port; port < _cfg.Port + 10; port++)
        {
            try
            {
                var listener = new TcpListener(IPAddress.Any, port);
                listener.Start();
                _listener = listener;
                Port = port;
                _running = true;
                var thread = new Thread(AcceptLoop) { IsBackground = true, Name = "landrop-http" };
                thread.Start();
                return true;
            }
            catch { }
        }
        return false;
    }

    public void Stop()
    {
        _running = false;
        try { _listener?.Stop(); } catch { }
        _listener = null;
    }

    private void AcceptLoop()
    {
        while (_running)
        {
            TcpClient client;
            try { client = _listener.AcceptTcpClient(); }
            catch { break; }
            var thread = new Thread(() => Handle(client)) { IsBackground = true, Name = "landrop-conn" };
            thread.Start();
        }
    }

    private void Handle(TcpClient client)
    {
        using (client)
        {
            try
            {
                client.ReceiveTimeout = 0;
                using var stream = client.GetStream();
                var ip = (client.Client.RemoteEndPoint as IPEndPoint)?.Address.ToString() ?? "?";
                var requestLine = ReadLine(stream);
                if (string.IsNullOrEmpty(requestLine)) return;
                var parts = requestLine.Split(' ');
                if (parts.Length < 3) return;
                var method = parts[0];
                var path = parts[1];
                var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                while (true)
                {
                    var line = ReadLine(stream);
                    if (string.IsNullOrEmpty(line)) break;
                    var idx = line.IndexOf(':');
                    if (idx <= 0) continue;
                    headers[line[..idx].Trim()] = line[(idx + 1)..].Trim();
                }

                if (_cfg.PinEnabled && path != "/v1/info")
                {
                    headers.TryGetValue("X-Pin", out var pin);
                    if (pin != _cfg.Pin)
                    {
                        Respond(stream, 401, "Unauthorized", "application/json",
                            Encoding.UTF8.GetBytes("{\"error\":{\"code\":\"pin_required\"}}"));
                        return;
                    }
                }

                if (method == "GET" && path == "/v1/info")
                {
                    var json = JsonSerializer.Serialize(new
                    {
                        app = "landrop",
                        v = 1,
                        id = _cfg.Id,
                        name = _cfg.Name,
                        platform = "windows",
                        version = "2.0.0",
                        port = Port,
                        pin_required = _cfg.PinEnabled,
                        inbox = _inbox.Root,
                        free_bytes = FreeBytes()
                    });
                    Respond(stream, 200, "OK", "application/json; charset=utf-8", Encoding.UTF8.GetBytes(json));
                    return;
                }

                if (method == "GET" && path == "/v1/files")
                {
                    var files = _inbox.List().Select(i => new { id = i.Id, name = i.Name, size = i.Size, kind = i.Kind, mtime = ((DateTimeOffset)i.MTime).ToUnixTimeSeconds() });
                    var json = JsonSerializer.Serialize(new { files });
                    Respond(stream, 200, "OK", "application/json; charset=utf-8", Encoding.UTF8.GetBytes(json));
                    return;
                }

                if (method == "POST" && path == "/v1/text")
                {
                    var body = ReadBody(stream, long.TryParse(Get(headers, "content-length"), out var l) ? l : 0);
                    string text = "", name = null;
                    using (var doc = JsonDocument.Parse(body))
                    {
                        text = doc.RootElement.TryGetProperty("text", out var t) ? t.GetString() ?? "" : "";
                        if (doc.RootElement.TryGetProperty("name", out var n)) name = n.GetString();
                    }
                    if (text.Length == 0) { Respond(stream, 400, "Bad Request", "application/json", "{\"error\":{\"code\":\"empty\"}}"u8.ToArray()); return; }
                    var fileName = _inbox.UniqueName(string.IsNullOrWhiteSpace(name) ? $"text-{DateTime.Now:HHmmss}.txt" : name);
                    var target = Path.Combine(_inbox.Root, fileName);
                    File.WriteAllText(target, text, new UTF8Encoding(false));
                    var item = _inbox.List().FirstOrDefault(i => i.Path == target);
                    if (item != null) Received?.Invoke(item, "");
                    var json = JsonSerializer.Serialize(new { id = item?.Id ?? "", name = fileName, size = Encoding.UTF8.GetByteCount(text) });
                    Respond(stream, 200, "OK", "application/json; charset=utf-8", Encoding.UTF8.GetBytes(json));
                    return;
                }

                if (method == "POST" && path == "/v1/upload")
                {
                    HandleUpload(stream, headers, ip);
                    return;
                }

                if (method == "POST" && path == "/v1/cancel")
                {
                    var fileId = Get(headers, "x-file-id") ?? "";
                    if (fileId.Length > 0) _cancelled[fileId] = 0;
                    Aborted?.Invoke(fileId);
                    Respond(stream, 200, "OK", "application/json", "{\"ok\":true}"u8.ToArray());
                    return;
                }

                if (method is "GET" or "HEAD" && path.StartsWith("/v1/files/") && path.EndsWith("/content"))
                {
                    var id = path["/v1/files/".Length..^"/content".Length];
                    HandleDownload(stream, method, headers, id);
                    return;
                }

                Respond(stream, 404, "Not Found", "application/json", "{\"error\":{\"code\":\"not_found\"}}"u8.ToArray());
            }
            catch { }
        }
    }

    private void HandleUpload(NetworkStream stream, Dictionary<string, string> headers, string ip)
    {
        var fileId = Get(headers, "x-file-id") ?? Guid.NewGuid().ToString("N");
        var rawName = Get(headers, "x-file-name") ?? "file";
        string name;
        try { name = Uri.UnescapeDataString(rawName); } catch { name = rawName; }
        var length = long.TryParse(Get(headers, "content-length"), out var l) ? l : 0;
        var total = long.TryParse(Get(headers, "x-file-size"), out var ts) ? ts : length;
        var offset = long.TryParse(Get(headers, "x-offset"), out var os) ? os : 0;

        var part = Path.Combine(_inbox.PartialDir, InboxStore.StableId(fileId) + ".part");
        var existing = File.Exists(part) ? new FileInfo(part).Length : 0;
        if (existing != offset)
        {
            var actual = Math.Min(existing, offset);
            if (existing > offset) { using (var trunc = new FileStream(part, FileMode.Open, FileAccess.Write)) trunc.SetLength(offset); }
            Respond(stream, 409, "Conflict", "application/json",
                Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new { actual_offset = actual })));
            return;
        }

        long received = offset;
        using (var fs = new FileStream(part, FileMode.Append, FileAccess.Write, FileShare.Read))
        {
            var buffer = new byte[256 * 1024];
            while (received - offset < length)
            {
                if (_cancelled.ContainsKey(fileId)) break;
                var want = (int)Math.Min(buffer.Length, length - (received - offset));
                int read;
                try { read = stream.Read(buffer, 0, want); } catch { break; }
                if (read <= 0) break;
                fs.Write(buffer, 0, read);
                received += read;
                Progress?.Invoke(fileId, name, received, total, ip);
            }
            fs.Flush(true);
        }

        var complete = total > 0 ? received >= total : length == 0;
        string finalName = null;
        InboxItem item = null;
        if (complete && !_cancelled.ContainsKey(fileId))
        {
            finalName = _inbox.UniqueName(name);
            var target = Path.Combine(_inbox.Root, finalName);
            try
            {
                File.Move(part, target, true);
                item = _inbox.List().FirstOrDefault(i => i.Path == target);
                if (item != null) Received?.Invoke(item, fileId);
            }
            catch { }
        }

        var json = JsonSerializer.Serialize(new
        {
            id = item?.Id ?? "",
            name = finalName ?? name,
            size = received,
            received,
            complete
        });
        Respond(stream, 200, "OK", "application/json; charset=utf-8", Encoding.UTF8.GetBytes(json));
    }

    private void HandleDownload(NetworkStream stream, string method, Dictionary<string, string> headers, string id)
    {
        var path = _inbox.PathForId(id);
        if (path == null || !File.Exists(path))
        {
            Respond(stream, 404, "Not Found", "application/json", "{\"error\":{\"code\":\"missing\"}}"u8.ToArray());
            return;
        }
        var total = new FileInfo(path).Length;
        long start = 0, end = total - 1;
        var range = Get(headers, "range");
        var partial = false;
        if (!string.IsNullOrEmpty(range) && range.StartsWith("bytes="))
        {
            var spec = range[6..].Split('-');
            long.TryParse(spec.ElementAtOrDefault(0), out start);
            if (spec.Length > 1 && long.TryParse(spec[1], out var e)) end = Math.Min(e, total - 1);
            if (end < start) { Respond(stream, 416, "Range Not Satisfiable", "application/json", "{}"u8.ToArray()); return; }
            partial = true;
        }
        var length = end - start + 1;
        var head = new StringBuilder();
        head.Append($"HTTP/1.1 {(partial ? 206 : 200)} {(partial ? "Partial Content" : "OK")}\r\n");
        head.Append($"Content-Length: {length}\r\n");
        head.Append("Accept-Ranges: bytes\r\n");
        if (partial) head.Append($"Content-Range: bytes {start}-{end}/{total}\r\n");
        head.Append("Content-Type: application/octet-stream\r\n");
        head.Append("Connection: close\r\n\r\n");
        var hb = Encoding.ASCII.GetBytes(head.ToString());
        stream.Write(hb, 0, hb.Length);
        if (method == "HEAD") return;
        using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
        fs.Seek(start, SeekOrigin.Begin);
        var buffer = new byte[64 * 1024];
        var left = length;
        while (left > 0)
        {
            var n = fs.Read(buffer, 0, (int)Math.Min(buffer.Length, left));
            if (n <= 0) break;
            stream.Write(buffer, 0, n);
            left -= n;
        }
    }

    private static string Get(Dictionary<string, string> headers, string key) =>
        headers.TryGetValue(key, out var v) ? v : null;

    private static byte[] ReadBody(NetworkStream stream, long length)
    {
        if (length <= 0) return Array.Empty<byte>();
        var buffer = new byte[length];
        var read = 0;
        while (read < length)
        {
            var n = stream.Read(buffer, read, (int)(length - read));
            if (n <= 0) break;
            read += n;
        }
        return buffer;
    }

    private static void Respond(NetworkStream stream, int code, string reason, string contentType, byte[] body)
    {
        var head = new StringBuilder();
        head.Append($"HTTP/1.1 {code} {reason}\r\n");
        head.Append($"Content-Length: {body.Length}\r\n");
        head.Append($"Content-Type: {contentType}\r\n");
        head.Append("Connection: close\r\n\r\n");
        var hb = Encoding.ASCII.GetBytes(head.ToString());
        stream.Write(hb, 0, hb.Length);
        if (body.Length > 0) stream.Write(body, 0, body.Length);
        stream.Flush();
    }

    private static string ReadLine(Stream stream)
    {
        var bytes = new List<byte>(128);
        while (true)
        {
            var b = stream.ReadByte();
            if (b < 0) break;
            if (b == '\n') break;
            if (b != '\r') bytes.Add((byte)b);
            if (bytes.Count > 8192) break;
        }
        return Encoding.UTF8.GetString(bytes.ToArray());
    }

    private static long FreeBytes()
    {
        try
        {
            var drive = new DriveInfo(Path.GetPathRoot(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile))!);
            return drive.AvailableFreeSpace;
        }
        catch { return 0; }
    }

    public void Dispose() => Stop();
}

public static class NfcTag
{
    public static string Payload(string id, string name, string host, int port, bool pinRequired)
    {
        var sb = new StringBuilder("landrop://tap?v=1&id=").Append(id);
        if (!string.IsNullOrWhiteSpace(name)) sb.Append("&n=").Append(Uri.EscapeDataString(name.Trim()));
        sb.Append("&p=windows&h=").Append(host).Append("&t=").Append(port);
        if (pinRequired) sb.Append("&k=1");
        return sb.ToString();
    }

    public static int Bytes(string payload) => 5 + Encoding.UTF8.GetByteCount(payload) + 2 + 37;
}
