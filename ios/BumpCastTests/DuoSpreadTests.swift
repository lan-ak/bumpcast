import SwiftUI
import Testing

@testable import BumpCast

/// The iPhone Duo inner screen: 951 pt wide, the fold's 40 pt band in the middle, an 84 pt system
/// column on the right. The spread runs from the 16 pt inset to 16 pt short of the system column.
enum Duo {
    static let band: ClosedRange<CGFloat> = 455.5...495.5
    static let open = DuoFold(band: band, isActive: false)
    static let partly = DuoFold(band: band, isActive: true)
    static let width: CGFloat = 951 - 84 - 2 * DuoSpacing.inset
}

/// Everything a spread must hold to, whatever it holds: equal pairs, no overlaps, nothing on a
/// live fold, the usual gap between flowing cards (so no holes), and balanced columns.
func violations(roles: [DuoRole], frames: [CGRect], width: CGFloat, fold: DuoFold) -> [String] {
    if fold.isActive { return stackedViolations(roles: roles, frames: frames, width: width, fold: fold) }
    let s = DuoSpacing.rows
    let tolerance: CGFloat = 0.5
    var problems: [String] = []
    let shown = frames.indices.filter { frames[$0].height > 0 }

    // Pairs: two to a row, the same top and height; rows the usual gap apart.
    var i = 0
    var lastRowBottom: CGFloat?
    while i < roles.count {
        guard roles[i] == .pair else { lastRowBottom = nil; i += 1; continue }
        if i + 1 < roles.count, roles[i + 1] == .pair {
            let a = frames[i], b = frames[i + 1]
            if abs(a.minY - b.minY) > tolerance || abs(a.height - b.height) > tolerance {
                problems.append("pair \(i)/\(i + 1) not level: \(a) vs \(b)")
            }
            if let bottom = lastRowBottom, abs(a.minY - bottom - s) > tolerance {
                problems.append("pair row \(i) gap \(a.minY - bottom), expected \(s)")
            }
            lastRowBottom = max(a.maxY, b.maxY)
            i += 2
        } else {
            i += 1
        }
    }

    // No two placed views overlap.
    for (n, a) in shown.enumerated() {
        for b in shown[(n + 1)...] {
            let overlap = frames[a].intersection(frames[b])
            if !overlap.isNull, overlap.width > tolerance, overlap.height > tolerance {
                problems.append("\(a) overlaps \(b): \(frames[a]) \(frames[b])")
            }
        }
    }

    for index in shown {
        let frame = frames[index]
        // Inside the spread.
        if frame.minX < -tolerance || frame.maxX > width + tolerance {
            problems.append("\(index) outside the spread: \(frame)")
        }
        // Partly open, only full-width (split) cards reach the fold's band.
        if fold.isActive, roles[index] != .full {
            let minX = frame.minX + DuoSpacing.inset, maxX = frame.maxX + DuoSpacing.inset
            if minX < fold.band.upperBound - tolerance, maxX > fold.band.lowerBound + tolerance {
                problems.append("\(index) (\(roles[index])) in the fold: \(frame)")
            }
        }
    }

    // Flowing cards sit the usual gap under whatever is above them in their column: no holes. The
    // one beside an odd last stretch card takes its empty slot, level with it.
    let flows = shown.filter { roles[$0] == .flow }
    for index in flows {
        let frame = frames[index]
        let fillsOddSlot = shown.contains { other in
            other < index && roles[other] == .pair && abs(frames[other].minY - frame.minY) <= tolerance
        }
        if fillsOddSlot { continue }
        let above = shown.filter { other in
            other < index && frames[other].maxY <= frame.minY + tolerance
                && frames[other].minX < frame.maxX - tolerance && frames[other].maxX > frame.minX + tolerance
        }
        let bottom = above.map { frames[$0].maxY }.max()
        let gap = frame.minY - (bottom ?? frame.minY)
        if bottom != nil, abs(gap - s) > tolerance {
            problems.append("flow \(index) gap \(gap), expected \(s)")
        }
    }

    // Masonry: with flowing cards in both columns, they end within one card of each other.
    let columns = DuoSpreadPlan.columns(width: width, fold: fold)
    let leftFlows = flows.filter { frames[$0].maxX <= columns.left.x + columns.left.width + tolerance }
    if !leftFlows.isEmpty, leftFlows.count < flows.count, let tallest = flows.map({ frames[$0].height }).max() {
        let leftBottom = shown.filter { frames[$0].maxX <= columns.left.x + columns.left.width + tolerance }.map { frames[$0].maxY }.max() ?? 0
        let rightBottom = shown.filter { frames[$0].minX >= columns.right.x - tolerance }.map { frames[$0].maxY }.max() ?? 0
        if abs(leftBottom - rightBottom) > tallest + s + tolerance {
            problems.append("columns unbalanced: \(leftBottom) vs \(rightBottom)")
        }
    }
    return problems
}

