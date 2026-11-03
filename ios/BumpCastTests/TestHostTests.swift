import Foundation
import Supabase
import Testing

@testable import BumpCast

/// Unit tests run inside the app. They must never sign in to production: every run would leave
/// an anonymous account behind (three test simulators did, on 2026-11-01).
@MainActor
struct TestHostTests {
    @Test func theAppKnowsItsHostingTests() {
        #expect(Services.isTestHost)
    }

    @Test func testsUseTheDemoServiceNotSupabase() {
        #expect(Services.flights is DemoFlightService)
        #expect(Services.isDemo)
    }

    @Test func nothingSignsInToSupabaseUnderTests() async throws {
        // Give any launch work that would have started a moment to run.
        try await Task.sleep(for: .seconds(1))
        #expect(SupabaseFlightService.signInAttempts == 0)
    }

    /// A Debug build launched without `-allowLiveSignIn` refuses to create an account outright:
    /// it never gets as far as the network (a network failure would be a different error).
    @Test func debugBuildsRefuseToCreateAProductionAccount() async {
        #expect(!SupabaseFlightService.liveSignInAllowed)
        let client = SupabaseClient(supabaseURL: URL(string: "https://sign-in-guard.invalid")!, supabaseKey: "test")
        let service = SupabaseFlightService(client: client)
        do {
            _ = try await service.signIn(allowSignUp: true)
            Issue.record("signed in")
        } catch {
            #expect(String(describing: error).contains("sessionMissing"), "\(error)")
        }
    }

    @Test func superwallIsNotConfiguredUnderTests() {
        #expect(!Paywalls.shared.isConfigured)
    }
}
