import SwiftUI
import Testing
import UIKit

@testable import BumpCast

extension DuoUITests {
    /// Renders of today's iPhone screens, to show the Duo work leaves the iPhone unchanged.
    @MainActor
    struct IPhoneBaselineTests {
        @Test func writeIPhoneFlightScreens() async {
            GlobalBeta.shared.set(true)
            for fixture in DuoFixtures.Case.allCases {
                let (flight, forecast) = DuoFixtures.flight(fixture)
                let store = await DuoFixtures.store([(flight, forecast)])
                let view = DuoFixtures.environment(
                    FlightDetailView(flightID: flight.id, embedded: true).padding(), store: store, fold: nil)
                let image = DuoFixtures.render(view, width: 402)
                #expect(image != nil)
                DuoFixtures.write(image, to: "iphone-after", name: fixture.rawValue)
            }
        }
    }

    /// Every Duo screen, data state and fold position against the one rule set in
    /// docs/design/duo-layout-rules.md. Each case is rendered at the Duo's measured size with the fold
    /// injected (no Device Hub needed), its placed frames are checked, and a picture of it is written
    /// to `ios/build/duo-audit/cases`, with an index grid of all of them.
    @MainActor
    @Suite(.serialized)
    struct DuoAuditTests {
        /// The inner screen less the 84 pt system column and the 16 pt insets either side.
        static let spreadWidth: CGFloat = 951 - 84 - 2 * DuoSpacing.inset
        static let folds: [(name: String, fold: DuoFold)] = [("open", Duo.open), ("partly", Duo.partly)]

        struct Outcome {
            let name: String
            let image: UIImage?
            let problems: [String]
        }

        // MARK: The cases

        /// The Flights tab's data states: the list renders the next flight's forecast in place.
        static let flightsCases: [(name: String, flights: [DuoFixtures.Case], unlocked: Bool)] = [
            ("flights-before", [.beforeFlight], true),
            ("flights-day-of", [.dayOf], true),
            ("flights-in-air", [.inAir], true),
            ("flights-just-landed", [.justLanded, .beforeFlight], true),
            ("flights-cancelled", [.cancelled, .beforeFlight], true),
            ("flights-diverted", [.diverted], true),
            ("flights-none", [], true),
            ("flights-locked", [.beforeFlight], false),
            ("flights-many", [.beforeFlight, .dayOf, .global, .lhrJfk, .lhrFco, .strong], true),
            ("flights-even-stretches", [.evenStretches], true),
        ]

        /// A flight opened from Coming up: its forecast, then the others coming up.
        static let detailCases: [(name: String, flight: DuoFixtures.Case)] = [
            ("detail-us", .beforeFlight), ("detail-global-warning", .global), ("detail-lhr-jfk", .lhrJfk),
            ("detail-lhr-fco", .lhrFco), ("detail-strong", .strong), ("detail-gusty", .gusty),
        ]

