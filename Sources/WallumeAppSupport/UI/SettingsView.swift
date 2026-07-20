import Foundation
import Observation
import SwiftUI

public struct SettingsBuildInfo: Equatable, Sendable {
    public let productVersion: String
    public let buildNumber: String

    public init(productVersion: String, buildNumber: String) {
        self.productVersion = productVersion
        self.buildNumber = buildNumber
    }

    public static let unavailable = SettingsBuildInfo(productVersion: "unavailable", buildNumber: "unavailable")

    public var displayText: String { "版本 \(productVersion)（\(buildNumber)）" }
}

public enum SettingsDiagnosticsExportState: Equatable, Sendable {
    case ready
    case exporting
    case succeeded
    case failed(String)
}

public struct SettingsPageViewState: Equatable, Sendable {
    public let buildInfo: SettingsBuildInfo
    public let dataDirectoryPath: String
    public let diagnosticsDirectoryPath: String
    public let exportState: SettingsDiagnosticsExportState

    public init(
        buildInfo: SettingsBuildInfo,
        dataDirectory: URL,
        diagnosticsDirectory: URL,
        exportState: SettingsDiagnosticsExportState
    ) {
        self.buildInfo = buildInfo
        dataDirectoryPath = dataDirectory.path
        diagnosticsDirectoryPath = diagnosticsDirectory.path
        self.exportState = exportState
    }

    public var showsLaunchAtLoginControl: Bool { true }
    public var showsOpenGalleryAtLaunchControl: Bool { true }
    public var showsLowPowerPauseControl: Bool { true }
    public var canRetryExport: Bool {
        if case .failed = exportState { true } else { false }
    }
    public var canChooseAnotherDestination: Bool { canRetryExport }
    public var exportErrorMessage: String? {
        if case let .failed(message) = exportState { message } else { nil }
    }
    public var exportActionTitle: String {
        switch exportState {
        case .ready, .succeeded: "导出诊断信息"
        case .exporting: "正在导出…"
        case .failed: "重试导出"
        }
    }
}

@MainActor @Observable
public final class SettingsDiagnosticsExportController {
    public private(set) var state: SettingsDiagnosticsExportState = .ready
    public private(set) var retryDestination: URL?

    private let chooseExportDestination: () -> URL?
    private let exportDiagnostics: (URL) async throws -> Void

    public init(
        chooseExportDestination: @escaping () -> URL?,
        exportDiagnostics: @escaping (URL) async throws -> Void
    ) {
        self.chooseExportDestination = chooseExportDestination
        self.exportDiagnostics = exportDiagnostics
    }

    public func exportToSelectedDestination() async {
        guard let destination = chooseExportDestination() else { return }
        retryDestination = destination
        await export(to: destination)
    }

    public func retry() async {
        guard let retryDestination else { return }
        await export(to: retryDestination)
    }

    public func chooseAnotherDestination() async {
        guard let destination = chooseExportDestination() else { return }
        retryDestination = destination
        await export(to: destination)
    }

    private func export(to destination: URL) async {
        state = .exporting
        do {
            try await exportDiagnostics(destination)
            state = .succeeded
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

public struct SettingsView: View {
    @Bindable private var store: SettingsStore
    private let buildInfo: SettingsBuildInfo
    private let dataDirectory: URL
    private let diagnosticsDirectory: URL
    private let openInFinder: (URL) -> Void
    private let chooseExportDestination: () -> URL?
    private let exportDiagnostics: (URL) async throws -> Void
    @State private var exportController: SettingsDiagnosticsExportController

    public init(
        store: SettingsStore,
        buildInfo: SettingsBuildInfo,
        dataDirectory: URL,
        diagnosticsDirectory: URL,
        openInFinder: @escaping (URL) -> Void,
        chooseExportDestination: @escaping () -> URL?,
        exportDiagnostics: @escaping (URL) async throws -> Void
    ) {
        self.store = store
        self.buildInfo = buildInfo
        self.dataDirectory = dataDirectory
        self.diagnosticsDirectory = diagnosticsDirectory
        self.openInFinder = openInFinder
        self.chooseExportDestination = chooseExportDestination
        self.exportDiagnostics = exportDiagnostics
        _exportController = State(initialValue: SettingsDiagnosticsExportController(
            chooseExportDestination: chooseExportDestination,
            exportDiagnostics: exportDiagnostics
        ))
    }

    public var body: some View {
        let page = SettingsPageViewState(
            buildInfo: buildInfo,
            dataDirectory: dataDirectory,
            diagnosticsDirectory: diagnosticsDirectory,
            exportState: exportController.state
        )
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("设置").font(.largeTitle.bold())
                preferencesCard
                directoriesCard(page)
                diagnosticsCard(page)
                Text(buildInfo.displayText).foregroundStyle(.secondary)
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding()
        }
        .alert("设置操作失败", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.dismissError() } }
        )) {
            Button("知道了") { store.dismissError() }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    private var preferencesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("启动与播放").font(.title3.bold())
            Toggle("登录时启动 Wallume", isOn: Binding(
                get: { store.settings.launchAtLogin },
                set: { store.setLaunchAtLogin($0) }
            ))
            Toggle("启动时打开图库", isOn: Binding(
                get: { store.settings.openGalleryAtLaunch },
                set: { store.setOpenGalleryAtLaunch($0) }
            ))
            Toggle("低电量模式时暂停播放", isOn: Binding(
                get: { store.settings.pauseInLowPowerMode },
                set: { store.setPauseInLowPowerMode($0) }
            ))
        }
        .settingsCardStyle()
    }

    private func directoriesCard(_ page: SettingsPageViewState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("本地数据").font(.title3.bold())
            directoryRow(title: "Wallume 数据", path: page.dataDirectoryPath, url: dataDirectory)
            directoryRow(title: "诊断数据", path: page.diagnosticsDirectoryPath, url: diagnosticsDirectory)
        }
        .settingsCardStyle()
    }

    private func directoryRow(title: String, path: String, url: URL) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
            Button("在访达中显示") { openInFinder(url) }
        }
    }

    private func diagnosticsCard(_ page: SettingsPageViewState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("诊断信息").font(.title3.bold())
            Text("导出仅包含设置、锁屏状态和匿名性能汇总，不包含媒体路径或缩略图。")
                .foregroundStyle(.secondary)
            if let message = page.exportErrorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            } else if exportController.state == .succeeded {
                Label("诊断信息已导出。", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
            if page.canRetryExport {
                HStack {
                    Button("重试导出") { Task { await exportController.retry() } }
                    Button("选择其他位置") { Task { await exportController.chooseAnotherDestination() } }
                }
            } else {
                Button(page.exportActionTitle) { Task { await exportController.exportToSelectedDestination() } }
                    .disabled(exportController.state == .exporting)
            }
        }
        .settingsCardStyle()
    }
}

private extension View {
    func settingsCardStyle() -> some View {
        padding(16).background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}
