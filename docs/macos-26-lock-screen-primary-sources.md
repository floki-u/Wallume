# macOS 26 锁屏兼容性：公开接口核查

日期：2026-07-22  
范围：只读核查 Apple 公共文档、当前机器的公开 SDK 与系统版本；未写入壁纸配置、未重启系统进程。

## 结论

截至 macOS 26.5.2，**没有发现 Apple 公开、受支持的 API 或文档化 URL scheme，可让第三方应用设置「自定义动态/视频锁屏壁纸」**。这仍然成立。Wallume 在 macOS 26 上的产品路径必须把自定义动态锁屏显示为不可用，并且不得写入 Aerial manifest、`Index.plist`、锁屏封面或重启 Wallpaper 相关进程。

后续实机复核已证明：本地 Aerial manifest 注册即使能让 Wallume 条目短暂出现在系统“墙纸”中，也不能稳定通过“锁定 → 解锁 → 再锁定”和重启后的锁屏验收。把媒体转为接近原生 Tahoe Aerial 的规格也没有消除受信任资产/提供方校验问题。因此 Tahoe 兼容注册和传统 `.saver` 都不能作为可发布锁屏功能或兜底方案。

## Apple 公开资料

| 问题 | 可核查的公开证据 | 结论 |
| --- | --- | --- |
| AppKit 是否能设置锁屏壁纸？ | [`NSWorkspace.setDesktopImageURL(_:for:options:)`](https://developer.apple.com/documentation/appkit/nsworkspace/setdesktopimageurl%28_%3Afor%3Aoptions%3A%29?changes=l__1) 的对象是指定 `NSScreen` 的**桌面图像** URL。 | 该 API 不是锁屏 API，也不接受视频/动态提供方。 |
| macOS 26 的动态锁屏内容如何配置？ | Apple 的 [自定义 Mac 壁纸说明](https://support.apple.com/en-mide/guide/mac-help/mchlp3013/mac) 说明内建 Aerial 在锁定/解锁时动画显示；添加自定义壁纸仅覆盖照片、图像和文件夹。 | 官方支持的是系统内建 Aerial 与用户自定义静态图像，未提供自定义视频成为 Aerial/锁屏动画的入口。 |
| 是否有官方的自定义屏保替代入口？ | Apple 的 [使用照片作为屏幕保护程序](https://support.apple.com/en-tj/guide/mac-help/mchle95c1370/26/mac/26) 只记录照片、文件夹或照片图库。 | 这不能替代自定义视频锁屏壁纸。 |
| 文档化设置入口是什么？ | Apple 的 [壁纸设置说明](https://support.apple.com/en-ie/guide/mac-help/mchlp1103/mac) 将 Wallpaper 设为系统设置中的用户界面；锁屏相关的公开选项是时钟显示位置。 | 可安全打开系统壁纸设置，但不能把它当作可自动写入锁屏媒体的 API。 |
| MDM 是否能处理？ | Apple 的 [`SettingsCommand…Wallpaper`](https://developer.apple.com/documentation/devicemanagement/settingscommand/command-data.dictionary/settings-data.dictionary/wallpaper-data.dictionary) 明确仅列 iOS/iPadOS 的锁屏/主屏位置。 | 不能用于 macOS。 |

## 本机只读验证

本机：macOS 26.5.2（25F84），Apple M4。

- Xcode 26.5 SDK 的公开框架中仅发现 `ScreenSaver.framework`，没有公开的 Wallpaper framework；在 AppKit 与 ScreenSaver 的公共头文件中检索 `wallpaper`、`lock screen`、`desktop picture`，没有锁屏壁纸写入接口。
- 当前 `/System/Library/CoreServices/WallpaperAgent.app/.../WallpaperAgent` 的只读字符串检查出现 `com.apple.wallpaper.choice.helios`、`com.apple.wallpaper.choice.image-folder` 和系统 Tahoe 视频路径；未出现旧 Aerial provider。这是实现细节，不是 Apple 公开契约，只能说明旧 Aerial 假设不可作为 macOS 26 的可靠方案。

## 后续门槛

只有在以下任一条件满足后，才重新开启“由 Wallume 写入 macOS 26 锁屏”的研发：

1. Apple 发布覆盖锁屏且允许动态媒体的公开 API 或设备管理接口；或
2. Apple 明确文档化可自动配置的系统设置 URL/配置格式，并允许第三方应用使用。

在此之前，不做私有 plist 修改、替换系统资源、替换缓存资源或重启 `WallpaperAgent` 的实验性写入。

## Provider 管线实机验收（2026-07-22）

本机已在隔离的开发 App 中完成 `com.apple.wallpaper` Provider 的注册和签名验收。结果是：**Provider 能被 PlugInKit 登记，但不能被系统墙纸宿主加载，更不能进入视频播放阶段。**

| 验收项 | 证据 | 结果 |
| --- | --- | --- |
| Apple Development 签名 | `codesign -dvv` 显示 `Apple Development: 820735157@qq.com (8F8XGGW86D)`、Team ID `PD9JWWM64D`，父 App 与 `.appex` 均已签署。 | 通过 |
| Provider 登记 | `pluginkit -m -A -D --raw -p com.apple.wallpaper` 能列出 `com.wallume.app.WallpaperExtension`。 | 通过（仅登记） |
| 系统要求 | 同一原始记录为该扩展点自动列出 `EXRequiredEntitlements = com.apple.private.wallpaper.extension`，以及 `EXRequiredHostEntitlements = com.apple.private.wallpaper.extension-host`。所有 Apple 内建 wallpaper Provider 的实际签名也含前者。 | 私有门槛确认 |
| 申请私有能力 | 在独立 Xcode 工程中，以相同开发团队和 `-allowProvisioningUpdates` 申请这两项能力，Xcode 明确拒绝：`Entitlement ... not found and could not be included in profile`。 | 不可获得 |
| 系统加载 | 缺少强制私有能力的已登记 Provider 不会出现在系统“墙纸”可选内容中，系统也没有向 Provider 建立 XPC 连接的日志。 | 未通过，符合权限拒绝 |
| 自定义视频锁屏播放 | 需要先由受授权 Provider 接收系统 XPC 请求并返回 `WallpaperRemoteContextXPC`；由于上一项未能加载，无法到达此阶段。 | 不可行 |

这次验收还排除了两个常见误判：

1. **不是缺少普通开发签名或 provisioning profile。** 该开发团队已经能完成父 App 和扩展的有效 Apple Development 签名；macOS 的常规本地开发签名不会因为没有 profile 而阻止构建。
2. **不是把 `.appex` 放错目录。** 同时测试了标准 Xcode App Extension 的 `Contents/PlugIns` 打包形式和 Wallume 的 `Contents/Extensions` 形式；两者都可被 PlugInKit 登记，但都无法满足系统 Provider 宿主的私有 entitlement 要求。

因此，第三方 Provider 管线不是一个可通过“继续逆向协议、伪造 XPC 数据或补齐普通签名”完成的方案。只有 Apple 为应用授予这两项私有 entitlement，或者未来发布等价的公开 Provider/API，才可能合法进入该管线。Wallume 不发布 Provider 实验代码；本地 Aerial 兼容注册也不得进入发行路径。

## 开源方案复核（2026-07-22）

检索到的开源项目中，`GonzaloRojas14/Wallpaper-Sync` 是唯一明确宣称可将本地视频同步到 macOS 锁屏的项目。其代码并未使用 macOS 26 的新 Provider 或一个公开接口，而是：

1. 覆盖 `~/Library/Application Support/com.apple.wallpaper/aerials/videos/<id>.mov`；
2. 改写 `Store/Index.plist` 的 `Idle`；
3. 写入 `/Library/Caches/Desktop Pictures/<uid>/lockscreen.png`；
4. 终止 `WallpaperAgent` 与 `WallpaperAerialsExtension` 以触发重新加载。

这与 Wallume 先前复现黑屏的 Aerial 媒体路线相同；脚本甚至针对 `sonoma` Provider 改写配置，不能证明其在 macOS 26.5.2 的新 `sequoia` Provider 下可靠。因此它只能作为旧系统行为的参考，不能直接引入 Wallume。

另一开源项目 `thusvill/LiveWallpaperMacOS` 也明确说明锁屏仅显示静态图，不能播放视频。Aerial 开源项目提供的是屏保/桌面连续性，不是一个让任意本地视频成为 macOS 原生动态锁屏的公开接口。未找到任何开源仓库实现或可注册 Apple 私有 `com.apple.private.wallpaper.extension` 权限。
