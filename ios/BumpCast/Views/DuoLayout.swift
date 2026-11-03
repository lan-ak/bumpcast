import SwiftUI
import UIKit

/// iPhone Duo, open: the only iPhone screen that's regular in both size classes. Closed it's compact
/// width like any iPhone, and every other iPhone is compact in at least one, so they never see this.
/// Screens lay out either side of the fold, which runs down the middle of the inner screen.
struct DuoFold: Equatable {
    /// The fold's band in the window's space, its margins included (40 pt).
    var band: ClosedRange<CGFloat>
    /// Partly open: the band is live, so nothing sits on it, cards included.
    var isActive: Bool
}

extension EnvironmentValues {
    /// Set on the open iPhone Duo only (see `DuoFold`); nil on every other screen.
    @Entry var duoFold: DuoFold?
    #if DEBUG
    /// Debug builds only: tests render the unlocked forecast without going through a paywall.
    @Entry var debugFullAccess = false
    #endif
}

extension View {
    /// The app root only: measures the fold and hands it to every screen, sheets and covers included.
    func duoFoldProbe() -> some View {
        modifier(DuoFoldProbe())
    }
}

enum DuoSpacing {
    /// Rows on a Duo spread sit this far apart, as drawn.
    static let rows: CGFloat = 8
    /// Every spread sits in the standard 16 pt padding from the screen's leading edge, so columns
    /// come straight from the fold. Never measured from the view itself: a column sized from its
    /// own position can feed back into layout and loop.
    static let inset: CGFloat = 16
}

/// How a spread moves when the fold changes: one curve for every view, a slight stagger in
/// reading order. With Reduce Motion, a quick fade instead (see `DuoFoldProbe`).
enum DuoMotion {
    /// Eases out and stops exactly at 0.5 s. A spring would creep its last fraction of a point for
    /// a while after, which a recording shows as stray late frames.
    static let move = Animation.timingCurve(0.25, 0.1, 0.25, 1, duration: 0.5)
    /// Up to 30 ms later per entry, capped at the tenth.
    static func move(at index: Int) -> Animation {
        move.delay(Double(min(index, 10)) * 0.03)
    }
}

private struct DuoFoldProbe: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var fold: DuoFold?
    /// The screen's width, safe areas included: the fold's middle until the probe reports.
    @State private var screenWidth: CGFloat = 0
    /// Reduce Motion: the screen fades out, changes, and fades back in, with nothing moving.
    @State private var fading = false

    func body(content: Content) -> some View {
        let open = horizontalSizeClass == .regular && verticalSizeClass == .regular
        let middle = screenWidth / 2
        let shown = open ? fold ?? DuoFold(band: middle - 20...middle + 20, isActive: false) : nil
        content
            .environment(\.duoFold, shown)
            .environment(\.isWideLayout, open)
            .environment(\.navigationBarFollowsSky, open)
            .opacity(fading ? 0 : 1)
            .background { FoldProbe { apply($0) }.allowsHitTesting(false) }
            .onGeometryChange(for: CGFloat.self) { $0.size.width + $0.safeAreaInsets.leading + $0.safeAreaInsets.trailing } action: {
                // Only a real change of screen (closing, opening), never a sub-point wobble.
                if abs(screenWidth - $0) > 0.5 { screenWidth = $0 }
            }
            #if DEBUG
            // Debug builds only: `-duoFoldDemo` flips the fold between partly and fully open every
            // 3 seconds on the open Duo, to watch and record the transition without Device Hub.
            .task(id: open) {
                guard open, ProcessInfo.processInfo.arguments.contains("-duoFoldDemo") else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(3))
                    guard let current = shown else { continue }
                    let now = fold ?? current
                    apply(DuoFold(band: now.band, isActive: !now.isActive))
                }
            }
            #endif
    }

    /// The first fold just arrives; every change after it moves (or, with Reduce Motion, fades).
    private func apply(_ new: DuoFold) {
        guard fold != new else { return }
        guard fold != nil else {
            fold = new
            return
        }
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.12)) { fading = true } completion: {
                fold = new
                withAnimation(.easeIn(duration: 0.18)) { fading = false }
            }
        } else {
            withAnimation(DuoMotion.move) { fold = new }
        }
    }
}

