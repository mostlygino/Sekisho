import SekishoCore
import SwiftUI

struct DiffPair: Codable, Hashable { let a: Int; let b: Int }

/// Two exchanges, line by line: request line, headers and body, then the response.
struct DiffWindow: View {
    @Environment(Store.self) private var store
    let pair: DiffPair?
    @State private var unified = false
    @State private var rows: [DiffRow]?

    var body: some View {
        Group {
            if let pair, let a = store.flow(pair.a), let b = store.flow(pair.b) {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Text(rows == nil ? "Comparing…" : summary(rows!))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Spacer()
                        Picker("Layout", selection: $unified) {
                            Text("Side by Side").tag(false)
                            Text("Unified").tag(true)
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    Rectangle().fill(Color.rule).frame(height: 1)
                    if !unified {
                        HStack(spacing: 0) {
                            side(a, mark: "A")
                            Rectangle().fill(Color.rule).frame(width: 1)
                            side(b, mark: "B")
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .background(Color.ground)
                        Rectangle().fill(Color.rule).frame(height: 1)
                    }
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array((rows ?? []).enumerated()), id: \.offset) { _, row in
                                if unified { unifiedRow(row) } else { sideRow(row) }
                            }
                        }
                        .font(.system(size: NSFont.systemFontSize - 1, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(.vertical, 6)
                    }
                }
                .task(id: "\(pair.a)-\(pair.b)-\(a.ended?.timeIntervalSince1970 ?? 0)-\(b.ended?.timeIntervalSince1970 ?? 0)") {
                    // Off the main thread, once per pair (and again only when one of them finishes).
                    let (ta, tb) = (TextDiff.text(a), TextDiff.text(b))
                    rows = await Task.detached { TextDiff.rows(ta, tb) }.value
                }
            } else {
                Text("One of these requests was cleared.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 560, minHeight: 400)
        .background(Color.raised)
    }

    private func summary(_ rows: [DiffRow]) -> String {
        let changed = rows.filter { $0.kind != .same }.count
        return changed == 0 ? "Identical, \(rows.count) lines" : "\(changed) of \(rows.count) lines differ"
    }

    private func side(_ f: Flow, mark: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(mark).font(.caption.weight(.bold)).foregroundStyle(Color.brass)
            Text("#\(store.number(f))").monospacedDigit().foregroundStyle(.secondary)
            Text(f.method).fontWeight(.semibold)
            Text(f.url).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if let s = f.status { Text(String(s)).monospacedDigit().foregroundStyle(StatusDot(f).color ?? .secondary) }
        }
        .font(.system(.callout, design: .monospaced))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("\(f.method) \(f.url)")
    }

    private func tint(_ kind: DiffRow.Kind, left: Bool) -> Color {
        switch kind {
        case .same: .clear
        case .removed: left ? Color.statusFailed.opacity(0.16) : Color.rule.opacity(0.25)
        case .added: left ? Color.rule.opacity(0.25) : Color.statusOK.opacity(0.16)
        case .changed: left ? Color.statusFailed.opacity(0.12) : Color.statusOK.opacity(0.12)
        }
    }

    private func half(_ text: String?, _ kind: DiffRow.Kind, left: Bool) -> some View {
        Text(text ?? "")
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 1)
            .background(tint(kind, left: left))
    }

    private func sideRow(_ row: DiffRow) -> some View {
        HStack(alignment: .top, spacing: 0) {
            half(row.left, row.kind, left: true)
            Rectangle().fill(Color.rule).frame(width: 1)
            half(row.right, row.kind, left: false)
        }
    }

    private func line(_ sign: String, _ text: String?, _ tint: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(sign).foregroundStyle(.secondary).frame(width: 10)
            Text(text ?? "").fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 1)
        .background(tint)
    }

    @ViewBuilder private func unifiedRow(_ row: DiffRow) -> some View {
        switch row.kind {
        case .same: line(" ", row.left, .clear)
        case .removed: line("-", row.left, Color.statusFailed.opacity(0.16))
        case .added: line("+", row.right, Color.statusOK.opacity(0.16))
        case .changed:
            line("-", row.left, Color.statusFailed.opacity(0.16))
            line("+", row.right, Color.statusOK.opacity(0.16))
        }
    }
}
