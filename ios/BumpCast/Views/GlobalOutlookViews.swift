import SwiftUI

// Global outlook (beta) screens: docs/design/global-forecasts-copy.md, revision 2.

extension Forecast.Warning: Identifiable {
    var id: String { "\(kind)-\(hazard)-\(startMin)-\(endMin)" }
}

/// Dark ink banner, the first thing on the forecast screen when an official warning
/// covers the route. A flag, never red or a warning triangle.
struct WarningBanner: View {
    let warning: Forecast.Warning
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Image(systemName: "flag.fill")
                    .font(.bcHeadline)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Official warning").eyebrow().opacity(0.8)
                    Text(warning.bannerText)
                        .font(.bcHeadline)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").opacity(0.7).accessibilityHidden(true)
            }
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.ink, in: .rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows what this means for your flight")
    }
}

/// What an official warning means for the flight, ending with what the crew does.
struct WarningSheet: View {
    let warning: Forecast.Warning

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label("Official warning", systemImage: "flag.fill").eyebrow().foregroundStyle(.secondary)
                Text(warning.bannerText).font(.bcTitle)
                VStack(alignment: .leading, spacing: 8) {
                    Text(Forecast.Warning.sheetHeading).font(.bcSection)
                    Text(warning.sheetBody)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(Forecast.Warning.crewTitle).font(.bcCardTitle)
                    Text(Forecast.Warning.crewBody).font(.bcSubheadline)
                }
                .skyCard()
                VStack(alignment: .leading, spacing: 8) {
                    Text("What you might feel").font(.bcSection)
                    Text(warning.whatYouMightFeel)
                }
                Text(Forecast.Warning.sheetFooter)
                    .font(.bcFootnote)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .skyBackground(.day)
    }
}

/// A pilot report on the route: the small flag's sheet, as on the map.
struct PilotReportNoteSheet: View {
    let warning: Forecast.Warning

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label("Pilot report", systemImage: "flag").eyebrow().foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 12) {
                    WaterGlass(severity: warning.severity, size: 34)
                    Text(Forecast.Warning.pilotReportTitle).font(.bcTitle)
                }
                Text(Forecast.Warning.pilotReportBody(warning))
                    .font(.bcSubheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .skyBackground(.day)
    }
}

/// Tap the Global outlook badge: what the beta is, what it's based on, how to read it.
struct GlobalOutlookSheet: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Image(systemName: "globe").accessibilityHidden(true)
                    Text("Global outlook")
                    BetaTag()
                }
                .font(.bcCardTitle)
                .foregroundStyle(Theme.secondaryInk)
                Text(GlobalOutlookCopy.title).font(.bcTitle)
                Text(GlobalOutlookCopy.body)
                section("Based on", GlobalOutlookCopy.basedOn)
                section("How to read it", GlobalOutlookCopy.howToRead)
                section("Help us improve it", GlobalOutlookCopy.helpImprove)
            }
            .padding(20)
        }
        .skyBackground(.day)
    }

    private func section(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.bcCardTitle)
            Text(body).font(.bcSubheadline).foregroundStyle(.secondary)
        }
    }
}

/// A stretch from the outlook: approximate time, a one-step range, never "smooth".
struct OutlookSegmentRow: View {
    let segment: Forecast.Segment
    let warning: Forecast.Warning?
    /// Partly confirmed routes tag their outlook stretches.
    let showsBetaTag: Bool
    let openWarning: (Forecast.Warning) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            WaterGlass(severity: warning == nil ? min(segment.severity, .moderate) : segment.severity, size: 26)
                .opacity(0.7)
            VStack(alignment: .leading, spacing: 4) {
                if showsBetaTag {
                    Text("Beta outlook").eyebrow().foregroundStyle(.secondary)
                }
                Text(segment.approximateTiming).font(.bcHeadline)
                Text(segment.outlookBody(warning: warning)).font(.bcSubheadline)
                if let warning {
                    Button {
                        openWarning(warning)
                    } label: {
                        Label(warning.rowLabel, systemImage: warning.isOfficial ? "flag.fill" : "flag")
                            .font(.bcSubheadlineStrong)
                            .foregroundStyle(warning.isOfficial ? Theme.ink : Theme.secondaryInk)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .skyCard(cornerRadius: 16, padding: 14)
        .accessibilityElement(children: .combine)
    }
}
