# macOS 26 (Tahoe) 锁屏兼容性调研

日期：2026-07-21
状态：旧 Aerial 集成已安全禁用；新提供方兼容性仍待独立调研

> **2026-07-23 决策更新：未达标，不可发布。**
>
> Wallume 的硬性产品诉求不是“看起来像锁屏”，也不是“首次锁屏能显示一次”。
> **必须让用户导入的任意自定义动态视频，在 macOS 26 的真实系统锁屏上稳定播放。**
> 只有同时通过“首次锁屏、解锁后再次锁屏、重启后的锁屏、多显示器，以及完整恢复”的真机验收，才能把该功能称为完成。
> 当前没有满足这一定义的实现；Phase 4 的锁屏部分不能验收、不能发布、不能以静态图或普通桌面窗口作为替代交付。

## 背景

Wallume 现有的锁屏同步方案在 macOS 14/15 上工作正常，在 macOS 26（Tahoe）上每次启用后第二次锁屏即变为全黑，且恢复流程经常卡死。本文档记录对 macOS 26 锁屏机制变化的逆向调研结果。

## 现有方案回顾

详见 `docs/lock-screen-safety.md` 与 `docs/superpowers/specs/2026-07-17-lock-screen-application-sync-design.md`。

核心写入路径（基于 `AerialPaths`，定义于 `Sources/WallumeCore/System/AerialPaths.swift`）：

| 路径 | 作用 |
|------|------|
| `~/Library/Application Support/com.apple.wallpaper/aerials/videos/<UUID>.mov` | 替换 Aerial 槽视频 |
| `~/Library/Application Support/com.apple.wallpaper/Store/Index.plist` | 修改锁屏索引的 `Idle` 节点 |
| `/Library/Caches/Desktop Pictures/<GeneratedUID>/lockscreen.png` | 替换锁屏封面 |

流程（`LockScreenTransaction.install()` in `Sources/WallumeCore/LockScreen/LockScreenTransaction.swift`）：

1. 备份 Aerial 槽视频与 lockscreen poster
2. 替换 Aerial 槽视频为用户动态壁纸视频
3. 修改 `Index.plist` 让锁屏指向该槽
4. 替换 lockscreen poster
5. `killall -TERM WallpaperAgent WallpaperAerialsExtension` 强制刷新

## macOS 26 关键发现

### 发现 1：Aerial provider 已被 Helios 取代

`/System/Library/CoreServices/WallpaperAgent.app/Contents/MacOS/WallpaperAgent` 中 `strings` 输出只包含两个 provider 字符串：

```
com.apple.wallpaper.choice.helios
com.apple.wallpaper.choice.image-folder
```

**不再包含 `com.apple.wallpaper.choice.aerials`**。用户 `Index.plist` 里残留的 `com.apple.wallpaper.choice.aerials` 条目是从旧系统迁移过来的历史数据，macOS 26 实际不再使用 Aerial 体系。

### 发现 2：系统源视频位置变化

`WallpaperAgent` 二进制硬编码字符串：

```
/System/Library/Desktop Pictures/.wallpapers/Tahoe Day/Tahoe Day.mov
```

实际目录内容：

```
/System/Library/Desktop Pictures/.wallpapers/
├── Sonoma/
│   ├── Sonoma Graphic Dark Landscape.mov
│   ├── Sonoma Graphic Dark Portrait.mov
│   ├── Sonoma Graphic Light Landscape.mov
│   └── Sonoma Graphic Light Portrait.mov
├── Sonoma Horizon/
└── Tahoe Day/
    └── Tahoe Day.mov          ← 170MB，系统源视频
```

**这是 macOS 26 上锁屏壁纸视频的真实存储位置**，位于 `/System/` 下，受 SIP 保护，普通程序无法写入。

### 发现 3：用户目录的 Aerial 视频只是缓存

用户 `Index.plist` 的 `Idle` 节点结构：

```
Provider: com.apple.wallpaper.choice.aerials
Configuration (binary plist): { assetID: "61AD6DD7-77F6-4C51-BCF7-7C2CDD6F985E" }
```

`assetID` 对应 `~/Library/Application Support/com.apple.wallpaper/aerials/videos/<id>.mov`，但这是**缓存目录**，不是源文件目录。

