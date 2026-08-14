import AVFoundation
import CoreMedia
import SwiftUI

struct VideoInspectorView: View {
    let entry: VideoDeploymentService.EntryInfo
    @Bindable var manager: WallumeProviderHostManager
    @State private var thumbnail: NSImage?
    @State private var selectedPreset: OptimizationPreset = .balanced
    @State private var codec: String = ""
    @State private var confirmingRemoveVariants = false
    @State private var confirmingDelete = false

    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?
    @State private var isPlaying = false
    @State private var isHoveringPreview = false

    private var isOptimizingThis: Bool {
        manager.isOptimizing && manager.optimizingEntryID == entry.id
    }

    var body: some View {
        Form {
            previewSection
            infoSection
            optimizationSection
            actionsSection
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .task(id: entry.id) {
            loadThumbnail()
            await loadCodec()
        }
        .onChange(of: entry.id) {
            cleanupPlayer()
        }
        .onDisappear {
            cleanupPlayer()
        }
    }

    // MARK: - Preview

    private var previewSection: some View {
        Section {
            VStack(spacing: 8) {
                ZStack {
                    if let player, isPlaying {
                        PlayerLayerView(player: player)
                    } else if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(16 / 9, contentMode: .fill)
                    } else {
                        Rectangle()
                            .fill(.quaternary)
                            .aspectRatio(16 / 9, contentMode: .fill)
                            .overlay {
                                Image(systemName: "film")
                                    .font(.system(size: 24))
                                    .foregroundStyle(.tertiary)
                            }
                    }

                    playOverlay
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isHoveringPreview = hovering
                    }
                }

                Text(entry.name)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var playOverlay: some View {
        let showOverlay = isHoveringPreview || !isPlaying
        return Button {
            togglePlayback()
        } label: {
            ZStack {
                Circle()
                    .frame(width: 44, height: 44)
                    .glassEffect(.clear)

                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .opacity(showOverlay ? 1 : 0)
        .scaleEffect(showOverlay ? 1 : 0.8)
        .animation(.spring(response: 0.5, dampingFraction: 0.7), value: showOverlay)
    }

    private func togglePlayback() {
        if isPlaying {
            player?.pause()
            isPlaying = false
        } else {
            if player == nil {
                createPlayer()
            }
            player?.play()
            isPlaying = true
        }
    }

    private func createPlayer() {
        let url = VideoDeploymentService.videoURL(for: entry)
        let item = AVPlayerItem(url: url)
        let queuePlayer = AVQueuePlayer(playerItem: item)
        queuePlayer.isMuted = true
        let playerLooper = AVPlayerLooper(player: queuePlayer, templateItem: item)
        player = queuePlayer
        looper = playerLooper
    }

    private func cleanupPlayer() {
        looper?.disableLooping()
        player?.pause()
        player = nil
        looper = nil
        isPlaying = false
    }

    // MARK: - Info

    private var infoSection: some View {
        Section {
            if entry.resolution != .zero {
                LabeledContent("Resolution", value: "\(Int(entry.resolution.width)) \u{00D7} \(Int(entry.resolution.height))")
            }
            if entry.fps > 0 {
                LabeledContent("Frame Rate", value: "\(Int(entry.fps)) fps")
            }
            if entry.duration > 0 {
                LabeledContent("Duration", value: formattedDuration(entry.duration))
            }
            if let size = VideoDeploymentService.fileSize(for: entry) {
                LabeledContent("File Size", value: formattedFileSize(size))
            }
            if !codec.isEmpty {
                LabeledContent("Codec", value: codec)
            }
        }
    }

    // MARK: - Optimization

    private var optimizationSection: some View {
        Section {
            if isOptimizingThis {
                optimizingView
            } else if let variants = entry.variants, !variants.isEmpty {
                optimizedView(variants)
            } else {
                notOptimizedView
            }
        } header: {
            if !isOptimizingThis, entry.variants?.isEmpty != false {
                Text("Optimization")
            }
        }
    }

    private var optimizingView: some View {
        VStack(spacing: 8) {
            ProgressView(value: manager.optimizationProgress) {
                Text("Optimizing...")
                    .font(.system(size: 12, weight: .medium))
            }

            Button("Cancel", role: .destructive) {
                manager.cancelOptimization()
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func optimizedView(_ variants: [VideoVariant]) -> some View {
        Group {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Optimized")
                    .font(.system(size: 12, weight: .medium))
            }

            ForEach(variants, id: \.filename) { variant in
                LabeledContent("\(variant.fps) fps") {
                    Text("\(Int(variant.resolution.width))\u{00D7}\(Int(variant.resolution.height))")
                        .foregroundStyle(.secondary)
                }
            }

            Button("Remove Variants", role: .destructive) {
                confirmingRemoveVariants = true
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .alert("Remove Variants", isPresented: $confirmingRemoveVariants) {
                Button("Remove", role: .destructive) {
                    manager.removeVariants(entryID: entry.id)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will delete the optimized variants. The original video is not affected.")
            }
        }
    }

    private var notOptimizedView: some View {
        Group {
            Picker(selection: $selectedPreset) {
                ForEach(OptimizationPreset.allCases) { preset in
                    Text(preset.rawValue).tag(preset)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(selectedPreset.description)
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                manager.optimizeVideo(entryID: entry.id, preset: selectedPreset)
            } label: {
                Text("Create Variants")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(entry.resolution == .zero)
        }
    }

    // MARK: - Actions

    private var actionsSection: some View {
        Section {
            Button {
                let url = VideoDeploymentService.videoURL(for: entry)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }

            Button(role: .destructive) {
                confirmingDelete = true
            } label: {
                Label("Delete from Library", systemImage: "trash")
            }
            .alert("Delete Video", isPresented: $confirmingDelete) {
                Button("Delete", role: .destructive) {
                    manager.removeVideo(entryID: entry.id)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Are you sure you want to remove \"\(entry.name)\" from your library?")
            }
        }
    }

    // MARK: - Helpers

    private func loadThumbnail() {
        if let url = VideoDeploymentService.thumbnailURL(for: entry.id),
           let image = NSImage(contentsOf: url) {
            thumbnail = image
        } else {
            thumbnail = nil
        }
    }

    private func loadCodec() async {
        let url = VideoDeploymentService.videoURL(for: entry)
        let asset = AVURLAsset(url: url)
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let descriptions = try? await track.load(.formatDescriptions),
           let desc = descriptions.first {
            let code = CMFormatDescriptionGetMediaSubType(desc)
            switch code {
            case kCMVideoCodecType_HEVC: codec = "HEVC"
            case kCMVideoCodecType_H264: codec = "H.264"
            case kCMVideoCodecType_VP9: codec = "VP9"
            case kCMVideoCodecType_AV1: codec = "AV1"
            default:
                let b3 = UInt8((code >> 24) & 0xFF)
                let b2 = UInt8((code >> 16) & 0xFF)
                let b1 = UInt8((code >> 8) & 0xFF)
                let b0 = UInt8(code & 0xFF)
                codec = String(bytes: [b3, b2, b1, b0], encoding: .ascii)?
                    .trimmingCharacters(in: .whitespaces) ?? "Unknown"
            }
        }
    }

    private func formattedDuration(_ seconds: Double) -> String {
        let total = Int(seconds)
        let mins = total / 60
        let secs = total % 60
        let secStr = secs < 10 ? "0\(secs)" : "\(secs)"
        return "\(mins):\(secStr)"
    }

    private func formattedFileSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
