import NuboDesign
import NuboNetworking
import SwiftUI

struct HomeView: View {
    @Bindable var model: iPadAppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Nubo")
                        .font(.system(size: 34, weight: .semibold))
                    Spacer()
                    Button { model.showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Settings")
                }

                Text("Available Macs")
                    .font(.headline)
                    .padding(.top, 52)
                    .padding(.bottom, 14)

                if model.hosts.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Looking for Macs…").fontWeight(.medium)
                        Text("Open Nubo on a Mac connected to this network.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .nuboRowStyle()
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(model.hosts) { host in
                            Button { model.connect(to: host) } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: "desktopcomputer")
                                        .font(.title3)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(host.name).fontWeight(.medium)
                                        Text("Ready").font(.callout).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.callout.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                                .nuboRowStyle()
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Button("Connect manually") { model.showManualConnection = true }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(.top, 22)
            }
            .frame(maxWidth: 720)
            .padding(.horizontal, 30)
            .padding(.vertical, 34)
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $model.showManualConnection) {
            ManualConnectionView(model: model)
        }
        .sheet(isPresented: $model.showSettings) {
            iPadSettingsView()
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
                    TextField("IP address or hostname", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Port", text: $port)
                        .keyboardType(.numberPad)
                } footer: {
                    Text("Hostnames such as macbook.tailnet.ts.net work without changing the Nubo protocol.")
                }
                if let validationMessage {
                    Text(validationMessage).foregroundStyle(.red)
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
        .presentationDetents([.medium])
    }
}