/// Reads the window's division region (iOS 27.1). Before that, or with none reported, the fold is
/// taken as the middle 40 pt of the window and never active.
private struct FoldProbe: UIViewRepresentable {
    let report: (DuoFold) -> Void

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.report = report
        return view
    }

    func updateUIView(_ view: ProbeView, context: Context) { view.report = report }

    final class ProbeView: UIView {
        var report: ((DuoFold) -> Void)?
        private var last: DuoFold?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            registerForTraitChanges([UITraitHorizontalSizeClass.self, UITraitVerticalSizeClass.self]) { (view: ProbeView, _) in view.measure() }
            measure()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            measure()
        }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            measure()
        }

        func measure() {
            guard let window else { return }
            var fold = DuoFold(band: window.bounds.midX - 20...window.bounds.midX + 20, isActive: false)
            if #available(iOS 27.1, *),
                let region = window.reservedRegions(kind: .division, options: .includeInactive).first
            {
                fold = DuoFold(band: region.frame.minX...region.frame.maxX, isActive: region.isActive)
            }
            guard fold != last else { return }
            last = fold
            // Out of the layout pass: the fold changes SwiftUI state.
            DispatchQueue.main.async { [report] in report?(fold) }
        }
    }
}

// MARK: - The spread layout

/// Where a view goes on a Duo spread (see `DuoSpread`).
enum DuoRole {
    /// Across both halves, even partly open: only for a line that leaves the middle empty (a
    /// section title). Cards are `.wide`.
    case full
    /// In the column left or right of the fold.
    case leading, trailing
    /// Two to a row, both as tall as the taller; an odd last one takes the left slot.
    case pair
    /// After the pairs: each goes to whichever column is shorter, so there are never holes.
    case flow
    /// A card that runs all the way across when it can: `full` with the fold closed, `flow` when
    /// it's live, so no text crosses the fold. The default for status cards and any big card.
    case wide

    /// The role the layout places by, for this fold. Partly open, everything but the pinned
    /// columns stacks (see `DuoSpreadPlan.stack`); fully open, wide cards run across.
    func resolved(for fold: DuoFold) -> DuoRole {
        if fold.isActive { return self == .leading || self == .trailing ? self : .flow }
        return self == .wide ? .full : self
    }
}

extension DuoRole {
    /// "What to expect": full width above its cards when open, with its first card partly open.
    static var heading: DuoRole { .full }
}

/// A component that says where it goes on a spread, once, where it's defined. Anything else is
/// `.wide`: full width when open, stacked when partly open, so a new card needs no Duo code.
@MainActor
protocol DuoPlaced {
    var duoRole: DuoRole { get }
}

/// One entry in a screen's list: a view, the place its component declares, and how far below the
/// previous entry it sits on the phone.
struct AdaptiveItem: Identifiable {
    let view: AnyView
    let role: DuoRole
    /// Space above it in the phone's stack; nil for the list's own spacing.
    let phoneSpacing: CGFloat?
    /// False for what only the open spread shows (Coming up after a flight's forecast).
    let onPhone: Bool
    /// Stable across renders (by default the view's type), so a card keeps its state when an entry
    /// before it comes and goes.
    let id: String

    @MainActor
    init<V: View>(_ view: V, id: String? = nil, phoneSpacing: CGFloat? = nil, onPhone: Bool = true) {
        self.view = AnyView(view)
        self.role = (view as? any DuoPlaced)?.duoRole ?? .wide
        self.phoneSpacing = phoneSpacing
        self.onPhone = onPhone
        self.id = id ?? String(describing: V.self)
    }

    private init(view: AnyView, role: DuoRole, phoneSpacing: CGFloat?, onPhone: Bool, id: String) {
        self.view = view
        self.role = role
        self.phoneSpacing = phoneSpacing
        self.onPhone = onPhone
        self.id = id
    }

    /// The same entry, a different distance below the previous one on the phone.
    func spaced(_ spacing: CGFloat?) -> AdaptiveItem {
        AdaptiveItem(view: view, role: role, phoneSpacing: spacing, onPhone: onPhone, id: id)
    }

