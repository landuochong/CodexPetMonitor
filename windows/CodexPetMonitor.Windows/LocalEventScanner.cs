using System.IO;
using System.Text;
using System.Text.Json;
using Microsoft.Data.Sqlite;

namespace CodexPetMonitor.Windows;

internal sealed class LocalEventScanner
{
    private const int MaxThreads = 20;
    private const long TailBytes = 1_048_576;
    private readonly string _codexHome = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex");

    public IReadOnlyList<ThreadState> Scan()
    {
        var databasePath = FindDatabase("state_5.sqlite", "state_*.sqlite");
        if (databasePath is null) return [];

        var approvalTimes = ReadLatestApprovalTimes();
        var threads = new List<ThreadState>();
        using var connection = OpenReadOnly(databasePath);
        using var command = connection.CreateCommand();
        command.CommandText = """
            SELECT id, rollout_path, updated_at_ms
            FROM threads
            WHERE archived = 0 AND preview <> ''
            ORDER BY updated_at_ms DESC
            LIMIT $limit;
            """;
        command.Parameters.AddWithValue("$limit", MaxThreads);
        using var reader = command.ExecuteReader();
        while (reader.Read())
        {
            var id = reader.GetString(0);
            var rolloutPath = reader.GetString(1);
            var updatedAt = DateTimeOffset.FromUnixTimeMilliseconds(reader.GetInt64(2));
            approvalTimes.TryGetValue(id, out var approvedAt);
            threads.Add(ScanRollout(id, rolloutPath, updatedAt, approvedAt));
        }
        return threads;
    }

    private Dictionary<string, DateTimeOffset> ReadLatestApprovalTimes()
    {
        var result = new Dictionary<string, DateTimeOffset>(StringComparer.Ordinal);
        var logsPath = FindDatabase("logs_2.sqlite", "logs_*.sqlite");
        if (logsPath is null) return result;

        try
        {
            using var connection = OpenReadOnly(logsPath);
            using var command = connection.CreateCommand();
            command.CommandText = """
                SELECT thread_id, MAX(ts)
                FROM logs
                WHERE thread_id IS NOT NULL
                  AND target = 'codex_core::session::handlers'
                  AND feedback_log_body LIKE '%Approval %decision:%'
                GROUP BY thread_id;
                """;
            using var reader = command.ExecuteReader();
            while (reader.Read())
            {
                var seconds = reader.GetDouble(1);
                result[reader.GetString(0)] = DateTimeOffset.FromUnixTimeMilliseconds((long)(seconds * 1000));
            }
        }
        catch (SqliteException)
        {
            // Older Codex builds may not have the logs database or this schema.
        }
        return result;
    }

    private string? FindDatabase(string preferredName, string pattern)
    {
        var preferred = new[]
        {
            Path.Combine(_codexHome, preferredName),
            Path.Combine(_codexHome, "sqlite", preferredName)
        };
        var exact = preferred.FirstOrDefault(File.Exists);
        if (exact is not null) return exact;

        try
        {
            return new[] { _codexHome, Path.Combine(_codexHome, "sqlite") }
                .Where(Directory.Exists)
                .SelectMany(directory => Directory.EnumerateFiles(directory, pattern, SearchOption.TopDirectoryOnly))
                .OrderByDescending(File.GetLastWriteTimeUtc)
                .FirstOrDefault();
        }
        catch (UnauthorizedAccessException)
        {
            return null;
        }
    }

    private static SqliteConnection OpenReadOnly(string path)
    {
        var connection = new SqliteConnection(new SqliteConnectionStringBuilder
        {
            DataSource = path,
            Mode = SqliteOpenMode.ReadOnly,
            Cache = SqliteCacheMode.Shared
        }.ToString());
        connection.Open();
        return connection;
    }

