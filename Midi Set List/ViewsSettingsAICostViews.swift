//
//  AICostViews.swift
//  Midi Set List
//
//  AI spending in Settings: today / this month at a glance, a daily history,
//  and CSV export (total row + daily breakdown) for each range.
//

import SwiftUI

enum CostFormat {
    /// Small amounts keep 4 decimals so a few cents of usage doesn't read as $0.00
    static func string(_ cost: Double) -> String {
        if cost == 0 { return "$0.00" }
        return cost < 1 ? String(format: "$%.4f", cost) : String(format: "$%.2f", cost)
    }
}

// MARK: - Settings section

struct AICostSection: View {
    @ObservedObject private var ledger = AICostLedger.shared

    var body: some View {
        Section {
            costRow("Today", ledger.total(for: .today))
            costRow("This Month", ledger.total(for: .thisMonth))

            NavigationLink {
                AICostHistoryView()
            } label: {
                Label("Daily History", systemImage: "calendar")
            }

            Menu {
                ForEach(AICostLedger.Range.allCases) { range in
                    ShareLink(
                        item: ledger.export(for: range),
                        preview: SharePreview("AI Costs — \(range.rawValue)")
                    ) {
                        Label(range.rawValue, systemImage: "tablecells")
                    }
                }
            } label: {
                Label("Export Costs (CSV)", systemImage: "square.and.arrow.up")
            }
        } header: {
            Text("AI Spending")
        } footer: {
            Text("Estimated from token usage at standard API rates — your Anthropic or OpenAI bill is the source of truth. On-device AI is free and isn't counted. Each export starts with a total row, then one row per day.")
        }
    }

    private func costRow(_ title: String, _ usage: AICostLedger.DayUsage) -> some View {
        HStack {
            Text(title)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(CostFormat.string(usage.cost))
                    .font(.body.weight(.semibold)).monospacedDigit()
                Text("\(usage.requests) request\(usage.requests == 1 ? "" : "s")")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Daily history

struct AICostHistoryView: View {
    @ObservedObject private var ledger = AICostLedger.shared
    @State private var showingResetConfirm = false

    private struct MonthGroup: Identifiable {
        let id: String          // yyyy-MM
        let title: String
        let rows: [AICostLedger.DayRow]
        var total: Double { rows.reduce(0) { $0 + $1.usage.cost } }
    }

    /// Days with spend, grouped by month, newest first
    private var months: [MonthGroup] {
        let rows = ledger.rows(for: .allTime).reversed()
        let grouped = Dictionary(grouping: rows) { String($0.key.prefix(7)) }
        return grouped.keys.sorted(by: >).map { key in
            let monthRows = grouped[key] ?? []
            let title = monthRows.first?.date.formatted(.dateTime.month(.wide).year()) ?? key
            return MonthGroup(id: key, title: title, rows: monthRows)
        }
    }

    var body: some View {
        List {
            if months.isEmpty {
                ContentUnavailableView(
                    "No AI Spending Yet",
                    systemImage: "dollarsign.circle",
                    description: Text("Costs from Claude and ChatGPT requests show up here, one row per day.")
                )
            } else {
                Section {
                    LabeledContent("All Time") {
                        Text(CostFormat.string(ledger.total(for: .allTime).cost))
                            .font(.body.weight(.semibold)).monospacedDigit()
                    }
                }
                ForEach(months) { month in
                    Section {
                        ForEach(month.rows) { row in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                                    Text("\(row.usage.requests) requests · \(row.usage.inputTokens + row.usage.outputTokens) tokens")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(CostFormat.string(row.usage.cost)).monospacedDigit()
                            }
                        }
                    } header: {
                        HStack {
                            Text(month.title)
                            Spacer()
                            Text(CostFormat.string(month.total)).monospacedDigit()
                        }
                    }
                }
            }
        }
        .navigationTitle("Daily AI Costs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !months.isEmpty {
                ToolbarItem(placement: .secondaryAction) {
                    Button("Reset History", systemImage: "trash", role: .destructive) {
                        showingResetConfirm = true
                    }
                }
            }
        }
        .confirmationDialog("Reset AI cost history?", isPresented: $showingResetConfirm, titleVisibility: .visible) {
            Button("Reset History", role: .destructive) { ledger.reset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes all recorded daily costs. Export first if you want to keep them.")
        }
    }
}
