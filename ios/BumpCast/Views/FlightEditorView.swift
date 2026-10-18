import SwiftUI

/// Add a new flight, or edit one when `flight` is set.
struct FlightEditorView: View {
    var flight: Flight?

    @Environment(FlightStore.self) private var store
    @Environment(PushNotifications.self) private var push
    @Environment(\.dismiss) private var dismiss
    @State private var origin: Airport?
    @State private var destination: Airport?
    @State private var departure = Calendar.current.date(byAdding: .day, value: 1, to: .now)!
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    AirportField(title: "From", airport: $origin)
                    AirportField(title: "To", airport: $destination)
                }
                Section {
                    DatePicker("Departs", selection: $departure, in: Date.now.addingTimeInterval(-3600)...)
                        .environment(\.timeZone, origin?.timeZone ?? .current)
                } footer: {
                    if let origin {
                        Text("Scheduled departure, local time in \(origin.city).")
                    }
                }
                if origin != nil, origin == destination {
                    Text("Pick two different airports.").foregroundStyle(.red)
                } else if let origin, let destination, !Coverage.covers(from: origin, to: destination) {
                    Label(
                        "This route is outside our US coverage for now. You can still save it, and we'll tell you when we cover it.",
                        systemImage: "globe"
                    )
                    .font(.bcFootnote)
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(flight == nil ? "Add flight" : "Edit flight")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(!canSave || isSaving)
                }
            }
            .onAppear(perform: loadExisting)
        }
    }

    private var canSave: Bool {
        guard let origin, let destination else { return false }
        return origin != destination
    }

    private func loadExisting() {
        guard let flight, origin == nil else { return }
        origin = flight.originAirport
        destination = flight.destinationAirport
        departure = flight.departureAt
    }

    private func save() async {
        guard let origin, let destination else { return }
        isSaving = true
        defer { isSaving = false }
        let draft = FlightDraft(origin: origin.icao, destination: destination.icao, departureAt: departure)
        if await store.save(draft, editing: flight?.id) != nil {
            dismiss()
            // The moment the user has a reason to want alerts: ask once.
            if push.status == .notDetermined {
                await push.requestPermission()
            }
        }
    }
}

private struct AirportField: View {
    let title: String
    @Binding var airport: Airport?

    var body: some View {
        NavigationLink {
            AirportSearchView(title: title, selection: $airport)
        } label: {
            LabeledContent(title) {
                if let airport {
                    Text("\(airport.iata) · \(airport.city)").foregroundStyle(.primary)
                } else {
                    Text("Choose airport")
                }
            }
        }
    }
}

private struct AirportSearchView: View {
    let title: String
    @Binding var selection: Airport?
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        List(AirportStore.shared.search(query)) { airport in
            Button {
                selection = airport
                dismiss()
            } label: {
                HStack {
                    Text(airport.iata).font(.bcMeta).frame(width: 48, alignment: .leading)
                    VStack(alignment: .leading) {
                        Text(airport.city)
                        Text(airport.name).font(.bcCaption).foregroundStyle(.secondary)
                    }
                }
            }
            .tint(.primary)
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "City, airport or code")
        .navigationTitle(title)
    }
}