macOS 26 上 `WallpaperAgent` 的行为：
1. 读 `Index.plist`，找到 `assetID`
2. 用 `assetID` 去 `~/Library/.../aerials/manifest/entries.json` 查询 → 得到 `accessibilityLabel`（如 "Tahoe Day"）
3. **直接从 `/System/Library/Desktop Pictures/.wallpapers/<accessibilityLabel>/<accessibilityLabel>.mov` 读取源视频**，忽略用户目录下的缓存副本
4. 用户目录下 `aerials/videos/<id>.mov` 仅作为下载缓存，系统会用源文件覆盖

`entries.json` 中单个 asset 结构示例：

```json
{
  "id": "4C108785-A7BA-422E-9C79-B0129F1D5550",
  "accessibilityLabel": "Tahoe Day",
  "localizedNameKey": "TA_L_002_NAME",
  "shotID": "TA_L_002",
  "preferredOrder": 1,
  "includeInShuffle": true,
  "showInTopLevel": true,
  "url-4K-SDR-240FPS": "https://sylvan.apple.com/.../LIGHT02_20250613_V2_sdr_4k_rate12000_240p_t2160_grover74_tsa_MTE-Modified.mov",
  "previewImage": "https://sylvan.apple.com/.../TA_L_002_thumbnail.png",
  "categories": ["A33A55D9-EDEA-4596-A850-6C10B54FBBB5"],
  "subcategories": ["0DC99DD8-3386-4D1E-8878-C43E97EB710A"],
  "pointsOfInterest": {}
}
```

### 发现 4：WallpaperAerialsExtension 会主动回写槽文件

日志证据：

```
[Wallume:LockScreen] restore conflicts: ["4C108785-A7BA-422E-9C79-B0129F1D5550.mov"]
  retained: ["3232DB3D-...-4C108785-...-TahoeDay.mov.original"]
```

`WallpaperAerialsExtension` 重启后会校验 Aerial 槽 `.mov` 文件的完整性，发现 hash 不匹配即**写回原始 Aerial 视频**。这导致 Wallume 替换的槽视频被撤销。

### 发现 5：Wallpaper 相关私有 framework

`WallpaperAgent` 依赖：

```
/System/Library/PrivateFrameworks/DynamicDesktop.framework
/System/Library/PrivateFrameworks/WallpaperExtensionKit.framework
/System/Library/PrivateFrameworks/WallpaperFoundation.framework
/System/Library/PrivateFrameworks/WallpaperAnalytics.framework
/System/Library/PrivateFrameworks/Wallpaper.framework
/System/Library/PrivateFrameworks/WallpaperAerialAssets.framework    ← 资源-only，无可执行文件
/System/Library/PrivateFrameworks/WallpaperTypes.framework
```

### 发现 6：Wallpaper appex 扩展列表

```
/System/Library/ExtensionKit/Extensions/Wallpaper.appex
/System/Library/ExtensionKit/Extensions/WallpaperAerialsExtension.appex
/System/Library/ExtensionKit/Extensions/WallpaperDynamicExtension.appex   ← com.apple.wallpaper.choice.dynamic
/System/Library/ExtensionKit/Extensions/WallpaperImageExtension.appex
/System/Library/ExtensionKit/Extensions/WallpaperGradientExtension.appex
/System/Library/ExtensionKit/Extensions/WallpaperMacintoshExtension.appex
/System/Library/ExtensionKit/Extensions/WallpaperMontereyExtension.appex
/System/Library/ExtensionKit/Extensions/WallpaperSequoiaExtension.appex
/System/Library/ExtensionKit/Extensions/WallpaperSonomaExtension.appex
/System/Library/ExtensionKit/Extensions/WallpaperVenturaExtension.appex
/System/Library/ExtensionKit/Extensions/WallpaperLegacyExtension.appex
/System/Library/ExtensionKit/Extensions/NeptuneOneWallpaper.appex
```

`helios` 字符串仅出现在 `WallpaperAgent` 主二进制中，未在任何 appex 中找到，可能是内部代号或被混淆。

## 故障现象汇总（macOS 26）