        @Test func everyScreenStateAndFoldFollowsTheRules() async {
            GlobalBeta.shared.set(true)
            var outcomes: [Outcome] = []

            for item in Self.flightsCases {
                let flights = item.flights.map { DuoFixtures.flight($0) }
                let store = await DuoFixtures.store(flights)
                for (foldName, fold) in Self.folds {
                    let view = DuoFixtures.environment(FlightsListView(contentOnly: true), store: store, fold: fold, unlocked: item.unlocked)
                    outcomes.append(audit("\(item.name)-\(foldName)", view: view, fold: fold, width: Self.spreadWidth))
                }
            }

            for item in Self.detailCases {
                let (flight, forecast) = DuoFixtures.flight(item.flight)
                // Others coming up after it, so Coming up shows.
                let others = [DuoFixtures.flight(.dayOf), DuoFixtures.flight(.strong)]
                let store = await DuoFixtures.store([(flight, forecast)] + others)
                for (foldName, fold) in Self.folds {
                    let view = DuoFixtures.environment(FlightDetailView(flightID: flight.id, embedded: true), store: store, fold: fold)
                    outcomes.append(audit("\(item.name)-\(foldName)", view: view, fold: fold, width: Self.spreadWidth))
                }
            }

            let store = await DuoFixtures.store([DuoFixtures.flight(.inAir)])
            for (foldName, fold) in Self.folds {
                // Learn's panes take the screen's height and start at its edge (they add the inset).
                let learn = DuoFixtures.environment(LearnView(contentOnly: true).frame(height: 635), store: store, fold: fold)
                outcomes.append(audit("learn-\(foldName)", view: learn, fold: fold, width: Self.spreadWidth + DuoSpacing.inset, padded: false))
                let calm = DuoFixtures.environment(CalmView(contentOnly: true), store: store, fold: fold)
                outcomes.append(audit("calm-\(foldName)", view: calm, fold: fold, width: Self.spreadWidth + 2 * DuoSpacing.inset, padded: false))
                let breathing = DuoFixtures.environment(BreathingView().frame(height: 669), store: store, fold: fold)
                outcomes.append(audit("breathing-\(foldName)", view: breathing, fold: fold, width: Self.spreadWidth + 2 * DuoSpacing.inset, padded: false))
            }

            writeIndex(outcomes)
            let failing = outcomes.filter { !$0.problems.isEmpty }
            for outcome in failing {
                Issue.record("\(outcome.name): \(outcome.problems)")
            }
            // The count is part of the report: every case above, rendered.
            #expect(outcomes.count == (Self.flightsCases.count + Self.detailCases.count + 3) * Self.folds.count)
            #expect(outcomes.allSatisfy { $0.image != nil })
        }

        /// Large text: the Flights and detail states at the largest standard size and a large
        /// accessibility size, both folds, against the same rules (nothing cut off, no overlaps, clear
        /// of the fold). Written to `large-text.png` beside the main contact sheet.
        @Test func largeTextFollowsTheRules() async {
            GlobalBeta.shared.set(true)
            let sizes: [(name: String, size: DynamicTypeSize)] = [("xxxl", .xxxLarge), ("ax3", .accessibility3)]
            var outcomes: [Outcome] = []
            for (sizeName, size) in sizes {
                for item in Self.flightsCases {
                    let store = await DuoFixtures.store(item.flights.map { DuoFixtures.flight($0) })
                    for (foldName, fold) in Self.folds {
                        let view = DuoFixtures.environment(FlightsListView(contentOnly: true), store: store, fold: fold, unlocked: item.unlocked)
                            .dynamicTypeSize(size)
                        outcomes.append(audit("\(item.name)-\(foldName)-\(sizeName)", view: view, fold: fold, width: Self.spreadWidth))
                    }
                }
                for item in Self.detailCases {
                    let (flight, forecast) = DuoFixtures.flight(item.flight)
                    let store = await DuoFixtures.store([(flight, forecast), DuoFixtures.flight(.dayOf), DuoFixtures.flight(.strong)])
                    for (foldName, fold) in Self.folds {
                        let view = DuoFixtures.environment(FlightDetailView(flightID: flight.id, embedded: true), store: store, fold: fold)
                            .dynamicTypeSize(size)
                        outcomes.append(audit("\(item.name)-\(foldName)-\(sizeName)", view: view, fold: fold, width: Self.spreadWidth))
                    }
                }
            }
            writeIndex(outcomes, name: "large-text")
            for outcome in outcomes where !outcome.problems.isEmpty {
                Issue.record("\(outcome.name): \(outcome.problems)")
            }
            #expect(outcomes.count == (Self.flightsCases.count + Self.detailCases.count) * Self.folds.count * sizes.count)
        }

        /// How a case is offline: no network, wifi that isn't reaching the internet, or a sync that
        /// failed for another reason (the neutral line).
        enum Offline: String {
            case noNetwork = "offline", planeWifi = "not-online", syncFailed = "sync-failed"
        }

        static let offlineCases: [(name: String, flights: [DuoFixtures.Case], offline: Offline)] = [
            ("before-saved", [.beforeFlight], .noNetwork),
            ("in-air", [.inAir], .noNetwork),
            ("in-air-plane-wifi", [.inAir], .planeWifi),
            ("nothing-saved", [.nothingSaved], .noNetwork),
            ("no-flights", [], .noNetwork),
            ("sync-failed", [.beforeFlight], .syncFailed),
        ]

