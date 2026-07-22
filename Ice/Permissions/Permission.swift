//
//  Permission.swift
//  Ice
//

import Combine
import Cocoa

// MARK: - Permission

/// An object that encapsulates the behavior of checking for and requesting
/// a specific permission for the app.
@MainActor
class Permission: ObservableObject, Identifiable {
    /// A Boolean value that indicates whether the app has this permission.
    @Published private(set) var hasPermission = false

    /// The title of the permission.
    let title: String

    /// Descriptive details for the permission.
    let details: [String]

    /// A Boolean value that indicates if the app can work without this permission.
    let isRequired: Bool

    /// The URL of the settings pane to open.
    private let settingsURL: URL?

    /// The function that checks permissions.
    private let check: () -> Bool

    /// The function that requests permissions.
    private let request: () -> Void

    /// Observer that runs on a timer to check permissions.
    private var timerCancellable: AnyCancellable?

    /// Observer that observes the ``hasPermission`` property.
    private var hasPermissionCancellable: AnyCancellable?

    /// Creates a permission.
    ///
    /// - Parameters:
    ///   - title: The title of the permission.
    ///   - details: Descriptive details for the permission.
    ///   - isRequired: A Boolean value that indicates if the app can work without this permission.
    ///   - settingsURL: The URL of the settings pane to open.
    ///   - check: A function that checks permissions.
    ///   - request: A function that requests permissions.
    init(
        title: String,
        details: [String],
        isRequired: Bool,
        settingsURL: URL?,
        check: @escaping () -> Bool,
        request: @escaping () -> Void
    ) {
        self.title = title
        self.details = details
        self.isRequired = isRequired
        self.settingsURL = settingsURL
        self.check = check
        self.request = request
        self.hasPermission = check()
        configureCancellables()
    }

    /// Sets up the internal observers for the permission.
    private func configureCancellables() {
        timerCancellable?.cancel()
        timerCancellable = nil

        timerCancellable = Timer.publish(every: 1, on: .main, in: .default)
            .autoconnect()
            .merge(with: Just(.now))
            .sink { [weak self] _ in
                guard let self else {
                    return
                }
                refreshPermission()
            }
    }

    /// Refreshes and returns the current permission result.
    @discardableResult
    func refreshPermission() -> Bool {
        let result = check()
        hasPermission = result
        return result
    }

    /// Performs the request and opens the System Settings app to the appropriate pane.
    func performRequest() {
        request()
        if let settingsURL {
            NSWorkspace.shared.open(settingsURL)
        }
    }

    /// Asynchronously waits for the app to be granted this permission.
    func waitForPermission() async {
        configureCancellables()
        guard !hasPermission else {
            return
        }
        return await withCheckedContinuation { continuation in
            hasPermissionCancellable?.cancel()
            hasPermissionCancellable = $hasPermission.sink { [weak self] hasPermission in
                guard let self else {
                    continuation.resume()
                    return
                }
                if hasPermission {
                    hasPermissionCancellable?.cancel()
                    continuation.resume()
                }
            }
        }
    }

    /// Stops running the permission check.
    func stopCheck() {
        timerCancellable?.cancel()
        timerCancellable = nil
        hasPermissionCancellable?.cancel()
        hasPermissionCancellable = nil
    }
}

// MARK: - AccessibilityPermission

final class AccessibilityPermission: Permission {
    init() {
        super.init(
            title: "Accessibility",
            details: [
                "Get real-time information about the menu bar.",
                "Arrange menu bar items.",
            ],
            isRequired: true,
            settingsURL: nil,
            check: {
                AXHelpers.isProcessTrusted()
            },
            request: {
                AXHelpers.isProcessTrusted(prompt: true)
            }
        )
    }
}

// MARK: - ScreenRecordingPermission

final class ScreenRecordingPermission: Permission {
    /// The detailed screen capture authorization state.
    @Published private(set) var authorizationState = ScreenCaptureAuthorizationState.notDetermined

