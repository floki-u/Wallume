# Phase-three occlusion and benchmark design

日期：2026-07-16

摘要：本批完成第三阶段可在当前机器实施的最后工作：无额外权限的保守遮挡暂停、显式性能基准模式和开发机报告。基础款 M1/macOS 14 正式认证保留为硬件阻塞，不宣称通过。

## 遮挡检测

WindowOcclusionMonitor 监听前台应用变化、Space 激活、显示器参数变化和应用激活事件，不使用定时轮询。WindowSnapshotProviding 封装 CGWindowListCopyWindowInfo，自动测试注入合成窗口列表。

检测按显示器独立计算。它忽略 Wallume 自身、桌面元素、透明或隐藏窗口，以及非普通应用窗口。只有其他应用窗口的可见区域并集完全覆盖一块显示器，才认为该显示器被遮挡。

只有全部活跃壁纸显示器都被完全覆盖时，运行环境才包含 appObscured。任一活跃显示器仍可见时继续播放。窗口列表读取失败或数据不完整时保持播放，避免误暂停。

本批不请求辅助功能权限。WindowSnapshotProviding 为第四阶段的精确 Accessibility 事件来源保留替换边界。

## 性能采集

wallume-runtime 增加 benchmark 子命令：

wallume-runtime benchmark <media-uuid> --duration <seconds> --scenario <label>

benchmark 显式启用每秒 RSS 与 CPU 采样。正常壁纸运行不启动采样定时器。场景标签支持 single-1080p、single-4k、dual-shared 和 paused；工具记录真实环境，不伪造显示器或媒体尺寸。

JSON 报告包含硬件型号、macOS 版本、显示器数量、媒体尺寸和帧率、样本数、峰值与平均 RSS、平均与峰值 CPU、暂停原因、共享播放器数量、场景标签和 GPU 验收状态。

GPU 状态为 notMeasured、pass 或 fail，由 Instruments 或 Metal HUD 人工检查后记录。开发机报告明确标为 developmentOnly。

## 完成标准

自动测试覆盖窗口过滤、区域并集、多显示器全遮挡、读取失败保守继续、事件触发，以及性能样本聚合和 JSON 编码。release 构建包含 benchmark 工具，完整测试与 whitespace 检查通过。

完成本批后，第三阶段状态为 engineeringComplete，正式性能认证为 blockedByHardware。基础款 M1/macOS 14 上验证 CPU、RSS 和 GPU 门槛后，才能改为 certified。

第三阶段工程成果完成并合并后，统一推送远端。

