//
//  ScreenCapture.swift
//  Ice
//

import AppKit
import CoreGraphics
import OSLog
import ScreenCaptureKit

/// The current screen capture authorization state.
enum ScreenCaptureAuthorizationState {
    case notDetermined
    case denied
    case granted
    case restartRequired
    case unavailable
}

/// A namespace for screen capture operations.
enum ScreenCapture {
    /// The result of requesting screen capture permission.
    struct PermissionRequestResult {
        /// The result returned by `CGRequestScreenCaptureAccess`, when used.
        let requestResult: Bool?

        /// The permission result immediately after the request completed.
        let permissionResult: Bool
    }

    /// Logger for screen capture operations.
    static let logger = Logger(category: "ScreenCapture")

    // MARK: Permissions

    /// A Boolean value that indicates whether the process has a stable identity
    /// that TCC can use for authorization.
    static var isAuthorizationAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.executableURL != nil
    }

    /// Returns a Boolean value that indicates whether the app has screen
    /// capture permissions.
    static func checkPermissions() -> Bool {
        logger.info("Screen capture permission check started")

        let operatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "Unavailable"
        let executablePath = Bundle.main.executableURL?.path ?? "Unavailable"
        logger.info("Operating system version: \(operatingSystemVersion, privacy: .public)")
        logger.info("Bundle identifier: \(bundleIdentifier, privacy: .public)")
        logger.info("Executable path: \(executablePath, privacy: .public)")

        let preflightResult = CGPreflightScreenCaptureAccess()
        logger.info("CGPreflightScreenCaptureAccess result: \(preflightResult, privacy: .public)")

        if #available(macOS 27.0, *) {
            return preflightResult
        }

        if preflightResult {
            return true
        }

        return legacyPermissionCheck()
    }

    /// Checks for screen capture permission using menu bar window metadata.
    ///
    /// This is a legacy fallback for macOS 14 through 26. Window titles are not
    /// a reliable indication of TCC authorization on macOS 27 and later.
    private static func legacyPermissionCheck() -> Bool {
        for windowID in Bridging.getMenuBarWindowList(option: [.itemsOnly, .activeSpace]) {
            guard
                let window = WindowInfo(windowID: windowID),
                window.owningApplication != .current // Skip windows we own.
            else {
                continue
            }
            if window.title != nil {
                return true
            }
        }
        return false
    }

    /// Returns a Boolean value that indicates whether the app has screen
    /// capture permissions.
    ///
    /// This function caches its initial result and returns it on subsequent
    /// calls. Pass `true` to the `reset` parameter to replace the cached
    /// result with a newly computed value.
    static func cachedCheckPermissions(reset: Bool = false) -> Bool {
        enum Context {
            static var cachedResult: Bool?
        }
        if !reset, let result = Context.cachedResult {
            return result
        }
        let result = checkPermissions()
        Context.cachedResult = result
        return result
    }

    /// Requests screen capture permissions and returns the immediate result.
    static func requestPermissions() async -> PermissionRequestResult {
        if #available(macOS 27.0, *) {
            let requestResult = CGRequestScreenCaptureAccess()
            logger.info("CGRequestScreenCaptureAccess result: \(requestResult, privacy: .public)")

            let permissionResult = CGPreflightScreenCaptureAccess()
            logger.info("Permission result immediately after request: \(permissionResult, privacy: .public)")
            return PermissionRequestResult(
                requestResult: requestResult,
                permissionResult: permissionResult
            )
        }

        if #available(macOS 15.0, *) {
            // CGRequestScreenCaptureAccess() is broken on macOS 15. We can
            // try accessing SCShareableContent to trigger a request if the
            // user doesn't have permissions.
            // Keep this compatibility behavior through macOS 26, but do not
            // use it as the source of truth for authorization.
            await requestPermissionsUsingShareableContent()
        } else {
            let requestResult = CGRequestScreenCaptureAccess()
            logger.info("CGRequestScreenCaptureAccess result: \(requestResult, privacy: .public)")

            let permissionResult = CGPreflightScreenCaptureAccess()
            logger.info("Permission result immediately after request: \(permissionResult, privacy: .public)")
            return PermissionRequestResult(
                requestResult: requestResult,
                permissionResult: permissionResult
            )
        }

        let permissionResult = CGPreflightScreenCaptureAccess()
        logger.info("Permission result immediately after request: \(permissionResult, privacy: .public)")
        return PermissionRequestResult(
            requestResult: nil,
            permissionResult: permissionResult
        )
    }

    /// Validates actual screen capture capability without saving any images.
    static func validateCaptureAccess() async -> Bool {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            logger.info("Capture validation succeeded")
            logShareableContentSuccess(content)
            return true
        } catch {
            logger.error("Capture validation failure")
            logShareableContentFailure(error)
            return false
        }
    }

    /// Opens the Screen Recording privacy pane, falling back to System Settings.
    @MainActor
    static func openSystemSettings() {
        let settingsURL = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        )
        let deepLinkOpened = settingsURL.map(NSWorkspace.shared.open) ?? false
        logger.info("System Settings deep link opened successfully: \(deepLinkOpened, privacy: .public)")

        guard !deepLinkOpened else {
            return
        }

        let applicationURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.systempreferences"
        )
        let systemSettingsOpened = applicationURL.map(NSWorkspace.shared.open) ?? false
        logger.info("System Settings fallback opened successfully: \(systemSettingsOpened, privacy: .public)")
    }

    /// Logs the permission result observed when the app becomes active.
    static func logPermissionResultWhenAppBecomesActive(_ result: Bool) {
        logger.info("Permission result when app becomes active: \(result, privacy: .public)")
    }

    /// Logs whether applying the current authorization requires a restart.
    static func logRestartRequired(_ required: Bool) {
        logger.info("Whether a restart is required: \(required, privacy: .public)")
    }

    /// Uses the macOS 15 through 26 compatibility request behavior.
    private static func requestPermissionsUsingShareableContent() async {
        await withCheckedContinuation { continuation in
            SCShareableContent.getWithCompletionHandler { content, error in
                if let content {
                    logShareableContentSuccess(content)
                } else if let error {
                    logShareableContentFailure(error)
                } else {
                    logger.error("SCShareableContent failure: no content or error returned")
                }
                continuation.resume()
            }
        }
    }

    /// Logs a successful shareable content query without logging window names.
    private static func logShareableContentSuccess(_ content: SCShareableContent) {
        logger.info("SCShareableContent success")
        logger.info("SCShareableContent displays count: \(content.displays.count, privacy: .public)")
        logger.info("SCShareableContent applications count: \(content.applications.count, privacy: .public)")
        logger.info("SCShareableContent windows count: \(content.windows.count, privacy: .public)")
    }

    /// Logs a failed shareable content query without treating it as a denial.
    private static func logShareableContentFailure(_ error: Error) {
        let nsError = error as NSError
        logger.error("SCShareableContent failure: \(error.localizedDescription, privacy: .public)")
        logger.error("SCShareableContent error domain: \(nsError.domain, privacy: .public)")
        logger.error("SCShareableContent error code: \(nsError.code, privacy: .public)")
    }

    // MARK: Capture Window(s)

    /// Captures a composite image of an array of windows.
    ///
    /// The windows are composited from front to back, according to the order
    /// of the `windowIDs` parameter.
    ///
    /// - Parameters:
    ///   - windowIDs: The identifiers of the windows to capture.
    ///   - screenBounds: The bounds to capture, specified in screen coordinates.
    ///     Pass `nil` to capture the minimum rectangle that encloses the windows.
    ///   - option: Options that specify which parts of the windows are captured.
    static func captureWindows(with windowIDs: [CGWindowID], screenBounds: CGRect? = nil, option: CGWindowImageOption = []) -> CGImage? {
        guard let array = Bridging.createCGWindowArray(with: windowIDs) else {
            return nil
        }
        let bounds = screenBounds ?? .null
        // ScreenCaptureKit doesn't support capturing images of offscreen menu bar
        // items, so we unfortunately have to use the deprecated CGWindowList API.
        return CGImage(windowListFromArrayScreenBounds: bounds, windowArray: array, imageOption: option)
    }

    /// Captures an image of a window.
    ///
    /// - Parameters:
    ///   - windowID: The identifier of the window to capture.
    ///   - screenBounds: The bounds to capture, specified in screen coordinates.
    ///     Pass `nil` to capture the minimum rectangle that encloses the window.
    ///   - option: Options that specify which parts of the window are captured.
    static func captureWindow(with windowID: CGWindowID, screenBounds: CGRect? = nil, option: CGWindowImageOption = []) -> CGImage? {
        captureWindows(with: [windowID], screenBounds: screenBounds, option: option)
    }
}
