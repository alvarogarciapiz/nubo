import AppKit
import NuboDesign
import SwiftUI

struct MacOnboardingView: View {
    @Bindable var model: MacAppModel
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var completedCount: Int {
        PermissionKind.allCases.filter(isGranted).count
    }

    private var currentPermission: PermissionKind? {
        PermissionKind.allCases.first { !isGranted($0) }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detail
        }
        .task {
            while !Task.isCancelled {
                model.refreshPermissions()
                try? await Task.sleep(for: .milliseconds(750))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.verifyPermissionsAfterReturning() }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)

            Text("Nubo")
                .font(.title2.weight(.semibold))
                .padding(.top, 14)
            Text("Set up this Mac")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(PermissionKind.allCases) { permission in
                    permissionRow(permission)
                }
            }
            .padding(.top, 34)

            Spacer()

            HStack(spacing: 8) {
                if model.isReady {
                    Image(systemName: "checkmark")
                } else if !model.requestedPermissions.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(model.isReady ? "Setup complete" : "Checking automatically")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(28)
        .frame(width: 232, alignment: .leading)
        .background(Color.primary.opacity(0.035))
    }

    private func permissionRow(_ permission: PermissionKind) -> some View {
        let granted = isGranted(permission)
        let active = permission == currentPermission

        return HStack(spacing: 11) {
            Image(systemName: granted ? "checkmark.circle.fill" : active ? "circle.inset.filled" : "circle")
                .symbolRenderingMode(.monochrome)
                .font(.body)
                .foregroundStyle(granted || active ? .primary : .tertiary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title)
                    .font(.callout.weight(active ? .semibold : .regular))
                Text(granted ? "Enabled" : active ? "Current step" : "Not configured")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                Group {
                    if let currentPermission {
                        permissionStep(currentPermission)
                            .id(currentPermission)
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .trailing)))
                    } else {
                        readyStep
                            .transition(.opacity)
                    }
                }
                .animation(reduceMotion ? nil : NuboDesign.quietAnimation, value: completedCount)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer(minLength: 20)
            Divider()
                .padding(.bottom, 20)
            footer
        }
        .padding(36)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func permissionStep(_ permission: PermissionKind) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("STEP \(completedCount + 1) OF \(PermissionKind.allCases.count)")
                .font(.caption.weight(.medium))
                .tracking(0.6)
                .foregroundStyle(.secondary)

            Image(systemName: symbol(for: permission))
                .font(.system(size: 30, weight: .regular))
                .symbolRenderingMode(.monochrome)
                .padding(.top, 28)
                .accessibilityHidden(true)

            Text(permission.title)
                .font(.title.weight(.semibold))
                .padding(.top, 18)
            Text(permission.explanation)
                .font(.title3)
                .foregroundStyle(.secondary)
                .padding(.top, 6)

            Divider()
                .padding(.vertical, 24)

            Text("What to do")
                .font(.headline)
            Text(instructions(for: permission))
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
            Text(detail(for: permission))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 7)

            if permission == .screenRecording,
               model.requestedPermissions.contains(.screenRecording),
               !model.screenRecordingGranted {
                Button("Show this copy of Nubo in Finder") {
                    model.revealCurrentAppInFinder()
                }
                .buttonStyle(.link)
                .padding(.top, 14)
            }

            if permission == .screenRecording, model.screenRecordingMayNeedRelaunch {
                Label(
                    "macOS may quit Nubo after this permission changes. Reopen it to continue here.",
                    systemImage: "arrow.clockwise"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 14)
            }

            if let statusMessage = model.permissionStatusMessage {
                Label(statusMessage, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)
            }

            if let errorMessage = model.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)
            }
        }
    }

    private var readyStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("SETUP COMPLETE")
                .font(.caption.weight(.medium))
                .tracking(0.6)
                .foregroundStyle(.secondary)

            Image(systemName: "checkmark")
                .font(.system(size: 32, weight: .medium))
                .padding(.top, 28)
                .accessibilityHidden(true)

            Text("This Mac is ready")
                .font(.title.weight(.semibold))
                .padding(.top, 18)
            Text("Nubo is available securely from the menu bar whenever this Mac is awake.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)

            Divider()
                .padding(.vertical, 24)

            VStack(alignment: .leading, spacing: 11) {
                readyRow("Screen Recording")
                readyRow("Accessibility")
                readyRow("Local Network")
            }
        }
    }

    private func readyRow(_ title: String) -> some View {
        Label(title, systemImage: "checkmark")
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()

            if let permission = currentPermission {
                Button(actionTitle(for: permission)) {
                    if model.requestedPermissions.contains(permission), permission != .localNetwork {
                        model.openSystemSettings(for: permission)
                    } else {
                        model.request(permission)
                    }
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: 8))
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            } else {
                Button("Start Using Nubo") {
                    model.finishOnboarding()
                    dismissWindow(id: "onboarding")
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: 8))
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
            "Your screen is shared only during an authorized connection. You can turn this permission off at any time."
        case .accessibility:
            "Allows your iPad’s keyboard and pointer to control this Mac. Every session is encrypted."
        case .localNetwork:
            "Makes this Mac visible to Nubo on your network. New iPads still need your approval."
        }
    }

    private func actionTitle(for permission: PermissionKind) -> String {
        if model.requestedPermissions.contains(permission) {
            return permission == .localNetwork ? "Try Again" : "Open System Settings"
        }
        return permission == .localNetwork ? "Start Local Service" : "Request Permission"
    }

    private func instructions(for permission: PermissionKind) -> String {
        switch permission {
        case .screenRecording: "1. Open Screen Recording settings.\n2. Turn on Nubo in the list.\n3. Return here, or reopen Nubo if macOS asks."
        case .accessibility: "1. Open Accessibility settings.\n2. Turn on Nubo in the list.\n3. Return here. We’ll check automatically."
        case .localNetwork: "Choose Start Local Service below. If macOS asks to find devices on your network, choose Allow."
        }
    }
}
