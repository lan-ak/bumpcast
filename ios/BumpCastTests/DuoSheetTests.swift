import SwiftUI
import Testing
import UIKit

@testable import BumpCast

extension DuoUITests {
    /// Sheets on the Duo: opened with the fold active they cover the screen with their content in the
    /// left half, nothing in the fold; fully open they're the system's sheet. Folding while one is
    /// open keeps what's in it. Presented for real, in a window the size of the open Duo.
    @MainActor
    struct DuoSheetTests {
        init() {
            DuoFixtures.enableAccessibility
        }

        @Observable final class Presenter {
            var fold: DuoFold? = Duo.open
            var shown = false
        }

        /// A screen that presents `sheet` through the app's one sheet rule.
        private struct Host<Sheet: View>: View {
            let presenter: Presenter
            let store: FlightStore
            let sheet: () -> Sheet

            var body: some View {
                DuoFixtures.environment(
                    Color.clear.adaptiveSheet(isPresented: Binding(get: { presenter.shown }, set: { presenter.shown = $0 })) { sheet() },
                    store: store, fold: presenter.fold)
            }
        }

        /// Where a sheet is shown: the open Duo either way, or an iPhone (no fold).
        static let screens: [(name: String, fold: DuoFold?, size: CGSize)] = [
            ("open", Duo.open, CGSize(width: 951, height: 669)),
            ("partly", Duo.partly, CGSize(width: 951, height: 669)),
            ("iphone", nil, CGSize(width: 402, height: 874)),
        ]

        /// Shows a sheet, lets it settle, and hands back the window to look at.
        private func present<Sheet: View>(
            _ sheet: @escaping () -> Sheet, fold: DuoFold?, store: FlightStore, size: CGSize = CGSize(width: 951, height: 669)
        ) async throws -> (window: UIWindow, presenter: Presenter) {
            let presenter = Presenter()
            presenter.fold = fold
            let (window, _) = try DuoFixtures.host(Host(presenter: presenter, store: store, sheet: sheet), size: size)
            try await Task.sleep(for: .seconds(0.4))
            presenter.shown = true
            try await Task.sleep(for: .seconds(1.2))
            return (window, presenter)
        }

        private func dismiss(_ window: UIWindow, _ presenter: Presenter) async throws {
            presenter.shown = false
            try await Task.sleep(for: .seconds(0.8))
            window.isHidden = true
        }

        /// Everything VoiceOver reaches in the window, with its frame on screen.
        private func elements(_ window: UIWindow) -> [(label: String, frame: CGRect)] {
            DuoFixtures.accessibilityElements(in: window).filter { $0.frame.width > 0 && $0.frame.height > 0 }
        }

        private func style(_ window: UIWindow) -> UIModalPresentationStyle? {
            window.rootViewController?.presentedViewController?.modalPresentationStyle
        }

        /// SwiftUI's full-screen cover presents over the full screen.
        private func covers(_ window: UIWindow) -> Bool {
            [.fullScreen, .overFullScreen].contains(style(window))
        }

        /// Things in the fold's band or right of it, with the fold active.
        private func intruders(_ window: UIWindow, fold: DuoFold) -> [String] {
            elements(window).filter { $0.frame.maxX > fold.band.lowerBound + 0.5 }.map { "\($0.label.prefix(30)) at \(Int($0.frame.minX))–\(Int($0.frame.maxX))" }
        }

        @Test func sheetsStayClearOfTheFold() async throws {
            GlobalBeta.shared.set(true)
            let (flight, forecast) = DuoFixtures.flight(.global)
            let store = await DuoFixtures.store([(flight, forecast)])
            let warning = try #require(forecast?.officialWarnings.first)
            let sheets: [(name: String, view: () -> AnyView)] = [
                ("add-flight", { AnyView(AddFlightView()) }),
                ("edit-flight", { AnyView(AddFlightView(flight: flight)) }),
                ("settings", { AnyView(SettingsView()) }),
                ("ready-to-add", { AnyView(ReadyToAddSheet()) }),
                ("warning", { AnyView(WarningSheet(warning: warning)) }),
                ("global-outlook", { AnyView(GlobalOutlookSheet(neverConfirmed: true)) }),
                ("email-import", { AnyView(EmailImportSheet()) }),
            ]
            var outcomes: [(name: String, image: UIImage?, problems: [String])] = []
            for sheet in sheets {
                for (foldName, fold, size) in Self.screens {
                    let (window, presenter) = try await present(sheet.view, fold: fold, store: store, size: size)
                    var problems: [String] = []
                    let shown = elements(window)
                    if shown.isEmpty { problems.append("nothing on screen") }
                    if let fold, fold.isActive {
                        if !covers(window) { problems.append("not full screen: \(String(describing: style(window)?.rawValue))") }
                        problems += intruders(window, fold: fold).map { "in or past the fold: \($0)" }
                    } else if covers(window) {
                        problems.append("full screen when \(fold == nil ? "on the iPhone" : "fully open")")
                    }
                    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                    }
                    let name = "sheet-\(sheet.name)-\(foldName)"
                    DuoFixtures.write(image, to: "cases", name: name)
                    outcomes.append((name, image, problems))
                    try await dismiss(window, presenter)
                }
            }
            DuoFixtures.writeGrid(outcomes.map { ($0.name, $0.image, $0.problems.isEmpty) }, name: "sheets")
            for outcome in outcomes where !outcome.problems.isEmpty {
                Issue.record("\(outcome.name): \(outcome.problems)")
            }
            #expect(outcomes.count == sheets.count * Self.screens.count)
        }

        /// A sheet that shows which instance it is: a new one would mean what was in it was lost.
        private struct Probe: View {
            @State private var instance = String(UUID().uuidString.prefix(8))
            @State private var typed = "UA 90"

