# EasySub

原生 macOS 字幕下载工具，已从 Objective-C / XIB 重构为 **Swift 6 + SwiftUI**。
支持 macOS 14 及以上，Apple Silicon 和 Intel，无第三方依赖。

## 使用

1. 拖入视频、文件夹，或按 `⌘O` 添加；自动递归扫描并去重。
2. 选择 ASS 优先、SRT 优先或两种格式。
3. 点击“下载待处理项”（`⌘Return`）。字幕保存到视频所在目录。
4. 在列表中查看结果；选择条目查看错误详情，右键可在访达中显示。

“下载待处理项”会并行搜索已启用的字幕来源，按片名、年份、季集、语言和来源可信度自动选择并下载。
首选格式不可用时尝试另一种格式；“两种格式”最多各保存一份。无法可靠匹配时保留手动选择入口。
已有字幕默认保留；可在设置中显式启用替换。失败、取消或部分完成的条目可再次下载。
下载期间可继续导入，新加入的视频留待下一批。完成条目保留至手动清除。
任务队列只保存在当前运行期间，不会在重启后自动恢复。

支持 MKV、MOV、MP4、M4V、RMVB、AVI、MPEG、MPG、TS、M2TS、WebM；
跳过隐藏文件、软件包及符号链接，避免目录循环。文件至少需要 8 KB 才能生成射手指纹。
界面支持简体中文、English，默认跟随系统应用语言，也可在设置的“语言”中手动选择。
语言更改在下次打开应用时生效，请在下载完成后再退出。App 名称始终为 EasySub。
适配浅色/深色模式；欢迎参照[翻译贡献指南](Docs/Localization.md)完善翻译或添加语言。

## 开发与验证

需要 Xcode 16 或更新版本（Swift 6）。直接打开 `EasySub.xcodeproj`，选择
`EasySub` scheme 后运行；已有 `.xcworkspace` 也可用。不再需要 CocoaPods。

```sh
# 核心逻辑测试，不依赖真实网络或用户视频
swift test

# 构建通用架构应用
xcodebuild -project EasySub.xcodeproj -scheme EasySub \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build

# Xcode 中也可以 Product > Test，或运行：
xcodebuild -project EasySub.xcodeproj -scheme EasySub \
  -destination 'platform=macOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO test
```