    /// The same entry, faded (a diverted flight's forecast).
    func faded(_ opacity: Double) -> AdaptiveItem {
        AdaptiveItem(view: AnyView(view.opacity(opacity)), role: role, phoneSpacing: phoneSpacing, onPhone: onPhone, id: id)
    }
}

// MARK: - The container

/// The one container for a screen's list: the phone's stack on an iPhone or a closed Duo, the
/// spread on the open Duo. Screens never check which; see docs/design/duo-layout-rules.md.
struct AdaptiveSpread: View {
    let items: [AdaptiveItem]
    /// Between entries on the phone, unless an entry says otherwise.
    var spacing: CGFloat = 18

    @Environment(\.duoFold) private var fold
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let fold {
            // The same views, by the same ids, whichever way the fold is: a fold change moves each
            // one from its old frame to its new one, in reading order.
            DuoSpread(fold: fold) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    item.view
                        // VoiceOver reads the list in the iPhone's order, each entry whole, rather
                        // than zigzagging across the columns by position.
                        .accessibilityElement(children: .contain)
                        .accessibilitySortPriority(Double(items.count - index))
                        .layoutValue(key: DuoRoleKey.self, value: item.role)
                        .layoutValue(key: DuoIDKey.self, value: item.id)
                        .animation(reduceMotion ? nil : DuoMotion.move(at: index), value: fold.isActive)
                }
            }
            .accessibilityElement(children: .contain)
        } else {
            // The iPhone: a plain stack, laid out exactly as the screens were before the Duo.
            let shown = items.filter(\.onPhone)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                    item.view.padding(.top, index == 0 ? 0 : item.phoneSpacing ?? spacing)
                }
            }
        }
    }
}

private struct DuoIDKey: LayoutValueKey {
    static let defaultValue = ""
}

private struct PhoneSpacingKey: LayoutValueKey {
    static let defaultValue: CGFloat? = nil
}

/// The phone's stack: a leading-aligned VStack whose entries can each set the space above them.
private struct PhoneStack: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        var height: CGFloat = 0
        var width: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
            if index > 0 { height += subview[PhoneSpacingKey.self] ?? spacing }
            height += size.height
            width = max(width, size.width)
        }
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for (index, subview) in subviews.enumerated() {
            if index > 0 { y += subview[PhoneSpacingKey.self] ?? spacing }
            let size = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            subview.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: size.height))
            y += size.height
        }
    }
}

/// For the screens whose open layout is a different arrangement, not the same list: Learn (list
/// and explainer side by side instead of a push), Calm and breathing (centred panes), and the
/// Flights list (the next flight's forecast in place). The container picks; the screen never does.
struct OpenLayout<Phone: View, Open: View>: View {
    @ViewBuilder var phone: Phone
    @ViewBuilder var open: Open

    @Environment(\.duoFold) private var fold

    var body: some View {
        if fold != nil { open } else { phone }
    }
}

/// Two panes either side of the fold, for `OpenLayout`'s open arrangement.
struct Panes<Leading: View, Trailing: View>: View {
    var alignment: DuoColumnAlignment = .top
    /// Each pane takes the full height (Learn's two scrolling columns).
    var fillsHeight = false
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        FoldSpread(alignment: alignment, fillsHeight: fillsHeight) {
            leading.duoRole(.leading)
            trailing.duoRole(.trailing)
        }
        // Full-height panes aren't in a padded scroll view: the spread's inset is added here.
        .padding(.leading, fillsHeight ? DuoSpacing.inset : 0)
    }
}

extension EnvironmentValues {
    /// Wide enough for side-by-side chrome: the open Duo (set by the app root). The map also
    /// counts a landscape phone.
    @Entry var isWideLayout = false
}

extension View {
    /// A floating card (the map's status card): centred, or partly open bottom left beside the
    /// side panel, clear of the fold, the bottom inset and Apple's Maps attribution.
    func floatsClearOfFold() -> some View {
        modifier(FloatsClearOfFold())
    }
}

