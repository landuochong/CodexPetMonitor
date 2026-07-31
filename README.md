# CodexPetMonitor

CodexPetMonitor 是一个本地运行的 macOS 桌面宠物。它读取 Codex 在本机记录的任务生命周期事件，把当前状态映射成透明悬浮窗口里的 Chopper 动作。

宠物不会遮挡桌面背景，可以拖动到任意位置，并出现在所有桌面空间。无需辅助功能权限，也不会上传任务内容。

## 功能

- 自动识别 Codex 的待机、工作中、等待批准和失败状态。
- 任意任务等待用户批准时持续奔跑，批准或请求结束后自动停止。
- 空闲和工作状态保持静止，避免桌面宠物持续晃动。
- 鼠标悬停时循环跳跃，点击时完成一次跳跃。
- 透明、无边框、置顶窗口，支持直接拖拽。
- 菜单栏提供自动检测、手动状态预览和退出操作。
- 每秒在后台扫描一次，本地诊断信息可用于排查误判。

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
- 已安装并使用过 Codex，且本机存在 `~/.codex/state_5.sqlite` 与对应任务事件文件。
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

应用只读取本机 Codex 数据：

1. 从 `~/.codex/state_5.sqlite` 获取最近的未归档任务及事件文件路径。
2. 从任务 JSONL 事件中识别 `task_started`、`task_complete`、`task_failed`、`turn_aborted` 和工具调用。
3. 从 `~/.codex/logs_2.sqlite` 判断批准请求是否已经得到响应。
4. 等待批准状态具有全局优先级；否则持续跟踪最近真正启动的前台任务。
5. 状态扫描在后台串行队列运行，界面动画留在主线程。

应用不会联网，不会修改 Codex 的数据库或任务事件。

## 隐私与权限

CodexPetMonitor 不需要辅助功能权限。它仅以只读方式访问 `~/.codex` 下的本地状态库、日志库和任务事件，并在以下路径写入一份诊断快照：

```text
~/.codex/codex-pet-monitor-status.json
```

诊断文件包含任务 ID、状态、时间戳和状态判断依据，不包含完整提示词或回复正文。若需要分享诊断信息，请仍先检查其中的任务标识是否适合公开。

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
- 检查诊断文件中是否出现 `waitingApproval`。
- 确认 Codex 的 `state_5.sqlite`、`logs_2.sqlite` 和任务事件文件可读。
- 如果 Codex 更新后更改了本地数据库或事件格式，需要同步更新扫描逻辑。

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
│   └── Resources/
│       └── chopper-spritesheet.png     # v2 动画图集
└── scripts/build_macos.sh              # release .app 构建脚本
```

## 已知限制

- Codex 本地数据库和事件格式不是稳定的公共接口，Codex 更新后可能需要适配。
- 当前只检查最近 20 个未归档且有预览内容的任务。
- 多个任务并行时，任意等待批准任务都会优先显示；否则跟踪最近真正启动的任务。
- 当前没有自动启动项，需要用户手动启动或自行添加到“登录项”。

## License

源代码采用 [MIT License](LICENSE)。仓库中角色素材仅用于个人桌面宠物与技术演示；角色及相关视觉形象的权利归其各自权利人所有，MIT License 不代表对第三方角色素材授予任何额外权利。