        /// Offline: the connection banners and notes, with a saved forecast, in the air, and with
        /// nothing saved, on the Flights spread and the flight's own screen, open, partly open and
        /// on the iPhone. Written to `offline.png`. The connection is set and put back around each
        /// render, with nothing in between that waits, so no other test sees it.
        @Test func offlineStatesFollowTheRules() async {
            GlobalBeta.shared.set(true)
            var outcomes: [Outcome] = []
            defer { Connectivity.shared.debugSet(hasPath: true) }
            for item in Self.offlineCases {
                let store = await DuoFixtures.store(item.flights.map { DuoFixtures.flight($0) })
                if item.offline == .syncFailed { store.debugNoteSyncFailed(onConnection: false) }
                func offline<T>(_ render: () -> T) -> T {
                    switch item.offline {
                    case .noNetwork: Connectivity.shared.debugSet(hasPath: false)
                    case .planeWifi: Connectivity.shared.debugSet(hasPath: true, isDegraded: true)
                    case .syncFailed: break
                    }
                    defer { Connectivity.shared.debugSet(hasPath: true) }
                    return render()
                }
                let name = "offline-\(item.name)"
                let flight = store.upcomingFlights.first
                for (foldName, fold) in Self.folds {
                    let list = DuoFixtures.environment(FlightsListView(contentOnly: true), store: store, fold: fold)
                    outcomes.append(offline { audit("\(name)-flights-\(foldName)", view: list, fold: fold, width: Self.spreadWidth) })
                    if let flight {
                        let detail = DuoFixtures.environment(FlightDetailView(flightID: flight.id, embedded: true), store: store, fold: fold)
                        outcomes.append(offline { audit("\(name)-detail-\(foldName)", view: detail, fold: fold, width: Self.spreadWidth) })
                    }
                }
                // The iPhone: the list, and the flight's own screen.
                var phone: [(String, AnyView)] = [("flights", AnyView(FlightsListView(contentOnly: true)))]
                if let flight { phone.append(("detail", AnyView(FlightDetailView(flightID: flight.id, embedded: true)))) }
                for (screen, view) in phone {
                    let image = offline { DuoFixtures.render(DuoFixtures.environment(view.padding(.horizontal, 16), store: store, fold: nil), width: 402) }
                    DuoFixtures.write(image, to: "cases", name: "\(name)-\(screen)-iphone")
                    outcomes.append(Outcome(name: "\(name)-\(screen)-iphone", image: image, problems: image == nil ? ["no render"] : []))
                }
            }
            writeIndex(outcomes, name: "offline")
            for outcome in outcomes where !outcome.problems.isEmpty {
                Issue.record("\(outcome.name): \(outcome.problems)")
            }
            // Six cases × (Flights on 2 folds + iPhone), plus a flight's screen for the five with one.
            #expect(outcomes.count == Self.offlineCases.count * 3 + 5 * 3)
        }