/// Where a floating card goes, apart from SwiftUI so it can be tested.
enum FloatingCardPlacement {
    static let panelWidth: CGFloat = 300
    static let margin: CGFloat = 12
    /// Apple's Maps · Legal attribution, bottom left above the inset, with room to spare.
    static let attributionHeight: CGFloat = 36

    /// The card's frame in its container (the safe area) for its size.
    static func frame(card: CGSize, in container: CGSize, fold: DuoFold?) -> CGRect {
        if let fold, fold.isActive {
            let width = min(card.width, panelWidth)
            return CGRect(x: margin, y: container.height - margin - attributionHeight - card.height, width: width, height: card.height)
        }
        let width = min(card.width, container.width - 32)
        return CGRect(x: (container.width - width) / 2, y: (container.height - card.height) / 2, width: width, height: card.height)
    }
}

private struct FloatsClearOfFold: ViewModifier {
    @Environment(\.duoFold) private var fold

    func body(content: Content) -> some View {
        FloatingCardLayout(fold: fold) { content }
    }
}

private struct FloatingCardLayout: Layout {
    let fold: DuoFold?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let card = subviews.first else { return }
        let limit = fold?.isActive == true ? FloatingCardPlacement.panelWidth : bounds.width - 32
        let size = card.sizeThatFits(ProposedViewSize(width: limit, height: nil))
        let frame = FloatingCardPlacement.frame(card: size, in: bounds.size, fold: fold)
        card.place(
            at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading,
            proposal: ProposedViewSize(width: frame.width, height: frame.height))
    }
}

// MARK: - Sheets

extension View {
    /// A sheet. Opened with the fold active it covers the whole screen with its content in the left
    /// half, clear of the fold; fully open and on the iPhone it's the system's sheet. Every sheet in
    /// the app goes through these, so the rule is set once.
    func adaptiveSheet<Content: View>(
        isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil, @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        modifier(AdaptiveSheet(isPresented: isPresented, onDismiss: onDismiss, sheet: content))
    }

    func adaptiveSheet<Item: Identifiable, Content: View>(
        item: Binding<Item?>, onDismiss: (() -> Void)? = nil, @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        modifier(AdaptiveItemSheet(item: item, onDismiss: onDismiss, sheet: content))
    }
}

/// How a sheet shows: chosen as it opens and kept until it closes, since changing the kind of
/// presentation would rebuild what's in it. A fold change while it's open moves its content instead.
private enum SheetStyle {
    case sheet, cover

    static func current(_ fold: DuoFold?) -> SheetStyle { fold?.isActive == true ? .cover : .sheet }
}

private struct AdaptiveSheet<Sheet: View>: ViewModifier {
    @Binding var isPresented: Bool
    let onDismiss: (() -> Void)?
    let sheet: () -> Sheet

    @Environment(\.duoFold) private var fold
    @State private var shown: SheetStyle?

    func body(content: Content) -> some View {
        let style = shown ?? SheetStyle.current(fold)
        content
            .sheet(isPresented: binding(style == .sheet), onDismiss: onDismiss) { sheet().modifier(DuoSheet()) }
            .fullScreenCover(isPresented: binding(style == .cover), onDismiss: onDismiss) { sheet().modifier(DuoSheet()) }
            .onChange(of: isPresented, initial: true) { _, presented in shown = presented ? style : nil }
    }

    private func binding(_ selected: Bool) -> Binding<Bool> {
        Binding(get: { selected && isPresented }, set: { if !$0, selected { isPresented = false } })
    }
}

private struct AdaptiveItemSheet<Item: Identifiable, Sheet: View>: ViewModifier {
    @Binding var item: Item?
    let onDismiss: (() -> Void)?
    let sheet: (Item) -> Sheet

    @Environment(\.duoFold) private var fold
    @State private var shown: SheetStyle?

    func body(content: Content) -> some View {
        let style = shown ?? SheetStyle.current(fold)
        content
            .sheet(item: binding(style == .sheet), onDismiss: onDismiss) { sheet($0).modifier(DuoSheet()) }
            .fullScreenCover(item: binding(style == .cover), onDismiss: onDismiss) { sheet($0).modifier(DuoSheet()) }
            .onChange(of: item != nil, initial: true) { _, presented in shown = presented ? style : nil }
    }

