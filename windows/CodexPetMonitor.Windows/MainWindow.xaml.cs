using System.Diagnostics;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace CodexPetMonitor.Windows;

public partial class MainWindow : Window, IDisposable
{
    private const int CellWidth = 192;
    private const int CellHeight = 208;
    private static readonly int[] FailedSequence = [0, 1, 2, 3, 4, 5, 4, 3, 2, 1];

    private readonly CodexStatusMonitor _monitor = new();
    private readonly DispatcherTimer _animationTimer;
    private readonly Stopwatch _clock = Stopwatch.StartNew();
    private readonly BitmapSource[,] _frames = new BitmapSource[11, 8];
    private TaskState _detectedState = TaskState.Idle;
    private TaskState? _manualState;
    private bool _hovered;
    private bool _clickJumpActive;
    private int _frame;
    private int _failedSequenceIndex;
    private double _frameAccumulator;
    private double _lastTickSeconds;

    public MainWindow()
    {
        InitializeComponent();
        LoadAtlas();
        PositionAtBottomRight();

        _monitor.SnapshotChanged += OnSnapshotChanged;
        _monitor.Start();

        _animationTimer = new DispatcherTimer(DispatcherPriority.Render)
        {
            Interval = TimeSpan.FromMilliseconds(16)
        };
        _animationTimer.Tick += AnimationTick;
        _lastTickSeconds = _clock.Elapsed.TotalSeconds;
        _animationTimer.Start();
        DisplayCurrentFrame();
    }

    public void SetManualState(TaskState? state)
    {
        _manualState = state;
        ResetAnimation();
    }

    private TaskState CurrentState => _manualState ?? _detectedState;

    private void LoadAtlas()
    {
        var atlas = new BitmapImage();
        atlas.BeginInit();
        atlas.UriSource = new Uri("pack://application:,,,/Assets/chopper-spritesheet.png");
        atlas.CacheOption = BitmapCacheOption.OnLoad;
        atlas.EndInit();
        atlas.Freeze();

        for (var row = 0; row < 11; row++)
        for (var column = 0; column < 8; column++)
        {
            var frame = new CroppedBitmap(atlas,
                new Int32Rect(column * CellWidth, row * CellHeight, CellWidth, CellHeight));
            frame.Freeze();
            _frames[row, column] = frame;
        }
    }

    private void PositionAtBottomRight()
    {
        var area = SystemParameters.WorkArea;
        Left = area.Right - Width - 24;
        Top = area.Bottom - Height - 24;
    }

    private void OnSnapshotChanged(StatusSnapshot snapshot)
    {
        Dispatcher.Invoke(() =>
        {
            RunningBadge.Text = $"▶ {snapshot.RunningCount}";
            WaitingBadge.Text = $"⌛ {snapshot.WaitingCount}";
            ToolTip = snapshot.Evidence;
            if (_detectedState != snapshot.State)
            {
                _detectedState = snapshot.State;
                if (_manualState is null) ResetAnimation();
            }
        });
    }

    private void AnimationTick(object? sender, EventArgs e)
    {
        var now = _clock.Elapsed.TotalSeconds;
        var elapsed = Math.Min(now - _lastTickSeconds, 0.1);
        _lastTickSeconds = now;
        _frameAccumulator += elapsed;

        var interval = CurrentFrameInterval();
        if (_frameAccumulator < interval) return;
        _frameAccumulator %= interval;
        AdvanceFrame();
    }

    private double CurrentFrameInterval()
    {
        if (CurrentState is TaskState.WaitingApproval) return 0.12;
        if (CurrentState is TaskState.Failed)
        {
            if (_frame == 0) return 0.48;
            if (_frame == 5) return 0.32;
            return 0.18;
        }
        if (_hovered || _clickJumpActive) return _frame == 4 ? 0.28 : 0.14;
        return 3600;
    }

    private void AdvanceFrame()
    {
        switch (CurrentState)
        {
            case TaskState.WaitingApproval:
                _frame = (_frame + 1) % 6;
                break;
            case TaskState.Failed:
                _failedSequenceIndex = (_failedSequenceIndex + 1) % FailedSequence.Length;
                _frame = FailedSequence[_failedSequenceIndex];
                break;
            default:
                if (_hovered)
                {
                    _frame = (_frame + 1) % 5;
                }
                else if (_clickJumpActive)
                {
                    if (_frame == 4)
                    {
                        _clickJumpActive = false;
                        _frame = 0;
                    }
                    else
                    {
                        _frame++;
                    }
                }
                else
                {
                    _frame = 0;
                }
                break;
        }
        DisplayCurrentFrame();
    }

    private void DisplayCurrentFrame()
    {
        var row = CurrentState switch
        {
            TaskState.Idle => 0,
            TaskState.Working => 7,
            TaskState.WaitingApproval => 1,
            TaskState.Failed => 5,
            _ => 0
        };
        if (CurrentState is not (TaskState.WaitingApproval or TaskState.Failed) &&
            (_hovered || _clickJumpActive)) row = 4;
        PetImage.Source = _frames[row, _frame];
    }

    private void ResetAnimation()
    {
        _frame = 0;
        _failedSequenceIndex = 0;
        _frameAccumulator = 0;
        _lastTickSeconds = _clock.Elapsed.TotalSeconds;
        DisplayCurrentFrame();
    }

    private void Window_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ButtonState != MouseButtonState.Pressed) return;
        _clickJumpActive = CurrentState is not (TaskState.WaitingApproval or TaskState.Failed);
        ResetAnimation();
        try { DragMove(); } catch (InvalidOperationException) { }
    }

    private void Window_MouseEnter(object sender, MouseEventArgs e)
    {
        if (CurrentState is TaskState.WaitingApproval or TaskState.Failed) return;
        _hovered = true;
        ResetAnimation();
    }

    private void Window_MouseLeave(object sender, MouseEventArgs e)
    {
        _hovered = false;
        _clickJumpActive = false;
        ResetAnimation();
    }

    public void Dispose()
    {
        _animationTimer.Stop();
        _monitor.Dispose();
    }
}