        /// The map offline, with nothing saved ("needs a connection") and with only another height
        /// saved ("no saved map at this height"): its status card says so, clear of the fold, the
        /// system column, the bottom inset and the attribution, open, partly open and on the iPhone.
        /// Hosted in a window (the map is UIKit), the card found by what VoiceOver reads.
        @Test func mapOfflineStatesStayClear() async throws {
            DuoFixtures.enableAccessibility
            let store = await DuoFixtures.store([DuoFixtures.flight(.beforeFlight)])
            let grid = TurbulenceGrid(
                validAt: .now, levelFt: 10000, cycle: .now.addingTimeInterval(-3600), north: 50, west: -125, step: 1,
                ny: 2, nx: 2, cells: "0000")
            let cases: [(name: String, saved: MapSnapshot, card: String)] = [
                ("needs-connection", MapSnapshot(grids: [:], savedAt: .now), "The map needs a connection"),
                ("no-saved-height", MapSnapshot(grids: [10000: [grid]], savedAt: .now), "No saved map at this height"),
            ]
            // The Duo's inner screen less the system column, and the iPhone, each less the bottom inset.
            let sizes: [(name: String, size: CGSize, fold: DuoFold?)] = [
                ("open", CGSize(width: 951 - 84, height: 669 - 34), Duo.open),
                ("partly", CGSize(width: 951 - 84, height: 669 - 34), Duo.partly),
                ("iphone", CGSize(width: 402, height: 874 - 34 - 62), nil),
            ]
            var outcomes: [Outcome] = []
            Connectivity.shared.debugSet(hasPath: false)
            defer { Connectivity.shared.debugSet(hasPath: true) }
            for item in cases {
                await LocalStore.shared.saveMap(item.saved)
                for size in sizes {
                    let view = DuoFixtures.environment(TurbulenceMapView(), store: store, fold: size.fold)
                    let (window, root) = try DuoFixtures.host(view, size: size.size)
                    try await Task.sleep(for: .seconds(1.5))
                    let card = DuoFixtures.accessibilityElements(in: root).first { $0.label.contains(item.card) }?.frame
                    let image = UIGraphicsImageRenderer(bounds: root.bounds).image { _ in
                        root.drawHierarchy(in: root.bounds, afterScreenUpdates: true)
                    }
                    window.isHidden = true
                    var problems: [String] = []
                    if let card {
                        let bounds = CGRect(origin: .zero, size: size.size)
                        let attribution = CGRect(x: 8, y: size.size.height - 32, width: 110, height: 28)
                        if !bounds.contains(card) { problems.append("off screen: \(card)") }
                        if card.intersects(attribution) { problems.append("over the attribution: \(card)") }
                        if let fold = size.fold, fold.isActive, card.maxX > fold.band.lowerBound, card.minX < fold.band.upperBound {
                            problems.append("in the fold: \(card)")
                        }
                    } else {
                        problems.append("no \"\(item.card)\" card")
                    }
                    let name = "offline-map-\(item.name)-\(size.name)"
                    DuoFixtures.write(image, to: "cases", name: name)
                    outcomes.append(Outcome(name: name, image: image, problems: problems))
                }
            }
            await LocalStore.shared.saveMap(MapSnapshot(grids: [:], savedAt: .now))
            writeIndex(outcomes, name: "offline-map")
            for outcome in outcomes where !outcome.problems.isEmpty {
                Issue.record("\(outcome.name): \(outcome.problems)")
            }
            #expect(outcomes.count == cases.count * sizes.count)
        }

        /// The same views, by the same ids, in the same order at both folds: a fold change moves them,
        /// never swaps one for another (what lets the transition animate rather than jump).
        @Test func itemIdentitiesAreStableAcrossFolds() async {
            GlobalBeta.shared.set(true)
            let cases: [[DuoFixtures.Case]] = [[.beforeFlight], [.inAir], [.justLanded, .beforeFlight], [.global], [.cancelled, .beforeFlight]]
            for flights in cases {
                let store = await DuoFixtures.store(flights.map { DuoFixtures.flight($0) })
                var ids: [[String]] = []
                for (_, fold) in Self.folds {
                    DuoSpreadRecorder.plans = []
                    _ = DuoFixtures.render(
                        DuoFixtures.environment(FlightsListView(contentOnly: true), store: store, fold: fold).padding(.horizontal, DuoSpacing.inset),
                        width: Self.spreadWidth + 2 * DuoSpacing.inset)
                    ids.append(DuoSpreadRecorder.plans.last { $0.fold == fold }?.ids ?? [])
                }
                #expect(!ids[0].isEmpty, "\(flights): nothing placed")
                #expect(ids[0] == ids[1], "\(flights): \(ids[0]) vs \(ids[1])")
                #expect(Set(ids[0]).count == ids[0].count, "\(flights): duplicate ids \(ids[0])")
            }
        }

        /// The map's status card, in every size its variants come in (loading; a message; a message
        /// with a button), clear of the fold, the bottom inset and the attribution.
        @Test(arguments: [CGSize(width: 220, height: 52), CGSize(width: 340, height: 118), CGSize(width: 340, height: 176)])
        func mapStatusCardStaysClear(card: CGSize) {
            // The map's safe area: the inner screen less the system column and the 34 pt bottom inset.
            let container = CGSize(width: 951 - 84, height: 669 - 34)
            // Apple's Maps · Legal attribution, bottom left just above the inset (measured ±2 pt).
            let attribution = CGRect(x: 8, y: container.height - 32, width: 110, height: 28)
            for (_, fold) in Self.folds {
                let frame = FloatingCardPlacement.frame(card: card, in: container, fold: fold)
                #expect(frame.maxY <= container.height, "bottom inset")
                #expect(frame.maxX <= container.width, "system column")
                #expect(!frame.intersects(attribution), "attribution: \(frame)")
                if fold.isActive {
                    #expect(frame.maxX <= fold.band.lowerBound || frame.minX >= fold.band.upperBound, "fold: \(frame)")
                }
            }
        }