/// Partly open: two freely stacking columns. Every view sits exactly one token under whatever is
/// above it in its column (or at the top), each column keeps reading order, nothing touches the
/// fold, and the columns end within one view of each other.
func stackedViolations(roles: [DuoRole], frames: [CGRect], width: CGFloat, fold: DuoFold) -> [String] {
    let s = DuoSpacing.rows
    let tolerance: CGFloat = 0.5
    var problems: [String] = []
    let shown = frames.indices.filter { frames[$0].height > 0 }
    let columns = DuoSpreadPlan.columns(width: width, fold: fold)
    func inLeft(_ i: Int) -> Bool { abs(frames[i].minX - columns.left.x) < tolerance }

    for index in shown {
        let frame = frames[index]
        let minX = frame.minX + DuoSpacing.inset, maxX = frame.maxX + DuoSpacing.inset
        if minX < fold.band.upperBound - tolerance, maxX > fold.band.lowerBound + tolerance {
            problems.append("\(index) in the fold: \(frame)")
        }
        if frame.minX < -tolerance || frame.maxX > width + tolerance {
            problems.append("\(index) outside the spread: \(frame)")
        }
        let sameColumn = shown.filter { $0 != index && inLeft($0) == inLeft(index) }
        let above = sameColumn.filter { frames[$0].maxY <= frame.minY + tolerance }.map { frames[$0].maxY }.max()
        if let above {
            if abs(frame.minY - above - s) > tolerance { problems.append("\(index) gap \(frame.minY - above)") }
        } else if frame.minY > tolerance {
            problems.append("\(index) starts \(frame.minY) down an empty column")
        }
        // Reading order within the column: the top band (leading and trailing) first, then the
        // rest, each in list order (docs/design/duo-layout-rules.md, section 2).
        func band(_ i: Int) -> Int { roles[i] == .leading || roles[i] == .trailing ? 0 : 1 }
        for other in sameColumn where (band(other), other) < (band(index), index) && frames[other].minY > frame.minY + tolerance {
            problems.append("\(other) placed below later \(index)")
        }
    }
    // Masonry: with flowing cards in both columns, they end within one card of each other. (A
    // column of pinned views alone can be taller than everything that flows beside it.)
    let flowing = shown.filter { roles[$0] != .leading && roles[$0] != .trailing }
    if flowing.contains(where: inLeft), flowing.contains(where: { !inLeft($0) }),
        let tallest = flowing.map({ frames[$0].height }).max()
    {
        let leftBottom = shown.filter(inLeft).map { frames[$0].maxY }.max() ?? 0
        let rightBottom = shown.filter { !inLeft($0) }.map { frames[$0].maxY }.max() ?? 0
        if abs(leftBottom - rightBottom) > tallest + s + tolerance {
            problems.append("columns unbalanced: \(leftBottom) vs \(rightBottom)")
        }
    }
    return problems
}

struct DuoSpreadPlanTests {
    /// A Flights spread with `pairs` stretch cards of uneven heights and the usual tail.
    private func spreadItems(pairs: Int) -> [DuoSpreadPlan.Item] {
        func fixed(_ role: DuoRole, _ h: CGFloat) -> DuoSpreadPlan.Item { .init(role: role) { _, _ in h } }
        var items: [DuoSpreadPlan.Item] = [
            fixed(.leading, 310), fixed(.trailing, 180), fixed(.trailing, 70),  // header; grade, tiles
            fixed(.wide, 120),  // notifications
            fixed(.wide, 250),  // timeline
            fixed(.full, 24),  // "What to expect"
        ]
        // Stretch cards whose heights depend on the column width, like wrapping text.
        items += (0..<pairs).map { n in
            .init(role: .pair) { width, _ in CGFloat(70 + (n * 37) % 60) + (width < 400 ? 20 : 0) }
        }
        items += [fixed(.flow, 44), fixed(.flow, 92), fixed(.flow, 0), fixed(.flow, 210), fixed(.flow, 80)]
        return items
    }

