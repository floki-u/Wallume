# Wallume macOS 26 调试修改记录

日期：2026-07-21
目的：记录为排查 macOS 26 锁屏问题所做的所有代码修改，供后续 AI 接手验证。

## 修改总览

| # | 文件 | 修改类型 | 解决的问题 |
|---|------|---------|-----------|
| 1 | `Sources/WallumeApp/Info.plist` | 新建 | SPM 可执行文件无 bundle identifier |
| 2 | `build-app.sh` | 新建 | SPM 可执行文件无 .app bundle |
| 3 | `Sources/WallumeAppSupport/AppKit/MainWindowController.swift` | 改写 | macOS 26 主窗口空白 |
| 4 | `Sources/WallumeAppSupport/AppKit/ImportPanelController.swift` | 增改 | 菜单栏应用无法弹出文件选择 |
| 5 | `Sources/WallumeAppSupport/LockScreen/LockScreenConfigurationStore.swift` | 增改 | retry 死锁 |
| 6 | `Sources/WallumeAppSupport/LockScreen/LockScreenSyncService.swift` | 多处改写 | 锁屏状态机多个死循环 |
| 7 | `Sources/WallumeCore/LockScreen/LockScreenTransaction.swift` | 加日志 | 排查 install 失败 |
| 8 | `Sources/WallumeCore/LockScreen/WallpaperRefresher.swift` | 试改后回退 | 探索阶段（最终保持原状） |

---

## 详细修改清单

### 1. `Sources/WallumeApp/Info.plist`（新建）

**问题：** SPM 可执行文件没有 proper app bundle，`Bundle.main` 为 nil，`NSOpenPanel` 调用时抛 `bundleProxyForCurrentProcess is nil` 异常。

**修改：** 创建 Info.plist，包含 `CFBundleIdentifier=com.wallume.app` 等基础字段。

**注意：** 这个文件被 SPM 当作 unhandled resource 警告，但不影响构建。实际打包由 `build-app.sh` 完成。

### 2. `build-app.sh`（新建）

**问题：** SPM 构建产物只是裸可执行文件，不是 `.app` bundle，导致：
- `Bundle.main` 为 nil
- `NSOpenPanel` 崩溃
- macOS 系统服务连接失败（`com.apple.linkd.autoShortcut`）

**修改：** 脚本执行 `swift build --product WallumeApp` 后，在 `.build/arm64-apple-macosx/debug/` 下创建 `Wallume.app/Contents/MacOS/WallumeApp` + `Contents/Info.plist`。

**使用：**
```bash
/Users/floki/NetCode/Wapper/Wallume/build-app.sh
open /Users/floki/NetCode/Wapper/Wallume/.build/arm64-apple-macosx/debug/Wallume.app
```

### 3. `Sources/WallumeAppSupport/AppKit/MainWindowController.swift`（改写）

**问题：** macOS 26 上打开 Wallume 主窗口完全空白，SwiftUI 内容不渲染。

**根因：** 原代码用 `NSHostingView`，在 macOS 26 上 view 没有 frame 和 autoresizingMask，尺寸为 0。

**修改：**
- 改用 `NSHostingController`（通过 `window.contentViewController`）
- 设置 `controller.view.frame = window.contentView!.bounds`
- 设置 `controller.view.autoresizingMask = [.width, .height]`
- `closeAndReleaseContent()` 和 `windowWillClose()` 同步清理 `hostingController`

**验证状态：** ✓ 已验证，窗口内容正常显示。

### 4. `Sources/WallumeAppSupport/AppKit/ImportPanelController.swift`（增改）

**问题：** 点击"导入文件"/"导入文件夹"无反应，`NSOpenPanel` 弹不出来。

**根因：** Wallume 是菜单栏应用（`NSApplication.setActivationPolicy(.accessory)`），没有激活到前台，`NSOpenPanel.runModal()` 无法显示。

**修改：** 在 `run()` 方法里 `panel.runModal()` 之前加：
```swift
NSApplication.shared.activate(ignoringOtherApps: true)
```

**验证状态：** ✓ 已验证，文件选择面板可正常弹出。

### 5. `Sources/WallumeAppSupport/LockScreen/LockScreenConfigurationStore.swift`（增改）

**问题：** 配置 store 进入 `.failed` 状态后无法恢复，retry/重新检测全部被 `unavailableAfterLoadFailure` 拒绝。

**根因：** `load()` 第 48-49 行直接 throw，没有任何重置路径。

**修改：** 新增 `reset()` 方法：
```swift
public func reset() {
    guard loadState == .failed else { return }
    value = .disabled
    persistedFile = nil
    loadState = .unloaded
    publish()
}
```

**验证状态：** ✓ 已验证，retry 不再死锁。

### 6. `Sources/WallumeAppSupport/LockScreen/LockScreenSyncService.swift`（多处改写）

这是修改量最大的文件。按修改点分述：

#### 6.1 `reconcileStartup()` 调用 `reset()`

**问题：** 启动对齐时 `configurationStore.load()` 可能因 `.failed` 状态失败。

