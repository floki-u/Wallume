import AVKit
import SwiftUI
import WallumeCore

public struct MediaDetailView: View {
    let item: MediaItem
    let onReveal: () -> Void
    let onDelete: () -> Void
    @State private var preview = MediaPreviewController()

    public init(item: MediaItem, onReveal: @escaping () -> Void, onDelete: @escaping () -> Void) {
        self.item = item; self.onReveal = onReveal; self.onDelete = onDelete
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
            }
            HStack {
                Button("播放预览") { preview.play(item.variantURL) }
                Button("在 Finder 中显示", action: onReveal)
                Spacer()
                Button("删除", role: .destructive, action: onDelete)
            }
        }
        .padding(20).frame(minWidth: 560, minHeight: 440)
        .onDisappear { preview.releasePlayer() }
    }
}