    @Test(arguments: [0, 1, 2, 7, 12])
    func invariantsHoldOpenAndPartlyOpen(pairs: Int) {
        for fold in [Duo.open, Duo.partly] {
            let items = spreadItems(pairs: pairs)
            let result = DuoSpreadPlan.place(items, width: Duo.width, fold: fold)
            let roles = items.map { $0.role.resolved(for: fold) }
            let problems = violations(roles: roles, frames: result.frames, width: Duo.width, fold: fold)
            #expect(problems.isEmpty, "\(pairs) pairs, active \(fold.isActive): \(problems)")
            #expect(abs(result.height - (result.frames.map(\.maxY).max() ?? 0)) < 0.5)
        }
    }

    @Test func oddLastCardLeavesNoHole() {
        let items = spreadItems(pairs: 7)
        let result = DuoSpreadPlan.place(items, width: Duo.width, fold: Duo.open)
        let lastPair = items.indices.last { items[$0].role == .pair }!
        let firstFlow = items.indices.first { items[$0].role == .flow }!
        // The first flowing card takes the empty right-hand slot beside the last stretch card.
        #expect(result.frames[firstFlow].minY == result.frames[lastPair].minY)
        #expect(result.frames[firstFlow].minX > result.frames[lastPair].maxX)
    }

    @Test func pairsAreProposedTheirRowHeight() {
        let items: [DuoSpreadPlan.Item] = [
            .init(role: .pair) { _, _ in 60 }, .init(role: .pair) { _, _ in 110 },
        ]
        let result = DuoSpreadPlan.place(items, width: Duo.width, fold: Duo.open)
        #expect(result.frames[0].height == 110)
        #expect(result.frames[1].height == 110)
    }

    @Test func columnsFollowTheFold() {
        let partly = DuoSpreadPlan.columns(width: Duo.width, fold: Duo.partly)
        #expect(partly.left.x + partly.left.width + DuoSpacing.inset == Duo.band.lowerBound)
        #expect(partly.right.x + DuoSpacing.inset == Duo.band.upperBound)
        // Open: they meet at the screen's middle, the usual gap apart.
        let open = DuoSpreadPlan.columns(width: Duo.width, fold: Duo.open)
        #expect(abs(open.right.x - (open.left.x + open.left.width) - DuoSpacing.rows) < 0.001)
    }

    @Test func warningStacksUnderTheHeaderAndTheGradeKeepsTheTopRight() {
        let items: [DuoSpreadPlan.Item] = [
            .init(role: .leading) { _, _ in 300 },  // header
            .init(role: .leading) { _, _ in 60 },  // official warning
            .init(role: .trailing) { _, _ in 180 },  // grade
        ]
        let result = DuoSpreadPlan.place(items, width: Duo.width, fold: Duo.partly)
        #expect(result.frames[1].minY == result.frames[0].maxY + DuoSpacing.rows)
        #expect(result.frames[1].minX == result.frames[0].minX)
        #expect(result.frames[2].minY == 0)
        #expect(result.frames[2].minX > result.frames[0].maxX)
    }

    /// Text that wraps: so many characters at about 7.5 pt each, 20 pt a line.
    private func text(_ role: DuoRole, characters: Int) -> DuoSpreadPlan.Item {
        .init(role: role) { width, _ in characters == 0 ? 0 : (CGFloat(characters) * 7.5 / max(width, 1)).rounded(.up) * 20 + 28 }
    }

    @Test(arguments: [0, 40, 600])
    func nothingIsPlacedShorterThanItNeeds(characters: Int) {
        for fold in [Duo.open, Duo.partly] {
            let items: [DuoSpreadPlan.Item] = [
                text(.leading, characters: characters), text(.trailing, characters: 80),
                text(.wide, characters: characters), text(.full, characters: 20),
                text(.pair, characters: characters), text(.pair, characters: 30), text(.pair, characters: characters),
                text(.flow, characters: characters), text(.flow, characters: 200), text(.wide, characters: characters),
            ]
            let result = DuoSpreadPlan.place(items, width: Duo.width, fold: fold)
            for (item, frame) in zip(items, result.frames) {
                let needed = item.height(frame.width, nil)
                #expect(frame.height >= needed - 0.5, "\(characters) chars, active \(fold.isActive): \(frame.height) < \(needed)")
            }
            let roles = items.map { $0.role.resolved(for: fold) }
            let problems = violations(roles: roles, frames: result.frames, width: Duo.width, fold: fold)
            #expect(problems.isEmpty, "\(characters) chars, active \(fold.isActive): \(problems)")
        }
    }

