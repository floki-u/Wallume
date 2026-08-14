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
            VStack(alignment: .leading, spacing: 18) {
                WallumePageHeader("性能诊断", subtitle: "实时观察资源占用，必要时导出匿名报告") { EmptyView() }
                statusCard(page)
                metricsCard
                runtimeCard
                diagnosticCard(page)
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding()
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

    private func statusCard(_ page: PerformancePageViewState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(statusText(page.mode)).font(.headline)
            Text("实时采样仅保存在内存中，最多保留最近 60 项。诊断会连续采样 30 秒并只保存匿名汇总数据。")
                .foregroundStyle(.secondary)
        }.wallumeCard()
    }

    private var metricsCard: some View {
        let metrics = store.snapshot.realtimeSummary
        return VStack(alignment: .leading, spacing: 8) {
            Text("进程指标").font(.title3.bold())
            Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 6) {
                GridRow { Text("指标"); Text("当前"); Text("平均"); Text("峰值") }.foregroundStyle(.secondary)
                GridRow { Text("CPU"); Text(percent(metrics.currentCPUPercent)); Text(percent(metrics.averageCPUPercent)); Text(percent(metrics.peakCPUPercent)) }
                GridRow { Text("常驻内存"); Text(bytes(metrics.currentResidentBytes)); Text(bytes(metrics.averageResidentBytes)); Text(bytes(metrics.peakResidentBytes)) }
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
    private func scenarioTitle(_ scenario: PerformanceDiagnosticScenario) -> String { switch scenario { case .singleDisplay: "单显示器"; case .twoDisplays: "双显示器"; case .paused: "暂停状态" } }
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
