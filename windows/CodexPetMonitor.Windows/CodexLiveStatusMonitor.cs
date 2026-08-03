using System.Buffers.Binary;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;

namespace CodexPetMonitor.Windows;

internal sealed record LiveThreadStatus(TaskState State, string[] ActiveFlags, string StatusType)
{
    public bool ReportsSystemError => StatusType == "systemError";
}

internal sealed class CodexLiveStatusMonitor : IDisposable
{
    private readonly string _socketPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex", "ipc", "ipc.sock");
    private readonly object _gate = new();
    private readonly SemaphoreSlim _writeGate = new(1, 1);
    private readonly CancellationTokenSource _cancellation = new();
    private readonly Dictionary<string, LiveThreadStatus> _statuses = new(StringComparer.Ordinal);
    private readonly HashSet<string> _desiredIds = new(StringComparer.Ordinal);
    private NetworkStream? _stream;
    private string? _clientId;

    public event Action<bool, IReadOnlyDictionary<string, LiveThreadStatus>>? Changed;

    public void Start() => _ = Task.Run(ConnectionLoopAsync);

    public void UpdateSubscriptions(IEnumerable<string> ids)
    {
        lock (_gate)
        {
            _desiredIds.Clear();
            foreach (var id in ids) _desiredIds.Add(id);
            foreach (var stale in _statuses.Keys.Where(id => !_desiredIds.Contains(id)).ToArray())
                _statuses.Remove(stale);
        }
        _ = SendSubscriptionsAsync();
    }

