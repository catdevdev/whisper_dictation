import AppKit
import ApplicationServices
import AVFoundation
import Foundation

public enum PermissionKind: CaseIterable, Sendable {
    case microphone
    case accessibility
    /// Optional recovery path on Macs where TCC refuses the listen-only tap
    /// even after Accessibility is granted. It is never a readiness gate.
    case inputMonitoring
}

public enum PermissionState: Equatable, Sendable {
    case notDetermined
    case granted
    case denied
    case restricted
}

/// Centralizes macOS privacy checks, prompts, and System Settings deep links.
@MainActor
public struct PermissionCenter {
    public init() {}

    public func status(for permission: PermissionKind) -> PermissionState {
        switch permission {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .notDetermined: .notDetermined
            case .authorized: .granted
            case .denied: .denied
            case .restricted: .restricted
            @unknown default: .denied
            }
        case .accessibility:
            AXIsProcessTrusted() ? .granted : .denied
        case .inputMonitoring:
            CGPreflightListenEventAccess() ? .granted : .denied
        }
    }

    /// Requests the selected permission and returns the immediately observable state.
    public func request(_ permission: PermissionKind) async -> PermissionState {
        switch permission {
        case .microphone:
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { allowed in
                    continuation.resume(returning: allowed)
                }
            }
            return granted ? .granted : status(for: .microphone)

        case .accessibility:
            // The imported SDK symbol is declared as mutable C global, which is not
            // concurrency-safe. Its documented CFString value is stable.
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options) ? .granted : .denied
        case .inputMonitoring:
            return CGRequestListenEventAccess() ? .granted : .denied
        }
    }

    /// Opens the corresponding Privacy & Security pane in System Settings.
    @discardableResult
    public func openSettings(for permission: PermissionKind) -> Bool {
        let pane: String
        switch permission {
        case .microphone:
            pane = "Privacy_Microphone"
        case .accessibility:
            pane = "Privacy_Accessibility"
        case .inputMonitoring:
            pane = "Privacy_ListenEvent"
        }

        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(pane)"
        ) else {
            return false
        }
        return NSWorkspace.shared.open(url)
    }

    public var microphone: PermissionState { status(for: .microphone) }
    public var accessibility: PermissionState { status(for: .accessibility) }
}
