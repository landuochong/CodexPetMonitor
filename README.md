# CodexPetMonitor

CodexPetMonitor 是一个本地运行的 macOS 桌面宠物。它直接订阅 Codex Desktop 的本机任务状态，并用本地事件文件作兼容兜底，把当前状态映射成透明悬浮窗口里的 Chopper 动作。

宠物不会遮挡桌面背景，可以拖动到任意位置，并出现在所有桌面空间。无需辅助功能权限，也不会上传任务内容。

## 功能

- 通过 Codex Desktop 本机 IPC 实时识别待机、工作中、等待批准和失败状态。
- 任意任务等待用户批准时持续奔跑，批准或请求结束后自动停止。
- 空闲和工作状态保持静止，避免桌面宠物持续晃动。
- 鼠标悬停时循环跳跃，点击时完成一次跳跃。
- 透明、无边框、置顶窗口，支持直接拖拽。
- 菜单栏提供自动检测、手动状态预览和退出操作。
- 状态变化由 IPC 即时推送；每秒后台扫描仅用于任务发现和旧版本兼容。

## 状态与动作

| Codex 状态 | 宠物表现 |
| --- | --- |
| `idle` | 静止待机 |
| `working` | 切换到静止的工作姿态 |
| `waitingApproval` | 连续奔跑，直到批准或请求结束 |
| `failed` | 循环播放失败动作 |
| 鼠标悬停 | 按原版节奏循环跳跃，落地后短暂停顿 |
| 鼠标点击 | 完成一次跳跃 |

状态优先级为：等待批准/失败 > 鼠标交互 > 工作/待机。等待批准或失败时，悬停不会覆盖任务状态动作。

## 系统要求

- macOS 13 Ventura 或更高版本。
- 已安装并正在运行 Codex Desktop。实时状态通过 `~/.codex/ipc/ipc.sock` 读取。
- 若 Codex Desktop 不支持实时 IPC，应用会回退到 `~/.codex/state_5.sqlite` 与对应任务事件文件。
- 从源码构建时需要 Swift 6 和 Xcode Command Line Tools。
- 系统提供 `/usr/bin/sqlite3`（macOS 默认包含）。

## 快速开始

克隆仓库：

```bash
git clone git@github.com:landuochong/CodexPetMonitor.git
cd CodexPetMonitor
```

直接从 Swift Package 启动：

```bash
swift run CodexPetMonitor
```

构建标准 `.app`：

```bash
./scripts/build_macos.sh
open dist/CodexPetMonitor.app
```

安装到当前用户的 Applications 目录：

```bash
mkdir -p "$HOME/Applications"
ditto dist/CodexPetMonitor.app "$HOME/Applications/CodexPetMonitor.app"
open "$HOME/Applications/CodexPetMonitor.app"
```

构建脚本会生成 release 可执行文件、复制资源和 `Info.plist`，然后执行本机临时签名。首次打开由本机临时签名的应用时，macOS 可能显示常规安全提示。

如果本机同时安装了多个 macOS SDK，并出现 Swift 编译器与默认 SDK 不匹配的错误，可以显式选择一个兼容 SDK：

```bash
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk \
  ./scripts/build_macos.sh
```

## 使用方法

启动后，宠物默认出现在主屏幕右下角：

- 按住宠物拖动可以调整位置。
- 鼠标移入宠物区域会触发跳跃。
- 点击菜单栏的爪印图标可以查看识别依据。
- “手动预览”可强制切换状态，选择“自动检测”恢复实时监控。
- 菜单中的“退出”会完全关闭应用。

## 工作原理

应用只读取本机 Codex 数据，采用“实时状态优先、事件扫描兜底”的两层机制：

1. 从 `~/.codex/state_5.sqlite` 获取最近的未归档任务 ID。
2. 连接 Codex Desktop 的用户级 Unix socket `~/.codex/ipc/ipc.sock`，订阅这些任务的 `thread-stream-state-changed` 广播。
3. 直接读取 `threadRuntimeStatus.activeFlags`；`waitingOnApproval` 或 `waitingOnUserInput` 会立即映射为等待批准动作。
4. IPC 断开、Codex 未启动或任务尚未产生实时快照时，从 JSONL 生命周期事件与 `logs_2.sqlite` 进行兼容判断。
5. 任意任务的实时状态为等待批准时具有全局优先级；状态补丁会即时开始或停止奔跑。
6. IPC 读取和事件扫描均在后台运行，界面动画留在主线程。

