import SwiftUI
import Testing
import UIKit

@testable import BumpCast

extension DuoUITests {
    /// VoiceOver reads a spread in the iPhone's order: the same content, in the same sequence, however
    /// the Duo arranges it on screen.
    @MainActor
    @Suite(.serialized)
    struct DuoAccessibilityTests {
        init() {
            DuoFixtures.enableAccessibility
        }

        /// The screen in a real window, tall enough that nothing scrolls: what VoiceOver reads.
        private func labels<V: View>(_ view: V, width: CGFloat) async throws -> [String] {
            let (window, root) = try DuoFixtures.host(view, size: CGSize(width: width, height: 6000))
            defer { window.isHidden = true }
            try await Task.sleep(for: .seconds(0.6))
            return DuoFixtures.accessibilityElements(in: root).map(\.label)
        }

        /// Each audited Flights and detail state, open and partly open: the elements VoiceOver reaches on
        /// both, in the same order as on the iPhone. The iPhone shows a Flights spread's content on the
        /// next flight's own screen, so that's what it's compared with; with no flights, the list.
        @Test func voiceOverReadsInTheIPhoneOrder() async throws {
            GlobalBeta.shared.set(true)
            var problems: [String] = []
            var compared = 0
            let duoWidth = DuoAuditTests.spreadWidth + 2 * DuoSpacing.inset
            for item in DuoAuditTests.flightsCases {
                let store = await DuoFixtures.store(item.flights.map { DuoFixtures.flight($0) })
                let phoneScreen: AnyView = store.upcomingFlights.first.map {
                    AnyView(FlightDetailView(flightID: $0.id, embedded: true))
                } ?? AnyView(FlightsListView(contentOnly: true))
                let phone = try await labels(
                    DuoFixtures.environment(phoneScreen, store: store, fold: nil, unlocked: item.unlocked).padding(.horizontal, 16), width: 393)
                for (foldName, fold) in DuoAuditTests.folds {
                    let duo = try await labels(
                        DuoFixtures.environment(FlightsListView(contentOnly: true), store: store, fold: fold, unlocked: item.unlocked)
                            .padding(.horizontal, DuoSpacing.inset), width: duoWidth)
                    problems += mismatch("\(item.name)-\(foldName)", duo: duo, phone: phone)
                    compared += 1
                }
            }
            for item in DuoAuditTests.detailCases {
                let (flight, forecast) = DuoFixtures.flight(item.flight)
                let store = await DuoFixtures.store([(flight, forecast), DuoFixtures.flight(.dayOf), DuoFixtures.flight(.strong)])
                let screen = FlightDetailView(flightID: flight.id, embedded: true)
                let phone = try await labels(DuoFixtures.environment(screen, store: store, fold: nil).padding(.horizontal, 16), width: 393)
                for (foldName, fold) in DuoAuditTests.folds {
                    let duo = try await labels(
                        DuoFixtures.environment(screen, store: store, fold: fold).padding(.horizontal, DuoSpacing.inset), width: duoWidth)
                    problems += mismatch("\(item.name)-\(foldName)", duo: duo, phone: phone)
                    compared += 1
                }
            }
            #expect(compared == (DuoAuditTests.flightsCases.count + DuoAuditTests.detailCases.count) * DuoAuditTests.folds.count)
            #expect(problems.isEmpty, Comment(rawValue: problems.joined(separator: "\n")))
        }

        /// The elements both read, in each one's order: they must be the same sequence.
        private func mismatch(_ name: String, duo: [String], phone: [String]) -> [String] {
            let shared = Set(duo).intersection(phone)
            let a = duo.filter(shared.contains), b = phone.filter(shared.contains)
            guard shared.count >= 3 else { return ["\(name): only \(shared.count) elements in common"] }
            guard a != b else { return [] }
            let first = (0..<min(a.count, b.count)).first { a[$0] != b[$0] } ?? min(a.count, b.count)
            func around(_ list: [String]) -> String {
                list[max(0, first - 1)..<min(list.count, first + 2)].map { String($0.prefix(40)) }.joined(separator: " | ")
            }
            return ["\(name): differs at \(first) of \(b.count): Duo [\(around(a))] vs iPhone [\(around(b))]"]
        }
    }
}
