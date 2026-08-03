using System.IO;
using System.Text.Json;

namespace CodexPetMonitor.Windows;

internal sealed class CodexStatusMonitor : IDisposable
{
    private static readonly TimeSpan FailureConfirmationDelay = TimeSpan.FromSeconds(3);
    private readonly LocalEventScanner _scanner = new();
    private readonly CodexLiveStatusMonitor _live = new();
    private readonly CancellationTokenSource _cancellation = new();
    private readonly object _gate = new();
    private readonly Dictionary<string, DateTimeOffset> _failureCandidateSince = new(StringComparer.Ordinal);
    private IReadOnlyList<ThreadState> _localStates = [];
    private IReadOnlyDictionary<string, LiveThreadStatus> _liveStates =
        new Dictionary<string, LiveThreadStatus>();
    private bool _liveConnected;
    private string? _foregroundThreadId;

    public event Action<StatusSnapshot>? SnapshotChanged;

    public void Start()
    {
        _live.Changed += OnLiveChanged;
        _live.Start();
        _ = Task.Run(PollLoopAsync);
    }

    private async Task PollLoopAsync()
    {
        while (!_cancellation.IsCancellationRequested)
        {
            try
            {
                var states = _scanner.Scan();
                lock (_gate) _localStates = states;
                _live.UpdateSubscriptions(states.Select(x => x.Id));
                Recompute();
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or Microsoft.Data.Sqlite.SqliteException)
            {
                Publish(new StatusSnapshot(TaskState.Idle, 0, 0, null,
                    $"无法读取 Codex 本地状态：{ex.Message}", false, DateTimeOffset.Now));
            }

            try { await Task.Delay(1000, _cancellation.Token); }
            catch (OperationCanceledException) { break; }
        }
    }

    private void OnLiveChanged(
        bool connected,
        IReadOnlyDictionary<string, LiveThreadStatus> statuses)
    {
        lock (_gate)
        {
            _liveConnected = connected;
            _liveStates = statuses;
        }
        Recompute();
    }

