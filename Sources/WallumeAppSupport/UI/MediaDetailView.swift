import AVKit
import AppKit
import SwiftUI
import WallumeCore

public struct MediaDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let item: MediaItem
    let onReveal: () -> Bool
    let onDelete: () -> Void
    let onSetWallpaper: (() -> Void)?
    let onChooseDisplay: (() -> Void)?
    @State private var preview = MediaPreviewController()
    @State private var revealError: String?

    public init(item: MediaItem, onReveal: @escaping () -> Bool, onDelete: @escaping () -> Void, onSetWallpaper: (() -> Void)? = nil, onChooseDisplay: (() -> Void)? = nil) {
        self.item = item; self.onReveal = onReveal; self.onDelete = onDelete; self.onSetWallpaper = onSetWallpaper; self.onChooseDisplay = onChooseDisplay
    }

    public var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let player = preview.player {
                        WallumeVideoPreview(player: player)
                    } else if let image = NSImage(contentsOf: item.coverURL) {
                        Image(nsImage: image).resizable().scaledToFill()
                    } else {
                        Color(nsColor: .underPageBackgroundColor)
                    }
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipped()
                Button("播放", systemImage: "play.fill") { preview.play(item.variantURL) }
                    .buttonStyle(.borderedProminent)
                    .tint(WallumeDesign.accent)
                    .padding(18)
            }

            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.displayName).font(.title2.weight(.bold))
                        Text("\(item.pixelWidth) × \(item.pixelHeight)  ·  \(item.codec)  ·  \(item.frameRate.formatted()) fps")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let onSetWallpaper {
                        Button("应用到主显示器", systemImage: "display", action: onSetWallpaper)
                            .buttonStyle(.borderedProminent)
                            .tint(WallumeDesign.accent)
                    }
                }

                Grid(alignment: .leading, horizontalSpacing: 30, verticalSpacing: 8) {
                    GridRow { Text("时长").foregroundStyle(.secondary); Text(item.durationSeconds.formatted()) }
                    GridRow { Text("文件大小").foregroundStyle(.secondary); Text(ByteCountFormatter.string(fromByteCount: item.sourceByteCount, countStyle: .file)) }
                    GridRow { Text("源文件").foregroundStyle(.secondary); Text(item.sourceURL.path).lineLimit(1).textSelection(.enabled) }
                }

                HStack {
                    Button("在 Finder 中显示", systemImage: "folder") {
                        if !onReveal() { revealError = "无法在 Finder 中显示源文件" }
                    }
                    if let onChooseDisplay {
                        Button("选择显示器", systemImage: "display.2", action: onChooseDisplay)
                    }
                    Spacer()
                    Button("删除", systemImage: "trash", role: .destructive, action: onDelete)
                    Button("关闭") { dismiss() }
                }
            }
            .padding(24)
        }
        .frame(minWidth: 700, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .onDisappear { preview.releasePlayer() }
        .alert("操作失败", isPresented: Binding(get: { revealError != nil }, set: { if !$0 { revealError = nil } })) {
            Button("知道了") { revealError = nil }
        } message: { Text(revealError ?? "") }
    }
}

/// `VideoPlayer` crashes inside `_AVKit_SwiftUI` on macOS 26 when it replaces the cover image
/// during a SwiftUI layout transaction. Keep AVKit's AppKit view stable instead.
private struct WallumeVideoPreview: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player {
            view.player = player
        }
    }
}