如果 `xcode-select -p` 指向 CommandLineTools，可在命令前临时设置
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`，不必修改系统全局设置。
构建产物为 `build/Build/Products/Release/EasySub.app`。
后续本地开发交付也统一使用上述 Release 构建命令和路径，方便直接打开最新版。
本地无签名构建用于开发；对外分发需使用自己的 Developer ID 签名并公证。

## 架构

- `Sources/EasySubApp`：SwiftUI 窗口、设置、文件选择、通知、中英文 String Catalog。
- `Sources/EasySubCore/DownloadStore.swift`：MainActor + Observation，批次快照、最多两个并发任务、取消和重试。
- `Sources/EasySubCore/Providers`：统一来源、搜索请求、候选模型与 Shooter、迅雷、ASSRT Provider。
- `Sources/EasySubCore/Services`：多源查询聚合、去重、失败回退与公共文件保存。
- `Sources/EasySubCore/Services/SubtitleArchive.swift`：通过系统 `bsdtar` 只读提取 ASSRT 压缩包中的 ASS/SRT 成员。
- `Sources/EasySubCore/HTTPTransport.swift`：可注入的 URLSession async/await 网络层。
- `Sources/EasySubCore/SubtitleService.swift`：保留 `ShooterService` 单来源兼容入口。
- `Sources/EasySubCore/VideoFiles.swift`：后台目录扫描、去重、兼容旧协议的四段 MD5 指纹。
- `Tests/EasySubCoreTests`：Swift Testing，使用临时文件和注入式网络替身。

已接入 Shooter、迅雷文件名搜索和 ASSRT 官方 API，应用通过 `MultiSourceSubtitleService` 统一调用。
选择单个视频后点击“搜索并选择字幕”，核对候选再下载。ASSRT 需在设置中启用并输入自己的 Token，Token 会自动保存在应用偏好中。
迅雷与 ASSRT 不提供可靠偏移信息，自动结果会标记“时间轴未经验证”；ASSRT 已用真实视频验证搜索、详情、下载和压缩包提取链路。SubtitleBest、A4K 暂未接入。
默认只启用迅雷。Shooter 是依赖精确文件版本的旧版指纹来源，当前匹配稀少，因此默认关闭，但仍可在设置中手动启用。
详见 [来源使用、验证状态与限制](Docs/Providers.md)。

核心可作为独立 Swift Package 测试；Xcode 应用和无宿主测试 target 编译相同核心源码。
新增或删除 Swift 文件后执行 `python3 Scripts/generate_project.py`，同步可复现的工程配置。
调整构建设置时也应修改生成脚本。CI 会检查工程同步、测试及 Release 构建。

## 网络与文件策略

- 迅雷按文件名查询，ASSRT 使用片名与年份查询、Bearer Token 鉴权并按默认配额限流；手动下载验证基本格式并转为 UTF-8。
- 使用原有射手接口 `https://www.shooter.cn/api/subapi.php`；仅发送视频指纹和文件名，不发送视频内容或完整目录路径。
- MD5 仅用于与射手的指纹协议兼容，不承担安全校验用途。
- 除 ASSRT 的 `fileN.assrt.net` / `dlN.assrt.net` 文件下载外只接受 HTTPS。ATS 仅对 `assrt.net` 子域作窄范围例外；ASSRT API 和 Token 始终使用 HTTPS。
- ASSRT 压缩包通过系统 `bsdtar` 只读列出并提取 ASS/SRT 成员，不把压缩包内路径写入磁盘；归档限制 32 MiB，单个字幕限制 8 MiB。
- 请求超时 30 秒，资源超时 90 秒；查询响应限制 2 MiB，单份字幕限制 8 MiB。
- 检查 HTTP 状态、JSON 结构、空响应和 HTML 错误页，兼容旧接口的 `0xff` / `-1` 无匹配标记。
- 每种格式按顺序尝试候选，成功后停止；部分成功会明确显示，其他视频不受影响。
- 自动下载保留已有字幕时，先写入同目录临时文件再移动；目标已存在则失败。手动选择可连续下载，同格式候选使用 `.1`、`.2` 后缀保留多份；替换模式使用原子写入。
- 当前面向直接分发，启用 Hardened Runtime，未启用 App Sandbox，以支持任意拖入视频目录的同目录写入。
  若未来发布 Mac App Store，需实现文件夹授权与 security-scoped bookmark，再启用 Sandbox。
- 通知默认关闭，用户在设置开启时才申请权限。

2026-10-20 已使用公开历史指纹验证射手旧接口：查询返回 3 个 SRT，下载内容有效。
该服务依赖视频文件的精确版本且当前有效匹配已很少；接口可达不代表特定视频一定有字幕，核心测试不依赖外部服务。

## 迁移说明

项目现以 EasySub 独立维护，应用 bundle identifier 为 `com.umlearn.EasySub`。
继续保留 `SZSubTypeKey` 偏好键，因此旧的 ASS/SRT/BOTH 设置仍可沿用；ASSRT Token
保存在应用偏好中的 `assrtToken` 键，不访问钥匙串，需要在新应用中重新录入一次。
旧 Objective-C、XIB 和 CocoaPods 配置已退出工程，历史实现可通过 Git 查看。
最低系统要求由 macOS 10.11 提高至 14，不再支持旧系统。

## 致谢与许可证

EasySub 基于原 ShooterSubX 项目演进。感谢原作者 Song Zhou 及贡献者、[Shooter.cn](https://www.shooter.cn)、
[FileLister](https://github.com/dwkns/FileLister)、
[ShooterSubPyDownloader](https://github.com/magic282/ShooterSubPyDownloader)。
沿用 [BSD-3-Clause](LICENSE.md)，保留原项目版权声明。

技术参考：[Apple 的 Observation 指南](https://developer.apple.com/documentation/swiftui/managing-model-data-in-your-app)、
[URLSession](https://developer.apple.com/documentation/foundation/urlsession)。
