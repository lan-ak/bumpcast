import ActivityKit
import SwiftUI
import WidgetKit

@main
struct BumpCastWidgets: WidgetBundle {
    var body: some Widget {
        FlightLiveActivity()
    }
}

/// Lock Screen and Dynamic Island countdown to the next bumpy stretch. Timers and the
/// progress bar run on the device with no updates, so it keeps working in flight mode.
struct FlightLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FlightActivityAttributes.self) { context in
            LockScreenView(attributes: context.attributes, state: context.state)
                .padding()
                .activityBackgroundTint(Color.black.opacity(0.6))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(URL(string: "bumpcast://flight/\(context.attributes.flightID.uuidString)"))
        } dynamicIsland: { context in
            let attributes = context.attributes
            let state = context.state
            let current = attributes.current(at: .now, state)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(attributes.route, systemImage: "airplane").font(.caption.bold())
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(timerInterval: countdown(to: attributes.landing(state)), countsDown: true)
                        .font(.caption.monospacedDigit())
                        .multilineTextAlignment(.trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        NextStretchText(attributes: attributes, state: state).font(.subheadline.bold())
                        FlightProgress(attributes: attributes, state: state)
                    }
                }
            } compactLeading: {
                Image(systemName: current == nil ? "sun.max" : "wind")
                    .foregroundStyle(color(current?.0.severity))
            } compactTrailing: {
                if let (stretch, inProgress) = current {
                    Text(
                        timerInterval: countdown(to: inProgress ? attributes.end(of: stretch, state) : attributes.start(of: stretch, state)),
                        countsDown: true
                    )
                    .monospacedDigit()
                    .frame(maxWidth: 48)
                    .foregroundStyle(color(stretch.severity))
                } else {
                    Image(systemName: "checkmark")
                }
            } minimal: {
                Image(systemName: current == nil ? "sun.max" : "wind")
                    .foregroundStyle(color(current?.0.severity))
            }
            .widgetURL(URL(string: "bumpcast://flight/\(attributes.flightID.uuidString)"))
        }
    }
}

/// now...end, clamped so a past `end` can't make an inverted range (a runtime trap).
private func countdown(to end: Date) -> ClosedRange<Date> {
    let now = Date.now
    return min(now, end)...end
}

private func color(_ severity: String?) -> Color {
    switch severity {
    case "severe": .red
    case "moderate": .orange
    case "light": .yellow
    default: .teal
    }
}

private struct LockScreenView: View {
    let attributes: FlightActivityAttributes
    let state: FlightActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(attributes.route, systemImage: "airplane").font(.headline)
                Spacer()
                Text("Lands in ").font(.caption) + Text(timerInterval: countdown(to: attributes.landing(state)), countsDown: true)
                    .font(.caption.monospacedDigit())
            }
            NextStretchText(attributes: attributes, state: state).font(.title3.bold())
            FlightProgress(attributes: attributes, state: state)
            Link(destination: URL(string: "bumpcast://breathe")!) {
                Label("Breathe with me", systemImage: "leaf").font(.caption.bold())
            }
        }
        .foregroundStyle(.white)
    }
}

private struct NextStretchText: View {
    let attributes: FlightActivityAttributes
    let state: FlightActivityAttributes.ContentState

    var body: some View {
        // Worked out at render time. The app sets staleDate to the next stretch boundary,
        // so the system re-renders this view there even with no connection.
        if let (stretch, inProgress) = attributes.current(at: .now, state) {
            if inProgress {
                Text("\(stretch.title) now · ends in ")
                    + Text(timerInterval: countdown(to: attributes.end(of: stretch, state)), countsDown: true).monospacedDigit()
            } else {
                Text("\(stretch.title) in ")
                    + Text(timerInterval: countdown(to: attributes.start(of: stretch, state)), countsDown: true).monospacedDigit()
            }
        } else {
            Text("Smooth air for the rest of the flight")
        }
    }
}

/// Flight progress with the bumpy stretches marked, so position vs. bumps stays visible offline.
private struct FlightProgress: View {
    let attributes: FlightActivityAttributes
    let state: FlightActivityAttributes.ContentState

    var body: some View {
        ZStack(alignment: .leading) {
            ProgressView(timerInterval: state.takeoff...attributes.landing(state), countsDown: false) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
            .tint(.white)
            GeometryReader { geo in
                ForEach(attributes.stretches, id: \.startMin) { stretch in
                    let total = Double(max(attributes.durationMin, 1))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color(stretch.severity))
                        .frame(
                            width: max(3, geo.size.width * Double(stretch.endMin - stretch.startMin + 1) / total),
                            height: 6)
                        .offset(x: geo.size.width * Double(stretch.startMin) / total, y: geo.size.height / 2 - 3)
                }
            }
            .allowsHitTesting(false)
        }
        .frame(height: 12)
    }
}
