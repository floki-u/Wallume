# macOS 26 锁屏：补充探索记录

日期：2026-07-27  
状态：发现一个必须真机验证的新候选；尚无可发布实现

## 目标与边界

目标没有变化：让用户导入的自定义视频在 macOS 26 的真实锁定体验中稳定播放，并通过首次锁定、解锁后二次锁定、重启、多显示器和完整移除/恢复验收。

以下路线已经否决，本文不重复实施：修改 Aerial cache/manifest/`Index.plist`，伪造 `com.apple.wallpaper` Provider，及把传统 `.saver` 当作锁屏壁纸的发布替代方案。原因和实机证据见 [macos-26-lock-screen-investigation.md](macos-26-lock-screen-investigation.md)。

## 候选一：系统可选的动态图像格式（Live Photo / 动画 HEIF）

这是唯一仍可在不调用私有 API、不写系统文件的前提下进行真实锁屏实验的公开路径。Apple 的 macOS 墙纸界面允许用户添加自定义照片或图像文件；ImageIO/Photos 也公开支持 HEIF 图像序列和 Live Photo 资产模型。但 Apple 文档只把锁定/解锁动画明确赋予内建 Aerial，没有承诺用户自定义动态图像会在 Mac 锁屏播放。[自定义 Mac 墙纸](https://support.apple.com/guide/mac-help/customize-the-wallpaper-on-your-mac-mchlp3013/mac)；[Live Photos](https://developer.apple.com/design/human-interface-guidelines/live-photos)。

需要用系统界面完成一个最小 POC：分别选择一个已验证的 Live Photo、一个动画 HEIF、一个动态 HEIC，然后执行“锁定 -> 解锁 -> 再锁定 -> 重启后锁定”，记录是播放、仅首帧、拒绝导入还是退回静态内容。即使播放，仍要解决第二个问题：没有公开 API 可由 Wallume 稳定地为用户设定该锁屏素材，因此它最多先证明媒体格式可行，不能立即成为完整产品方案。

本 POC 不得写 Aerial manifest、`Index.plist`、屏保偏好或锁屏封面；不得注册私有扩展或终止 Wallpaper 进程。

## 候选二：Tahoe 现代屏保扩展（内部机制观察）

### 为什么值得单独验证

本机 macOS 26.5.2 的 PlugInKit 已登记 13 个 `com.apple.screensaver` 扩展，例如：

- `/System/Library/ExtensionKit/Extensions/Monterey.appex`
- `/System/Library/ExtensionKit/Extensions/Arabesque.appex`
- `/System/Library/Frameworks/ScreenSaver.framework/PlugIns/legacyScreenSaver.appex`

前三者的 `Info.plist` 使用 `NSExtensionPointIdentifier = com.apple.screensaver`，并声明 `ScreenSaverViewControllerClass`。其中 `legacyScreenSaver.appex` 的名字和 `ScreenSaverExtensionManagerClass = LegacyExtensionManager` 表明：现有 `.saver` bundle 是通过兼容桥接运行，并不是 Tahoe 设置界面本身的原生扩展格式。

这解释了已观察到的事实：Wallume 的传统 `Wallume.saver` 可被加载，却不在 Tahoe 的“自定”界面可靠列出。它暴露出一个不同于 `.saver` 的系统内部宿主链路，但**并没有提供可供第三方依赖的公开入口**。

**这不是公开 API 已经可用的结论。** Xcode 26.5 的公开 Screen Saver 模板仍输出 `.saver`，SDK 公共头文件只公开 `ScreenSaverView`，没有公开 `ScreenSaverExtension`/`ScreenSaverViewController` 的开发契约。因此该扩展点应视为 Apple 内部入口；能由 PlugInKit 登记也不能证明系统设置会加载第三方扩展，更不能证明它会进入真实锁屏。它不应进入 Wallume 产品代码或发行物；只有 Apple 发布契约、DTS 明确许可，或研究性质的隔离 POC 有书面授权时才可继续。

Apple 的用户文档仍明确区分屏保和锁屏：屏保可以由“锁定屏幕”启动，但墙纸中的动态 Aerial 是 Apple 内建内容。文档没有说明第三方屏保可成为自定义动态锁屏壁纸。[使用屏幕保护程序](https://support.apple.com/guide/mac-help/use-a-screen-saver-mchl4b68853d/mac)；[自定义 Mac 墙纸](https://support.apple.com/guide/mac-help/customize-the-wallpaper-on-your-mac-mchlp3013/mac)。

### 隔离 POC 的验收序列

若未来得到继续该内部机制实验的授权，POC 必须放在单独的签名 App bundle 中，不能写 `com.apple.wallpaper`、Aerial 数据、`Index.plist` 或杀掉 Wallpaper 进程。

1. 编写最小 `com.apple.screensaver` `.appex`：只显示可识别的视频帧和版本号，不复用 Wallume 锁屏状态机。
2. 用普通 Developer ID 签名后嵌入宿主 App 的 `Contents/PlugIns`，启动宿主并确认 `pluginkit -m -A -D -p com.apple.screensaver` 能登记该扩展。
3. 打开 macOS 26 的 Wallpaper > Screen Saver > Custom，确认它出现在可选列表、可预览且宿主实际建立连接。仅“已登记”不算通过。
4. 由用户在系统设置中选择该屏保；应用不得改写 `com.apple.screensaver` 偏好。验证手动锁定、闲置启动和“要求密码”后的展示边界。
5. 使用本地 H.264 和 HEVC 两个小视频，连续执行“锁定 -> 解锁 -> 再锁定”、重启后锁定和双显示器锁定。任意黑屏、崩溃、仅预览可播或只在桌面空闲时可播，均判定不满足产品硬性锁屏要求。
6. 卸载 POC，确认系统回到用户先前的屏保/锁屏选择；全程比较 Aerial manifest、`Index.plist`、锁屏 poster 的前后哈希，应完全不变。

判定规则：如果第 3 步失败，说明该扩展点对第三方不可用；如果第 4 或第 5 步失败，说明它只是屏保能力，不能承担 Wallume 的锁屏功能。只有全部通过，才值得设计与 Wallume 媒体库的受限配置通道和恢复机制。

## 管理设备专用候选：MDM ScreenSaver payload

Apple 的 Device Management 文档公开了 macOS `com.apple.screensaver` payload，字段包括 `moduleName`、`loginWindowModulePath`、`loginWindowIdleTime` 和 `askForPassword`。[ScreenSaver payload](https://developer.apple.com/documentation/devicemanagement/screensaver)。

这表示受管理设备可由配置描述文件指定屏保，并包含登录窗口的屏保字段；它值得作为**企业场景的第二个 POC**，测试已签名 `.saver` 是否能在登录窗口/锁定前阶段播放视频。

它不是通用产品解法：需要 MDM/配置描述文件的部署权限，文档仍引用 `.saver` module path，且没有把第三方视频接入 macOS 动态锁屏墙纸。除非它本身通过完整真实锁定验收，不能把它写入消费者版路线图。

## 已复核、继续排除的路径

| 路径 | 结论 | 依据 |
| --- | --- | --- |
| 公共 Wallpaper API / URL scheme | 无法设置自定义视频锁屏 | `NSWorkspace.setDesktopImageURL` 仅设置指定 `NSScreen` 的桌面图像；Apple 墙纸文档只允许自定义照片、图像或文件夹。[AppKit](https://developer.apple.com/documentation/appkit/nsworkspace/setdesktopimageurl%28_%3Afor%3Aoptions%3A%29)；[Apple 支持](https://support.apple.com/guide/mac-help/customize-the-wallpaper-on-your-mac-mchlp3013/mac) |
| `com.apple.wallpaper` ExtensionKit Provider | 被私有 entitlement 阻断 | 本机 Apple 内建 `WallpaperLegacyExtension` 和 `WallpaperDynamicExtension` 均拥有 `com.apple.private.wallpaper.extension`；此前普通签名 Provider 已能登记但未被墙纸宿主加载。公开 SDK 也没有 `WallpaperKit`。 |
| PosterKit / `com.apple.posterkit.provider` | 被私有 entitlement 阻断 | 本机 `DynamicBackgroundPosterExtension` 使用 `com.apple.posterkit.provider`，其相关框架在 `PrivateFrameworks`；它不是第三方锁屏背景入口。 |
| 动态 HEIC / Live Photo / 视频转格式 | 尚无 Mac 锁屏播放承诺 | Apple 的 Mac 文档把用户自定义墙纸限定为照片、图像、文件夹；Live Photo 锁屏播放是 iPhone/iPad 功能，不能迁移推断到 Mac。因此只保留系统 UI 的零写入 POC，不把格式转换视为方案。 |
| System Settings URL scheme / AppleScript / Shortcuts | 最多导航或操作桌面偏好 | 不构成媒体注册或锁屏视频 API。 |
| 传统 `.saver` 直接安装 | 已在 Tahoe 设置 UI 实测不可靠 | 保留为上述 MDM 专用 POC 的被测对象，不作为发布兜底。 |

## 推荐优先级

1. **Live Photo / 动画 HEIF POC**：唯一公开、无系统写入的候选。先回答“系统是否会播放”，再评估人工选择是否能满足产品体验。
2. **MDM login-window POC**：仅当产品接受企业管理设备部署时开展；它可以验证真实登录窗口阶段，但不应阻塞消费者版结论。
3. **现代 `com.apple.screensaver` 扩展**：保留为内部实现观察，不进入产品研发；因为缺少公开契约，不能把“可能登记”当作可交付能力。
4. 若 Live Photo/动画 HEIF 只显示首帧或无法稳定贯穿重启，macOS 26 上不存在 Wallume 可自行交付的公开技术路径。下一步只能是向 Apple 提交 Feedback/DTS，要求公开的动态锁屏/墙纸 Provider 能力，或等待 Apple 提供相应 API/授权。

## 本机复现命令（只读）

```sh
pluginkit -m -A -D -p com.apple.screensaver
plutil -p /System/Library/ExtensionKit/Extensions/Monterey.appex/Contents/Info.plist
plutil -p /System/Library/Frameworks/ScreenSaver.framework/PlugIns/legacyScreenSaver.appex/Contents/Info.plist
codesign -d --entitlements :- /System/Library/ExtensionKit/Extensions/WallpaperDynamicExtension.appex
```

这些命令只读取系统安装内容。任何 POC 在开始前都应记录当前墙纸相关文件哈希，并在结束后再次验证未变化。

## 首次 POC 准备记录（2026-07-27）

已在 macOS 26.5.2 上开始执行候选一的零写入准备，结果如下：

- 开始与结束时，`aerials/manifest/entries.json` 的 SHA-256 均为 `08b308dec90fd3f6aa6d29c92a1b741431cc4636cc8af607ebe6c85f8d18ff09`，`Store/Index.plist` 均为 `e9ae7e6cf6ee54497372eddf4938239a562e58b5760dfd6ea74f20324b80e680`。
- 当前 `SystemWallpaperURL` 保持为系统 `Sequoia Sunrise.mov`；`com.apple.screensaver/moduleDict` 不存在，未创建或改写屏保偏好。
- 临时目录 `/tmp/wallume-lock-poc` 中以公开 AppKit/ImageIO/AVFoundation 生成了自有 JPEG 与 H.264 MOV 配对样本。普通 AVAssetExportSession 无法重封装受系统保护的内建动态墙纸源视频，因此已停止使用系统视频作为 POC 输入。
- 配对样本尚未被 Spotlight 识别为 Live Photo，不能把它当作“验证过的 Live Photo”送入墙纸测试。公开 Photos API 文档说明 Live Photo 是照片和配对影片组成的单一 Photos asset；后续需要一个由相机/Photos 已确认的真实 Live Photo，或先在隔离 Photos 库中以公开 Photos API 验证资源配对。
- Tahoe 墙纸页的“添加照片”控件在当前 UI 自动化会话中暴露为不可点击的 offscreen Accessibility 元素。没有改用私有偏好或 UI 脚本绕过；因此尚未选择任何自定义媒体，也尚未执行锁定/重启。

下一次真机验收应由用户在系统 Wallpaper > Your Photos > Add Photo 中手动选择一个**已确认可播放**的 Live Photo，随后再执行锁定、解锁、二次锁定与重启。若系统把它作为普通静态图导入，立即记录为候选一失败，不继续伪造媒体格式或写入私有墙纸数据。
