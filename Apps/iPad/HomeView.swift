import NuboCore
import NuboDesign
import NuboNetworking
import SwiftUI

struct HomeView: View {
    @Bindable var model: iPadAppModel
    @State private var editingHost: DiscoveredHost?
    @State private var removingHost: DiscoveredHost?
    @State private var removalError: String?
    @AppStorage("nubo.hostAppearance") private var appearanceData = Data()
    @Environment(\.scenePhase) private var scenePhase

    private var appearances: [String: HostAppearance] {
        (try? JSONDecoder().decode([String: HostAppearance].self, from: appearanceData)) ?? [:]
    }

    private func appearance(for host: DiscoveredHost) -> HostAppearance {
        appearances[host.peerID?.uuidString ?? host.id] ?? .init(name: host.name, symbol: HostAppearance.symbol(for: host.name))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Your Macs").font(.title2.weight(.semibold))
                    Text("Your workspace, a touch away.").foregroundStyle(.secondary)
                }
                if model.hosts.isEmpty {
                    ContentUnavailableView {
                        Label("Your Mac, right here.", systemImage: "desktopcomputer.and.macbook")
                    } description: {
                        Text("Open Nubo on your Mac and connect both devices to the same network. Your Mac will appear here.")
                    }
                    .frame(maxWidth: .infinity, minHeight: 220)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 16)], spacing: 16) {
                    ForEach(model.hosts) { host in
                        Button { model.connect(to: host) } label: {
                            VStack(alignment: .leading, spacing: 18) {
                                if let preview = model.previews[host.id] {
                                    Image(uiImage: preview).resizable().aspectRatio(contentMode: .fit)
                                        .frame(maxWidth: .infinity, minHeight: 112, maxHeight: 150)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                        .accessibilityLabel("Last desktop preview")
                                } else {
                                Image(systemName: appearance(for: host).symbol)
                                    .font(.system(size: 64, weight: .ultraLight))
                                    .symbolRenderingMode(.hierarchical)
                                    .frame(maxWidth: .infinity, minHeight: 112)
                                    .accessibilityHidden(true)
                                }
                                HStack(alignment: .bottom) {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(appearance(for: host).name).font(.headline).lineLimit(2)
                                        Text(isCompatible(host) ? "Ready to connect" : "Update required")
                                            .font(.subheadline).foregroundStyle(.secondary)
                                        if let date = model.previewDates[host.id] {
                                            Text(date, style: .relative).font(.caption).foregroundStyle(.tertiary)
                                        }
                                    }
                                    Spacer(minLength: 8)
                                    Image(systemName: "arrow.up.right").foregroundStyle(.tertiary)
                                }
                            }
                            .padding(24)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                            .contentShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .disabled(!isCompatible(host))
                        .contextMenu {
                            Button("Customize Mac", systemImage: "pencil") { editingHost = host }
                            Button("Forget Mac", systemImage: "trash", role: .destructive) { removingHost = host }
                        }
                        .accessibilityAction(named: "Customize Mac") { editingHost = host }
                    }
                    }
                }
                Button { model.showManualConnection = true } label: {
                    Label("Add a Mac by address", systemImage: "plus")
                }
                .padding(.vertical, 8)
                Button("Show all nearby Macs") { model.showNearbyMacs() }
                    .font(.footnote)
                Text("Touch and hold a Mac to change its name or icon.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Nubo")
        .onAppear { model.startPreviews() }
        .onDisappear { model.stopPreviews() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.startPreviews() } else { model.stopPreviews() }
        }
        .confirmationDialog("Forget this Mac?", isPresented: Binding(get: { removingHost != nil }, set: { if !$0 { removingHost = nil } }), titleVisibility: .visible) {
            if let host = removingHost {
                Button("Forget \(appearance(for: host).name)", role: .destructive) {
                    Task {
                        do {
                            try await model.forget(host)
                            var values = appearances
                            values.removeValue(forKey: host.peerID?.uuidString ?? host.id)
                            if let data = try? JSONEncoder().encode(values) { appearanceData = data }
                        } catch { removalError = error.localizedDescription }
                    }
                }
            }
        } message: {
            Text("Remove its saved key, name and icon from this iPad. Connecting again will require pairing. This does not revoke other devices on the Mac.")
        }
        .alert("Could not forget Mac", isPresented: Binding(get: { removalError != nil }, set: { if !$0 { removalError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(removalError ?? "") }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { model.showSettings = true } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
            }
        }
        .refreshable { model.startDiscovery() }
        .sheet(isPresented: $model.showManualConnection) {
            ManualConnectionView(model: model)
        }
        .sheet(isPresented: $model.showSettings) {
            iPadSettingsView()
        }
        .sheet(item: $editingHost) { host in
            HostAppearanceEditor(appearance: appearance(for: host)) { updated in
                var values = appearances
                values[host.peerID?.uuidString ?? host.id] = updated
                if let data = try? JSONEncoder().encode(values) { appearanceData = data }
            }
        }
    }

    private func isCompatible(_ host: DiscoveredHost) -> Bool {
        host.protocolVersion.map { $0 == NuboConstants.protocolVersion } ?? true
    }
}

private struct HostAppearance: Codable {
    var name: String
    var symbol: String
    static let icons = [("MacBook", "macbook"), ("iMac", "desktopcomputer"), ("Mac mini", "macmini"),
                        ("Mac Studio", "macstudio"), ("Mac Pro", "macpro.gen3")]
    static func symbol(for name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("mini") { return "macmini" }
        if lower.contains("studio") { return "macstudio" }
        if lower.contains("book") { return "macbook" }
        if lower.contains("mac pro") { return "macpro.gen3" }
        return "desktopcomputer"
    }
}

private struct HostAppearanceEditor: View {
    @State var appearance: HostAppearance
    let save: (HostAppearance) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("Name on this iPad") { TextField("Mac name", text: $appearance.name) }
                Section("Product icon") {
                    ForEach(HostAppearance.icons, id: \.1) { title, symbol in
                        Button { appearance.symbol = symbol } label: {
                            HStack {
                                Label(title, systemImage: symbol)
                                Spacer()
                                if appearance.symbol == symbol { Image(systemName: "checkmark") }
                            }
                        }.tint(.primary)
                    }
                }
                Section { Text("This changes the appearance here, not the Mac’s system name or trusted identity.").font(.footnote) }
            }
            .navigationTitle("Customize Mac").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        appearance.name = appearance.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        save(appearance); dismiss()
                    }.disabled(appearance.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private struct ManualConnectionView: View {
    @Bindable var model: iPadAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var port = "49832"
    @State private var validationMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Hostname or IP address", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Port", text: $port)
                        .keyboardType(.numberPad)
                } header: {
                    Text("Mac")
                } footer: {
                    Text("Enter the address of a Mac you can reach on your network. You’ll confirm its identity before connecting.")
                }

                if let validationMessage {
                    Section {
                        Label(validationMessage, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Connect manually")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect") {
                        do {
                            try model.connectManually(host: host, port: Int(port) ?? 0)
                        } catch {
                            validationMessage = "Enter a valid hostname and port."
                        }
                    }
                    .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