**修改：** `reconcileStartup()` 开头加：
```swift
await configurationStore.reset()
```

#### 6.2 `align()` 完全重写

**问题：** 原逻辑：
- `candidates.count > 1` → 直接 `ambiguousRecovery`
- orphan candidate phase 不匹配 → `ambiguousRecovery`
- `.conflicted` phase → `conflictedTransaction`（无恢复路径）

**修改：**
- 有 `activeTransactionID` 时：过滤出 stale transactions（id 不匹配），逐个静默 `restore()` 清理；只对 active candidate 做 phase 判断
- `.conflicted` phase → 调用 `forceRecoverAndClear()` 自动恢复
- 无 `activeTransactionID` 时：所有 orphan 静默清理，不触发 `ambiguousRecovery`
- `isEnabled=true` 且 orphan 是 `.committed` + aerialID 匹配 → `restoreOrphan()` 重新同步

#### 6.3 新增 `forceRecoverAndClear()`

**问题：** `.conflicted` phase 的 transaction 无法自动恢复，用户被卡死。

**修改：** 新增方法，强制调 `restore()`（失败也忽略），然后 `persist(.disabled)` 清空配置，保留 `selectedAerialID` 到 service 层。

```swift
private func forceRecoverAndClear(
    transactionID: UUID,
    configuration current: LockScreenConfiguration
) async -> Bool {
    publish(phase: .restoring)
    do {
        let client = systemClient
        _ = try await Task.detached {
            try client.restore(transactionID: transactionID)
        }.value
    } catch {
        print("[Wallume:LockScreen] forceRecoverAndClear restore failed (non-fatal): \(error)")
    }
    guard await persist(.disabled) else { return false }
    selectedAerialID = current.selectedAerialID
    return true
}
```

**注意：** 一开始这里写错了，传了 `LockScreenConfiguration(isEnabled: false, selectedAerialID: ...)`，但 `validate()` 规定 disabled 配置不能包含 `selectedAerialID`，导致 `disabledConfigurationContainsSyncState` 错误。后改为 `persist(.disabled)`，`selectedAerialID` 保存在 service 层的 `selectedAerialID` 属性里。

#### 6.4 新增 `restoreIgnoringConflict()`

**问题：** `restoreWithoutConflict()` 遇到 conflict 就失败，但 macOS 26 上 conflict 是常态（系统已把文件改回原版）。

**修改：** 新增方法，调 `restore()` 但完全忽略 conflict/retainedBackups，直接返回 true。

#### 6.5 修改 `explicitlyRecoverAndDisable()`

**问题：** 原代码要求 candidate phase 必须是 `.conflicted`，但实际场景下 phase 可能是其他值。

**修改：**
- 移除 `candidate.phase == .conflicted` 检查
- 改用 `restoreIgnoringConflict()` 替代 `restoreWithoutConflict()`

#### 6.6 新增 `persistAfterInstall()`

**问题：** `install()` 成功后 `persist(installed)` 失败，错误是 `configurationChangedExternally`。

**修改：** `install()` 最后一步改用 `persistAfterInstall()`：
- 先尝试 `configurationStore.update()`
- 失败且是 `configurationChangedExternally` → `reset()` + `load()` → 再 `persist()`
- 其他错误走原 `persist()` 逻辑

#### 6.7 `lastSyncedAt` 截断到秒

**问题：** `now()` 返回的 `Date` 有亚秒精度（如 `.123456`），JSON ISO8601 编码后丢失亚秒（变 `.0`），`persist()` 写入再读回时 `reloaded.configuration != configuration` → 误判为 `configurationChangedExternally`。

**修改：** `install()` 里 `lastSyncedAt` 改为：
```swift
lastSyncedAt: Date(timeIntervalSince1970: floor(now().timeIntervalSince1970))
```

**验证状态：** ✓ 已验证，install 后 persist 不再失败，锁屏可以同步成功。

#### 6.8 `refreshProbeOnly()` 失败时回退

**问题：** `刷新检测` 走 `refreshProbeOnly()`，`wasTrusted=false` 时直接 `publishRepair(.retryRequired)`，用户没有任何恢复入口。

**修改：** `wasTrusted=false` 时改为调用 `reconcileStartup()`，走完整对齐流程。

#### 6.9 加日志

以下位置加了 `print("[Wallume:LockScreen] ...")` 日志：
- `install()` 的 `verifyTrustedSource` 失败、`install` 失败、`install result invalid`
- `persist()` 失败
- `restoreWithoutConflict()` 的 restore 失败、conflict 详情
- `forceRecoverAndClear()` 的 restore 失败
- `persistAfterInstall()` 的 reload 失败

**日志格式：** `[Wallume:LockScreen] <message>`

### 7. `Sources/WallumeCore/LockScreen/LockScreenTransaction.swift`（加日志）

**问题：** `install()` 失败时没有日志，无法定位失败位置。