| 现象 | 根因 |
|------|------|
| 启用锁屏后第二次锁屏变黑 | WallpaperAgent 从 `/System/` 读源视频，忽略用户目录替换 |
| kill WallpaperAgent 后桌面也变黑 | WallpaperAgent 同时管理桌面壁纸，重启延迟或读到被改的 Index.plist |
| 恢复时 `restoreConflict` | 系统已把槽文件写回原版，Wallume 检测到 hash 不匹配 |
| `ambiguousRecovery` 死循环 | 多次失败产生多个 transaction manifest |
| `configurationChangedExternally` | 安装时 Date 亚秒精度在 JSON 编码时丢失（已修复） |

## 已实施的代码修复

以下修复已应用到代码中，但**不解决 macOS 26 上锁屏无效的根本问题**：

1. `LockScreenConfigurationStore.reset()` — 允许从 `.failed` 状态恢复
2. `LockScreenSyncService.reconcileStartup()` 调用 `reset()` — 解除 retry 死锁
3. `align()` 重写 — 静默清理 orphan transaction，不再触发 `ambiguousRecovery`
4. `.conflicted` phase 自动强制恢复 — `forceRecoverAndClear()`
5. `restoreIgnoringConflict()` — 忽略 conflict 完成恢复
6. `persistAfterInstall()` — install 后 persist 失败时 reload 重试
7. `lastSyncedAt` 截断到秒 — 避免 Date 亚秒精度导致 `configurationChangedExternally` 误判
8. `refreshProbeOnly()` 失败时回退到 `reconcileStartup()` — 不再卡 `retryRequired`
9. `NSHostingController` 替换 `NSHostingView` + 设置 frame/autoresizing — 修复 macOS 26 上窗口空白
10. `ImportPanelController` 打开面板前 `activate(ignoringOtherApps:)` — 修复菜单栏应用无法弹出文件选择
11. `build-app.sh` 生成 `.app` bundle — 解决 SPM 可执行文件 `Bundle.main` 为 nil 的问题

## 当前安全行为

从本轮起，macOS 26 被视为旧 Aerial 锁屏集成的只读系统：Wallume 在探测后直接显示“不支持”，不会扫描恢复记录、改写 Aerial 缓存或 `Index.plist`、替换锁屏封面，也不会重启 Wallpaper 相关进程。这样可以避免已确认的第二次锁屏全黑问题。

这不是 macOS 26 自定义动态锁屏已经兼容的声明。新的 `helios` / `image-folder` 提供方需要在独立实验中验证其格式与公开可用性，验证完成前不得启用写入。

## 2026-07-23：实机复核与屏幕保护程序路线结论

本节覆盖此前“首次能显示、第二次锁屏黑屏”的最终复核，优先级高于文中较早的乐观实验描述。

### 已得到的确定证据

| 路线 | 实机结果 | 结论 |
| --- | --- | --- |
| 私有 Aerial/manifest 注册 | Wallume 条目可短暂出现在系统“墙纸”中，首次锁屏可能显示；解锁后再次锁屏会变黑或退回默认内容。 | 不稳定，否决。 |
| 替换为 Apple 原生 `Tahoe Day.mov` 的对照实验 | 即使 Wallume 注册项使用原生 Tahoe 视频，重启相关墙纸进程后也不能稳定维持该项目。 | 根因不是用户视频编码、色彩空间或权限，而是系统冷启动时的受信任资产/提供方校验。 |
| 第三方 `com.apple.wallpaper` Provider | 扩展可以被 PlugInKit 登记，但正常开发者签名拿不到 `com.apple.private.wallpaper.extension` 和 host entitlement，系统不会加载。 | 受 Apple 私有权限边界限制，否决。 |
| 传统 `.saver` 屏幕保护程序 | `Wallume.saver` 位于 `~/Library/Screen Savers`；Spotlight 可识别，Bundle 能加载且主类可实例化；但 Tahoe 的“自定”界面没有列出它。 | 不能作为 Tahoe 可交付的锁屏兜底。 |

传统 ScreenSaver 框架的公开规范仍要求 `.saver` bundle 与 `ScreenSaverView`，而实际 Tahoe 设置界面未可靠枚举该模块。该差异必须按真实系统行为处理，不能因为 bundle 校验成功而宣称功能可用。

### 关键根因

