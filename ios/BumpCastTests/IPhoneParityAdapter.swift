import SwiftUI

@testable import BumpCast

/// The current build's side of the iPhone comparison (`IPhoneParityTests`). The earlier build gets
/// its own copy of this file from `scripts/iphone-parity.sh`, with the same names doing what that
/// build did.
@MainActor
enum IPhoneParityAdapter {
    /// Everything unlocked, as in a demo build (earlier builds' test host had no lock).
    static func prepare() {
        Paywalls.debugTestsSeeEverything = true
    }
}

extension View {
    /// A sheet, the way the app presents one.
    func paritySheet<Content: View>(isPresented: Binding<Bool>, content: @escaping () -> Content) -> some View {
        adaptiveSheet(isPresented: isPresented, content: content)
    }
}
