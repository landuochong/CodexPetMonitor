namespace CodexPetMonitor.Windows;

public enum TaskState
{
    Idle,
    Working,
    WaitingApproval,
    Failed
}

public sealed record ThreadState(
    string Id,
    string RolloutPath,
    DateTimeOffset UpdatedAt,
    TaskState State,
    DateTimeOffset LastEventAt,
    DateTimeOffset LastStartedAt,
    string Evidence);

public sealed record StatusSnapshot(
    TaskState State,
    int RunningCount,
    int WaitingCount,
    string? TrackedThreadId,
    string Evidence,
    bool LiveConnected,
    DateTimeOffset UpdatedAt);