    private static ThreadState ScanRollout(
        string id,
        string rolloutPath,
        DateTimeOffset updatedAt,
        DateTimeOffset approvedAt)
    {
        if (!File.Exists(rolloutPath))
        {
            return new ThreadState(id, rolloutPath, updatedAt, TaskState.Idle,
                DateTimeOffset.MinValue, DateTimeOffset.MinValue, "任务事件文件不可读");
        }

        var active = false;
        var failed = false;
        var lastEventAt = DateTimeOffset.MinValue;
        var lastStartedAt = DateTimeOffset.MinValue;
        var pendingApprovals = new Dictionary<string, DateTimeOffset>(StringComparer.Ordinal);

        try
        {
            using var stream = new FileStream(rolloutPath, FileMode.Open, FileAccess.Read,
                FileShare.ReadWrite | FileShare.Delete);
            if (stream.Length > TailBytes)
            {
                stream.Seek(-TailBytes, SeekOrigin.End);
            }
            using var text = new StreamReader(stream, Encoding.UTF8, true, 64 * 1024, leaveOpen: false);
            if (stream.Position > 0) _ = text.ReadLine();

            while (text.ReadLine() is { } line)
            {
                if (!TryReadEvent(line, out var eventType, out var timestamp, out var payload)) continue;
                if (timestamp > lastEventAt) lastEventAt = timestamp;

                switch (eventType)
                {
                    case "task_started":
                        active = true;
                        failed = false;
                        lastStartedAt = timestamp;
                        pendingApprovals.Clear();
                        break;
                    case "task_complete":
                    case "turn_aborted":
                        active = false;
                        failed = false;
                        pendingApprovals.Clear();
                        break;
                    case "task_failed":
                        active = false;
                        failed = true;
                        pendingApprovals.Clear();
                        break;
                    case "custom_tool_call":
                    case "function_call":
                    {
                        var callId = ReadString(payload, "call_id");
                        var name = ReadString(payload, "name");
                        var input = ReadString(payload, "input") ?? ReadString(payload, "arguments") ?? "";
                        if (!string.IsNullOrEmpty(callId) &&
                            (input.Contains("require_escalated", StringComparison.Ordinal) ||
                             name == "request_user_input"))
                        {
                            pendingApprovals[callId] = timestamp;
                        }
                        break;
                    }
                    case "custom_tool_call_output":
                    case "function_call_output":
                    {
                        var callId = ReadString(payload, "call_id");
                        if (callId is not null) pendingApprovals.Remove(callId);
                        break;
                    }
                }
            }
        }
        catch (IOException)
        {
            return new ThreadState(id, rolloutPath, updatedAt, TaskState.Idle,
                lastEventAt, lastStartedAt, "任务事件暂时不可读");
        }

        if (approvedAt != default)
        {
            foreach (var key in pendingApprovals.Where(x => x.Value <= approvedAt).Select(x => x.Key).ToArray())
                pendingApprovals.Remove(key);
        }

        if (pendingApprovals.Count > 0)
            return new ThreadState(id, rolloutPath, updatedAt, TaskState.WaitingApproval,
                lastEventAt, lastStartedAt, "本地事件：等待你的批准");
        if (failed)
            return new ThreadState(id, rolloutPath, updatedAt, TaskState.Failed,
                lastEventAt, lastStartedAt, "本地事件：任务异常结束");
        if (active)
            return new ThreadState(id, rolloutPath, updatedAt, TaskState.Working,
                lastEventAt, lastStartedAt, "本地事件：任务正在运行");
        return new ThreadState(id, rolloutPath, updatedAt, TaskState.Idle,
            lastEventAt, lastStartedAt, "本地事件：没有任务等待");
    }

    private static bool TryReadEvent(
        string line,
        out string eventType,
        out DateTimeOffset timestamp,
        out JsonElement payload)
    {
        eventType = "";
        timestamp = DateTimeOffset.MinValue;
        payload = default;
        try
        {
            using var document = JsonDocument.Parse(line);
            var root = document.RootElement;
            if (!root.TryGetProperty("payload", out var source)) return false;
            if (!source.TryGetProperty("type", out var typeElement)) return false;
            eventType = typeElement.GetString() ?? "";
            if (root.TryGetProperty("timestamp", out var timestampElement))
                DateTimeOffset.TryParse(timestampElement.GetString(), out timestamp);
            payload = source.Clone();
            return true;
        }
        catch (JsonException)
        {
            return false;
        }
    }

    private static string? ReadString(JsonElement element, string name) =>
        element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString()
            : null;
}
