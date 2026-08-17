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
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text(wallumeLocalized("投放到屏幕"))
                    .font(.title2.weight(.bold))
                Text("选择要应用“\(mediaName)”的显示器。每块屏幕会保留自己的显示方式。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button(wallumeLocalized("全部选择")) { model.selectAll() }
                Button(wallumeLocalized("清除选择")) { model.clearAll() }
                Spacer()
                Text(model.summary)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(WallumeDesign.accent)
            }

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(model.targets) { target in
                        let isSelected = model.selectedIDs.contains(target.id)
                        Button {
                            model.toggle(target.id)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "display")
                                    .font(.title3.weight(.medium))
                                    .frame(width: 32, height: 28)
                                    .background(isSelected ? WallumeDesign.accent.opacity(0.18) : .primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(target.name).font(.subheadline.weight(.semibold))
                                        if target.isMain { WallumeStatusBadge("主显示器", systemImage: "star.fill", tint: WallumeDesign.accent) }
                                    }
                                    Text(currentAssignments[target.id].map { wallumeLocalized("当前播放：") + $0 } ?? wallumeLocalized("尚未设置画面"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 12)
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(isSelected ? WallumeDesign.accent : .secondary)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(isSelected ? WallumeDesign.accent.opacity(0.1) : .primary.opacity(0.035), in: RoundedRectangle(cornerRadius: WallumeDesign.cardCornerRadius, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: WallumeDesign.cardCornerRadius, style: .continuous)
                                    .strokeBorder(isSelected ? WallumeDesign.accent.opacity(0.55) : .primary.opacity(0.08))
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(target.name)
                        .accessibilityValue(wallumeLocalized(isSelected ? "已选择" : "未选择"))
                    }
                }
            }
            .frame(minHeight: 220, maxHeight: 320)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("display-assignment-error")
            }

            HStack {
                Spacer()
                Button(wallumeLocalized("取消"), action: onCancel)
                Button(wallumeLocalized("确认")) { onConfirm(model.selectedIDs) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canConfirm)
            }
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 410)
    }
}
