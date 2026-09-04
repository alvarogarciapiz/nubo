import NuboDesign
import SwiftUI

struct MacOnboardingView: View {
    @Bindable var model: MacAppModel
    @Environment(\.dismissWindow) private var dismissWindow

    private var completedCount: Int {
        PermissionKind.allCases.filter(isGranted).count
    }

    private var currentPermission: PermissionKind? {
        PermissionKind.allCases.first { !isGranted($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            permissionProgress
                .padding(.top, 34)

            Group {
                if let currentPermission {
                    permissionStep(currentPermission)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                } else {
                    readyStep
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
            }
            .padding(.top, 20)
            .animation(NuboDesign.quietAnimation, value: completedCount)

            Spacer(minLength: 28)
            footer
        }
        .padding(.horizontal, 52)
        .padding(.vertical, 40)
        .task {
            while !Task.isCancelled, !model.isReady {
                model.refreshPermissions()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "display.and.arrow.down")
                .font(.system(size: 25, weight: .medium))
                .accessibilityHidden(true)
            Text("Welcome to Nubo")
                .font(.system(size: 32, weight: .semibold))
            Text("Three quick permissions make this Mac ready for secure remote control.")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private var permissionProgress: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(model.isReady ? "Setup complete" : "Step \(min(completedCount + 1, 3)) of 3")
                    .font(.callout.weight(.medium))
                Spacer()
                Text("\(completedCount)/3")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { index in
                    Capsule()
                        .fill(index < completedCount ? Color.primary : Color.primary.opacity(0.12))
                        .frame(height: 3)
                }
            }
        }
    }

    private func permissionStep(_ permission: PermissionKind) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 15) {
                Image(systemName: symbol(for: permission))
                    .font(.system(size: 19, weight: .medium))
                    .frame(width: 25)

                VStack(alignment: .leading, spacing: 6) {
                    Text(permission.title)
                        .font(.headline)
                    Text(permission.explanation)
                        .foregroundStyle(.secondary)
                    Text(detail(for: permission))
                        .font(.callout)
                        .foregroundStyle(.secondary.opacity(0.78))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Button(actionTitle(for: permission)) {
                model.request(permission)
            }
            .buttonStyle(.borderedProminent)
            .tint(.primary)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .padding(22)
        .background(NuboDesign.secondaryFill)
        .clipShape(RoundedRectangle(cornerRadius: NuboDesign.radius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: NuboDesign.radius, style: .continuous)
                .stroke(NuboDesign.border, lineWidth: 1)
        }
    }

    private var readyStep: some View {
        HStack(spacing: 15) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 23))
            VStack(alignment: .leading, spacing: 4) {
                Text("This Mac is ready")
                    .font(.headline)
                Text("Nubo will stay available from the menu bar. Only paired iPads can connect.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NuboDesign.secondaryFill)
        .clipShape(RoundedRectangle(cornerRadius: NuboDesign.radius, style: .continuous))
    }

    private var footer: some View {
        HStack {
            if !model.isReady {
                Button("Check Again") { model.refreshPermissions() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isReady {
                Button("Finish Setup") {
                    model.finishOnboarding()
                    dismissWindow(id: "onboarding")
                }
                .buttonStyle(.borderedProminent)
                .tint(.primary)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func isGranted(_ permission: PermissionKind) -> Bool {
        switch permission {
        case .screenRecording: model.screenRecordingGranted
        case .accessibility: model.accessibilityGranted
        case .localNetwork: model.localNetworkAcknowledged
        }
    }

    private func symbol(for permission: PermissionKind) -> String {
        switch permission {
        case .screenRecording: "rectangle.inset.filled.and.person.filled"
        case .accessibility: "accessibility"
        case .localNetwork: "network"
        }
    }

    private func detail(for permission: PermissionKind) -> String {
        switch permission {
        case .screenRecording:
            "Nubo captures the selected display only while an authenticated iPad is connected. macOS may ask you to reopen the app."
        case .accessibility:
            "Used only to reproduce mouse and keyboard events received through an encrypted session."
        case .localNetwork:
            "Starts a private Bonjour service for discovery. Bonjour is optional later when connecting by hostname or IP."
        }
    }

    private func actionTitle(for permission: PermissionKind) -> String {
        switch permission {
        case .localNetwork: "Start Local Service"
        default: "Allow in macOS"
        }
    }
}