        /// "Set once": no screen lays itself out for the Duo. Only the engine and container may read
        /// the fold or place views by role; components only declare their role. Sheets go through
        /// `adaptiveSheet`, so every one follows the fold rule.
        @Test func noScreenHasItsOwnDuoLayout() throws {
            let views = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appending(path: "BumpCast/Views")
            let allowed: Set<String> = ["DuoLayout.swift"]
            let banned = ["duoFold", ".duoRole(", "DuoFold", "FoldSpread", "DuoSpread(", "DuoSpreadPlan", ".sheet(", ".fullScreenCover("]
            var offences: [String] = []
            for file in try FileManager.default.contentsOfDirectory(atPath: views.path(percentEncoded: false)) where file.hasSuffix(".swift") && !allowed.contains(file) {
                let text = try String(contentsOf: views.appending(path: file), encoding: .utf8)
                for token in banned where text.contains(token) { offences.append("\(file): \(token)") }
            }
            #expect(offences.isEmpty, "\(offences)")
        }

        /// Shared builders only: one Coming up title, one Delete button, one timeline, one menu.
        @Test func sharedPiecesAreDefinedOnce() throws {
            let views = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appending(path: "BumpCast/Views")
            var text = ""
            for file in try FileManager.default.contentsOfDirectory(atPath: views.path(percentEncoded: false)) where file.hasSuffix(".swift") {
                text += try String(contentsOf: views.appending(path: file), encoding: .utf8)
            }
            func count(_ needle: String) -> Int { text.components(separatedBy: needle).count - 1 }
            #expect(count("\"Coming up\"") == 1)
            #expect(count("Button(\"Delete flight\"") == 1)
            #expect(count("struct TimelineCard") == 1)
            #expect(count("Menu(\"More\"") == 1)
        }

        // MARK: Checking one case

        private func audit<V: View>(_ name: String, view: V, fold: DuoFold, width: CGFloat, padded: Bool = true) -> Outcome {
            DuoSpreadRecorder.plans = []
            let image = DuoFixtures.render(padded ? AnyView(view.padding(.horizontal, DuoSpacing.inset)) : AnyView(view), width: padded ? width + 2 * DuoSpacing.inset : width)
            var problems: [String] = []
            let plan = DuoSpreadRecorder.plans.last { $0.fold == fold && $0.frames.count > 0 }
            if let plan {
                // Lists follow the list rules. Two panes (rules, section 5) are centred on each other
                // or fill the height and scroll, so only the fold, overlap and edge rules apply.
                if plan.centred || plan.fillsHeight {
                    problems += paneViolations(frames: plan.frames, width: plan.width, fold: fold)
                } else {
                    problems += violations(roles: plan.roles, frames: plan.frames, width: plan.width, fold: fold)
                    // Never shorter than its text needs (scrolling panes scroll instead).
                    for (index, frame) in plan.frames.enumerated() where frame.height < plan.needed[index] - 0.5 {
                        problems.append("\(index) cut to \(frame.height) of \(plan.needed[index])")
                    }
                }
                // Clear of the system column on the right.
                for frame in plan.frames where frame.maxX + DuoSpacing.inset > 951 - 84 + 0.5 {
                    problems.append("into the system column: \(frame)")
                }
                // Timeline hour labels at the timeline's width: never on top of each other.
                if let timeline = plan.frames.first(where: { $0.width > 0 && $0.height >= 200 && $0.height <= 320 }) {
                    let plotWidth = timeline.width - 32 - 76  // card padding, the Strong/Moderate/Light chop labels
                    for minutes in [95, 386, 573, 900] {
                        let axis = TimelineAxis(totalMinutes: minutes, plotWidth: plotWidth)
                        let labelled = axis.ticks.filter { axis.labeled.contains($0) }
                        for (a, b) in zip(labelled, labelled.dropFirst()) {
                            let end = TimelineAxis.x(of: a, totalMinutes: minutes, plotWidth: plotWidth)
                                + (a == 0 ? TimelineAxis.takeoffWidth : TimelineAxis.hourWidth)
                            if TimelineAxis.x(of: b, totalMinutes: minutes, plotWidth: plotWidth) < end + TimelineAxis.gap - 0.5 {
                                problems.append("axis labels \(a) and \(b) overlap at \(Int(plotWidth)) pt")
                            }
                        }
                    }
                }
            } else {
                problems.append("no spread placed")
            }
            let marked = image.map { mark($0, name: name, fold: fold, padded: padded) }
            DuoFixtures.write(marked, to: "cases", name: name)
            return Outcome(name: name, image: marked, problems: problems)
        }

