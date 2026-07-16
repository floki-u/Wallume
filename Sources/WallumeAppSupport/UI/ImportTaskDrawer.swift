import SwiftUI

public struct ImportTaskDrawer: View {
    @Bindable private var store: ImportTaskStore
    public init(store: ImportTaskStore) { self.store = store }

    public var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(store.menuBarSummary).font(.headline)
                Spacer()
                if store.snapshot.isActive {
                    Button("取消当前") { store.cancelCurrent() }
                    Button("取消全部", role: .destructive) { store.cancelAll() }
                }
                Button { store.isExpanded.toggle() } label: {
                    Image(systemName: store.isExpanded ? "chevron.down" : "chevron.up")
                }.buttonStyle(.plain)
            }
            if store.isExpanded {
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(store.snapshot.items) { item in
                            HStack {
                                Text(item.source.lastPathComponent).lineLimit(1)
                                Spacer()
                                Text(item.attempts.last?.status.rawValue ?? "waiting").foregroundStyle(.secondary)
                                if item.attempts.last?.status == .failed {
                                    Button("重试") { store.retry(item.id) }
                                }
                            }
                        }
                        ForEach(store.snapshot.warnings, id: \.url) { warning in
                            Text("\(warning.url.lastPathComponent)：\(warning.message)").foregroundStyle(.orange)
                        }
                    }
                }.frame(maxHeight: 180)
                if store.snapshot.summary.failed > 0 {
                    HStack { Spacer(); Button("重试全部失败项") { store.retryAllFailures() } }
                }
            }
        }
        .padding(10)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("导入任务")
    }
}
