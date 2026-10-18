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
    @AppStorage("haptics.enabled") private var hapticsEnabled = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if paywalls.isPro {
                        Label("You have Pro", systemImage: "checkmark.seal.fill").foregroundStyle(Theme.accent)
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
                } header: {
                    Text("BumpCast Pro").eyebrow()
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
                    Text("Forecast ready 48 hours before departure, then updates at 24, 6 and 2 hours. Quiet overnight unless you fly early.")
                }
                Section {
                    Toggle("Haptics", isOn: $hapticsEnabled).tint(Theme.accent)
                } footer: {
                    Text("Soft taps for breathing and when a forecast is confirmed. Never used as a warning.")
                }
                Section {
                    if let stats, let exact = stats.exactPercent, let close = stats.withinOnePercent {
                        LabeledContent("Flights checked", value: "\(stats.reports)")
                        LabeledContent("Felt about right", value: "\(exact)%")
                        LabeledContent("Within one level", value: "\(close)%")
                    } else {
                        Text("Not enough landed flights yet. Rate your flights after landing to help.")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("How accurate are we?").eyebrow()
                }
                Section {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                    // One row covers the fonts' SIL Open Font License notices.
                    NavigationLink("Licences") { LicensesView() }
                } footer: {
                    Text("Forecasts are guidance, not guarantees. Always follow crew instructions.")
                }
            }
            // The same calm sky as the rest of the app, behind the standard grouped rows.
            .scrollContentBackground(.hidden)
            .background { SkyBackground(sky: Sky(date: .now)) }
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

/// Fonts bundled under the SIL Open Font License; the licence text ships with the app.
struct FontCredit: Identifiable {
    let name: String
    let author: String
    let licenseFile: String
    var id: String { licenseFile }

    static let all = [
        FontCredit(name: "Familjen Grotesk", author: "Familjen STHLM", licenseFile: "OFL-FamiljenGrotesk"),
        FontCredit(name: "Atkinson Hyperlegible", author: "Braille Institute", licenseFile: "OFL-AtkinsonHyperlegible"),
        FontCredit(name: "IBM Plex Mono", author: "IBM", licenseFile: "OFL-IBMPlexMono"),
    ]
}

/// Every bundled font's licence on one page.
private struct LicensesView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ForEach(FontCredit.all) { credit in
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(credit.name) · \(credit.author)").font(.bcCardTitle)
                        Text(Self.text(credit)).font(.bcFootnote)
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background { SkyBackground(sky: Sky(date: .now)) }
        .navigationTitle("Licences")
        .navigationBarTitleDisplayMode(.inline)
    }

    private static func text(_ credit: FontCredit) -> String {
        guard let url = Bundle.main.url(forResource: credit.licenseFile, withExtension: "txt"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "SIL Open Font License, Version 1.1" }
        return text
    }
}
