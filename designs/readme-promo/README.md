# README 展示素材

这个目录用于生成 README 的产品展示图与模拟操作录屏，基于项目已批准的 `wallume-redesign` 原型，并参考当前 SwiftUI 界面。它不操作真实素材库或系统墙纸。

- `index.html`：可播放、暂停和拖动时间轴的 14 秒演示。
- `promo.jsx` / `promo.css`：产品排版与操作演示。
- `assets/wallpaper-atlas.png`：沿用项目现有的示例素材。

主文档中的展示图、动图明确标注为模拟演示；显示器名称、素材和系统确认步骤仅用于说明。

预览时从仓库根目录运行 `python3 -m http.server 4311`，打开 `http://localhost:4311/designs/readme-promo/`。资源使用固定版本的 React、ReactDOM 和 Babel CDN，首次预览需要网络。

导出时向唯一的 `[data-om-exportable-video-with-duration-secs]` 元素发送 `data-om-seek-to-time-frame` 事件，使用 `detail: {time: 秒数, sync: true}`。帧由内置动画引擎同步渲染；README 图片位于 `docs/images/`。
