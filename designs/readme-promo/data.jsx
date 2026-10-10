const wallumeMedia = [
  {
    id: "silent-orbit",
    title: "Silent Orbit",
    subtitle: "银色轨道",
    duration: "04:24",
    meta: "2560 × 1600 · 60 fps",
    image: "assets/wallpaper-atlas.png",
    position: "0% 0%",
    atlas: true,
    tone: "mono"
  },
  {
    id: "last-train",
    title: "Last Train Home",
    subtitle: "暮色列车",
    duration: "00:38",
    meta: "3840 × 2160 · 30 fps",
    image: "assets/wallpaper-atlas.png",
    position: "50% 0%",
    atlas: true,
    tone: "amber"
  },
  {
    id: "after-rain",
    title: "After Rain",
    subtitle: "雨后城区",
    duration: "01:16",
    meta: "3840 × 2160 · 60 fps",
    image: "assets/wallpaper-atlas.png",
    position: "100% 0%",
    atlas: true,
    tone: "blue"
  },
  {
    id: "night-garage",
    title: "Night Garage",
    subtitle: "红色车库",
    duration: "00:52",
    meta: "2560 × 1440 · 30 fps",
    image: "assets/wallpaper-atlas.png",
    position: "0% 100%",
    atlas: true,
    tone: "red"
  },
  {
    id: "paper-hills",
    title: "Paper Hills",
    subtitle: "纸上原野",
    duration: "00:29",
    meta: "2880 × 1800 · 30 fps",
    image: "assets/wallpaper-atlas.png",
    position: "50% 100%",
    atlas: true,
    tone: "day"
  },
  {
    id: "quiet-neon",
    title: "Quiet Neon",
    subtitle: "夜间小店",
    duration: "00:47",
    meta: "2560 × 1600 · 60 fps",
    image: "assets/wallpaper-atlas.png",
    position: "100% 100%",
    atlas: true,
    tone: "neon"
  }
];

const wallumeDisplays = [
  { id: "studio", name: "Studio Display", detail: "5120 × 2880", main: true, mediaId: "silent-orbit", state: "正在放映" },
  { id: "macbook", name: "MacBook Pro", detail: "3024 × 1964", main: false, mediaId: "last-train", state: "正在放映" },
  { id: "desk", name: "DeskPad Display", detail: "3360 × 2100", main: false, mediaId: "after-rain", state: "已暂停" }
];

const wallumeReferences = [
  { name: "Apple HIG", role: "侧边栏、工具栏、系统材质", url: "https://developer.apple.com/design/human-interface-guidelines/" },
  { name: "Apple Photos", role: "媒体库、缩略图密度、预览", url: "https://support.apple.com/guide/photos/browse-your-photo-library-pht53854a251/mac" },
  { name: "Raycast", role: "键盘效率、命令入口、紧凑层级", url: "https://www.raycast.com/" },
  { name: "Arc", role: "侧边栏工作区、沉浸内容画布", url: "https://arc.net/" },
  { name: "Screen Studio", role: "影像舞台、克制的参数面板", url: "https://screen.studio/" }
];

Object.assign(window, { wallumeMedia, wallumeDisplays, wallumeReferences });