“第一次正常、解锁后再次锁屏黑屏”并非随机问题：第一次渲染可复用仍在内存中的墙纸/扩展缓存；解锁后相关私有提供方冷启动，会重新校验 Apple 管理的提供方和资产目录。Wallume 写入的 UUID、manifest 和视频文件不属于该受信任目录，因此失去缓存后无法再次被系统锁屏渲染。

这也说明以下做法都不满足产品要求：

- 仅修改 `Index.plist` 或 Aerial 缓存；
- 通过重启 `WallpaperAgent` 强制刷新；
- 只验证“第一次锁屏”；
- 把静态封面、普通桌面窗口、或未被 Tahoe 枚举的传统屏保当作“动态锁屏”。

### 后续研究计划（按证据门槛推进）

1. **先冻结所有 Tahoe 自动私有写入。** 保留无阻塞的恢复/清理能力，默认不再写入 Aerial、墙纸索引或系统封面；移除会把“已注册”误报为“已稳定播放”的 UI 文案。
2. **建立隔离的 Tahoe 锁屏验收实验。** 每个候选方案都必须从干净系统状态开始，并记录：写入内容、首次锁屏、解锁、二次锁屏、重启、双显示器、恢复后的系统状态与日志。实验代码不进入发行路径。
3. **只探索能真正进入系统锁屏渲染链的机制。** 优先寻找 Apple 新增的公开 API、可获得的 Apple 授权 entitlement、或由系统文档明确支持的动态媒体提供方；`image-folder` 仅在能证明接受本地视频并通过二次锁屏验收时继续。
4. **明确排除伪替代方案。** 独立全屏窗口、屏幕保护程序、静态降级只能作为辅助体验，不能关闭或替代“原生锁屏自定义动态视频”这个需求。
5. **设定停止条件。** 若没有公开/获授权的系统渲染入口，必须把事实记录为“macOS 26 当前不具备可发布实现”，而不是继续累积不可恢复的私有修改。只有出现可重复通过完整验收的入口，才恢复产品实现工作。

### 最终验收标准（必须全部通过）

- 用户从 Wallume 导入任意受支持视频并选择为锁屏媒体；
- 不需要手工修改系统文件或关闭 SIP；
- 首次锁屏、解锁后第二次锁屏、重启后再次锁屏均播放该视频；
- 多显示器配置不会丢失显示器选择或使任一屏黑屏；
- 失败时自动停止写入，桌面壁纸保持可用；
- 用户可在 Wallume 内一键恢复到修改前的系统锁屏状态，卸载后没有遗留条目、配置或缓存。

## 2026-07-22：新 Provider 管线签名、加载与播放验收

独立实验已经完成，结果否定了“第三方注册 `com.apple.wallpaper` Provider 后可实现本地视频锁屏”的前提：

1. Wallume 的父 App 与 `.appex` 已使用开发团队 `PD9JWWM64D` 的 Apple Development 证书完成签名，并能被 `pluginkit` 登记、选中为 `com.apple.wallpaper` Provider。
2. `pluginkit --raw` 对该扩展点返回的系统元数据强制要求 Provider 具备 `com.apple.private.wallpaper.extension`，宿主具备 `com.apple.private.wallpaper.extension-host`。这不是 Wallume 自己声明的可选能力；同一要求出现在每一个 Apple 内建 wallpaper Provider 的元数据中。
3. 以同一 Apple Development 身份、相同 bundle ID、`xcodebuild -allowProvisioningUpdates` 申请两项能力，Xcode 返回：`Entitlement com.apple.private.wallpaper.extension not found and could not be included in profile`，以及对应 host entitlement 的同样错误。
4. 不带私有能力的扩展虽会登记，但系统“墙纸”页不加载它，也不会建立 Provider XPC 连接；因此无法提交 choice request、无法获得渲染上下文、更无法播放视频。

结论：这条新 Provider 管线是 Apple 私有接口，常规 Apple Developer 团队不能在本机合法签名、加载或播放自定义视频锁屏。继续逆向 XPC 方法签名不能改变该系统权限边界。后续只有 Apple 授权这两项 entitlement 或发布公开 API 时，才重新评估。

## 2026-07-22：实机 Provider 边界复核（只读）

