import StoreKit
import SwiftUI

struct SettingsView: View {
    @Environment(Paywalls.self) private var paywalls
    @Environment(PushNotifications.self) private var push
    @Environment(FlightStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var isManagingSubscription = false
    @State private var restoreMessage: String?
    @State private var stats: AccuracyStats?

    var body: some View {
        NavigationStack {
            Form {
                Section("BumpCast Pro") {
                    if paywalls.isPro {
                        Label("You have Pro", systemImage: "checkmark.seal.fill").foregroundStyle(.blue)
                        // Easy cancel: straight to Apple's subscription management.
                        Button("Manage or cancel subscription") { isManagingSubscription = true }
                    } else {
                        Button("Get BumpCast Pro") {
                            paywalls.unlock(.upgradeFromSettings) {}
                        }
                        if !store.passes.isEmpty {
                            Text("\(store.passes.count) flight pass\(store.passes.count == 1 ? "" : "es") used")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button("Restore purchases") {
                        Task {
                            restoreMessage = await paywalls.restorePurchases() ? "Purchases restored." : "Nothing to restore."
                        }
                    }
                }
                Section {
                    LabeledContent("Notifications", value: push.isEnabled ? "On" : "Off")
                    if !push.isEnabled {
                        Button(push.status == .denied ? "Turn on in Settings" : "Turn on notifications") {
                            if push.status == .denied {
                                openURL(URL(string: UIApplication.openNotificationSettingsURLString)!)
                            } else {
                                Task { await push.requestPermission() }
                            }
                        }
                    }
                } footer: {
                    Text("Forecast ready 48 hours before departure, then updates at 24, 6 and 2 hours.")
                }
                Section("How accurate are we?") {
                    if let stats, let exact = stats.exactPercent, let close = stats.withinOnePercent {
                        LabeledContent("Flights checked", value: "\(stats.reports)")
                        LabeledContent("Felt about right", value: "\(exact)%")
                        LabeledContent("Within one level", value: "\(close)%")
                    } else {
                        Text("Not enough landed flights yet. Rate your flights after landing to help.")
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                } footer: {
                    Text("Forecasts are guidance, not guarantees. Always follow crew instructions.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .manageSubscriptionsSheet(isPresented: $isManagingSubscription)
            .alert(restoreMessage ?? "", isPresented: .constant(restoreMessage != nil)) {
                Button("OK") { restoreMessage = nil }
            }
            .task { stats = try? await store.service.accuracyStats() }
        }
    }
}