    private void Recompute()
    {
        IReadOnlyList<ThreadState> local;
        IReadOnlyDictionary<string, LiveThreadStatus> live;
        bool liveConnected;
        lock (_gate)
        {
            local = _localStates;
            live = _liveStates;
            liveConnected = _liveConnected;
        }

        var now = DateTimeOffset.Now;
        var localById = local.ToDictionary(x => x.Id, StringComparer.Ordinal);
        HashSet<string> failureCandidates;
        if (liveConnected)
        {
            failureCandidates = live
                .Where(x => x.Value.ReportsSystemError &&
                            localById.GetValueOrDefault(x.Key)?.State == TaskState.Failed)
                .Select(x => x.Key)
                .ToHashSet(StringComparer.Ordinal);
        }
        else
        {
            failureCandidates = local.Where(x => x.State == TaskState.Failed)
                .Select(x => x.Id).ToHashSet(StringComparer.Ordinal);
        }

        lock (_gate)
        {
            foreach (var stale in _failureCandidateSince.Keys
                         .Where(id => !failureCandidates.Contains(id)).ToArray())
                _failureCandidateSince.Remove(stale);
            foreach (var id in failureCandidates)
                _failureCandidateSince.TryAdd(id, now);
        }
        HashSet<string> confirmedFailures;
        lock (_gate)
        {
            confirmedFailures = failureCandidates.Where(id =>
                    now - _failureCandidateSince.GetValueOrDefault(id, now) >= FailureConfirmationDelay)
                .ToHashSet(StringComparer.Ordinal);
        }

        var runningCount = liveConnected
            ? live.Count(x => x.Value.State == TaskState.Working)
            : local.Count(x => x.State == TaskState.Working);
        var waitingCount = liveConnected
            ? live.Count(x => x.Value.State == TaskState.WaitingApproval)
            : local.Count(x => x.State == TaskState.WaitingApproval);

        var newestStarted = local.MaxBy(x => x.LastStartedAt);
        if (_foregroundThreadId is null || !localById.ContainsKey(_foregroundThreadId))
            _foregroundThreadId = newestStarted?.Id;
        else if (newestStarted is not null &&
                 newestStarted.LastStartedAt > localById[_foregroundThreadId].LastStartedAt)
            _foregroundThreadId = newestStarted.Id;

        var liveWaiting = live.FirstOrDefault(x => x.Value.State == TaskState.WaitingApproval);
        var localWaiting = local.Where(x => x.State == TaskState.WaitingApproval).MaxBy(x => x.LastEventAt);
        var foreground = _foregroundThreadId is not null
            ? localById.GetValueOrDefault(_foregroundThreadId)
            : local.FirstOrDefault();
        StatusSnapshot snapshot;
        if (liveConnected && !string.IsNullOrEmpty(liveWaiting.Key))
        {
            snapshot = new StatusSnapshot(TaskState.WaitingApproval, runningCount, waitingCount,
                liveWaiting.Key, $"Codex 实时状态：{waitingCount} 个任务等待你的批准", true, now);
        }
        else if (localWaiting is not null)
        {
            snapshot = new StatusSnapshot(TaskState.WaitingApproval, runningCount, waitingCount,
                localWaiting.Id, "本地事件：任务等待你的批准", liveConnected, now);
        }
        else if (local.Where(x => confirmedFailures.Contains(x.Id)).MaxBy(x => x.LastEventAt) is { } failed)
        {
            snapshot = new StatusSnapshot(TaskState.Failed, runningCount, waitingCount,
                failed.Id, "已确认：任务持续报告真实错误", liveConnected, now);
        }
        else if (foreground is not null)
        {
            var state = foreground.State;
            var prefix = "本地事件";
            if (liveConnected && live.TryGetValue(foreground.Id, out var liveStatus))
            {
                prefix = "Codex 实时状态";
                state = liveStatus.ReportsSystemError
                    ? foreground.State == TaskState.Failed ? TaskState.Idle : foreground.State
                    : liveStatus.State;
            }
            var evidence = state switch
            {
                TaskState.Working => $"{prefix}：当前任务正在运行",
                TaskState.WaitingApproval => $"{prefix}：当前任务等待你的批准",
                TaskState.Failed => $"{prefix}：当前任务异常结束",
                _ => $"{prefix}：当前任务已结束，进入待机"
            };
            snapshot = new StatusSnapshot(state, runningCount, waitingCount,
                foreground.Id, evidence, liveConnected, now);
        }
        else
        {
            snapshot = new StatusSnapshot(TaskState.Idle, runningCount, waitingCount,
                null, "没有发现 Codex 任务", liveConnected, now);
        }

        WriteDiagnostics(snapshot, local, live);
        Publish(snapshot);
    }

    private void Publish(StatusSnapshot snapshot) => SnapshotChanged?.Invoke(snapshot);

    private static void WriteDiagnostics(
        StatusSnapshot snapshot,
        IReadOnlyList<ThreadState> local,
        IReadOnlyDictionary<string, LiveThreadStatus> live)
    {
        try
        {
            var codexHome = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex");
            Directory.CreateDirectory(codexHome);
            var path = Path.Combine(codexHome, "codex-pet-monitor-status-windows.json");
            var temporary = path + ".tmp";
            var payload = new
            {
                platform = "windows",
                dataSource = snapshot.LiveConnected ? "codex-desktop-ipc+local-events" : "codex-local-events",
                detectedState = snapshot.State.ToString(),
                snapshot.RunningCount,
                snapshot.WaitingCount,
                snapshot.TrackedThreadId,
                snapshot.Evidence,
                snapshot.LiveConnected,
                snapshot.UpdatedAt,
                liveThreadStatuses = live.ToDictionary(x => x.Key, x => new
                {
                    state = x.Value.State.ToString(),
                    x.Value.StatusType,
                    x.Value.ActiveFlags,
                    x.Value.ReportsSystemError
                }),
                threadStates = local.Select(x => new
                {
                    x.Id,
                    state = x.State.ToString(),
                    x.RolloutPath,
                    x.UpdatedAt,
                    x.LastEventAt,
                    x.LastStartedAt,
                    x.Evidence
                })
            };
            File.WriteAllText(temporary, JsonSerializer.Serialize(payload, new JsonSerializerOptions
            {
                WriteIndented = true
            }));
            File.Move(temporary, path, overwrite: true);
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    public void Dispose()
    {
        _cancellation.Cancel();
        _live.Dispose();
        _cancellation.Dispose();
    }
}
