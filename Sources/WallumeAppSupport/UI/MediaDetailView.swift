import AVKit
import SwiftUI
import WallumeCore

public struct MediaDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let item: MediaItem
    let onReveal: () -> Bool
    let onDelete: () -> Void
    let onSetWallpaper: (() -> Void)?
    @State private var preview = MediaPreviewController()
    @State private var revealError: String?

    public init(item: MediaItem, onReveal: @escaping () -> Bool, onDelete: @escaping () -> Void, onSetWallpaper: (() -> Void)? = nil) {
        self.item = item; self.onReveal = onReveal; self.onDelete = onDelete; self.onSetWallpaper = onSetWallpaper
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let player = preview.player {
                VideoPlayer(player: player).frame(minHeight: 240)
            } else if let image = NSImage(contentsOf: item.coverURL) {
                Image(nsImage: image).resizable().scaledToFit().frame(minHeight: 240)
            }
            Text(item.displayName).font(.title2.bold())
            Grid(alignment: .leading) {
                GridRow { Text("分辨率"); Text("\(item.pixelWidth) × \(item.pixelHeight)") }
                GridRow { Text("帧率"); Text(item.frameRate.formatted()) }
                GridRow { Text("编码"); Text(item.codec) }
                GridRow { Text("时长"); Text(item.durationSeconds.formatted()) }
                GridRow { Text("文件大小"); Text(ByteCountFormatter.string(fromByteCount: item.sourceByteCount, countStyle: .file)) }
                GridRow { Text("源文件"); Text(item.sourceURL.path).lineLimit(2) }
            }
            HStack {
                Button("关闭") { dismiss() }
                if let onSetWallpaper { Button("设为壁纸", systemImage: "display", action: onSetWallpaper) }
                Button("播放预览") { preview.play(item.variantURL) }
                Button("在 Finder 中显示") { if !onReveal() { revealError = "无法在 Finder 中显示源文件" } }
                Spacer()
                Button("删除", role: .destructive, action: onDelete)
            }
        }
        .padding(20).frame(minWidth: 560, minHeight: 440)
        .onDisappear { preview.releasePlayer() }
        .alert("操作失败", isPresented: Binding(get: { revealError != nil }, set: { if !$0 { revealError = nil } })) {
            Button("知道了") { revealError = nil }
        } message: { Text(revealError ?? "") }
    }
}