    private func binding(_ selected: Bool) -> Binding<Item?> {
        Binding(get: { selected ? item : nil }, set: { if $0 == nil, selected { item = nil } })
    }
}

/// What's in a sheet with the fold active: kept left of the fold, the sky showing to its right.
/// Off the open Duo (the iPhone, the closed Duo) it's the content as it is.
private struct DuoSheet: ViewModifier {
    @Environment(\.duoFold) private var fold

    func body(content: Content) -> some View {
        #if DEBUG
            let _ = DuoSpreadRecorder.noteSheetBody()
        #endif
        if let fold {
            content
                .modifier(LeftOfFold(onlyWhenActive: true))
                .background { if fold.isActive { Color.clear.skyBackground(Sky(date: .now)) } }
        } else {
            content
        }
    }
}

extension View {
    /// A one-column screen (the onboarding fallback): on the open Duo its content keeps to the left
    /// half, clear of the fold, with what's behind it still across the screen. Off the open Duo it's
    /// the content as it is.
    func leftOfFold() -> some View {
        modifier(LeftOfFold(onlyWhenActive: false))
    }
}

/// Content kept left of the fold. Where it sits is read during layout, never measured into state,
/// so nothing can feed back; off the open Duo it's the content untouched.
private struct LeftOfFold: ViewModifier {
    /// Only with the fold active (sheets); otherwise whenever the Duo is open (one-column screens).
    let onlyWhenActive: Bool

    @Environment(\.duoFold) private var fold

    func body(content: Content) -> some View {
        if let fold {
            GeometryReader { geometry in
                // From half a gap before the fold to the right edge stays clear.
                let clear = !onlyWhenActive || fold.isActive
                    ? max(0, geometry.frame(in: .global).maxX - fold.band.lowerBound + DuoSpacing.rows / 2) : 0
                content
                    .padding(.trailing, clear)
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
        } else {
            content
        }
    }
}

enum DuoColumnAlignment {
    case top
    /// A run of leading and trailing views centred on each other (Calm, breathing).
    case center
}

private struct DuoRoleKey: LayoutValueKey {
    static let defaultValue = DuoRole.full
}

extension View {
    /// This view's place on a Duo spread.
    func duoRole(_ role: DuoRole) -> some View {
        layoutValue(key: DuoRoleKey.self, value: role)
    }
}

/// The spread's arithmetic, apart from SwiftUI so it can be tested with fixed sizes. Frames are in
/// the spread's own space, which starts `DuoSpacing.inset` from the screen's leading edge.
enum DuoSpreadPlan {
    struct Item {
        let role: DuoRole
        /// The view's height for a width and, when the spread fills its height, a proposed height.
        let height: (_ width: CGFloat, _ proposed: CGFloat?) -> CGFloat
    }

    struct Result {
        var frames: [CGRect]
        var height: CGFloat
    }

    struct Column {
        let x: CGFloat
        let width: CGFloat
    }

    /// Partly open, the columns end and start at the fold's band. Open, they meet at the screen's
    /// middle with the usual gap between them.
    static func columns(width: CGFloat, fold: DuoFold) -> (left: Column, right: Column) {
        let s = DuoSpacing.rows
        let inset = DuoSpacing.inset
        var leftEnd: CGFloat
        var rightStart: CGFloat
        if fold.isActive {
            leftEnd = fold.band.lowerBound - inset
            rightStart = fold.band.upperBound - inset
        } else {
            let middle = (fold.band.lowerBound + fold.band.upperBound) / 2 - inset
            leftEnd = middle - s / 2
            rightStart = middle + s / 2
        }
        leftEnd = min(max(leftEnd, 0), width)
        rightStart = min(max(rightStart, leftEnd), width)
        return (Column(x: 0, width: leftEnd), Column(x: rightStart, width: width - rightStart))
    }

    /// The width a spread takes when nothing proposes one: the screen's, less the insets.
    static func naturalWidth(fold: DuoFold) -> CGFloat {
        max((fold.band.lowerBound + fold.band.upperBound) - 2 * DuoSpacing.inset, 0)
    }

