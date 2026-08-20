import SwiftUI
import UniformTypeIdentifiers

public struct PerformancePageViewState: Equatable, Sendable {
    public enum Mode: Equatable, Sendable { case idle, realtime, running, completed, saveFailed, failed }

    public let mode: Mode
    public let progress: Double
    public let canStartDiagnostic: Bool
    public let canCancelDiagnostic: Bool
    public let canRetrySave: Bool
    public let canExportReport: Bool

    public init(snapshot: PerformanceDiagnosticsSnapshot) {
        progress = snapshot.diagnosticSampleLimit > 0
            ? min(1, Double(snapshot.diagnosticSampleCount) / Double(snapshot.diagnosticSampleLimit)) : 0
        canCancelDiagnostic = snapshot.isDiagnosticRunning
        canRetrySave = snapshot.reportSaveError != nil && snapshot.completedReport != nil
        canExportReport = snapshot.completedReport != nil
        canStartDiagnostic = !snapshot.isDiagnosticRunning && snapshot.reportSaveError == nil
        if snapshot.isDiagnosticRunning { mode = .running }
        else if snapshot.reportSaveError != nil { mode = .saveFailed }
        else if snapshot.completedReport != nil { mode = .completed }
        else if snapshot.diagnosticError != nil || snapshot.realtimeError != nil { mode = .failed }
        else if snapshot.isRealtimeActive { mode = .realtime }
        else { mode = .idle }
    }
}

public struct PerformanceView: View {
    @Bindable private var store: PerformanceFeatureStore
    @State private var presentsExporter = false
    @State private var document: PerformanceDiagnosticDocument?

    public init(store: PerformanceFeatureStore) { self.store = store }

