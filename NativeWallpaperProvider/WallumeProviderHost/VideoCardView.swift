import SwiftUI

struct VideoCardView: View {
    let entry: VideoDeploymentService.EntryInfo
    var isSelected: Bool = false
    let onSelect: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false
    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            thumbnailView
            infoBar
        }
        .background(.quinary)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.tint, lineWidth: 2.5)
            }
        }
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .shadow(color: .black.opacity(isHovered ? 0.2 : 0.1), radius: isHovered ? 8 : 4)
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .onHover { isHovered = $0 }
        .onTapGesture { onSelect() }
        .contextMenu { contextMenuItems }
        .task { loadThumbnail() }
    }

    // MARK: - Thumbnail

    private var thumbnailView: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let thumbnail {
                    Color.clear
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .overlay {
                            Image(nsImage: thumbnail)
                                .resizable()
                                .scaledToFill()
                        }
                } else {
                    Rectangle()
                        .fill(.quaternary)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .overlay {
                            Image(systemName: "film")
                                .font(.system(size: 24))
                                .foregroundStyle(.tertiary)
                        }
                }
            }
            .clipped()

            if isHovered {
                Button {
                    onDelete()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .padding(6)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Delete")
                .padding(6)
                .transition(.opacity)
            }
        }
    }

    // MARK: - Info Bar

    private var infoBar: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 6) {
                if entry.resolution != .zero {
                    Text("\(Int(entry.resolution.width))\u{00D7}\(Int(entry.resolution.height))")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                if entry.fps > 0 {
                    Text("\(Int(entry.fps))fps")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                if entry.variants?.isEmpty == false {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.green)
                        .help("Optimized")
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: - Context Menu

    @ViewBuilder
    private var contextMenuItems: some View {
        Button("Show in Finder") { showInFinder() }
        Divider()
        Button("Delete", role: .destructive) { onDelete() }
    }

    // MARK: - Private

    private func loadThumbnail() {
        if let url = VideoDeploymentService.thumbnailURL(for: entry.id),
           let image = NSImage(contentsOf: url) {
            thumbnail = image
        }
    }

    private func showInFinder() {
        let url = VideoDeploymentService.videoURL(for: entry)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
