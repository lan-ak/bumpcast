import Charts
import SwiftUI

struct ForecastView: View {
    let forecast: Forecast
    let flight: Flight

    @Environment(Paywalls.self) private var paywalls
    @Environment(InFlight.self) private var inFlight

    var body: some View {
        let confidence = forecast.confidence(departure: flight.departureAt)
        VStack(alignment: .leading, spacing: 20) {
            if let grade = forecast.grade {
                GradeCard(grade: grade, forecast: forecast, confidence: confidence)
            }
            if paywalls.hasFullAccess(to: flight) {
                TimelineCard(
                    forecast: forecast, confidence: confidence,
                    nowMinute: inFlight.elapsedMinutes(flight, forecast: forecast))
                if !forecast.segments.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("What to expect").font(.title3.bold())
                        ForEach(forecast.segments, id: \.startMin) { SegmentRow(segment: $0) }
                    }
                }
                ConfidenceNote(forecast: forecast, confidence: confidence)
            } else {
                LockedTimelineCard(forecast: forecast) {
                    paywalls.unlock(.timelineLocked, flight: flight) {}
                }
            }
        }
        .onAppear { paywalls.firstGradeViewed(flight) }
    }
}

/// Free users see the grade; the timeline is Pro. Show its shape without the detail.
private struct LockedTimelineCard: View {
    let forecast: Forecast
    let unlock: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Bumps along the way").font(.title3.bold())
            Chart(forecast.samples, id: \.min) { sample in
                RectangleMark(
                    xStart: .value("Minute", sample.min), xEnd: .value("Minute", sample.min + 1),
                    yStart: .value("Bumpiness", 0), yEnd: .value("Bumpiness", max(sample.edr, 0.02)))
                    .foregroundStyle(.secondary)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 120)
            .blur(radius: 8)
            .accessibilityHidden(true)
            Text(teaser).font(.subheadline)
            Button(action: unlock) {
                Label(forecast.segments.isEmpty ? "See the full timeline" : "See when the bumps are", systemImage: "lock.open")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            Text("Includes the full timeline, update alerts and in-flight countdowns.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.fill.quaternary, in: .rect(cornerRadius: 20))
    }

    private var teaser: String {
        switch forecast.segments.count {
        case 0: "No bumpy stretches expected. See the minute-by-minute timeline."
        case 1: "1 bumpy stretch on this flight. See exactly when, and how it'll feel."
        default: "\(forecast.segments.count) bumpy stretches on this flight. See exactly when, and how they'll feel."
        }
    }
}

struct ConfidenceBadge: View {
    let confidence: Forecast.Confidence

    var body: some View {
        Label(confidence.title, systemImage: confidence.symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(confidence.color)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.background.opacity(0.7), in: .capsule)
    }
}

private struct GradeCard: View {
    let grade: Forecast.Grade
    let forecast: Forecast
    let confidence: Forecast.Confidence

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ConfidenceBadge(confidence: confidence)
            Label(grade.title, systemImage: grade.symbol)
                .font(.title.bold())
                .foregroundStyle(grade.color)
            Text(grade.summary)
            if let minutes = forecast.durationMin {
                Text("About \(minutes.durationText) in the air · \(bumpsText)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(grade.color.opacity(0.12), in: .rect(cornerRadius: 20))
    }

    private var bumpsText: String {
        let minutes = forecast.samples.filter { $0.severity > .smooth }.count
        return minutes == 0 ? "no bumps expected" : "\(minutes) min of bumps"
    }
}

/// Bumpiness minute by minute, coloured by severity. Outlook minutes are faded.
private struct TimelineCard: View {
    let forecast: Forecast
    let confidence: Forecast.Confidence
    /// Minutes since takeoff while flying: drawn as a "you are here" line.
    var nowMinute: Int? = nil

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
                .opacity(isOutlook(sample.min) ? 0.4 : 1)
                if let nowMinute, sample.min == nowMinute {
                    RuleMark(x: .value("Now", nowMinute))
                        .foregroundStyle(.primary)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .annotation(position: .top, alignment: .leading) {
                            Text("You are here").font(.caption2.bold())
                        }
                }
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

    private func isOutlook(_ minute: Int) -> Bool {
        switch confidence {
        case .early: true
        case .partly(let until): minute >= until
        case .confirmed: false
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

/// Explains how settled the forecast is and when it will firm up.
private struct ConfidenceNote: View {
    let forecast: Forecast
    let confidence: Forecast.Confidence

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(confidence.title, systemImage: confidence.symbol)
                .font(.headline)
                .foregroundStyle(confidence.color)
            Text(confidence.explanation)
                .font(.subheadline)
            if let issued = forecast.issuedAt {
                Text("Updated \(issued.formatted(.relative(presentation: .named)))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.fill.quaternary, in: .rect(cornerRadius: 20))
    }
}