    @Test func wideRunsAcrossWhenOpenAndFlowsWhenPartlyOpen() {
        let items: [DuoSpreadPlan.Item] = [
            .init(role: .leading) { _, _ in 200 }, .init(role: .trailing) { _, _ in 120 }, .init(role: .wide) { _, _ in 300 },
        ]
        let open = DuoSpreadPlan.place(items, width: Duo.width, fold: Duo.open)
        #expect(open.frames[2].width == Duo.width)
        #expect(open.frames[2].minY == 200 + DuoSpacing.rows)
        // Partly open it goes to the shorter column (under the grade), clear of the fold.
        let partly = DuoSpreadPlan.place(items, width: Duo.width, fold: Duo.partly)
        #expect(partly.frames[2].minX == partly.frames[1].minX)
        #expect(partly.frames[2].minY == 120 + DuoSpacing.rows)
    }

    @Test func wideTimelinePartlyOpenFillsTheShorterColumnAndKeepsOffTheFold() {
        // In the air: header left, grade right, the tall in-flight card and the timeline both wide.
        let items: [DuoSpreadPlan.Item] = [
            .init(role: .leading) { _, _ in 260 },  // header
            .init(role: .trailing) { _, _ in 180 },  // grade
            .init(role: .wide) { _, _ in 420 },  // in-flight card
            .init(role: .wide) { width, _ in width < 500 ? 280 : 250 },  // timeline (190 pt chart in a column)
            .init(role: .flow) { _, _ in 44 },  // what follows in the same column
        ]
        let result = DuoSpreadPlan.place(items, width: Duo.width, fold: Duo.partly)
        let band = (Duo.band.lowerBound - DuoSpacing.inset)...(Duo.band.upperBound - DuoSpacing.inset)
        for index in [2, 3] {
            let frame = result.frames[index]
            #expect(frame.maxX <= band.lowerBound + 0.5 || frame.minX >= band.upperBound - 0.5, "wide \(index) in the fold: \(frame)")
        }
        // The in-flight card goes under the grade (shorter); the timeline then fills the left column
        // under the header, beside it: no empty column.
        #expect(result.frames[2].minX == result.frames[1].minX)
        #expect(result.frames[3].minX == result.frames[0].minX)
        #expect(result.frames[3].minY == result.frames[0].maxY + DuoSpacing.rows)
        // What follows sits one token under whatever is above it in its column.
        let next = result.frames[4]
        let above = result.frames[..<4].filter { $0.minX == next.minX }.map(\.maxY).max()!
        #expect(next.minY == above + DuoSpacing.rows)
        // Fully open, both run across.
        let open = DuoSpreadPlan.place(items, width: Duo.width, fold: Duo.open)
        #expect(open.frames[2].width == Duo.width && open.frames[3].width == Duo.width)
    }

    @Test func partlyOpenHeadingKeepsWithItsFirstCard() {
        let items: [DuoSpreadPlan.Item] = [
            .init(role: .leading) { _, _ in 100 }, .init(role: .trailing) { _, _ in 300 },
            .init(role: .wide) { _, _ in 120 },  // goes left (shorter), so left is now 228
            .init(role: .full) { _, _ in 24 },  // "What to expect": left is still shorter
            .init(role: .pair) { _, _ in 400 },  // its first card: same column, right under it
            .init(role: .pair) { _, _ in 90 },
        ]
        let result = DuoSpreadPlan.place(items, width: Duo.width, fold: Duo.partly)
        #expect(result.frames[4].minX == result.frames[3].minX)
        #expect(result.frames[4].minY == result.frames[3].maxY + DuoSpacing.rows)
        // Partly open, cards in different columns aren't made the same height.
        #expect(result.frames[5].height == 90)
    }

