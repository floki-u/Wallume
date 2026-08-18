# Wallume

Wallume 是一个 macOS 本地动态墙纸实验项目：导入本地视频后，可分配至内建屏或外接屏；在 macOS 26 上，还可将主显示器素材准备给原生墙纸提供者，由用户在系统设置中确认应用到桌面和锁屏。

> 实验版：项目依赖 macOS 26 的非公开墙纸行为，仅用于本地验证。请勿将其视为可在所有 macOS 版本稳定运行的正式产品。

## 本地构建

需要 Xcode、macOS 26 SDK，以及当前机器可用的 Apple Development 签名身份。

```bash
./build-app.sh
open "$(swift build --show-bin-path)/Wallume.app"
```

构建脚本会嵌入并注册 `com.wallume.app.wallpaper` 扩展。可按需通过以下环境变量覆盖签名设置：

```bash
WALLUME_SIGNING_IDENTITY="Apple Development: 你的名称" \
WALLUME_XCODE_SIGNING_IDENTITY="Apple Development" \
WALLUME_DEVELOPMENT_TEAM="你的 Team ID" \
./build-app.sh
```

## 使用锁屏素材

1. 导入视频，并在“显示器”中分配给主显示器。
2. 在“锁屏同步”中点击“用于锁屏”，Wallume 只会准备私有副本。
3. 按页面提示打开“系统设置 → 墙纸”，手动选择 Wallume 中准备好的动态画面。
4. 返回 Wallume，点击“我已选择，重新检查”。只有检测到扩展回传的系统选择后，才会显示“锁屏已启用”。

Wallume 不会直接改写 Apple 的墙纸存储。切换、重置或删除锁屏资源时，必须先在系统设置中选择非 Wallume 墙纸，再回到应用确认并清理。

## 清理

- “设置 → 本地数据”可分别清理可再生成的预览缓存和不可恢复的诊断数据，不会删除素材库或显示器分配。
- “锁屏同步 → 管理锁屏资源”会先检查系统是否不再使用 Wallume，之后才能清理锁屏副本。
- 构建后的卸载辅助脚本位于 `$(swift build --show-bin-path)/uninstall-wallume.sh`。它只注销扩展并清理提供者数据；正式卸载的素材库清理策略尚未提供。

## 仓库内容

仓库只保存源码、构建/卸载脚本、应用图标和必要第三方许可。`.build`、Xcode 派生数据、应用包、DMG、证书和公证密钥均不会提交。
