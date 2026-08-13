import Combine
import Foundation
import ServiceManagement

/// Manages launch-at-login registration for the main application.
@MainActor
public final class LoginItemManager: ObservableObject {
    @Published public private(set) var isEnabled = false
    @Published public private(set) var requiresApproval = false

    private let service: SMAppService

    public init() {
        service = .mainApp
        refresh()
    }

    /// Refreshes published state from Service Management.
    public func refresh() {
        switch service.status {
        case .enabled:
            isEnabled = true
            requiresApproval = false
        case .requiresApproval:
            isEnabled = false
            requiresApproval = true
        case .notRegistered, .notFound:
            isEnabled = false
            requiresApproval = false
        @unknown default:
            isEnabled = false
            requiresApproval = false
        }
    }

    /// Registers or unregisters `SMAppService.mainApp`.
    public func setEnabled(_ enabled: Bool) throws {
        defer { refresh() }
        if enabled {
            guard service.status != .enabled else { return }
            try service.register()
        } else {
            guard service.status != .notRegistered,
                  service.status != .notFound else { return }
            try service.unregister()
        }
    }

    /// Opens the Login Items pane when macOS requires manual user approval.
    public func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