    @Test func fullyOpenIsUnchanged() {
        let items = spreadItems(pairs: 7)
        let result = DuoSpreadPlan.place(items, width: Duo.width, fold: Duo.open)
        let pairs = items.indices.filter { items[$0].role == .pair }
        // Pairs level and equal, and the title spans the spread.
        #expect(result.frames[pairs[0]].minY == result.frames[pairs[1]].minY)
        #expect(result.frames[pairs[0]].height == result.frames[pairs[1]].height)
        let title = items.indices.first { items[$0].role == .full }!
        #expect(result.frames[title].width == Duo.width)
    }

    @Test func emptySpreadHasNoHeight() {
        let result = DuoSpreadPlan.place([], width: Duo.width, fold: Duo.partly)
        #expect(result.frames.isEmpty)
        #expect(result.height == 0)
    }

    @Test func centredColumnsShareAMiddle() {
        let items: [DuoSpreadPlan.Item] = [.init(role: .leading) { _, _ in 300 }, .init(role: .trailing) { _, _ in 100 }]
        let result = DuoSpreadPlan.place(items, width: Duo.width, fold: Duo.open, alignment: .center)
        #expect(result.frames[0].midY == result.frames[1].midY)
    }
}

extension DuoUITests {
    /// The real forecast spread, rendered with each demo's forecast, checked on the frames
    /// `DuoSpread` actually placed.
    @MainActor
    struct DuoSpreadRenderTests {
        private static let demos: [(name: String, forecast: Forecast, origin: String, destination: String)] = [
            ("demo", DemoFlightService.sampleForecast, "KJFK", "KLAX"),
            ("demoGateWind", DemoFlightService.gustySample, "KJFK", "KLAX"),
            ("demoStrong", DemoFlightService.strongSample, "KJFK", "KLAX"),
            ("demoGlobal", DemoFlightService.load("sample_global_outlook"), "SBGR", "LPPT"),
            ("demoEurope", DemoFlightService.load("sample_global_lhr_jfk"), "EGLL", "KJFK"),
        ]

        @Test(arguments: [true, false])
        func everyDemoHoldsTheInvariantsOpenAndPartlyOpen(unlocked: Bool) {
            for demo in Self.demos {
                for fold in [Duo.open, Duo.partly] {
                    let flight = Flight(
                        id: UUID(), origin: demo.origin, destination: demo.destination,
                        departureAt: .now.addingTimeInterval(2 * 3600))
                    let view = ForecastView(
                        forecast: demo.forecast, flight: flight,
                        before: [
                            AdaptiveItem(FlightRouteHeader(flight: flight)),
                            // A status card with a long headline, as the in-flight card has (no role: wide).
                            AdaptiveItem(
                                Text(String(repeating: "Next: light chop in about 1 h 45 min, for about 40 min. ", count: 4))
                                    .skyCard()),
                        ],
                        after: [
                            AdaptiveItem(Text(String(repeating: "Coming up flight ", count: 30)).frame(maxWidth: .infinity), id: "a"),
                            AdaptiveItem(Color.clear.frame(height: 72), id: "b"),
                        ]
                    )
                    .environment(\.duoFold, fold)
                    .environment(\.debugFullAccess, unlocked)
                    .environment(Paywalls.shared)
                    .environment(InFlight.shared)
                    .environment(FlightStore.shared)
                    .environment(Router.shared)
                    .environment(PushNotifications.shared)
                    .environment(Connectivity.shared)
                    .environment(EmailImport.shared)
                    .frame(width: Duo.width)

                    DuoSpreadRecorder.plans = []
                    let renderer = ImageRenderer(content: view)
                    renderer.proposedSize = ProposedViewSize(width: Duo.width, height: nil)
                    #expect(renderer.uiImage != nil)

                    let plan = DuoSpreadRecorder.plans.last { abs($0.width - Duo.width) < 0.5 && $0.roles.contains(.flow) }
                    #expect(plan != nil, "\(demo.name): no spread placed")
                    guard let plan else { continue }
                    let problems = violations(roles: plan.roles, frames: plan.frames, width: plan.width, fold: fold)
                    #expect(problems.isEmpty, "\(demo.name), active \(fold.isActive), unlocked \(unlocked): \(problems)")
                    // Every view placed at least as tall as it needs at its placed width: nothing truncates.
                    for (index, frame) in plan.frames.enumerated() {
                        #expect(
                            frame.height >= plan.needed[index] - 0.5,
                            "\(demo.name), active \(fold.isActive): view \(index) placed \(frame.height), needs \(plan.needed[index])")
                    }
                    // An official warning sits under the header on the left; the grade tops the right column.
                    if !demo.forecast.officialWarnings.isEmpty {
                        let leading = plan.roles.indices.filter { plan.roles[$0] == .leading }
                        #expect(leading.count >= 2 && plan.frames[leading[1]].minY > plan.frames[leading[0]].minY, "\(demo.name): warning")
                        let topRight = plan.roles.indices.first { plan.roles[$0] == .trailing }
                        #expect(topRight.map { plan.frames[$0].minY == 0 } == true, "\(demo.name): grade")
                    }
                    // Unlocked, the stretch cards are really there (every demo has some); locked, none.
                    // Fully open, the stretch cards pair up (unlocked); partly open everything stacks.
                    if !fold.isActive {
                        let pairs = plan.roles.filter { $0 == .pair }.count
                        #expect(unlocked ? pairs >= 2 : pairs == 0, "\(demo.name): \(pairs) pairs")
                    }
                }
            }
        }
    }
}

