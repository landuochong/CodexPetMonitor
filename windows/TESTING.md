# Windows 真机测试清单

## 1. 构建

安装 [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0)，在仓库根目录打开 PowerShell：

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\windows\build.ps1 -Runtime win-x64
```

成功标志：

```text
Built: ...\windows\publish\win-x64\CodexPetMonitor.exe
```

若失败，请保留完整的 `dotnet restore/build/publish` 输出。

## 2. 启动和界面

```powershell
.\windows\publish\win-x64\CodexPetMonitor.exe
```

检查：

- 宠物出现在主屏幕右下角，没有窗口背景和任务栏按钮。
- 鼠标可以直接拖动宠物。
- 鼠标移入时连续跳跃，移出后静止。
- 系统托盘出现图标；右键可以切换四种预览状态并恢复自动检测。
- 右下角绿色、红色任务计数没有遮挡拖拽。

## 3. 动画

通过托盘菜单依次测试：

- `预览：待机`：完全静止。
- `预览：工作`：工作姿态静止。
- `预览：等待批准`：持续、流畅奔跑，中间没有停顿。
- `预览：失败`：下沉哭泣、短暂停顿、原路回升，循环边界没有跳帧。
- `恢复自动检测`：回到 Codex 实际状态。

## 4. Codex 状态

打开 Windows 版 Codex/ChatGPT 桌面应用并创建测试任务：

1. 普通执行时绿色数字增加，宠物保持工作姿态。
2. 触发一个需要批准的命令，红色数字增加，宠物持续奔跑。
3. 批准后红色数字减少，奔跑立即或在约 1 秒内停止。
4. 正常取消任务不应触发哭泣。
5. 只有真实 `task_failed` 持续 3 秒才触发哭泣。

诊断文件：

```text
%USERPROFILE%\.codex\codex-pet-monitor-status-windows.json
```

重点检查：

- `dataSource`：优先为 `codex-desktop-ipc+local-events`；若为 `codex-local-events`，表示该 Codex 版本未暴露兼容 Socket，应用正在使用兜底扫描。
- `detectedState`
- `RunningCount`
- `WaitingCount`
- `Evidence`
- `liveThreadStatuses`

反馈问题时，请提供构建输出、Windows 版本、Codex/ChatGPT 桌面应用版本和该诊断文件。诊断文件不包含完整提示词或回复正文，但包含任务 ID，公开分享前请检查。