            var body: some View {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Sheet \(instance)")
                    TextField("Flight number", text: $typed)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }

        /// Opened either way, then folded back and forth: the same sheet, the same kind of
        /// presentation, and with the fold active nothing in it in the fold.
        @Test(arguments: [false, true])
        func foldingWithASheetOpenKeepsItsState(openedPartly: Bool) async throws {
            let store = await DuoFixtures.store([])
            let start = openedPartly ? Duo.partly : Duo.open
            let (window, presenter) = try await present({ Probe() }, fold: start, store: store)
            func instance() -> String? { elements(window).first { $0.label.hasPrefix("Sheet ") }?.label }
            let first = try #require(instance())
            let firstStyle = style(window)
            #expect(covers(window) == openedPartly, "opened \(openedPartly ? "partly" : "fully") open as style \(String(describing: firstStyle?.rawValue))")
            for fold in [openedPartly ? Duo.open : Duo.partly, start, openedPartly ? Duo.open : Duo.partly] {
                withAnimation(DuoMotion.move) { presenter.fold = fold }
                try await Task.sleep(for: .seconds(1.0))
                #expect(instance() == first, "rebuilt after folding to \(fold.isActive ? "partly" : "open")")
                #expect(style(window) == firstStyle, "presentation changed")
                #expect(elements(window).contains { $0.label.contains("UA 90") }, "typed text lost")
                if fold.isActive {
                    #expect(intruders(window, fold: fold).isEmpty, "\(intruders(window, fold: fold))")
                }
            }
            try await dismiss(window, presenter)
        }
    
        /// A sheet left open goes quiet: on the iPhone and on the open Duo either way, its content
        /// isn't evaluated again once it has settled (a value fed back from layout would keep it busy).
        @Test func anOpenSheetGoesIdle() async throws {
            let store = await DuoFixtures.store([DuoFixtures.flight(.global)])
            for (name, fold, size) in Self.screens {
                let (window, presenter) = try await present({ SettingsView() }, fold: fold, store: store, size: size)
                try await Task.sleep(for: .seconds(1))
                let settled = DuoSpreadRecorder.sheetBodies
                try await Task.sleep(for: .seconds(1))
                let more = DuoSpreadRecorder.sheetBodies - settled
                #expect(more <= 1, "\(name): \(more) evaluations in 1 s with the sheet open and nothing changing")
                #expect(!elements(window).isEmpty, "\(name): blank")
                try await dismiss(window, presenter)
            }
        }
    
        /// A paywall first, the way Superwall shows one on the open Duo (from a window of its own,
        /// told it's compact width), then one of the app's sheets: the paywall's override stays on
        /// its window, and the sheet follows the rule on every screen as if there'd been none.
        @Test func aSheetRightAfterAPaywallFollowsTheRule() async throws {
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let paywallWindow = UIWindow(windowScene: scene)
            paywallWindow.frame = CGRect(x: 0, y: 0, width: 951, height: 669)
            paywallWindow.rootViewController = UIViewController()
            paywallWindow.makeKeyAndVisible()
            paywallWindow.traitOverrides.horizontalSizeClass = .compact
            let paywall = UIViewController()
            paywall.modalPresentationStyle = .pageSheet
            paywallWindow.rootViewController?.present(paywall, animated: false)
            try await Task.sleep(for: .seconds(0.5))
            paywall.dismiss(animated: false)
            paywallWindow.isHidden = true

            let store = await DuoFixtures.store([])
            for (name, fold, size) in Self.screens {
                let (window, presenter) = try await present({ Probe() }, fold: fold, store: store, size: size)
                #expect(covers(window) == (fold?.isActive == true), "\(name): style \(String(describing: style(window)?.rawValue))")
                #expect(!window.traitOverrides.contains(UITraitHorizontalSizeClass.self), "\(name): the app's window was overridden")
                if let fold, fold.isActive {
                    #expect(intruders(window, fold: fold).isEmpty, "\(name): \(intruders(window, fold: fold))")
                }
                try await dismiss(window, presenter)
            }
        }
    
        /// The onboarding fallback (shown when the Superwall flow can't be): on the open Duo, either
        /// way, its headline and button keep to the left half, nothing in the fold; default and large
        /// text, and the iPhone for comparison. Written to `onboarding.png`.
        @Test func onboardingFallbackStaysLeftOfTheFold() async throws {
            let store = await DuoFixtures.store([])
            var outcomes: [(name: String, image: UIImage?, passed: Bool)] = []
            for (textName, textSize) in [("default", DynamicTypeSize.large), ("ax3", .accessibility3)] {
                for (name, fold, size) in Self.screens {
                    let view = DuoFixtures.environment(NativeOnboardingView().dynamicTypeSize(textSize), store: store, fold: fold)
                    let (window, _) = try DuoFixtures.host(view, size: size)
                    try await Task.sleep(for: .seconds(1))
                    var problems: [String] = []
                    let shown = elements(window)
                    if !shown.contains(where: { $0.label.contains("Know what your flight will feel like") }) { problems.append("no headline") }
                    if !shown.contains(where: { $0.label.contains("Get started") }) { problems.append("no button") }
                    if let fold { problems += intruders(window, fold: fold).map { "in or past the fold: \($0)" } }
                    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                    }
                    window.isHidden = true
                    let caseName = "onboarding-\(name)-\(textName)"
                    DuoFixtures.write(image, to: "cases", name: caseName)
                    outcomes.append((caseName, image, problems.isEmpty))
                    for problem in problems { Issue.record("\(caseName): \(problem)") }
                }
            }
            DuoFixtures.writeGrid(outcomes, name: "onboarding")
            #expect(outcomes.count == 2 * Self.screens.count)
        }
    }
}
