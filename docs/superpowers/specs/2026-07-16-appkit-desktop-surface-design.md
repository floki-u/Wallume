# AppKit desktop surface design

日期：2026-07-16

摘要：本批为已完成的运行时核心提供 AppKit 边缘适配层。它监听显示器变化并为每个显示器维护一个静态桌面承载窗口，不创建真实视频播放器或完整应用 UI。

## 目标与边界

实现通知驱动的屏幕快照、差量窗口生命周期和可测试的表面工厂。运行时核心保持 Foundation-only；本批不分配媒体、不启动 AVPlayer、不写锁屏状态、不创建菜单栏或图库。

## 架构

ScreenProvider 产出稳定 DisplayID 与 frame 快照。生产实现订阅 AppKit 屏幕参数变化与应用激活通知，不使用轮询。

DesktopWindowController 在主线程根据快照创建、更新和关闭 DesktopSurface。DesktopSurfaceFactory 隔离 NSWindow 创建，测试替身仅记录调用。AppKitDesktopSurface 使用无边框、非激活、忽略鼠标、无阴影、跨 Space 的窗口，并显示空白占位视图。

## 生命周期与故障

新增显示器创建并显示表面。frame 改变时只更新该表面。消失显示器立即关闭表面。重复快照不重复创建或更新。

单个表面创建失败记录该显示器故障，不影响其他显示器，且下次快照允许重试。通知、窗口创建、更新和关闭均在主线程执行。

## 测试与验收

单元测试使用假屏幕提供者和假表面工厂，覆盖初始创建、多显示器、frame 更新、热插拔、单屏失败隔离与幂等性。生产适配器补充手动多屏检查：窗口不抢焦点、不响应鼠标、随断开屏幕关闭。

本批验收要求完整 swift test、release 构建与 whitespace 检查通过，且不调用锁屏事务或创建真实播放器。

## 后续

下一批实现 AVFoundation 播放资源和静态表面内容替换；它通过既有 PlayerPool 共享资源，不将 AppKit 对象泄漏到运行时核心。

