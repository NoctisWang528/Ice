//
//  MenuBarItemMovementProvider.swift
//  Ice
//

import Cocoa
import OSLog

/// An operating-system-specific backend for physical menu bar item movement.
@MainActor
protocol MenuBarItemMovementProviding: Sendable {
    func canMove(
        item: MenuBarItem,
        from sourceSection: MenuBarSection.Name,
        to targetSection: MenuBarSection.Name
    ) -> Bool

    func canUseAsTarget(
        item: MenuBarItem,
        for sourceItem: MenuBarItem,
        from sourceSection: MenuBarSection.Name,
        to targetSection: MenuBarSection.Name
    ) -> Bool

    func move(
        item: MenuBarItem,
        to destination: MenuBarItemManager.MoveDestination
    ) async throws
}

/// Selects the movement backend once, outside of the layout interface.
@MainActor
enum MenuBarItemMovementProviderFactory {
    static func makeProvider(
        manager: MenuBarItemManager
    ) -> any MenuBarItemMovementProviding {
        if #available(macOS 27.0, *) {
            MacOS27SyntheticMovementProvider(manager: manager)
        } else {
            LegacyWindowMovementProvider(manager: manager)
        }
    }
}

/// Preserves Ice's WindowServer movement implementation on macOS 14–26.
@MainActor
private final class LegacyWindowMovementProvider: MenuBarItemMovementProviding {
    private weak var manager: MenuBarItemManager?

    init(manager: MenuBarItemManager) {
        self.manager = manager
    }

    func canMove(
        item: MenuBarItem,
        from sourceSection: MenuBarSection.Name,
        to targetSection: MenuBarSection.Name
    ) -> Bool {
        _ = sourceSection
        _ = targetSection
        return item.isMovable
    }

    func canUseAsTarget(
        item: MenuBarItem,
        for sourceItem: MenuBarItem,
        from sourceSection: MenuBarSection.Name,
        to targetSection: MenuBarSection.Name
    ) -> Bool {
        _ = sourceItem
        _ = sourceSection
        _ = targetSection
        return item.isMovable
    }

    func move(
        item: MenuBarItem,
        to destination: MenuBarItemManager.MoveDestination
    ) async throws {
        guard let manager else {
            throw MenuBarItemManager.EventError.cannotComplete
        }
        try await manager.moveLegacyWindowItem(item: item, to: destination)
    }
}

/// Restrictive capability policy for macOS 27 Accessibility items.
@available(macOS 27.0, *)
enum MacOS27MenuBarMovementPolicy {
    private static let menuBarAgentBundleIdentifier = "com.apple.MenuBarAgent"

    static func canMoveSource(_ item: MenuBarItem) -> Bool {
        guard
            !item.hasRealWindowID,
            item.tag.isMovable,
            item.isOnScreen,
            hasValidFrame(item.bounds),
            !item.isControlItem,
            !item.isSystemClone,
            let identity = item.accessibilityIdentity,
            !identity.isAmbiguous,
            !identity.isMenuBarAgentPublisher,
            !isUnsafeIdentity(identity),
            let publisher = identity.publisherBundleIdentifier,
            publisher != Constants.bundleIdentifier,
            publisher.caseInsensitiveCompare(menuBarAgentBundleIdentifier) != .orderedSame,
            !publisher.lowercased().hasPrefix("com.apple.")
        else {
            return false
        }
        return true
    }

    static func canUseAsTarget(_ item: MenuBarItem) -> Bool {
        guard
            !item.hasRealWindowID,
            item.isOnScreen,
            hasValidFrame(item.bounds),
            !item.isSystemClone,
            let identity = item.accessibilityIdentity,
            !identity.isAmbiguous,
            !isUnsafeIdentity(identity)
        else {
            return false
        }
        if item.isControlItem {
            return item.tag == .visibleControlItem
        }
        return true
    }

    static func hasValidFrame(_ frame: CGRect) -> Bool {
        frame.origin.x.isFinite &&
        frame.origin.y.isFinite &&
        frame.width.isFinite &&
        frame.height.isFinite &&
        frame.width > 0 &&
        frame.height > 0 &&
        frame.height <= 40
    }

    private static func isUnsafeIdentity(
        _ identity: MenuBarItem.AccessibilityIdentity
    ) -> Bool {
        let trimmed = identity.stableIdentity
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()
        if trimmed == "AXOverflowButton" ||
            lowercased.contains("liveactivity") ||
            lowercased.contains("audio video") ||
            lowercased.contains("audiovideomodule") ||
            lowercased.contains("screencapture")
        {
            return true
        }
        let isGenericItem = trimmed.range(
            of: #"^Item-[0-9]+$"#,
            options: .regularExpression
        ) != nil
        let publisher = identity.publisherBundleIdentifier?.lowercased()
        if isGenericItem && (
            identity.isMenuBarAgentPublisher ||
            publisher?.hasPrefix("com.apple.") == true
        ) {
            return true
        }
        let overflowCharacters = CharacterSet(charactersIn: "<>‹›«»")
        return !trimmed.isEmpty &&
        trimmed.unicodeScalars.allSatisfy { overflowCharacters.contains($0) }
    }
}

/// Executes physical Command-drags for safe macOS 27 Visible items.
@available(macOS 27.0, *)
@MainActor
private final class MacOS27SyntheticMovementProvider: MenuBarItemMovementProviding {
    private weak var manager: MenuBarItemManager?
    private let logger = Logger(category: "MacOS27SyntheticMovementProvider")

    init(manager: MenuBarItemManager) {
        self.manager = manager
    }

