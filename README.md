# Wallume

Wallume 是一个 macOS 本地动态墙纸实验项目：导入本地视频后，可分配至内建屏或外接屏；在 macOS 26 上，还可将主显示器素材准备给原生墙纸提供者，由用户在系统设置中确认应用到桌面和锁屏。

> 实验版：项目依赖 macOS 26 的非公开墙纸行为，仅用于本地验证。请勿将其视为可在所有 macOS 版本稳定运行的正式产品。

## 本地构建

需要 Xcode、macOS 26 SDK，以及当前机器可用的 Apple Development 签名身份。

```bash
./build-app.sh
open "$(swift build --show-bin-path)/Wallume.app"
```

构建脚本会嵌入 `com.wallume.app.wallpaper` 扩展。日常本地调试如需预先注册扩展，可额外设置 `WALLUME_REGISTER_EXTENSION=1`。可按需通过以下环境变量覆盖签名设置：

```bash
WALLUME_SIGNING_IDENTITY="Apple Development: 你的名称" \
WALLUME_XCODE_SIGNING_IDENTITY="Apple Development" \
WALLUME_DEVELOPMENT_TEAM="你的 Team ID" \
WALLUME_REGISTER_EXTENSION=1 \
./build-app.sh
```

实验分发包（不提交产物）可在构建完成后生成：

```bash
./package-experimental.sh 1.2.9
```

压缩包同时包含 `Wallume.app` 和 `uninstall-wallume.sh`；请在拖入废纸篓之前运行后者。

## 使用锁屏素材

1. 导入视频，并在“显示器”中分配给主显示器。
2. 在“锁屏同步”中点击“用于锁屏”，Wallume 只会准备私有副本。
3. 按页面提示打开“系统设置 → 墙纸”，手动选择 Wallume 中准备好的动态画面。
4. 返回 Wallume，点击“我已选择，重新检查”。只有检测到扩展回传的系统选择后，才会显示“锁屏已启用”。

Wallume 不会直接改写 Apple 的墙纸存储。切换、重置或删除锁屏资源时，必须先在系统设置中选择非 Wallume 墙纸，再回到应用确认并清理。

## 清理

- 暂停使用：先在“系统设置 → 墙纸”选择非 Wallume 墙纸，再退出 Wallume；如需释放原生锁屏副本，在“锁屏同步 → 管理锁屏资源”中检查并清理。
- 完整卸载：在仍保留 `Wallume.app` 时运行 `$(swift build --show-bin-path)/uninstall-wallume.sh`，它会退出应用、确认系统已不再使用 Wallume、注销扩展并清理提供者副本。完成后再把 `Wallume.app` 拖到废纸篓。
- 如确定不再保留素材库、预览缓存、诊断和应用偏好，运行 `$(swift build --show-bin-path)/uninstall-wallume.sh --purge-data` 并输入 `DELETE`。这些 Wallume 专属目录会移到废纸篓；从其他位置导入的原始视频不会删除。

## 仓库内容

仓库只保存源码、构建/卸载脚本、应用图标和必要第三方许可。`.build`、Xcode 派生数据、应用包、DMG、证书和公证密钥均不会提交。