        /// Two panes: inside the spread, not overlapping, and clear of a live fold.
        private func paneViolations(frames: [CGRect], width: CGFloat, fold: DuoFold) -> [String] {
            var problems: [String] = []
            for (i, a) in frames.enumerated() {
                if a.minX < -0.5 || a.maxX > width + 0.5 { problems.append("\(i) outside the spread: \(a)") }
                if fold.isActive, a.minX + DuoSpacing.inset < fold.band.upperBound - 0.5, a.maxX + DuoSpacing.inset > fold.band.lowerBound + 0.5 {
                    problems.append("\(i) in the fold: \(a)")
                }
                for (j, b) in frames.enumerated() where j > i {
                    let overlap = a.intersection(b)
                    if !overlap.isNull, overlap.width > 0.5, overlap.height > 0.5 { problems.append("\(i) overlaps \(j)") }
                }
            }
            return problems
        }

        /// The fold's band drawn over a partly open render, so the picture shows what the check checks.
        private func mark(_ image: UIImage, name: String, fold: DuoFold, padded: Bool) -> UIImage {
            guard fold.isActive else { return image }
            let renderer = UIGraphicsImageRenderer(size: image.size)
            return renderer.image { context in
                image.draw(at: .zero)
                UIColor.systemPink.withAlphaComponent(0.18).setFill()
                context.fill(CGRect(x: fold.band.lowerBound, y: 0, width: fold.band.upperBound - fold.band.lowerBound, height: image.size.height))
            }
        }

        /// One grid of every case, labelled and marked pass or fail, for review in one place.
        private func writeIndex(_ outcomes: [Outcome], name: String = "index") {
            let columns = 4
            let thumbWidth: CGFloat = 420
            let thumbHeight: CGFloat = 620
            let labelHeight: CGFloat = 36
            let rows = (outcomes.count + columns - 1) / columns
            let size = CGSize(width: CGFloat(columns) * thumbWidth, height: CGFloat(rows) * (thumbHeight + labelHeight))
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let grid = UIGraphicsImageRenderer(size: size, format: format).image { context in
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: size))
                for (index, outcome) in outcomes.enumerated() {
                    let origin = CGPoint(
                        x: CGFloat(index % columns) * thumbWidth, y: CGFloat(index / columns) * (thumbHeight + labelHeight))
                    let passed = outcome.problems.isEmpty
                    let label = "\(passed ? "PASS" : "FAIL")  \(outcome.name)" as NSString
                    label.draw(
                        at: CGPoint(x: origin.x + 8, y: origin.y + 8),
                        withAttributes: [
                            .font: UIFont.monospacedSystemFont(ofSize: 15, weight: .semibold),
                            .foregroundColor: passed ? UIColor.systemGreen : UIColor.systemRed,
                        ])
                    if let image = outcome.image {
                        // The top of each screen, scaled to the cell's width.
                        let scale = (thumbWidth - 16) / image.size.width
                        let shown = CGRect(x: origin.x + 8, y: origin.y + labelHeight, width: thumbWidth - 16, height: min(image.size.height * scale, thumbHeight - 8))
                        context.cgContext.saveGState()
                        context.cgContext.clip(to: shown)
                        image.draw(in: CGRect(x: shown.minX, y: shown.minY, width: image.size.width * scale, height: image.size.height * scale))
                        context.cgContext.restoreGState()
                    }
                }
            }
            DuoFixtures.write(grid, to: ".", name: name)
        }
    }
}
