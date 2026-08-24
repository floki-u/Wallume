import SwiftUI

public struct ImportTaskDrawer: View {
    @Bindable private var store: ImportTaskStore
    public init(store: ImportTaskStore) { self.store = store }

    public var body: some View {
        VStack(spacing: 8) {
            HStack {
                VStack(alignment: .leading) {
                    Text(store.menuBarSummary).font(.headline)
                    if let current = store.snapshot.items.first(where: { $0.attempts.last?.status == .running }), let attempt = current.attempts.last {
                        Text(wallumeLocalized("%@ · %@", current.source.lastPathComponent, wallumeLocalized(attempt.stage?.rawValue ?? "准备中"))).font(.caption)
                        if let progress = attempt.progress { ProgressView(value: progress).frame(width: 180) }
                    }
                }
                Spacer()
                if store.snapshot.isActive {
                    Button(wallumeLocalized("取消当前")) { store.cancelCurrent() }
                    Button(wallumeLocalized("取消全部"), role: .destructive) { store.cancelAll() }
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
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(item.source.lastPathComponent).lineLimit(1)
                                    Spacer()
                                    Text(item.attempts.last?.status.rawValue ?? "waiting").foregroundStyle(.secondary)
                                    if item.attempts.last?.status == .failed { Button(wallumeLocalized("重试")) { store.retry(item.id) } }
                                }
                                ForEach(Array(item.attempts.enumerated()), id: \.element.id) { index, attempt in
                                    HStack {
                                        Text(wallumeLocalized("尝试 %lld · %@", index + 1, wallumeLocalized(attempt.stage?.rawValue ?? attempt.status.rawValue))).font(.caption)
                                        if let progress = attempt.progress { ProgressView(value: progress).frame(width: 100) }
                                        if let message = attempt.message { Text(message).font(.caption).foregroundStyle(.red) }
                                    }
                                }
                            }
                        }
                        ForEach(store.snapshot.warnings, id: \.url) { warning in
                            Text("\(warning.url.lastPathComponent)：\(warning.message)").foregroundStyle(.orange)
                        }
                    }
                }.frame(maxHeight: 180)
                if store.snapshot.summary.failed > 0 {
                    HStack { Spacer(); Button(wallumeLocalized("重试全部失败项")) { store.retryAllFailures() } }
                }
                let summary = store.snapshot.summary
                Text(wallumeLocalized("成功 %lld · 重复 %lld · 失败 %lld · 取消 %lld", summary.imported, summary.duplicate, summary.failed, summary.cancelled)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(wallumeLocalized("导入任务"))
    }
}