在用户手动切换到 Apple 内建动态壁纸后，对本机 macOS 26.5.2 的配置和系统扩展进行了只读检查，得到以下补充证据：

1. 当前与历史空间的 `Idle` 选择会使用 `com.apple.wallpaper.choice.sequoia`，其 `Configuration` 为空；自定义文件壁纸则使用 `com.apple.wallpaper.choice.image`，配置包含本地图片 URL，但配对的 `Idle` 仍为系统提供方。换言之，已观察到的自定义本地文件路径只适用于桌面静态图片，不能把本地视频带入锁屏动态提供方。
2. `WallpaperSequoiaExtension`、`WallpaperDynamicExtension` 与 `WallpaperAerialsExtension` 虽同属私有 `com.apple.wallpaper` 扩展点，但都带有 Apple 私有 entitlement `com.apple.private.wallpaper.extension`。Wallume 不能获得或合法签名该权限。
3. `WallpaperDynamicExtension` 只被授予访问 `com.apple.MobileAsset.DesktopPicture` 系统资产以及系统应用支持目录的权限；`WallpaperAerialsExtension` 对视频缓存/manifest 的写入权限也仅限 Apple 受控目录。它们不是可由第三方注册、传入任意本地视频的扩展接口。

因此，当前没有一个可由普通第三方 macOS 应用安全调用的“自定义视频 → macOS 26 锁屏动态壁纸”导入通道。继续修改 `Index.plist`、伪造 Provider 或替换缓存文件，只能依赖 Apple 私有实现且已知会造成黑屏；不应进入产品代码或发布版本。

## macOS 26 可行方案方向

### 方向 1：改用 `com.apple.wallpaper.choice.image-folder` provider

`WallpaperAgent` 二进制支持该 provider。探索：
- Configuration 的 binary plist 格式
- 是否可指向用户目录下的自定义视频/图片文件夹
- 能否绕开 Aerial 整套机制

风险：`image-folder` 字面意思偏向"图片文件夹"，可能不支持视频/动态壁纸。

### 方向 2：`com.apple.wallpaper.choice.helios` 逆向

`helios` 仅作为字符串常量出现在 `WallpaperAgent` 二进制，未在任何 appex 中找到。可能是：
- 内部代号
- 通过 `Wallpaper.appex` 或 `NeptuneOneWallpaper.appex` 实现
- 被符号混淆

需要反汇编 `WallpaperAgent` 主二进制定位 `helios` 的实际处理逻辑。

### 方向 3：利用 WallpaperKit 私有 API

未验证 macOS 26 上是否有 `WallpaperKit.framework`，需要进一步检查 `/System/Library/PrivateFrameworks/`。

### 方向 4：Endpoint Security API 重定向文件访问

拦截 `WallpaperAgent` 对 `/System/.../Tahoe Day.mov` 的读取，重定向到用户目录文件。需要 Endpoint Security entitlement（通常只发给安全厂商），对普通应用不现实。

### 方向 5：关闭 SIP

恢复模式 `csrutil disable` 后替换 `/System/` 源文件。不现实，会牺牲整个系统安全性。

## 下一步行动

优先探索方向 1（`image-folder` provider），次选方向 2（`helios` 逆向）。

## 相关代码位置

| 文件 | 作用 |
|------|------|
| `Sources/WallumeCore/System/AerialPaths.swift` | 路径定义 |
| `Sources/WallumeCore/LockScreen/LockScreenTransaction.swift` | install 流程 |
| `Sources/WallumeCore/LockScreen/RecoveryCoordinator.swift` | restore 流程 |
| `Sources/WallumeCore/LockScreen/WallpaperIndexPatcher.swift` | Index.plist 修改逻辑 |
| `Sources/WallumeCore/LockScreen/WallpaperRefresher.swift` | `killall` 进程刷新 |
| `Sources/WallumeAppSupport/LockScreen/LockScreenSyncService.swift` | 应用层状态机 |
| `Sources/WallumeAppSupport/LockScreen/LockScreenConfigurationStore.swift` | 配置存储 |
| `Sources/WallumeAppSupport/LockScreen/LockScreenSystemClient.swift` | 系统客户端封装 |
| `Sources/WallumeCore/System/SystemVersion.swift` | macOS 版本判定 |