    /// Places a screen's list. Leading and trailing views form the top band wherever they sit in
    /// the list (the route header left, the grade right); everything else follows in list order.
    static func place(
        _ items: [Item], width: CGFloat, height: CGFloat? = nil, fold: DuoFold,
        alignment: DuoColumnAlignment = .top, fillsHeight: Bool = false
    ) -> Result {
        let pinned = items.indices.filter { items[$0].role == .leading || items[$0].role == .trailing }
        let order = pinned + items.indices.filter { !pinned.contains($0) }
        let placed = placeInOrder(
            order.map { items[$0] }, width: width, height: height, fold: fold, alignment: alignment, fillsHeight: fillsHeight)
        var frames = [CGRect](repeating: .zero, count: items.count)
        for (position, index) in order.enumerated() { frames[index] = placed.frames[position] }
        return Result(frames: frames, height: placed.height)
    }

    private static func placeInOrder(
        _ items: [Item], width: CGFloat, height: CGFloat?, fold: DuoFold,
        alignment: DuoColumnAlignment, fillsHeight: Bool
    ) -> Result {
        if fold.isActive {
            return stack(items, width: width, height: height, fold: fold, alignment: alignment, fillsHeight: fillsHeight)
        }
        let items = items.map { Item(role: $0.role.resolved(for: fold), height: $0.height) }
        let s = DuoSpacing.rows
        let (left, right) = columns(width: width, fold: fold)
        var frames = [CGRect](repeating: .zero, count: items.count)
        // Where the next view in each column starts.
        var nextLeft: CGFloat = 0
        var nextRight: CGFloat = 0
        // The current run of leading and trailing views, for centring.
        var runLeft: [Int] = []
        var runRight: [Int] = []
        var runTop: CGFloat = 0

        func finishRun() {
            if alignment == .center, !runLeft.isEmpty, !runRight.isEmpty {
                let leftHeight = (runLeft.map { frames[$0].maxY }.max() ?? runTop) - runTop
                let rightHeight = (runRight.map { frames[$0].maxY }.max() ?? runTop) - runTop
                let shorter = leftHeight < rightHeight ? runLeft : runRight
                let shift = abs(leftHeight - rightHeight) / 2
                for index in shorter { frames[index].origin.y += shift }
            }
            runLeft = []
            runRight = []
        }

        // Both columns continue from the lower of the two.
        func level() -> CGFloat {
            finishRun()
            let y = max(nextLeft, nextRight)
            nextLeft = y
            nextRight = y
            runTop = y
            return y
        }

        func after(_ y: CGFloat, _ h: CGFloat) -> CGFloat { h > 0 ? y + h + s : y }

        var i = 0
        while i < items.count {
            let item = items[i]
            switch item.role {
            case .full:
                let y = level()
                let h = item.height(width, nil)
                frames[i] = CGRect(x: 0, y: y, width: width, height: h)
                nextLeft = after(y, h)
                nextRight = nextLeft
                runTop = nextLeft
                i += 1
            case .leading, .trailing:
                let isLeft = item.role == .leading
                let column = isLeft ? left : right
                let y = isLeft ? nextLeft : nextRight
                let proposed = fillsHeight ? height.map { max($0 - y, 0) } : nil
                let h = proposed ?? item.height(column.width, nil)
                frames[i] = CGRect(x: column.x, y: y, width: column.width, height: h)
                if isLeft {
                    nextLeft = after(y, h)
                    runLeft.append(i)
                } else {
                    nextRight = after(y, h)
                    runRight.append(i)
                }
                i += 1
            case .pair:
                var y = level()
                var odd = false
                while i < items.count, items[i].role == .pair {
                    if i + 1 < items.count, items[i + 1].role == .pair {
                        let rowHeight = max(items[i].height(left.width, nil), items[i + 1].height(right.width, nil))
                        frames[i] = CGRect(x: left.x, y: y, width: left.width, height: rowHeight)
                        frames[i + 1] = CGRect(x: right.x, y: y, width: right.width, height: rowHeight)
                        y = after(y, rowHeight)
                        i += 2
                    } else {
                        let h = items[i].height(left.width, nil)
                        frames[i] = CGRect(x: left.x, y: y, width: left.width, height: h)
                        nextLeft = after(y, h)
                        nextRight = y  // the empty slot: the next flow view takes it
                        odd = true
                        i += 1
                    }
                }
                if !odd {
                    nextLeft = y
                    nextRight = y
                }
            case .flow, .wide:  // `.wide` is resolved to `.full` or `.flow` above
                finishRun()
                let isLeft = nextLeft <= nextRight
                let column = isLeft ? left : right
                let y = isLeft ? nextLeft : nextRight
                let h = item.height(column.width, nil)
                frames[i] = CGRect(x: column.x, y: y, width: column.width, height: h)
                if isLeft { nextLeft = after(y, h) } else { nextRight = after(y, h) }
                i += 1
            }
        }
        finishRun()
        let total = frames.map(\.maxY).max() ?? 0
        return Result(frames: frames, height: fillsHeight ? max(total, height ?? 0) : total)
    }
}

extension DuoSpreadPlan {
    /// Partly open: two columns that each stack freely in reading order, so neither ever waits for
    /// the other and there are no gaps. Leading and trailing views keep their column; everything
    /// else goes to whichever column is shorter. A `.full` view (a section title) becomes a heading
    /// that keeps with the view after it, in the same column. Nothing is made the same height.
    static func stack(
        _ items: [Item], width: CGFloat, height: CGFloat?, fold: DuoFold,
        alignment: DuoColumnAlignment, fillsHeight: Bool
    ) -> Result {
        let s = DuoSpacing.rows
        let (left, right) = columns(width: width, fold: fold)
        var frames = [CGRect](repeating: .zero, count: items.count)
        var nextLeft: CGFloat = 0
        var nextRight: CGFloat = 0
        var keepWith: Bool?  // the column a heading's next view must join (true: left)
        var pinnedLeft: [Int] = []
        var pinnedRight: [Int] = []

        for (i, item) in items.enumerated() {
            let isLeft: Bool
            switch item.role {
            case .leading: isLeft = true
            case .trailing: isLeft = false
            default: isLeft = keepWith ?? (nextLeft <= nextRight)
            }
            keepWith = item.role == .full ? isLeft : nil
            let column = isLeft ? left : right
            let y = isLeft ? nextLeft : nextRight
            let pinned = item.role == .leading || item.role == .trailing
            let proposed = fillsHeight && pinned ? height.map { max($0 - y, 0) } : nil
            let h = proposed ?? item.height(column.width, nil)
            frames[i] = CGRect(x: column.x, y: y, width: column.width, height: h)
            let next = h > 0 ? y + h + s : y
            if isLeft { nextLeft = next } else { nextRight = next }
            if item.role == .leading { pinnedLeft.append(i) }
            if item.role == .trailing { pinnedRight.append(i) }
        }
        // Calm and breathing: one view each side, centred on each other.
        if alignment == .center, pinnedLeft.count + pinnedRight.count == items.count,
            !pinnedLeft.isEmpty, !pinnedRight.isEmpty
        {
            let leftHeight = pinnedLeft.map { frames[$0].maxY }.max() ?? 0
            let rightHeight = pinnedRight.map { frames[$0].maxY }.max() ?? 0
            let shorter = leftHeight < rightHeight ? pinnedLeft : pinnedRight
            for index in shorter { frames[index].origin.y += abs(leftHeight - rightHeight) / 2 }
        }
        let total = frames.map(\.maxY).max() ?? 0
        return Result(frames: frames, height: fillsHeight ? max(total, height ?? 0) : total)
    }
}

/// The one layout for a Duo spread: it measures each view once for its column and places it by
/// its `DuoRole`. No geometry is read back, so nothing can feed back into layout.
struct DuoSpread: Layout {
    var fold: DuoFold
    var alignment: DuoColumnAlignment = .top
    /// Leading and trailing views take the rest of the height (Learn's two scrolling columns).
    var fillsHeight = false