旧实现只配对 JSONL 中的工具调用与输出。对于 `functions.exec` 内部已经返回 cell、但嵌套命令仍等待批准的情况，外层调用在 JSONL 中看起来已经完成，因此会漏报。当前版本改为读取 Codex Desktop 自己维护的 `waitingOnApproval` 标记，JSONL 不再承担实时审批判断的主职责。

应用不会联网，不会修改 Codex 的数据库或任务事件。

## 隐私与权限

CodexPetMonitor 不需要辅助功能权限。它仅以只读方式访问 `~/.codex` 下的本地状态库、日志库和任务事件，并在以下路径写入一份诊断快照：

```text
~/.codex/codex-pet-monitor-status.json
```

诊断文件包含任务 ID、状态、活动标记、时间戳和状态判断依据，不包含完整提示词或回复正文。`liveStatusConnected: true` 表示实时 IPC 已连接；`liveThreadStatuses` 展示 Codex Desktop 返回的精简状态。若需要分享诊断信息，请仍先检查其中的任务标识是否适合公开。

## 故障排查

### 宠物没有出现

确认进程已启动：

```bash
pgrep -fl CodexPetMonitor
```

如果使用源码运行，查看终端中的资源加载或构建错误。宠物窗口会出现在主屏幕右下角，也可能位于其他桌面空间中。

### 一直显示工作中

先查看诊断文件中的 `detectedState`、`trackedThreadID`、`lastEvidence` 和 `threadStates`：

```bash
jq . "$HOME/.codex/codex-pet-monitor-status.json"
```

与 Codex 对话或执行工具时，当前任务会被识别为 `working`；该状态现在只显示静止工作姿态。任务发出 `task_complete` 后会回到待机。

### 有批准请求但没有奔跑

- 在菜单栏确认使用的是“自动检测”，而不是手动预览状态。
- 检查诊断文件中的 `liveStatusConnected` 是否为 `true`。
- 在 `liveThreadStatuses` 中查找 `activeFlags: ["waitingOnApproval"]`，此时 `detectedState` 应立即变为 `waitingApproval`。
- 若 IPC 未连接，确认 Codex Desktop 正在运行，并检查 `~/.codex/ipc/ipc.sock` 是否存在；应用会自动每秒重连。
- 若使用较旧 Codex，只能走兼容兜底，请确认 `state_5.sqlite`、`logs_2.sqlite` 和任务事件文件可读。

### 反复要求辅助功能权限

当前版本不使用辅助功能 API，因此正常运行不应弹出辅助功能授权。若系统设置里仍有旧版 `CodexPetMonitor` 条目，可以关闭或删除该旧条目后重新启动当前版本。

## 自定义宠物素材

当前资源位于：

```text
Sources/CodexPetMonitor/Resources/chopper-spritesheet.png
```

图集采用 Codex v2 宠物规格：

- 图集尺寸：`1536 × 2288`
- 单元格尺寸：`192 × 208`
- 每行 8 列，共 11 行
- 标准动作位于第 0–8 行，16 个观察方向位于第 9–10 行

替换素材时应保持相同尺寸、透明背景和动作行语义。运行时会按固定单元格裁切，不会自动推断不规则布局。

## 项目结构

```text
CodexPetMonitor/
├── AppBundle/Contents/Info.plist       # macOS 应用包模板
├── Package.swift                       # Swift Package 配置
├── Sources/CodexPetMonitor/
│   ├── CodexPetMonitorApp.swift        # 状态监控、窗口、交互与动画
│   ├── CodexIPCStatusMonitor.swift      # Codex Desktop 实时状态 IPC 客户端
│   └── Resources/
│       └── chopper-spritesheet.png     # v2 动画图集
└── scripts/build_macos.sh              # release .app 构建脚本
```

## 已知限制

- Codex Desktop 本机 IPC 与本地数据库都不是稳定的公共接口，Codex 更新后可能需要适配。
- 当前只检查最近 20 个未归档且有预览内容的任务。
- 多个任务并行时，任意等待批准任务都会优先显示；否则跟踪最近真正启动的任务。
- 当前没有自动启动项，需要用户手动启动或自行添加到“登录项”。

## License

源代码采用 [MIT License](LICENSE)。仓库中角色素材仅用于个人桌面宠物与技术演示；角色及相关视觉形象的权利归其各自权利人所有，MIT License 不代表对第三方角色素材授予任何额外权利。
