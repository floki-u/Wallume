import SwiftUI
import WallumeCore

public struct DisplaySelectorModel: Equatable {
    public let targets: [DisplayRecord]
    public var selectedIDs: Set<DisplayID>

    public init(targets: [DisplayRecord], selectedIDs: Set<DisplayID> = []) {
        self.targets = targets
        self.selectedIDs = selectedIDs.intersection(Set(targets.map(\.id)))
    }

    public var canConfirm: Bool { !selectedIDs.isEmpty }
    public var summary: String { "将应用到 \(selectedIDs.count) 台显示器" }
    public mutating func selectAll() { selectedIDs = Set(targets.map(\.id)) }
    public mutating func clearAll() { selectedIDs.removeAll() }
    public mutating func toggle(_ id: DisplayID) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
    }
}

public struct DisplaySelectorView: View {
    private let mediaName: String
    private let currentAssignments: [DisplayID: String]
    private let errorMessage: String?
    private let onCancel: () -> Void
    private let onConfirm: (Set<DisplayID>) -> Void
    @State private var model: DisplaySelectorModel

    public init(
        mediaName: String,
        targets: [DisplayRecord],
        currentAssignments: [DisplayID: String],
        selectedIDs: Set<DisplayID> = [],
        errorMessage: String? = nil,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping (Set<DisplayID>) -> Void
    ) {
        self.mediaName = mediaName
        self.currentAssignments = currentAssignments
        self.errorMessage = errorMessage
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        _model = State(initialValue: DisplaySelectorModel(targets: targets, selectedIDs: selectedIDs))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("设为壁纸").font(.title2.bold())
            Text("选择要应用“\(mediaName)”的显示器").foregroundStyle(.secondary)

            HStack {
                Button("全部选择") { model.selectAll() }
                Button("清除选择") { model.clearAll() }
                Spacer()
                Text(model.summary).foregroundStyle(.secondary)
            }

            List(model.targets) { target in
                Toggle(isOn: Binding(
                    get: { model.selectedIDs.contains(target.id) },
                    set: { _ in model.toggle(target.id) }
                )) {
                    VStack(alignment: .leading) {
                        HStack {
                            Text(target.name)
                            if target.isMain { Text("主显示器").font(.caption).foregroundStyle(.blue) }
                        }
                        Text(currentAssignments[target.id].map { "当前：\($0)" } ?? "当前未设置")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(minHeight: 200)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("display-assignment-error")
            }

            HStack {
                Spacer()
                Button("取消", action: onCancel)
                Button("确认") { onConfirm(model.selectedIDs) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canConfirm)
            }
        }
        .padding(20)
        .frame(minWidth: 460, minHeight: 360)
    }
}