    /// Plans by the size they were made for. SwiftUI clears it whenever a subview changes (a
    /// countdown line growing), so it's only reused across passes for the same content: the frames
    /// of a fold change are planned once and SwiftUI interpolates them, with no re-measuring per frame.
    struct Cache {
        struct Key: Hashable {
            let width: CGFloat
            let height: CGFloat?
            let foldActive: Bool
        }
        var plans: [Key: DuoSpreadPlan.Result] = [:]
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache.plans.removeAll() }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = proposal.width ?? DuoSpreadPlan.naturalWidth(fold: fold)
        return CGSize(width: width, height: plan(width: width, height: proposal.height, subviews: subviews, cache: &cache).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let result = plan(width: bounds.width, height: fillsHeight ? bounds.height : proposal.height, subviews: subviews, cache: &cache)
        #if DEBUG
        DuoSpreadRecorder.placements += 1
        #endif
        for (subview, frame) in zip(subviews, result.frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading,
                proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }

    private func plan(width: CGFloat, height: CGFloat?, subviews: Subviews, cache: inout Cache) -> DuoSpreadPlan.Result {
        let key = Cache.Key(width: width.rounded(), height: height?.rounded(), foldActive: fold.isActive)
        if let planned = cache.plans[key] { return planned }
        let roles = subviews.map { $0[DuoRoleKey.self] }
        let items = zip(subviews, roles).map { subview, role in
            DuoSpreadPlan.Item(role: role) { w, h in subview.sizeThatFits(ProposedViewSize(width: w, height: h)).height }
        }
        let result = DuoSpreadPlan.place(
            items, width: width, height: height, fold: fold, alignment: alignment, fillsHeight: fillsHeight)
        cache.plans[key] = result
        #if DEBUG
        // What each view needs at the width it's placed at, for the tests' "never shorter" check.
        let needed = zip(subviews, result.frames).map { subview, frame in
            subview.sizeThatFits(ProposedViewSize(width: frame.width, height: nil)).height
        }
        DuoSpreadRecorder.record(
            roles: roles.map { $0.resolved(for: fold) }, result: result, needed: needed, width: width, fold: fold,
            centred: alignment == .center, fillsHeight: fillsHeight, ids: subviews.map { $0[DuoIDKey.self] })
        #endif
        return result
    }
}

/// A spread with the fold read from the environment. Off the Duo it's one column.
struct FoldSpread<Content: View>: View {
    var alignment: DuoColumnAlignment = .top
    var fillsHeight = false
    @ViewBuilder var content: Content

