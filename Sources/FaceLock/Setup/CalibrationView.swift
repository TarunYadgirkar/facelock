import Charts
import FaceLockCore
import SwiftUI

/// The LFW benchmark's stranger scores for this pipeline (docs/benchmarks.md): what the owner's
/// histogram is drawn against.
enum Benchmark {
    static let strangerMax = 0.333
    static let strangerP99 = 0.223
}

struct ScoreBin: Identifiable {
    let lower: Double
    let count: Int
    var id: Double { lower }

    static let width = 0.02

    static func bins(_ scores: [Float]) -> [ScoreBin] {
        let grouped = Dictionary(grouping: scores) { (Double($0) / width).rounded(.down) * width }
        return grouped.map { ScoreBin(lower: $0.key, count: $0.value.count) }.sorted { $0.lower < $1.lower }
    }
}

/// The calibration result: your looks against the benchmark strangers, the threshold line, and
/// what it means in plain words.
struct CalibrationView: View {
    let report: CalibrationReport
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text(Calibrator.headline(report))
                .font(compact ? Typeface.state : Typeface.title)
                .fixedSize(horizontal: false, vertical: true)
            Text(summary)
                .font(Typeface.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .readableWidth()
            chart
                .frame(height: compact ? 120 : 170)
            legend
            if !report.closeLooks.isEmpty { closeLooks }
            if report.singleSession {
                Label("Single session. Tomorrow, add a second sitting in different light so the threshold covers more than one afternoon.",
                      systemImage: "sun.max")
                    .font(Typeface.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var summary: String {
        let t = String(format: "%.2f", report.thresholds.accept)
        guard let low = report.ownerLow else {
            return "FaceLock accepts a match at \(t) or higher until it has enough looks to compare."
        }
        return "FaceLock accepts a match at \(t) or higher. 98% of your looks scored \(String(format: "%.2f", low)) or more "
            + "against your other looks. Strangers in the benchmark never passed \(String(format: "%.2f", Benchmark.strangerMax))."
    }

    private var chart: some View {
        Chart {
            RectangleMark(xStart: .value("Score", 0), xEnd: .value("Score", Benchmark.strangerMax))
                .foregroundStyle(Theme.neutral.opacity(0.16))
            ForEach(ScoreBin.bins(report.ownerScores)) { bin in
                RectangleMark(xStart: .value("Score", bin.lower), xEnd: .value("Score", bin.lower + ScoreBin.width),
                              yStart: .value("Looks", 0), yEnd: .value("Looks", bin.count))
                    .foregroundStyle(Theme.accent)
            }
            RuleMark(x: .value("Lowest allowed", Double(report.thresholds.floor)))
                .foregroundStyle(Theme.neutral)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            RuleMark(x: .value("Your threshold", Double(report.thresholds.accept)))
                .foregroundStyle(Color.primary)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .annotation(position: .top, alignment: .center, spacing: 2) {
                    Text("Your threshold \(String(format: "%.2f", report.thresholds.accept))")
                        .font(Typeface.caption.weight(.semibold))
                        .monospacedDigit()
                }
        }
        .chartXScale(domain: 0...1)
        // Tick labels without grid lines, so the dashed floor is the only dashed rule on the chart.
        .chartXAxis {
            AxisMarks(values: [0, 0.25, 0.5, 0.75, 1]) { _ in
                AxisTick()
                AxisValueLabel()
            }
        }
        .chartYAxis { AxisMarks(position: .leading) }
        .accessibilityLabel("Histogram of your look scores against the benchmark stranger range")
    }

    private var legend: some View {
        HStack(spacing: Space.l) {
            LegendKey(color: Theme.accent, text: "Your looks")
            LegendKey(color: Theme.neutral.opacity(0.16), text: "Benchmark strangers, up to 0.33")
            LegendKey(color: Theme.neutral, text: "Lowest allowed \(String(format: "%.2f", report.thresholds.floor))", dashed: true)
        }
        .font(Typeface.caption)
        .foregroundStyle(.secondary)
    }

    private var closeLooks: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("Close to strangers").font(Typeface.bodyEmphasis)
            ForEach(report.closeLooks, id: \.target) { look in
                Text("\(EnrollmentTarget.label(forStored: look.target)): lowest \(String(format: "%.2f", look.lowestScore))")
                    .font(Typeface.body)
                    .monospacedDigit()
            }
            Text("Use Teach a New Look from the menu to add them again.")
                .font(Typeface.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct LegendKey: View {
    let color: Color
    let text: String
    var dashed = false

    var body: some View {
        HStack(spacing: Space.xs + 2) {
            if dashed {
                Rectangle().fill(color).frame(width: 10, height: 1.5)
            } else {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            }
            Text(text)
        }
    }
}
