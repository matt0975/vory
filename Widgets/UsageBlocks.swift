import SwiftUI
import VoryCore
import WidgetKit

/// The activity blocks from Home: one column per week, one row per weekday, brighter for busier
/// days. Drawn by the widgets, the complications and the watch app from the same snapshot.
struct UsageBlocks: View {
    var days: [WidgetSnapshot.Usage.Day]
    /// How many weeks to draw. `nil` fits as many whole weeks as the width holds at the height
    /// given, ending on this week at the trailing edge.
    var weeks: Int?
    var spacing: CGFloat = 2
    /// Vory's blue where a face or a page draws in colour; an accented face recolours it.
    var tint: Color = UsageBlocks.voryBlue
    static let voryBlue = Color(red: 0.231, green: 0.482, blue: 1.0)

    private var counts: [Date: Int] {
        let cal = Calendar.current
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return Dictionary(days.compactMap { d in f.date(from: d.day).map { (cal.startOfDay(for: $0), d.sessions) } }, uniquingKeysWith: +)
    }

    var body: some View {
        if let weeks {
            grid(weeks: weeks, cell: nil)
        } else {
            GeometryReader { geo in
                let cell = max(2, (geo.size.height - spacing * 6) / 7)
                let fit = max(1, Int((geo.size.width + spacing) / (cell + spacing)))
                grid(weeks: fit, cell: cell)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            }
        }
    }

    private func grid(weeks: Int, cell: CGFloat?) -> some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let weekday = cal.component(.weekday, from: today)
        let daysBack = weeks * 7 - (7 - weekday)
        let start = cal.date(byAdding: .day, value: -(daysBack - 1), to: today)!
        let counts = counts
        let peak = max(1, counts.values.max() ?? 1)
        return HStack(alignment: .top, spacing: spacing) {
            ForEach(0..<weeks, id: \.self) { w in
                VStack(spacing: spacing) {
                    ForEach(0..<7, id: \.self) { d in
                        let day = cal.date(byAdding: .day, value: w * 7 + d, to: start)!
                        let n = counts[day] ?? 0
                        let block = RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(day > today ? Color.clear : (n == 0 ? Color.primary.opacity(0.08) : tint.opacity(0.3 + 0.7 * min(1, Double(n) / Double(peak)))))
                        if let cell { block.frame(width: cell, height: cell) } else { block.aspectRatio(1, contentMode: .fit) }
                    }
                }
            }
        }
        .widgetAccentable()
    }
}

/// The last `side × side` days as a square of blocks, oldest first, today last: the grid's
/// look where a whole week column would be too small to read (a circular complication).
struct RecentBlocks: View {
    var days: [WidgetSnapshot.Usage.Day]
    var side = 4
    var spacing: CGFloat = 2

    var body: some View {
        let cal = Calendar.current
        let f = DateFormatter()
        let _ = { f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current }()
        let today = cal.startOfDay(for: Date())
        let counts = Dictionary(days.compactMap { d in f.date(from: d.day).map { (cal.startOfDay(for: $0), d.sessions) } }, uniquingKeysWith: +)
        let total = side * side
        let window = (0..<total).map { cal.date(byAdding: .day, value: $0 - (total - 1), to: today)! }
        let peak = max(1, window.map { counts[$0] ?? 0 }.max() ?? 1)
        VStack(spacing: spacing) {
            ForEach(0..<side, id: \.self) { r in
                HStack(spacing: spacing) {
                    ForEach(0..<side, id: \.self) { c in
                        let n = counts[window[r * side + c]] ?? 0
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(n == 0 ? Color.primary.opacity(0.14) : UsageBlocks.voryBlue.opacity(0.35 + 0.65 * min(1, Double(n) / Double(peak))))
                            .aspectRatio(1, contentMode: .fit)
                    }
                }
            }
        }
        .widgetAccentable()
    }
}
