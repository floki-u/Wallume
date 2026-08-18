# Wallume

> 一款 macOS 本地视频动态墙纸实验应用：为内建屏和外接屏分别播放本地视频，并在 macOS 26 上协助你将素材交给系统墙纸设置。

Wallume 只处理本地文件，不上传视频，也不会自行替你修改 macOS 的墙纸选择。原生动态墙纸与锁屏需要你在“系统设置 → 墙纸”中最后确认。

> **实验版 / macOS 26**：项目依赖 macOS 26 的墙纸提供者行为，仍在验证多显示器、睡眠唤醒和锁屏切换。请把它当作测试软件使用，并保留原始视频文件。

## 适用范围

- 导入本地视频，分别分配给内建屏和外接屏。
- 在应用运行期间播放桌面动态墙纸。
- 在 macOS 26 上准备主显示器素材，让用户在系统墙纸设置中确认后用于原生桌面与锁屏。
- 提供预览缓存、诊断数据和锁屏提供者副本的独立清理路径。

当前不承诺所有 macOS 版本、所有显示器组合或所有视频编码格式都可稳定工作；原生锁屏是否生效始终以系统设置中的实际选择为准。

## 下载与安装（普通用户）

1. 打开仓库右侧的 [Releases](https://github.com/floki-u/Wallume/releases)，下载最新标为 **Pre-release** 的 `Wallume-Experimental-*-macos26.zip`。
2. 解压后，将 `Wallume.app` 拖到“应用程序”。保留同目录的 `uninstall-wallume.sh`，卸载前需要它。
3. 第一次打开前，在“终端”执行：

   ```bash
   xattr -dr com.apple.quarantine /Applications/Wallume.app
   open /Applications/Wallume.app
   ```

   实验版使用开发签名，尚未经过 Apple 公证；这一步只应对从本项目 Releases 下载的包执行。
4. 若系统仍拦截打开，在 Finder 中按住 Control 点击 `Wallume.app`，选择“打开”，再确认一次。

### 解压很慢或卡住

Finder 的“归档实用工具”偶尔会在大型应用包上停留很久。可在“终端”中直接解压：

```bash
cd ~/Downloads
ditto -x -k Wallume-Experimental-*-macos26.zip .
```

解压完成后再继续安装；不要从压缩包内直接运行应用。

## 快速开始

1. 打开 Wallume，在“素材库”导入一个本地视频或视频文件夹。
2. 到“显示器”，为内建屏和每个外接屏分别选择素材。
3. 确认桌面预览正常；拔插显示器、让电脑睡眠后唤醒时，观察各屏是否仍能恢复显示。
4. 如需原生桌面/锁屏动态墙纸，选中主显示器素材后打开“锁屏同步”，点击“用于锁屏”。
5. Wallume 准备好专属副本后会打开系统墙纸设置。在 **Wallume** 分组中选择该动态画面。
6. 回到 Wallume，点击“我已选择，重新检查”。只有系统实际回传已选状态，页面才会显示“锁屏已启用”。

### 切换、重置与删除锁屏素材

Wallume 不会越过系统直接替换锁屏。切换到新素材、改回系统墙纸或删除已使用素材时，请按下列顺序操作：

1. 在“系统设置 → 墙纸”中先选择非 Wallume 的墙纸。
2. 回到 Wallume 的“锁屏同步 → 管理锁屏资源”，点击“检查系统状态”。
3. 只有显示“可以清理”后才清理锁屏副本，随后再准备或删除素材。

如果你只希望改用一张静态图，请在系统墙纸设置中选择那张图；Wallume 不会自动替换你的系统选择。

## 暂停使用与卸载

### 暂停使用，但保留素材库

1. 在“系统设置 → 墙纸”选择非 Wallume 墙纸。
2. 退出 Wallume。
3. 需要释放原生墙纸副本时，在解压目录运行：

   ```bash
   ./uninstall-wallume.sh /Applications/Wallume.app
   ```

该命令会退出应用、注销原生墙纸扩展并清理提供者副本；已导入的素材库、缓存和设置会保留，以便之后重新使用。

### 完整卸载

仍保留 `Wallume.app` 时，在解压目录运行：

```bash
./uninstall-wallume.sh --purge-data /Applications/Wallume.app
```

先按提示确认系统已改用非 Wallume 墙纸；再输入 `DELETE`，Wallume 的素材库、缓存、诊断和偏好会被移到废纸篓。外部位置的原始视频不会删除。脚本结束后，再将 `/Applications/Wallume.app` 拖到废纸篓。

## 常见问题

### 为什么应用显示“已准备”，但锁屏没有变化？

“已准备”只代表 Wallume 创建了私有副本。请在系统墙纸设置的 **Wallume** 分组中选择它，并回到应用点击“我已选择，重新检查”。

### 为什么选择系统墙纸后，Wallume 暂时没有同步？

系统墙纸提供者的上下文会在锁屏、设置页面切换或唤醒后延迟释放。请等待数秒后点击“检查系统状态”；未确认前，不要清理当前仍可能被系统引用的资源。

### 为什么不建议直接删除 App？

拖入废纸篓不会让 macOS 执行卸载逻辑，原生墙纸扩展和提供者资源可能残留。请先运行上面的卸载脚本。

## 从源码构建（开发者）

需要：macOS 26 SDK、Xcode，以及本机可用的 Apple Development 签名身份。

```bash
git clone https://github.com/floki-u/Wallume.git
cd Wallume

WALLUME_SIGNING_IDENTITY="Apple Development: 你的名称" \
WALLUME_XCODE_SIGNING_IDENTITY="Apple Development" \
WALLUME_DEVELOPMENT_TEAM="你的 Team ID" \
./build-app.sh

open "$(swift build --show-bin-path)/Wallume.app"
```

仅在本机调试、且需要构建后立即预注册墙纸扩展时，额外设置 `WALLUME_REGISTER_EXTENSION=1`。分发构建不应设置它，以免把本机 `.build` 路径注册到系统设置。

生成不提交到 Git 的实验包：

```bash
./package-experimental.sh 1.2.9
```

产物位于 `.artifacts/`，并包含应用与卸载脚本。

## 发布实验版（维护者）

**使用 GitHub Releases，不使用 npm 或 GitHub Packages。** GitHub Release 既能将版本标签与源码对应，也能为普通用户提供一个固定下载页；npm 和 Packages 都不是 macOS 应用分发渠道。

每次发布按以下顺序进行：

1. 在干净工作区完成多显示器、睡眠唤醒、锁屏切换/删除/重置和重启恢复回归。
2. 使用发布签名构建并在另一套干净状态下验证应用：

   ```bash
   ./build-app.sh
   ./package-experimental.sh 1.2.9
   shasum -a 256 .artifacts/Wallume-Experimental-1.2.9-macos26.zip
   ```

3. 在 GitHub 的 **Releases → Draft a new release** 中创建标签 `v1.2.9-experimental`，标题写为 `Wallume 1.2.9 Experimental`，并勾选 **Set as a pre-release**。
4. 上传 `.artifacts/Wallume-Experimental-1.2.9-macos26.zip`；将上一步 SHA-256 写进发行说明，并说明已验证的 macOS 版本、已知限制及卸载方式。
5. 发布后，在一台没有开发环境痕迹的 Mac 上从 Release 下载、解压、安装、运行和卸载一次。

也可使用 GitHub CLI 创建预发布：

```bash
gh release create v1.2.9-experimental \
  .artifacts/Wallume-Experimental-1.2.9-macos26.zip \
  --title "Wallume 1.2.9 Experimental" \
  --prerelease \
  --generate-notes
```

正式面向广泛用户前，应使用 Developer ID Application 签名并通过 Apple 公证；届时可将 Release 附件升级为 `.dmg`，但 GitHub Releases 仍是下载入口。

## 反馈

提交 Issue 时请说明：macOS 版本、芯片类型、内建/外接屏数量、视频格式、复现步骤，以及是否发生在拔插显示器、睡眠唤醒或锁屏之后。请勿上传私人视频；可在“设置 → 本地数据”导出匿名诊断摘要。

## 仓库约定

仓库仅提交源码、构建/打包/卸载脚本、应用图标和必要第三方许可；`.build`、Xcode 派生数据、应用包、DMG、证书、公证密钥及 Release 产物均不提交。

本仓库尚未声明开源许可证。复用或分发源码前，请先取得仓库所有者的明确许可。