    @Environment(\.duoFold) private var fold

    var body: some View {
        if let fold {
            DuoSpread(fold: fold, alignment: alignment, fillsHeight: fillsHeight) { content }
        } else {
            VStack(alignment: .leading, spacing: 18) { content }
        }
    }
}

#if DEBUG
/// Debug builds only: the frames each spread placed, for the layout tests.
enum DuoSpreadRecorder {
    struct Plan {
        let roles: [DuoRole]
        let frames: [CGRect]
        /// Each view's height at its placed width, unconstrained.
        let needed: [CGFloat]
        let width: CGFloat
        let fold: DuoFold
        /// Two panes centred on each other (Calm, breathing).
        let centred: Bool
        /// Panes that take the full height and scroll (Learn).
        let fillsHeight: Bool
        /// Each view's id, to show the same views are placed whichever way the fold is.
        let ids: [String]
    }

    nonisolated(unsafe) static var plans: [Plan] = []
    /// How many times any spread has placed its views: a fold change should take a handful of
    /// passes, not one per animation frame.
    nonisolated(unsafe) static var placements = 0
    /// How many times a sheet's content has been evaluated: a sheet left open should go quiet.
    nonisolated(unsafe) static var sheetBodies = 0

    static func noteSheetBody() -> Bool {
        sheetBodies += 1
        return true
    }

    static func record(
        roles: [DuoRole], result: DuoSpreadPlan.Result, needed: [CGFloat], width: CGFloat, fold: DuoFold,
        centred: Bool = false, fillsHeight: Bool = false, ids: [String] = []
    ) {
        plans.append(Plan(
            roles: roles, frames: result.frames, needed: needed, width: width, fold: fold, centred: centred,
            fillsHeight: fillsHeight, ids: ids))
        if plans.count > 200 { plans.removeFirst(plans.count - 200) }
    }
}
#endif