    public var body: some View {
        let page = PerformancePageViewState(snapshot: store.snapshot)
        ScrollView {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 84) { statusCopy(page); signalPanel(page) }.frame(minWidth: 920)
                VStack(alignment: .leading, spacing: 32) { statusCopy(page); signalPanel(page) }
            }
            .frame(maxWidth: 1_160)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 32)
            .padding(.vertical, 40)
        }
        .wallumePageBackground()
        .task { await store.pageAppeared() }
        .onDisappear { Task { await store.pageDisappeared() } }
        .alert("性能诊断操作失败", isPresented: Binding(get: { store.pageError != nil }, set: { if !$0 { store.dismissPageError() } })) {
            Button("知道了") { store.dismissPageError() }
        } message: { Text(store.pageError ?? "") }
        .fileExporter(isPresented: $presentsExporter, document: document, contentType: .json, defaultFilename: "Wallume-performance-diagnostics") { result in
            if case let .failure(error) = result { store.reportPageError(error.localizedDescription) }
        }
    }

    private func statusCopy(_ page: PerformancePageViewState) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("安静地，\n保持运行。").font(.system(size: 46, weight: .bold, design: .serif))
            Text("实时数据只留在内存中；诊断报告只在你手动导出时落盘。")
                .foregroundStyle(.secondary).frame(maxWidth: 360, alignment: .leading)
            WallumeStatusBadge(statusBadgeText(page.mode), systemImage: statusBadgeIcon(page.mode), tint: statusBadgeTint(page.mode))
        }
        .frame(maxWidth: 390, alignment: .leading)
    }

    private func signalPanel(_ page: PerformancePageViewState) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text("实时采样").font(.caption).foregroundStyle(.secondary); Spacer(); Text("LIVE").font(.caption.weight(.bold)).foregroundStyle(WallumeDesign.accent) }
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(0..<12, id: \.self) { index in
                    Capsule().fill(WallumeDesign.accent.opacity(0.75)).frame(maxWidth: .infinity).frame(height: CGFloat(52 + (index * 23) % 110))
                }
            }
            .frame(height: 180, alignment: .bottom)
            Divider()
            HStack { metric("显示器", value: store.snapshot.runtime.activeDisplayCount.formatted()); metric("CPU", value: percent(store.snapshot.realtimeSummary.currentCPUPercent)); metric("内存", value: bytes(store.snapshot.realtimeSummary.currentResidentBytes)) }
            nativeRendererMetricsCard
            diagnosticCard(page)
        }
        .padding(24)
        .frame(maxWidth: 590)
        .background(PerformancePanelSurface())
    }

    private func metric(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) { Text(value).font(.title3.weight(.semibold)).monospacedDigit(); Text(label).font(.caption).foregroundStyle(.secondary) }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusCard(_ page: PerformancePageViewState) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: statusBadgeIcon(page.mode))
                .font(.title3.weight(.semibold))
                .foregroundStyle(statusBadgeTint(page.mode))
                .frame(width: 34, height: 34)
                .background(statusBadgeTint(page.mode).opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(statusText(page.mode)).font(.headline)
            Text("实时采样仅保存在内存中，最多保留最近 60 项。诊断会连续采样 30 秒并只保存匿名汇总数据。")
                    .font(.caption)
                .foregroundStyle(.secondary)
            }
        }.wallumeCard()
    }

    private var metricsCard: some View {
        let metrics = store.snapshot.realtimeSummary
        return VStack(alignment: .leading, spacing: 14) {
            Text(wallumeLocalized("正在消耗")).font(.headline)
            HStack(alignment: .firstTextBaseline, spacing: 28) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("CPU").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(percent(metrics.currentCPUPercent))
                        .font(.system(size: 32, weight: .semibold, design: .rounded))
                        .fontDesign(.rounded)
                        .monospacedDigit()
                    Text("平均 \(percent(metrics.averageCPUPercent)) · 峰值 \(percent(metrics.peakCPUPercent))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Divider().frame(height: 58)
                VStack(alignment: .leading, spacing: 4) {
                    Text(wallumeLocalized("常驻内存")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(bytes(metrics.currentResidentBytes))
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                    Text("平均 \(bytes(metrics.averageResidentBytes)) · 峰值 \(bytes(metrics.peakResidentBytes))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }.wallumeCard()
    }

    private var runtimeCard: some View {
        let runtime = store.snapshot.runtime
        return VStack(alignment: .leading, spacing: 6) {
            Text("壁纸运行时").font(.title3.bold())
            Text("显示器 \(runtime.activeDisplayCount) · 会话 \(runtime.activeSessionCount) · 资源 \(runtime.activeResourceCount)")
            Text("共享资源 \(runtime.sharedResourceCount)（引用 \(runtime.sharedResourceReferenceCount)）· 已创建资源 \(runtime.resourceCreationCount)")
            Text(runtime.pauseReasons.isEmpty ? "暂停原因：无" : "暂停原因：\(runtime.pauseReasons.map(\.rawValue).joined(separator: "、"))")
                .foregroundStyle(.secondary)
        }.wallumeCard()
    }

    private var nativeRendererMetricsCard: some View {
        let metrics = store.nativeRendererMetrics
        return VStack(alignment: .leading, spacing: 6) {
            Text("原生墙纸渲染器").font(.title3.bold())
            if metrics.updatedAt == nil {
                Text("系统墙纸尚未启用 Wallume，暂无原生渲染数据。")
                    .foregroundStyle(.secondary)
            } else {
                Text("活动渲染器 \(metrics.activeRenderers) · 已提交帧 \(metrics.enqueuedFrames) · 读取器循环 \(metrics.readerExhaustions)")
                Text("每秒刷新；仅显示本机计数，不包含视频名称或路径。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }.wallumeCard()
    }

    private func diagnosticCard(_ page: PerformancePageViewState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("30 秒本地诊断").font(.title3.bold())
            if page.mode == .running {
                ProgressView(value: page.progress) { Text("已采样 \(store.snapshot.diagnosticSampleCount) / \(store.snapshot.diagnosticSampleLimit)") }
                Button("取消当前诊断", role: .destructive) { Task { await store.cancelDiagnostic() } }
            } else {
                Menu("开始诊断") {
                    ForEach(PerformanceDiagnosticScenario.allCases, id: \.self) { scenario in
                        Button(scenarioTitle(scenario)) { Task { await store.startDiagnostic(scenario: scenario) } }
                    }
                }.disabled(!page.canStartDiagnostic)
            }
            if page.canRetrySave { Button("重试保存本地报告") { Task { await store.retrySave() } } }
            if page.canExportReport {
                Button("导出匿名 JSON 报告") {
                    do { document = PerformanceDiagnosticDocument(data: try store.makeDiagnosticExportData()); presentsExporter = true }
                    catch { store.reportPageError(error.localizedDescription) }
                }
            }
        }.wallumeCard()
    }

    private func statusText(_ mode: PerformancePageViewState.Mode) -> String {
        switch mode {
        case .idle: "等待开始实时性能采样。"
        case .realtime: "正在每秒采集实时性能指标。"
        case .running: "正在执行 30 秒本地性能诊断。"
        case .completed: "诊断已完成，本地报告可导出。"
        case .saveFailed: "诊断已完成，但本地保存失败；可重试或直接导出。"
        case .failed: "性能采样遇到问题，请重试。"
        }
    }

    private func statusBadgeText(_ mode: PerformancePageViewState.Mode) -> String {
        switch mode {
        case .idle: "空闲"
        case .realtime: "正在采样"
        case .running: "正在诊断"
        case .completed: "已完成"
        case .saveFailed, .failed: "需要处理"
        }
    }

    private func statusBadgeIcon(_ mode: PerformancePageViewState.Mode) -> String {
        switch mode {
        case .idle: "circle"
        case .realtime: "waveform.path.ecg"
        case .running: "gauge.with.dots.needle.67percent"
        case .completed: "checkmark.circle.fill"
        case .saveFailed, .failed: "exclamationmark.triangle.fill"
        }
    }

    private func statusBadgeTint(_ mode: PerformancePageViewState.Mode) -> Color {
        switch mode {
        case .completed: .green
        case .saveFailed, .failed: .red
        case .realtime, .running: WallumeDesign.accent
        case .idle: .secondary
        }
    }
    private func scenarioTitle(_ scenario: PerformanceDiagnosticScenario) -> String { switch scenario { case .singleDisplay: "单显示器"; case .twoDisplays: "双显示器"; case .paused: "暂停状态" } }
    private func percent(_ value: Double) -> String { String(format: "%.1f%%", value) }
    private func bytes(_ value: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory) }
}

private struct PerformancePanelSurface: View {
    @AppStorage("wallume.theme") private var themeName = WallumeTheme.nocturne.rawValue
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = WallumeThemePalette.resolve(WallumeTheme.fromStoredValue(themeName), scheme: colorScheme)
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(palette.panelRaised)
            .overlay { RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(palette.line) }
    }
}

public struct PerformanceDiagnosticDocument: FileDocument {
    public static let readableContentTypes: [UTType] = [.json]
    public let data: Data
    public init(data: Data) { self.data = data }
    public init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
