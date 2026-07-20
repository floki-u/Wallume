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

public enum SettingsPreferenceControl: String, CaseIterable, Identifiable, Sendable {
    case launchAtLogin
    case openGalleryAtLaunch
    case pauseInLowPowerMode

    public var id: Self { self }

    public var title: String {
        switch self {
        case .launchAtLogin: "登录时启动 Wallume"
        case .openGalleryAtLaunch: "启动时打开图库"
        case .pauseInLowPowerMode: "低电量模式时暂停播放"
        }
    }
}

public enum SettingsDiagnosticsAction: String, Identifiable, Sendable {
    case selectDestination
    case retry
    case chooseAnotherDestination

    public var id: Self { self }
}

public enum SettingsControlRole: Equatable, Sendable {
    case toggle
    case button
}

public enum SettingsControlAction: Equatable, Sendable {
    case setPreference(SettingsPreferenceControl)
    case diagnostics(SettingsDiagnosticsAction)
}

public struct SettingsControlPresentation: Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let role: SettingsControlRole
    public let isEnabled: Bool
    public let action: SettingsControlAction
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

    public var preferenceControls: [SettingsControlPresentation] {
        SettingsPreferenceControl.allCases.map { control in
            SettingsControlPresentation(
                id: "settings.preference.\(control.rawValue)",
                title: control.title,
                role: .toggle,
                isEnabled: true,
                action: .setPreference(control)
            )
        }
    }

    public var diagnosticsControls: [SettingsControlPresentation] {
        let actions: [(SettingsDiagnosticsAction, String, Bool)] = switch exportState {
        case .ready, .succeeded:
            [(.selectDestination, "导出诊断信息", true)]
        case .exporting:
            [(.selectDestination, "正在导出…", false)]
        case .failed:
            [
                (.retry, "重试导出", true),
                (.chooseAnotherDestination, "选择其他位置", true),
            ]
        }
        return actions.map { action, title, isEnabled in
            SettingsControlPresentation(
                id: "settings.diagnostics.\(action.rawValue)",
                title: title,
                role: .button,
                isEnabled: isEnabled,
                action: .diagnostics(action)
            )
        }
    }

    public var exportErrorMessage: String? {
        if case let .failed(message) = exportState { message } else { nil }
    }

    public var exportSuccessMessage: String? {
        exportState == .succeeded ? "诊断信息已导出。" : nil
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
        await selectDestinationAndExport()
    }

    public func retry() async {
        guard let retryDestination else { return }
        await export(to: retryDestination)
    }

    public func chooseAnotherDestination() async {
        await selectDestinationAndExport()
    }

    private func selectDestinationAndExport() async {
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
        self.init(
            store: store,
            buildInfo: buildInfo,
            dataDirectory: dataDirectory,
            diagnosticsDirectory: diagnosticsDirectory,
            openInFinder: openInFinder,
            exportController: SettingsDiagnosticsExportController(
                chooseExportDestination: chooseExportDestination,
                exportDiagnostics: exportDiagnostics
            )
        )
    }

    init(
        store: SettingsStore,
        buildInfo: SettingsBuildInfo,
        dataDirectory: URL,
        diagnosticsDirectory: URL,
        openInFinder: @escaping (URL) -> Void,
        exportController: SettingsDiagnosticsExportController
    ) {
        self.store = store
        self.buildInfo = buildInfo
        self.dataDirectory = dataDirectory
        self.diagnosticsDirectory = diagnosticsDirectory
        self.openInFinder = openInFinder
        _exportController = State(initialValue: exportController)
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
                preferencesCard(page)
                directoriesCard(page)
                diagnosticsCard(page)
                Text(page.buildInfo.displayText).foregroundStyle(.secondary)
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

    private func preferencesCard(_ page: SettingsPageViewState) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("启动与播放").font(.title3.bold())
            ForEach(page.preferenceControls) { presentation in
                if case let .setPreference(control) = presentation.action {
                    Toggle(presentation.title, isOn: preferenceBinding(for: control))
                        .disabled(!presentation.isEnabled)
                        .accessibilityIdentifier(presentation.id)
                }
            }
        }
        .settingsCardStyle()
    }

    private func preferenceBinding(for control: SettingsPreferenceControl) -> Binding<Bool> {
        switch control {
        case .launchAtLogin:
            Binding(
                get: { store.settings.launchAtLogin },
                set: { store.setLaunchAtLogin($0) }
            )
        case .openGalleryAtLaunch:
            Binding(
                get: { store.settings.openGalleryAtLaunch },
                set: { store.setOpenGalleryAtLaunch($0) }
            )
        case .pauseInLowPowerMode:
            Binding(
                get: { store.settings.pauseInLowPowerMode },
                set: { store.setPauseInLowPowerMode($0) }
            )
        }
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
            } else if let message = page.exportSuccessMessage {
                Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
            HStack {
                ForEach(page.diagnosticsControls) { presentation in
                    if case let .diagnostics(action) = presentation.action {
                        Button(presentation.title) { performDiagnosticsAction(action) }
                            .disabled(!presentation.isEnabled)
                            .accessibilityIdentifier(presentation.id)
                    }
                }
            }
        }
        .settingsCardStyle()
    }

    private func performDiagnosticsAction(_ action: SettingsDiagnosticsAction) {
        switch action {
        case .selectDestination:
            Task { await exportController.exportToSelectedDestination() }
        case .retry:
            Task { await exportController.retry() }
        case .chooseAnotherDestination:
            Task { await exportController.chooseAnotherDestination() }
        }
    }
}

private extension View {
    func settingsCardStyle() -> some View {
        padding(16).background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}