/// The timeline's hour labels never run together, whatever the flight's length and the card's width.
struct TimelineAxisTests {
    @Test(arguments: [(573, 260), (573, 330), (573, 700), (95, 260), (386, 330), (900, 260), (60, 100)])
    func labelsNeverOverlap(totalMinutes: Int, width: Int) {
        let plotWidth = CGFloat(width)
        let axis = TimelineAxis(totalMinutes: totalMinutes, plotWidth: plotWidth)
        let labeled = axis.ticks.filter { axis.labeled.contains($0) }
        #expect(labeled.first == 0, "Takeoff is always labelled")
        for (a, b) in zip(labeled, labeled.dropFirst()) {
            let end = TimelineAxis.x(of: a, totalMinutes: totalMinutes, plotWidth: plotWidth)
                + (a == 0 ? TimelineAxis.takeoffWidth : TimelineAxis.hourWidth)
            let start = TimelineAxis.x(of: b, totalMinutes: totalMinutes, plotWidth: plotWidth)
            #expect(start >= end + TimelineAxis.gap - 0.5, "\(totalMinutes) min at \(width): \(a) runs into \(b)")
        }
        if let last = labeled.last, last > 0 {
            #expect(TimelineAxis.x(of: last, totalMinutes: totalMinutes, plotWidth: plotWidth) + TimelineAxis.hourWidth <= plotWidth + 0.5)
        }
        // Wide enough for hourly marks, it keeps them: the iPhone's usual flights look as before.
        if CGFloat(60 * width) / CGFloat(totalMinutes) >= TimelineAxis.hourWidth + TimelineAxis.gap {
            #expect(axis.ticks.count == Int((Double(totalMinutes) / 60).rounded(.up)))
        }
    }

    @Test func longFlightInANarrowCardSpacesOut() {
        // GRU→LIS, 9 h 33 min, in an iPhone-width plot: no longer every hour.
        let axis = TimelineAxis(totalMinutes: 573, plotWidth: 260)
        #expect(axis.ticks.count < 10)
        #expect(axis.ticks.count >= 3)
    }

    /// At accessibility text sizes the labels are wider, so they space further apart and still
    /// never touch (a 4 h 40 min flight in a narrow partly-open column at AX3, about 2.2×).
    @Test(arguments: [1.0, 1.5, 2.2, 3.0])
    func largeTextLabelsNeverTouch(scale: Double) {
        let scale = CGFloat(scale), totalMinutes = 280, plotWidth: CGFloat = 230
        let axis = TimelineAxis(totalMinutes: totalMinutes, plotWidth: plotWidth, labelScale: scale)
        let xs = axis.labeled.sorted().map { TimelineAxis.x(of: $0, totalMinutes: totalMinutes, plotWidth: plotWidth) }
        #expect(xs.first == 0)
        for (index, x) in xs.enumerated().dropFirst() {
            let previousWidth = (index == 1 ? TimelineAxis.takeoffWidth : TimelineAxis.hourWidth) * scale
            #expect(x - xs[index - 1] >= previousWidth + TimelineAxis.gap, "scale \(scale): \(xs)")
            #expect(x + TimelineAxis.hourWidth * scale <= plotWidth, "scale \(scale): \(xs)")
        }
    }
}
