import Charts
import SwiftUI

struct ForecastView: View {
    let forecast: Forecast

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let grade = forecast.grade {
                GradeCard(grade: grade, forecast: forecast)
            }
            TimelineCard(forecast: forecast)
            if !forecast.segments.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("What to expect").font(.title3.bold())
                    ForEach(forecast.segments, id: \.startMin) { SegmentRow(segment: $0) }
                }
            }
            SourceNote(forecast: forecast)
        }
    }
}

private struct GradeCard: View {
    let grade: Forecast.Grade
    let forecast: Forecast

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(grade.title, systemImage: grade.symbol)
                .font(.title.bold())
                .foregroundStyle(grade.color)
            Text(grade.summary)
            if let minutes = forecast.durationMin {
                Text("About \(minutes.durationText) in the air · \(bumpyMinutes) min of bumps")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(grade.color.opacity(0.12), in: .rect(cornerRadius: 20))
    }

    private var bumpyMinutes: Int { forecast.samples.filter { $0.severity > .smooth }.count }
}

/// Bumpiness minute by minute, coloured by severity.
private struct TimelineCard: View {
    let forecast: Forecast

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Bumps along the way").font(.title3.bold())
            Chart(forecast.samples, id: \.min) { sample in
                RectangleMark(
                    xStart: .value("Minutes into flight", sample.min),
                    xEnd: .value("Minutes into flight", sample.min + 1),
                    yStart: .value("Bumpiness", 0),
                    yEnd: .value("Bumpiness", max(sample.edr, 0.02))
                )
                .foregroundStyle(sample.severity.color.gradient)
            }
            .chartYScale(domain: 0...max(0.4, forecast.samples.map(\.edr).max() ?? 0))
            .chartYAxis {
                AxisMarks(values: [0.10, 0.22, 0.34]) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                    AxisValueLabel {
                        if let edr = value.as(Double.self) { Text(Severity(edr: edr).title) }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: 60)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let minute = value.as(Int.self) { Text(minute == 0 ? "Takeoff" : "\(minute / 60) h") }
                    }
                }
            }
            .frame(height: 180)
            .accessibilityLabel("Turbulence timeline")
            Legend()
        }
    }
}

private struct Legend: View {
    var body: some View {
        HStack(spacing: 14) {
            ForEach(Severity.allCases, id: \.self) { severity in
                HStack(spacing: 4) {
                    Circle().fill(severity.color).frame(width: 8, height: 8)
                    Text(severity.title)
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

private struct SegmentRow: View {
    let segment: Forecast.Segment

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 3)
                .fill(segment.severity.color)
                .frame(width: 6)
            VStack(alignment: .leading, spacing: 4) {
                Text(timing).font(.headline)
                Text("\(segment.severity.title) for about \(segment.minutes) min while \(FlightPhase.title(segment.phase))")
                    .font(.subheadline)
                Text(segment.severity.feelsLike).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var timing: String {
        segment.startMin == 0 ? "Right after takeoff" : "\(segment.startMin.durationText) into the flight"
    }
}

private struct SourceNote: View {
    let forecast: Forecast

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(sourceText)
            if let issued = forecast.issuedAt {
                Text("Updated \(issued.formatted(.relative(presentation: .named)))")
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    private var sourceText: String {
        switch forecast.source {
        case "gtg": "Based on NOAA's Graphical Turbulence Guidance, the same forecast US dispatchers use."
        case "mixed": "Based on NOAA turbulence guidance, plus our longer-range outlook for the later part of the flight."
        default: "Early outlook from global weather models. It sharpens to NOAA's detailed turbulence forecast 18 hours before departure."
        }
    }
}
