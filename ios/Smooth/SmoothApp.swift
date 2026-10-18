import SwiftUI

@main
struct SmoothApp: App {
    @State private var store = FlightStore()

    var body: some Scene {
        WindowGroup {
            FlightsListView()
                .environment(store)
                .task { await store.start() }
        }
    }
}
