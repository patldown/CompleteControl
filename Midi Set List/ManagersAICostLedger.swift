//
//  AICostLedger.swift
//  Midi Set List
//
//  Running per-day totals of external AI spend (Claude / ChatGPT), recorded
//  from every paid request. On-device AI is free and isn't recorded.
//  Costs are estimates from AIPricing, not a bill.
//

import Combine
import CoreTransferable
import Foundation
import UniformTypeIdentifiers

final class AICostLedger: ObservableObject {
    static let shared = AICostLedger()

    struct DayUsage: Codable {
        var cost: Double = 0
        var requests: Int = 0
        var inputTokens: Int = 0
        var outputTokens: Int = 0
    }

    enum Range: String, CaseIterable, Identifiable {
        case today = "Today"
        case thisMonth = "This Month"
        case lastMonth = "Last Month"
        case allTime = "All Time"
        var id: String { rawValue }
    }

    /// Keyed by local calendar day, "yyyy-MM-dd"
    @Published private(set) var days: [String: DayUsage] = [:]

    private let calendar = Calendar.current

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ai_cost_ledger.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let saved = try? JSONDecoder().decode([String: DayUsage].self, from: data) {
            days = saved
        }
    }

    // MARK: Recording

    func record(_ response: AIResponse) {
        let key = Self.dayFormatter.string(from: Date())
        var day = days[key] ?? DayUsage()
        day.cost += response.cost()
        day.requests += 1
        day.inputTokens += response.inputTokens
        day.outputTokens += response.outputTokens
        days[key] = day
        save()
    }

    func reset() {
        days = [:]
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(days) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    // MARK: Queries

    struct DayRow: Identifiable {
        let date: Date
        let key: String
        let usage: DayUsage
        var id: String { key }
    }

    /// Every calendar day in the range, oldest first (zero days included), except
    /// All Time, which lists only days with spend.
    func rows(for range: Range, now: Date = Date()) -> [DayRow] {
        if range == .allTime {
            return days.keys.sorted().compactMap { key in
                guard let date = Self.dayFormatter.date(from: key), let usage = days[key] else { return nil }
                return DayRow(date: date, key: key, usage: usage)
            }
        }
        guard let interval = dateInterval(for: range, now: now) else { return [] }
        var rows: [DayRow] = []
        var day = calendar.startOfDay(for: interval.start)
        // Don't list future days of the current month
        let end = min(interval.end, calendar.startOfDay(for: now).addingTimeInterval(1))
        while day < end {
            let key = Self.dayFormatter.string(from: day)
            rows.append(DayRow(date: day, key: key, usage: days[key] ?? DayUsage()))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return rows
    }

    func total(for range: Range, now: Date = Date()) -> DayUsage {
        rows(for: range, now: now).reduce(into: DayUsage()) { sum, row in
            sum.cost += row.usage.cost
            sum.requests += row.usage.requests
            sum.inputTokens += row.usage.inputTokens
            sum.outputTokens += row.usage.outputTokens
        }
    }

    private func dateInterval(for range: Range, now: Date) -> DateInterval? {
        switch range {
        case .today:
            return calendar.dateInterval(of: .day, for: now)
        case .thisMonth:
            return calendar.dateInterval(of: .month, for: now)
        case .lastMonth:
            guard let previous = calendar.date(byAdding: .month, value: -1, to: now) else { return nil }
            return calendar.dateInterval(of: .month, for: previous)
        case .allTime:
            return nil
        }
    }

    // MARK: Export

    /// CSV: a TOTAL row first, then one row per day.
    func csv(for range: Range, now: Date = Date()) -> String {
        let total = total(for: range, now: now)
        var lines = ["Date,Requests,Input Tokens,Output Tokens,Estimated Cost (USD)"]
        lines.append(Self.csvLine("TOTAL", total))
        for row in rows(for: range, now: now) {
            lines.append(Self.csvLine(row.key, row.usage))
        }
        lines.append("")
        lines.append("\"Note: costs are estimates based on token counts at standard API rates — a gauge, not an actual bill. Check your Anthropic or OpenAI billing for exact amounts.\"")
        return lines.joined(separator: "\n") + "\n"
    }

    func export(for range: Range, now: Date = Date()) -> CostExport {
        let label: String
        switch range {
        case .today:     label = Self.dayFormatter.string(from: now)
        case .thisMonth: label = Self.monthLabel(now)
        case .lastMonth: label = calendar.date(byAdding: .month, value: -1, to: now).map(Self.monthLabel) ?? ""
        case .allTime:   label = "through \(Self.dayFormatter.string(from: now))"
        }
        return CostExport(fileName: "AI Costs - \(range.rawValue) (\(label)).csv", csv: csv(for: range, now: now))
    }

    private static func monthLabel(_ date: Date) -> String {
        String(dayFormatter.string(from: date).prefix(7))   // yyyy-MM
    }

    private static func csvLine(_ label: String, _ u: DayUsage) -> String {
        "\(label),\(u.requests),\(u.inputTokens),\(u.outputTokens),\(String(format: "%.4f", u.cost))"
    }
}

// MARK: - Shareable CSV file

struct CostExport: Transferable {
    let fileName: String
    let csv: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .commaSeparatedText) { export in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(export.fileName)
            try export.csv.write(to: url, atomically: true, encoding: .utf8)
            return SentTransferredFile(url)
        }
    }
}
