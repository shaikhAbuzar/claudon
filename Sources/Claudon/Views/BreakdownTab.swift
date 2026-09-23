import ClaudonCore
import SwiftUI

/// Models or projects ranked by tokens, as a table: every value is readable without hovering.
struct BreakdownTab: View {
    enum Kind { case models, projects }

    @ObservedObject var model: AppModel
    let kind: Kind
    @Environment(\.colorScheme) private var scheme

    private static let visibleRows = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Segmented(options: [(AppModel.Range.week, "7 days"), (.month, "30 days"), (.all, "All time")],
                      selection: $model.range)
            let rows = folded(kind == .models ? model.modelRows : model.projectRows)
            if rows.isEmpty {
                Text(kind == .models ? "No model usage in this range." : "No project usage in this range.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 7) {
                    GridRow {
                        header(kind == .models ? "Model" : "Project")
                        header("Share")
                        header("Tokens").gridColumnAlignment(.trailing)
                        header(kind == .models ? "Time" : "Replies").gridColumnAlignment(.trailing)
                        header("API cost").gridColumnAlignment(.trailing)
                    }
                    ForEach(rows) { row in
                        GridRow {
                            Text(row.name)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 104, alignment: .leading)
                                .help(row.name)
                            ShareBar(share: row.share, color: Theme.accent(scheme))
                            Text(Formatters.tokens(row.tokens)).monospacedDigit()
                            Text(kind == .models ? Formatters.duration(minutes: row.minutes ?? 0)
                                                 : Formatters.tokens(row.messages))
                                .monospacedDigit()
                            Text(Formatters.money(row.cost, compact: true)).monospacedDigit()
                        }
                        .font(.system(size: 11.5))
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            Spacer(minLength: 0)
            Text(kind == .models
                 ? "Share of tokens, cache reads included. Cost at API list prices."
                 : "Projects are Claude Code working folders. Cost at API list prices.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    private func header(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
    }

    /// The top rows, with the rest folded into "Other".
    private func folded(_ rows: [ShareRow]) -> [ShareRow] {
        guard rows.count > Self.visibleRows else { return rows }
        let rest = rows.dropFirst(Self.visibleRows - 1)
        let minutes = rest.compactMap(\.minutes)
        let other = ShareRow(id: "other", name: "Other (\(rest.count))",
                             tokens: rest.reduce(0) { $0 + $1.tokens },
                             cost: rest.reduce(0) { $0 + $1.cost },
                             messages: rest.reduce(0) { $0 + $1.messages },
                             minutes: minutes.isEmpty ? nil : minutes.reduce(0, +),
                             share: rest.reduce(0) { $0 + $1.share })
        return Array(rows.prefix(Self.visibleRows - 1)) + [other]
    }
}