    private async Task ConnectionLoopAsync()
    {
        while (!_cancellation.IsCancellationRequested)
        {
            try
            {
                using var socket = new Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified);
                await socket.ConnectAsync(new UnixDomainSocketEndPoint(_socketPath), _cancellation.Token);
                using var stream = new NetworkStream(socket, ownsSocket: false);
                lock (_gate)
                {
                    _stream = stream;
                    _clientId = null;
                    _statuses.Clear();
                }
                Publish(true);
                await SendAsync(new
                {
                    type = "request",
                    requestId = "codex-pet-windows-initialize",
                    sourceClientId = "initializing-client",
                    version = 1,
                    method = "initialize",
                    @params = new { clientType = "codex-pet-monitor-windows" },
                    timeoutMs = 5000
                });

                while (!_cancellation.IsCancellationRequested)
                {
                    var data = await ReadFrameAsync(stream, _cancellation.Token);
                    if (data is null) break;
                    ProcessFrame(data);
                }
            }
            catch (Exception ex) when (ex is IOException or SocketException or OperationCanceledException)
            {
                if (_cancellation.IsCancellationRequested) break;
            }
            finally
            {
                lock (_gate)
                {
                    _stream = null;
                    _clientId = null;
                    _statuses.Clear();
                }
                Publish(false);
            }
            try { await Task.Delay(1000, _cancellation.Token); }
            catch (OperationCanceledException) { break; }
        }
    }

    private void ProcessFrame(byte[] data)
    {
        var text = Encoding.UTF8.GetString(data);
        if (text.Contains("\"method\":\"initialize\"", StringComparison.Ordinal))
        {
            try
            {
                using var document = JsonDocument.Parse(data);
                var root = document.RootElement;
                if (root.TryGetProperty("result", out var result) &&
                    result.TryGetProperty("clientId", out var id))
                {
                    lock (_gate) _clientId = id.GetString();
                    _ = SendSubscriptionsAsync();
                }
            }
            catch (JsonException) { }
            return;
        }

        if (!text.Contains("thread-stream-state-changed", StringComparison.Ordinal) ||
            !text.Contains("threadRuntimeStatus", StringComparison.Ordinal)) return;
        var threadId = ExtractJsonString(text, "conversationId");
        if (threadId is null) return;

        if (text.Contains("\"type\":\"snapshot\"", StringComparison.Ordinal) &&
            ExtractJsonObject(text, "threadRuntimeStatus") is { } statusJson)
        {
            try
            {
                using var statusDocument = JsonDocument.Parse(statusJson);
                UpdateStatus(threadId, statusDocument.RootElement);
            }
            catch (JsonException) { }
            return;
        }

        try
        {
            using var document = JsonDocument.Parse(data);
            var root = document.RootElement;
            if (!root.TryGetProperty("params", out var parameters) ||
                !parameters.TryGetProperty("change", out var change)) return;
            if (!change.TryGetProperty("patches", out var patches)) return;
            foreach (var patch in patches.EnumerateArray()) ProcessPatch(threadId, patch);
        }
        catch (JsonException)
        {
            // A future Codex schema change should fall back to local events.
        }
    }

    private void ProcessPatch(string threadId, JsonElement patch)
    {
        if (!patch.TryGetProperty("path", out var path)) return;
        var parts = path.EnumerateArray().Select(x => x.GetString() ?? "").ToArray();
        if (parts.Length == 0 || parts[0] != "threadRuntimeStatus") return;
        if (!patch.TryGetProperty("value", out var value)) return;
        if (parts.Length == 1 && value.ValueKind == JsonValueKind.Object)
        {
            UpdateStatus(threadId, value);
            return;
        }

        LiveThreadStatus current;
        lock (_gate) current = _statuses.GetValueOrDefault(threadId) ??
                              new LiveThreadStatus(TaskState.Idle, [], "notLoaded");
        if (parts.Length == 2 && parts[1] == "activeFlags")
        {
            var flags = value.ValueKind == JsonValueKind.Array
                ? value.EnumerateArray().Select(x => x.GetString() ?? "").ToArray()
                : [];
            UpdateStatus(threadId, current.StatusType, flags);
        }
        else if (parts.Length == 2 && parts[1] == "type")
        {
            UpdateStatus(threadId, value.GetString() ?? "notLoaded", current.ActiveFlags);
        }
    }

    private void UpdateStatus(string threadId, JsonElement value)
    {
        var type = value.TryGetProperty("type", out var typeElement)
            ? typeElement.GetString() ?? "notLoaded"
            : "notLoaded";
        var flags = value.TryGetProperty("activeFlags", out var flagsElement) &&
                    flagsElement.ValueKind == JsonValueKind.Array
            ? flagsElement.EnumerateArray().Select(x => x.GetString() ?? "").ToArray()
            : [];
        UpdateStatus(threadId, type, flags);
    }

    private void UpdateStatus(string threadId, string type, string[] flags)
    {
        var state = flags.Contains("waitingOnApproval") || flags.Contains("waitingOnUserInput")
            ? TaskState.WaitingApproval
            : type switch
            {
                "active" => TaskState.Working,
                "systemError" => TaskState.Failed,
                _ => TaskState.Idle
            };
        lock (_gate)
        {
            if (!_desiredIds.Contains(threadId)) return;
            _statuses[threadId] = new LiveThreadStatus(state, flags, type);
        }
        Publish(true);
    }

    private async Task SendSubscriptionsAsync()
    {
        string? clientId;
        string[] ids;
        lock (_gate)
        {
            clientId = _clientId;
            ids = _desiredIds.ToArray();
        }
        if (clientId is null) return;
        await SendAsync(new
        {
            type = "broadcast",
            method = "thread-stream-following-status-requested",
            sourceClientId = clientId,
            version = 1,
            @params = new { }
        });
        foreach (var id in ids)
        {
            await SendAsync(new
            {
                type = "broadcast",
                method = "thread-stream-following-changed",
                sourceClientId = clientId,
                version = 1,
                @params = new { conversationId = id, hostId = "local", following = true }
            });
        }
    }

    private async Task SendAsync(object value)
    {
        NetworkStream? stream;
        lock (_gate) stream = _stream;
        if (stream is null) return;
        var payload = JsonSerializer.SerializeToUtf8Bytes(value);
        var frame = new byte[payload.Length + 4];
        BinaryPrimitives.WriteUInt32LittleEndian(frame, (uint)payload.Length);
        payload.CopyTo(frame.AsSpan(4));
        await _writeGate.WaitAsync(_cancellation.Token);
        try { await stream.WriteAsync(frame, _cancellation.Token); }
        catch (IOException) { }
        finally { _writeGate.Release(); }
    }

    private static async Task<byte[]?> ReadFrameAsync(Stream stream, CancellationToken cancellationToken)
    {
        var header = new byte[4];
        if (!await ReadExactlyAsync(stream, header, cancellationToken)) return null;
        var length = BinaryPrimitives.ReadUInt32LittleEndian(header);
        if (length is 0 or > 268_435_456) return null;
        var payload = new byte[(int)length];
        return await ReadExactlyAsync(stream, payload, cancellationToken) ? payload : null;
    }

    private static async Task<bool> ReadExactlyAsync(Stream stream, byte[] buffer, CancellationToken token)
    {
        var offset = 0;
        while (offset < buffer.Length)
        {
            var count = await stream.ReadAsync(buffer.AsMemory(offset), token);
            if (count == 0) return false;
            offset += count;
        }
        return true;
    }

    private static string? ExtractJsonString(string text, string name)
    {
        var marker = $"\"{name}\":\"";
        var start = text.IndexOf(marker, StringComparison.Ordinal);
        if (start < 0) return null;
        start += marker.Length;
        var builder = new StringBuilder();
        var escaped = false;
        for (var index = start; index < text.Length; index++)
        {
            var character = text[index];
            if (escaped) { builder.Append(character); escaped = false; }
            else if (character == '\\') escaped = true;
            else if (character == '"') return builder.ToString();
            else builder.Append(character);
        }
        return null;
    }

    private static string? ExtractJsonObject(string text, string name)
    {
        var marker = $"\"{name}\":";
        var markerIndex = text.IndexOf(marker, StringComparison.Ordinal);
        if (markerIndex < 0) return null;
        var start = text.IndexOf('{', markerIndex + marker.Length);
        if (start < 0) return null;
        var depth = 0;
        var insideString = false;
        var escaped = false;
        for (var index = start; index < text.Length; index++)
        {
            var character = text[index];
            if (insideString)
            {
                if (escaped) escaped = false;
                else if (character == '\\') escaped = true;
                else if (character == '"') insideString = false;
                continue;
            }
            if (character == '"') insideString = true;
            else if (character == '{') depth++;
            else if (character == '}' && --depth == 0) return text[start..(index + 1)];
        }
        return null;
    }

    private void Publish(bool connected)
    {
        Dictionary<string, LiveThreadStatus> snapshot;
        lock (_gate) snapshot = new Dictionary<string, LiveThreadStatus>(_statuses);
        Changed?.Invoke(connected, snapshot);
    }

    public void Dispose()
    {
        _cancellation.Cancel();
        lock (_gate) _stream?.Dispose();
        _writeGate.Dispose();
        _cancellation.Dispose();
    }
}