    /// A Boolean value that indicates whether a permission request is running.
    @Published private(set) var isRequesting = false

    /// A Boolean value that indicates whether a request was made in this process.
    ///
    /// Public screen capture APIs cannot distinguish a first request from a
    /// previous denial. This in-memory value only improves the distinction for
    /// the lifetime of the current process and intentionally is not persisted.
    private var hasRequestedPermission = false

    /// The most recent result from `CGRequestScreenCaptureAccess`, when used.
    private var lastRequestResult: Bool?

    /// Observer that keeps the detailed state in sync with `hasPermission`.
    private var permissionCancellable: AnyCancellable?

    /// Observer that refreshes permission as soon as the app becomes active.
    private var appDidBecomeActiveCancellable: AnyCancellable?

    /// The current capture capability validation task.
    private var validationTask: Task<Void, Never>?

    init() {
        super.init(
            title: "Screen Recording",
            details: [
                "Change the menu bar's appearance.",
                "Display images of individual menu bar items.",
            ],
            isRequired: false,
            settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"),
            check: {
                ScreenCapture.cachedCheckPermissions(reset: true)
            },
            request: {}
        )

        permissionCancellable = $hasPermission
            .removeDuplicates()
            .sink { [weak self] hasPermission in
                self?.updateAuthorizationState(hasPermission: hasPermission)
            }

        appDidBecomeActiveCancellable = NotificationCenter.default
            .publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleAppDidBecomeActive()
            }

        if hasPermission {
            startCaptureValidation()
        }
    }

    deinit {
        validationTask?.cancel()
    }

    /// Performs a user-initiated screen capture permission request.
    override func performRequest() {
        guard !isRequesting else {
            return
        }

        guard ScreenCapture.isAuthorizationAvailable else {
            setAuthorizationState(.unavailable)
            return
        }

        isRequesting = true
        hasRequestedPermission = true

        Task { [weak self] in
            let request = await ScreenCapture.requestPermissions()
            guard let self else {
                return
            }

            lastRequestResult = request.requestResult
            let hasPermission = refreshPermission()

            if hasPermission {
                setAuthorizationState(.granted)
                startCaptureValidation()
            } else if request.requestResult == true {
                setAuthorizationState(.restartRequired)
            } else {
                setAuthorizationState(.denied)
                ScreenCapture.openSystemSettings()
            }

            isRequesting = false
        }
    }

    /// Refreshes permission immediately after the app returns to the foreground.
    private func handleAppDidBecomeActive() {
        let hasPermission = refreshPermission()
        ScreenCapture.logPermissionResultWhenAppBecomesActive(hasPermission)
        updateAuthorizationState(hasPermission: hasPermission)

        if hasPermission {
            startCaptureValidation()
        }
    }

    /// Updates the detailed state from the primary permission result.
    private func updateAuthorizationState(hasPermission: Bool) {
        guard ScreenCapture.isAuthorizationAvailable else {
            setAuthorizationState(.unavailable)
            return
        }

        if hasPermission {
            setAuthorizationState(.granted)
        } else if lastRequestResult == true {
            setAuthorizationState(.restartRequired)
        } else if hasRequestedPermission {
            setAuthorizationState(.denied)
        } else {
            setAuthorizationState(.notDetermined)
        }
    }

    /// Performs a diagnostic ScreenCaptureKit query after TCC reports access.
    private func startCaptureValidation() {
        validationTask?.cancel()
        validationTask = Task { [weak self] in
            let succeeded = await ScreenCapture.validateCaptureAccess()
            guard let self, !Task.isCancelled else {
                return
            }

            if succeeded {
                setAuthorizationState(.granted)
            } else {
                setAuthorizationState(.restartRequired)
            }
        }
    }

    /// Updates the authorization state and logs restart requirements.
    private func setAuthorizationState(_ state: ScreenCaptureAuthorizationState) {
        authorizationState = state
        ScreenCapture.logRestartRequired(state == .restartRequired)
    }
}
