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
            VStack(alignment: .leading, spacing: 24) {
                healthHero(page)
                metricRibbon
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        runtimeCard.frame(maxWidth: .infinity)
                        diagnosticCard(page).frame(maxWidth: .infinity)
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        runtimeCard
                        diagnosticCard(page)
                    }
                }
                nativeRendererMetricsCard
            }
            .frame(maxWidth: 1_180)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
        }
        .wallumePageBackground()
        .task { await store.pageAppeared() }
        .onDisappear { Task { await store.pageDisappeared() } }
        .alert(wallumeLocalized("性能诊断操作失败"), isPresented: Binding(get: { store.pageError != nil }, set: { if !$0 { store.dismissPageError() } })) {
            Button(wallumeLocalized("知道了")) { store.dismissPageError() }
        } message: { Text(store.pageError ?? "") }
        .fileExporter(isPresented: $presentsExporter, document: document, contentType: .json, defaultFilename: "Wallume-performance-diagnostics") { result in
            if case let .failure(error) = result { store.reportPageError(error.localizedDescription) }
        }
    }

    private func healthHero(_ page: PerformancePageViewState) -> some View {
        HStack(spacing: 28) {
            ZStack {
                Circle()
                    .stroke(WallumeDesign.line, lineWidth: 8)
                Circle()
                    .trim(from: 0, to: page.mode == .failed || page.mode == .saveFailed ? 0.34 : 0.86)
                    .stroke(
                        statusBadgeTint(page.mode),
                        style: StrokeStyle(lineWidth: 8, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                Text(statusBadgeText(page.mode))
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .frame(width: 126, height: 126)

            VStack(alignment: .leading, spacing: 9) {
                Text("SYSTEM HEALTH")
                    .font(.caption2.weight(.bold))
                    .tracking(1.6)
                    .foregroundStyle(.tertiary)
                Text(statusHeadline(page.mode))
                    .font(.system(size: 30, weight: .semibold))
                    .tracking(-0.7)
                Text(statusText(page.mode))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                WallumeStatusBadge(statusBadgeText(page.mode), systemImage: statusBadgeIcon(page.mode), tint: statusBadgeTint(page.mode))
            }
            Spacer(minLength: 0)
        }
        .padding(28)
        .background(WallumeDesign.surface2, in: RoundedRectangle(cornerRadius: WallumeDesign.largeCornerRadius, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: WallumeDesign.largeCornerRadius, style: .continuous).strokeBorder(WallumeDesign.line) }
    }

    private var metricRibbon: some View {
        let realtime = store.snapshot.realtimeSummary
        let runtime = store.snapshot.runtime
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                ribbonMetric("CPU", percent(realtime.currentCPUPercent), detail: wallumeLocalized("当前应用"))
                ribbonMetric(wallumeLocalized("内存"), bytes(realtime.currentResidentBytes), detail: wallumeLocalized("常驻内存"))
                ribbonMetric(wallumeLocalized("显示器"), runtime.activeDisplayCount.formatted(), detail: wallumeLocalized("活动画面"))
                ribbonMetric(wallumeLocalized("会话"), runtime.activeSessionCount.formatted(), detail: wallumeLocalized("壁纸运行时"))
            }
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ribbonMetric("CPU", percent(realtime.currentCPUPercent), detail: wallumeLocalized("当前应用"))
                    ribbonMetric(wallumeLocalized("内存"), bytes(realtime.currentResidentBytes), detail: wallumeLocalized("常驻内存"))
                }
                HStack(spacing: 0) {
                    ribbonMetric(wallumeLocalized("显示器"), runtime.activeDisplayCount.formatted(), detail: wallumeLocalized("活动画面"))
                    ribbonMetric(wallumeLocalized("会话"), runtime.activeSessionCount.formatted(), detail: wallumeLocalized("壁纸运行时"))
                }
            }
        }
        .background(WallumeDesign.surface1)
        .clipShape(RoundedRectangle(cornerRadius: WallumeDesign.cardCornerRadius, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: WallumeDesign.cardCornerRadius, style: .continuous).strokeBorder(WallumeDesign.line) }
    }

    private func ribbonMetric(_ label: String, _ value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 24, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .trailing) { Rectangle().fill(WallumeDesign.line).frame(width: 1) }
    }

    private func statusHeadline(_ mode: PerformancePageViewState.Mode) -> String {
        switch mode {
        case .realtime: wallumeLocalized("一切运行正常")
        case .running: wallumeLocalized("正在执行本地诊断")
        case .completed: wallumeLocalized("诊断已经完成")
        case .saveFailed, .failed: wallumeLocalized("有一项需要处理")
        case .idle: wallumeLocalized("等待开始采样")
        }
    }

    private var runtimeCard: some View {
        let runtime = store.snapshot.runtime
        return VStack(alignment: .leading, spacing: 6) {
            wallumeText("壁纸运行时").font(.title3.bold())
            Text(wallumeLocalized("显示器 %lld · 会话 %lld · 资源 %lld", runtime.activeDisplayCount, runtime.activeSessionCount, runtime.activeResourceCount))
            Text(wallumeLocalized("共享资源 %lld（引用 %lld）· 已创建资源 %lld", runtime.sharedResourceCount, runtime.sharedResourceReferenceCount, runtime.resourceCreationCount))
            Text(runtime.pauseReasons.isEmpty ? wallumeLocalized("暂停原因：无") : wallumeLocalized("暂停原因：%@", runtime.pauseReasons.map(\.rawValue).joined(separator: "、")))
                .foregroundStyle(.secondary)
        }.wallumeCard()
    }

    private var nativeRendererMetricsCard: some View {
        let metrics = store.nativeRendererMetrics
        return VStack(alignment: .leading, spacing: 6) {
            wallumeText("原生墙纸渲染器").font(.title3.bold())
            if metrics.updatedAt == nil {
                wallumeText("系统墙纸尚未启用 Wallume，暂无原生渲染数据。")
                    .foregroundStyle(.secondary)
            } else {
                Text(wallumeLocalized("活动原生表面 %lld · 已提交帧 %lld · 读取器循环 %lld", metrics.activeRenderers, metrics.enqueuedFrames, metrics.readerExhaustions))
                wallumeText("每秒刷新；仅显示本机计数，不包含视频名称或路径。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }.wallumeCard()
    }

    private func diagnosticCard(_ page: PerformancePageViewState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            wallumeText("30 秒本地诊断").font(.title3.bold())
            if page.mode == .running {
                ProgressView(value: page.progress) { Text(wallumeLocalized("已采样 %lld / %lld", store.snapshot.diagnosticSampleCount, store.snapshot.diagnosticSampleLimit)) }
                Button(wallumeLocalized("取消当前诊断"), role: .destructive) { Task { await store.cancelDiagnostic() } }
            } else {
                Menu(wallumeLocalized("开始诊断")) {
                    ForEach(PerformanceDiagnosticScenario.allCases, id: \.self) { scenario in
                        Button(scenarioTitle(scenario)) { Task { await store.startDiagnostic(scenario: scenario) } }
                    }
                }.disabled(!page.canStartDiagnostic)
            }
            if page.canRetrySave { Button(wallumeLocalized("重试保存本地报告")) { Task { await store.retrySave() } } }
            if page.canExportReport {
                Button(wallumeLocalized("导出匿名 JSON 报告")) {
                    do { document = PerformanceDiagnosticDocument(data: try store.makeDiagnosticExportData()); presentsExporter = true }
                    catch { store.reportPageError(error.localizedDescription) }
                }
            }
        }.wallumeCard()
    }

    private func statusText(_ mode: PerformancePageViewState.Mode) -> String {
        switch mode {
        case .idle: wallumeLocalized("等待开始实时性能采样。")
        case .realtime: wallumeLocalized("正在每秒采集实时性能指标。")
        case .running: wallumeLocalized("正在执行 30 秒本地性能诊断。")
        case .completed: wallumeLocalized("诊断已完成，本地报告可导出。")
        case .saveFailed: wallumeLocalized("诊断已完成，但本地保存失败；可重试或直接导出。")
        case .failed: wallumeLocalized("性能采样遇到问题，请重试。")
        }
    }

    private func statusBadgeText(_ mode: PerformancePageViewState.Mode) -> String {
        switch mode {
        case .idle: wallumeLocalized("空闲")
        case .realtime: wallumeLocalized("正在采样")
        case .running: wallumeLocalized("正在诊断")
        case .completed: wallumeLocalized("已完成")
        case .saveFailed, .failed: wallumeLocalized("需要处理")
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
        case .completed, .realtime: WallumeDesign.success
        case .saveFailed, .failed: WallumeDesign.destructive
        case .running: WallumeDesign.accent
        case .idle: .secondary
        }
    }
    private func scenarioTitle(_ scenario: PerformanceDiagnosticScenario) -> String { switch scenario { case .singleDisplay: wallumeLocalized("单显示器"); case .twoDisplays: wallumeLocalized("双显示器"); case .paused: wallumeLocalized("暂停状态") } }
    private func percent(_ value: Double) -> String { String(format: "%.1f%%", value) }
    private func bytes(_ value: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory) }
}

public struct PerformanceDiagnosticDocument: FileDocument {
    public static let readableContentTypes: [UTType] = [.json]
    public let data: Data
    public init(data: Data) { self.data = data }
    public init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