    func canMove(
        item: MenuBarItem,
        from sourceSection: MenuBarSection.Name,
        to targetSection: MenuBarSection.Name
    ) -> Bool {
        guard
            sourceSection == .visible,
            targetSection == .visible,
            manager?.isApplyingMenuBarMove == false
        else {
            return false
        }
        return MacOS27MenuBarMovementPolicy.canMoveSource(item)
    }

    func canUseAsTarget(
        item: MenuBarItem,
        for sourceItem: MenuBarItem,
        from sourceSection: MenuBarSection.Name,
        to targetSection: MenuBarSection.Name
    ) -> Bool {
        guard
            item != sourceItem,
            sourceSection == .visible,
            targetSection == .visible,
            manager?.isApplyingMenuBarMove == false
        else {
            return false
        }
        return MacOS27MenuBarMovementPolicy.canUseAsTarget(item)
    }

    func move(
        item: MenuBarItem,
        to destination: MenuBarItemManager.MoveDestination
    ) async throws {
        guard
            let manager,
            let sourceSection = manager.itemCache.address(for: item.tag)?.section,
            let targetSection = manager.itemCache.address(for: destination.targetItem.tag)?.section,
            canMove(item: item, from: sourceSection, to: targetSection),
            canUseAsTarget(
                item: destination.targetItem,
                for: item,
                from: sourceSection,
                to: targetSection
            )
        else {
            throw MenuBarItemManager.EventError.itemNotMovable(item)
        }

        manager.setApplyingMenuBarMove(true)
        defer {
            manager.setApplyingMenuBarMove(false)
        }

        let result: Result<Void, Error>
        do {
            try await performProtectedMove(
                manager: manager,
                item: item,
                destination: destination
            )
            result = .success(())
        } catch {
            result = .failure(error)
        }

        logger.info("Forcing menu bar recache after synthetic move attempt")
        await manager.refreshAfterSyntheticMove()
        logger.info("Synthetic move recache and glyph refresh finished")

        switch result {
        case .success:
            logger.info("Synthetic menu bar move completed and recached successfully")
            return
        case .failure(let error):
            logger.error(
                "Synthetic menu bar move failed; reason=\(error.localizedDescription, privacy: .public), forcedRecache=true"
            )
            throw error
        }
    }

    private func performProtectedMove(
        manager: MenuBarItemManager,
        item: MenuBarItem,
        destination: MenuBarItemManager.MoveDestination
    ) async throws {
        try await manager.eventSemaphore.waitUnlessCancelled()
        defer {
            manager.eventSemaphore.signal()
        }

        try await manager.waitForUserToPauseInput()
        guard
            let appState = manager.appState,
            let mouseLocation = MouseHelpers.locationCoreGraphics
        else {
            throw MenuBarItemManager.EventError.missingMouseLocation
        }

        appState.hidEventManager.stopAll()
        logger.debug("Stopped HIDEventManager for synthetic move")
        defer {
            appState.hidEventManager.startAll()
            logger.info("Restored HIDEventManager after synthetic move")
        }

        try await manager.waitForMoveOperationBuffer()
        guard let displayID = manager.itemCache.displayID ?? Bridging.getActiveMenuBarDisplayID() else {
            throw MenuBarItemManager.EventError.invalidMoveGeometry
        }

        guard let eventSource = CGEventSource(stateID: .combinedSessionState) else {
            throw MenuBarItemManager.EventError.invalidEventSource
        }

        manager.markMoveOperation()
        MouseHelpers.hideCursor()
        defer {
            MouseHelpers.warpCursor(to: mouseLocation)
            MouseHelpers.showCursor()
            manager.markMoveOperation()
            logger.info("Restored cursor after synthetic move")
        }

        logger.info(
            """
            Starting synthetic movement; backend=macOS27Accessibility, source=\(item.stableIdentityLogString, privacy: .public), target=\(destination.targetItem.stableIdentityLogString, privacy: .public), sourceNamespace=\(item.accessibilityIdentity?.namespace ?? "nil", privacy: .public), targetNamespace=\(destination.targetItem.accessibilityIdentity?.namespace ?? "nil", privacy: .public), sourcePID=\(item.sourcePID ?? item.ownerPID, privacy: .public), targetPID=\(destination.targetItem.sourcePID ?? destination.targetItem.ownerPID, privacy: .public), displayID=\(displayID, privacy: .public)
            """
        )

        let engine = MacOS27SyntheticMoveEngine(
            itemProvider: manager.itemProvider,
            displayID: displayID,
            eventSource: eventSource
        )
        try await engine.move(item: item, to: destination)
    }
}

// MARK: - MenuBarItemManager Movement Interface

extension MenuBarItemManager {
    func canMove(item: MenuBarItem) -> Bool {
        guard let section = itemCache.address(for: item.tag)?.section else {
            return false
        }
        return canMove(item: item, from: section, to: section)
    }

    func canMove(
        item: MenuBarItem,
        from sourceSection: MenuBarSection.Name,
        to targetSection: MenuBarSection.Name
    ) -> Bool {
        movementProvider?.canMove(
            item: item,
            from: sourceSection,
            to: targetSection
        ) ?? item.isMovable
    }

    func canUseAsMoveTarget(
        item: MenuBarItem,
        for sourceItem: MenuBarItem,
        from sourceSection: MenuBarSection.Name,
        to targetSection: MenuBarSection.Name
    ) -> Bool {
        movementProvider?.canUseAsTarget(
            item: item,
            for: sourceItem,
            from: sourceSection,
            to: targetSection
        ) ?? item.isMovable
    }

    func move(item: MenuBarItem, to destination: MoveDestination) async throws {
        guard let movementProvider else {
            throw EventError.cannotComplete
        }
        try await movementProvider.move(item: item, to: destination)
    }
}

private extension MenuBarItem {
    var stableIdentityLogString: String {
        accessibilityIdentity?.stableIdentity ?? tag.description
    }
}
