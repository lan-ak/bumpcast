import QuartzCore
import SwiftUI
import Testing
import UIKit

@testable import BumpCast

extension DuoUITests {
    /// The fold changing on a live screen: the spread must plan the new layout once and let SwiftUI
    /// interpolate it, not lay out (and measure every card) on every animation frame.
    @MainActor
    @Suite(.serialized)
    struct DuoMotionTests {
        @Observable final class FoldHolder {
            var fold = Duo.open
        }

        /// A screen in a real window the size of the open Duo's content, with the fold switchable.
        private struct Host<Screen: View>: View {
            let holder: FoldHolder
            let store: FlightStore
            let screen: () -> Screen

            var body: some View {
                ScrollView {
                    DuoFixtures.environment(screen(), store: store, fold: holder.fold)
                        .padding(.horizontal, DuoSpacing.inset)
                }
            }
        }

        /// Counts display-link ticks and the longest gap between them while the main thread is free.
        private final class FrameClock: NSObject {
            var stamps: [CFTimeInterval] = []
            private var link: CADisplayLink?

            func start() {
                let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
                link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
                link.add(to: .main, forMode: .common)
                self.link = link
            }

            @objc func tick(_ link: CADisplayLink) { stamps.append(link.timestamp) }

            func stop() { link?.invalidate() }

            var gaps: [CFTimeInterval] { zip(stamps.dropFirst(), stamps).map { $0 - $1 } }
            var longestGap: CFTimeInterval { gaps.max() ?? .infinity }
            var fps: Double {
                guard let first = stamps.first, let last = stamps.last, last > first else { return 0 }
                return Double(stamps.count - 1) / (last - first)
            }
        }

        struct Transition {
            let placements: Int
            let plans: Int
            let longestGap: CFTimeInterval
            let lateFrames: Int
            let fps: Double
        }

        /// Opens `screen` on the open Duo, lets it settle, then folds it partly open (and back),
        /// measuring each move.
        private func measure<Screen: View>(_ store: FlightStore, _ screen: @escaping () -> Screen) async throws -> (idle: Int, moves: [Transition]) {
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let holder = FoldHolder()
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 951 - 84, height: 669)
            window.rootViewController = UIHostingController(rootView: Host(holder: holder, store: store, screen: screen))
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            try await Task.sleep(for: .seconds(5))

            // At rest nothing should lay the spread out again (a live clock or progress bar would).
            let atRest = DuoSpreadRecorder.placements
            let restClock = FrameClock()
            restClock.start()
            try await Task.sleep(for: .seconds(1.0))
            restClock.stop()
            print("at rest: \(Int(restClock.fps)) fps")
            let idle = DuoSpreadRecorder.placements - atRest

            var transitions: [Transition] = []
            for fold in [Duo.partly, Duo.open] {
                let placements = DuoSpreadRecorder.placements
                let plans = DuoSpreadRecorder.plans.count
                let clock = FrameClock()
                clock.start()
                withAnimation(DuoMotion.move) { holder.fold = fold }
                try await Task.sleep(for: .seconds(1.0))
                clock.stop()
                transitions.append(Transition(
                    placements: DuoSpreadRecorder.placements - placements,
                    plans: DuoSpreadRecorder.plans.count - plans,
                    longestGap: clock.longestGap, lateFrames: clock.gaps.filter { $0 > 0.05 }.count, fps: clock.fps))
                try await Task.sleep(for: .seconds(0.3))
            }
            return (idle, transitions)
        }

        private func check(_ measured: (idle: Int, moves: [Transition]), _ name: String) {
            print("\(name) at rest: \(measured.idle) placements in 1 s")
            #expect(measured.idle <= 1, "\(name): \(measured.idle) placements in 1 s at rest")
            for (index, t) in measured.moves.enumerated() {
                let label = "\(name) move \(index + 1): \(t.placements) placements, \(t.plans) plans, " +
                    "longest frame gap \(Int(t.longestGap * 1000)) ms, \(t.lateFrames) over 50 ms, \(Int(t.fps)) fps"
                print(label)
                // A 0.55 s spring at 60 fps is ~33 frames; a handful of passes means no per-frame layout.
                #expect(t.placements <= 8, Comment(rawValue: label))
                // The move's first frame does the one re-layout and may run late; no other frame may.
                #expect(t.lateFrames <= 1, Comment(rawValue: label))
                #expect(t.longestGap <= 0.1, Comment(rawValue: label))
                #expect(t.fps >= 50, Comment(rawValue: label))
            }
        }

        @Test func flightsSpreadInTheAirFoldsSmoothly() async throws {
            let store = await DuoFixtures.store([DuoFixtures.flight(.inAir), DuoFixtures.flight(.beforeFlight)])
            check(try await measure(store) { FlightsListView(contentOnly: true) }, "Flights, in the air")
        }

        @Test func globalOutlookDetailFoldsSmoothly() async throws {
            GlobalBeta.shared.set(true)
            let (flight, forecast) = DuoFixtures.flight(.global)
            let store = await DuoFixtures.store([(flight, forecast)])
            check(try await measure(store) { FlightDetailView(flightID: flight.id, embedded: true) }, "GRU→LIS")
        }
    }
}