**修改：** 在 `install()` 的每个关键步骤加 `print` 日志：
- `exchanging video` — 开始替换视频前
- `video done, patching index` — 视频替换完成
- `index changed before exchange (daemon modified it)` — 新增检测点
- `index changed after exchange (daemon wrote back)` — 新增检测点
- `index done, writing poster` — 索引替换完成
- `poster done, refreshing` — 封面替换完成
- `committed` — 事务提交完成

**日志格式：** `[Wallume:Install] <step>`

**验证状态：** 日志确认 install 能走到 `committed`，失败发生在 persist 阶段。

### 8. `Sources/WallumeCore/LockScreen/WallpaperRefresher.swift`（试改后回退）

**探索：** 把 `processNames` 从 `["WallpaperAgent", "WallpaperAerialsExtension"]` 改为 `["WallpaperAgent"]`，验证是否 `WallpaperAerialsExtension` 是回写槽文件的元凶。

**结果：** 失败，且 kill `WallpaperAgent` 后桌面壁纸也变黑。

**当前状态：** 已回退，保持 `["WallpaperAgent", "WallpaperAerialsExtension"]`。

---

## 验证清单

以下修改已在 macOS 26 上验证通过：

- [x] 主窗口正常显示（修改 3）
- [x] 文件选择面板可弹出（修改 4）
- [x] retry 不再死锁（修改 5、6.1）
- [x] `ambiguousRecovery` 不再卡死（修改 6.2）
- [x] `.conflicted` 状态可自动恢复（修改 6.3）
- [x] install 后 persist 不再因 Date 精度失败（修改 6.7）
- [x] 锁屏可同步成功，日志走到 `[Wallume:Install] committed`（修改 6.7 + 7）

以下问题未解决（macOS 26 系统行为导致）：

- [ ] **第二次锁屏变黑** — WallpaperAgent 从 `/System/` 读源视频，忽略用户目录替换
- [ ] **kill WallpaperAgent 后桌面变黑** — WallpaperAgent 同时管理桌面壁纸
- [ ] **restore conflict** — 系统已把槽文件写回原版，Wallume 检测到 hash 不匹配

详见 `docs/macos-26-lock-screen-investigation.md`。

---

## 接手者须知

### 当前代码状态

代码可以正常 build 和运行：
```bash
swift build --product WallumeApp
/Users/floki/NetCode/Wapper/Wallume/build-app.sh
open /Users/floki/NetCode/Wapper/Wallume/.build/arm64-apple-macosx/debug/Wallume.app
```

### 已知的 macOS 26 根本问题

**Aerial 体系在 macOS 26 上已被 Helios 取代。** `WallpaperAgent` 二进制里 `com.apple.wallpaper.choice.aerials` 不存在，只有 `com.apple.wallpaper.choice-folder`。

系统源视频位置：
```
/System/Library/Desktop Pictures/.wallpapers/Tahoe Day/Tahoe Day.mov
```

用户目录 `~/Library/Application Support/com.apple.wallpaper/aerials/videos/` 只是缓存，Wallume 替换这里没用。

### 下一步探索方向

1. **`com.apple.wallpaper.choice.image-folder`** — 探索其 Configuration 格式，看能否指向用户目录的自定义视频
2. **`com.apple.wallpaper.choice.helios`** — 逆向 WallpaperAgent 主二进制定位处理逻辑
3. **WallpaperKit 私有 API** — 检查 `/System/Library/PrivateFrameworks/` 是否有可用 API

### 调试日志查看

运行 `.app` 后，日志输出到 stdout/stderr。在 Xcode 里运行（打开 `Package.swift`）可在控制台看到。终端运行用：
```bash
/Users/floki/NetCode/Wapper/Wallume/.build/arm64-apple-macosx/debug/Wallume.app/Contents/MacOS/WallumeApp
```

关键日志前缀：
- `[Wallume:Install]` — install 流程
- `[Wallume:LockScreen]` — service 层

### 避坑提示

- **不要同时运行多个 Wallume 进程**，会互相覆盖配置文件，导致 `configurationChangedExternally`
- **`persist(.disabled)` 不能传 `selectedAerialID`**，`validate()` 会拒绝，`selectedAerialID` 只能保存在 service 层
- **修改 `.app` bundle 后要 `pkill -x WallumeApp`** 确保旧进程不干扰

---

## 文件变更清单

```
新建:
  Sources/WallumeApp/Info.plist
  build-app.sh
  docs/macos-26-lock-screen-investigation.md
  docs/wallume-macos-26-debug-changes.md  (本文件)

修改:
  Sources/WallumeAppSupport/AppKit/MainWindowController.swift
  Sources/WallumeAppSupport/AppKit/ImportPanelController.swift
  Sources/WallumeAppSupport/LockScreen/LockScreenConfigurationStore.swift
  Sources/WallumeAppSupport/LockScreen/LockScreenSyncService.swift
  Sources/WallumeCore/LockScreen/LockScreenTransaction.swift
  Sources/WallumeCore/LockScreen/WallpaperRefresher.swift  (试改后回退，无实际变更)
```
