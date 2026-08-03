using System.Drawing;
using System.Windows;
using Forms = System.Windows.Forms;

namespace CodexPetMonitor.Windows;

public partial class App : System.Windows.Application
{
    private Forms.NotifyIcon? _trayIcon;
    private MainWindow? _window;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        _window = new MainWindow();
        _window.Show();

        var menu = new Forms.ContextMenuStrip();
        menu.Items.Add("显示宠物", null, (_, _) => ShowPet());
        menu.Items.Add("恢复自动检测", null, (_, _) => _window.SetManualState(null));
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("预览：待机", null, (_, _) => _window.SetManualState(TaskState.Idle));
        menu.Items.Add("预览：工作", null, (_, _) => _window.SetManualState(TaskState.Working));
        menu.Items.Add("预览：等待批准", null, (_, _) => _window.SetManualState(TaskState.WaitingApproval));
        menu.Items.Add("预览：失败", null, (_, _) => _window.SetManualState(TaskState.Failed));
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("退出", null, (_, _) => Shutdown());

        _trayIcon = new Forms.NotifyIcon
        {
            Text = "Codex Pet Monitor",
            Icon = SystemIcons.Application,
            ContextMenuStrip = menu,
            Visible = true
        };
        _trayIcon.DoubleClick += (_, _) => ShowPet();
    }

    private void ShowPet()
    {
        if (_window is null) return;
        _window.Show();
        _window.Topmost = true;
        _window.Activate();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _trayIcon?.Dispose();
        _window?.Dispose();
        base.OnExit(e);
    }
}
