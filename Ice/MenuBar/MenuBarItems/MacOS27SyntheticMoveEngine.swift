//
//  MacOS27SyntheticMoveEngine.swift
//  Ice
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3
//

import Cocoa
import OSLog

/// Reorders a visible Accessibility-backed item through a synthetic Command-drag.
@available(macOS 27.0, *)
@MainActor
struct MacOS27SyntheticMoveEngine {
    private typealias EventError = MenuBarItemManager.EventError
    private typealias MoveDestination = MenuBarItemManager.MoveDestination

    private static let logger = Logger(category: "MacOS27SyntheticMoveEngine")
    private static let maximumAttempts = 2
    private static let menuBarHeight: CGFloat = 40
    private static let dropInset: CGFloat = 2

    let itemProvider: any MenuBarItemProviding
    let displayID: CGDirectDisplayID
    let eventSource: CGEventSource

    func move(
        item: MenuBarItem,
        to destination: MenuBarItemManager.MoveDestination
    ) async throws {
        guard
            MacOS27MenuBarMovementPolicy.canMoveSource(item),
            MacOS27MenuBarMovementPolicy.canUseAsTarget(destination.targetItem)
        else {
            throw EventError.itemNotMovable(item)
        }

        var liveItems = try await enumerateItems()
        let initialSource = try resolve(item, in: liveItems)
        let initialTarget = try resolve(destination.targetItem, in: liveItems)
        try validateCapabilities(source: initialSource, target: initialTarget)
        logOrder(
            prefix: "Movement order before",
            items: verificationItems(in: liveItems, target: initialTarget)
        )

        if try destinationIsSatisfied(
            item: initialSource,
            destination: destination.replacingTarget(with: initialTarget),
            in: liveItems
        ) {
            Self.logger.info("Requested synthetic menu bar order is already satisfied")
            return
        }

        for attempt in 1...Self.maximumAttempts {
            try Task.checkCancellation()

            let sourceItem = try resolve(item, in: liveItems)
            let targetItem = try resolve(destination.targetItem, in: liveItems)
            try validateCapabilities(source: sourceItem, target: targetItem)
            let liveDestination = destination.replacingTarget(with: targetItem)
            let points = try dragPoints(
                source: sourceItem,
                destination: liveDestination,
                liveItems: liveItems,
                attempt: attempt
            )

            Self.logger.info(
                """
                Synthetic drag attempt; attempt=\(attempt, privacy: .public), sourceFrame=\(String(describing: sourceItem.bounds), privacy: .public), targetFrame=\(String(describing: targetItem.bounds), privacy: .public), start=\(String(describing: points.start), privacy: .public), end=\(String(describing: points.end), privacy: .public)
                """
            )
            Self.logger.debug("Synthetic Command-drag event dispatch started")
            try await postCommandDrag(from: points.start, to: points.end)
            Self.logger.debug("Synthetic Command-drag event dispatch finished")

            let settleStart = ContinuousClock.now
            try await Task.sleep(for: .milliseconds(250))
            liveItems = try await enumerateItems()
            let settledSource = try resolve(item, in: liveItems)
            let settledTarget = try resolve(destination.targetItem, in: liveItems)
            let settledDestination = destination.replacingTarget(with: settledTarget)
            let settledDuration = settleStart.duration(to: .now)
            let order = verificationItems(in: liveItems, target: settledTarget)
            logOrder(prefix: "Movement order after attempt \(attempt)", items: order)

            let verified = try destinationIsSatisfied(
                item: settledSource,
                destination: settledDestination,
                in: liveItems
            )
            Self.logger.info(
                """
                Synthetic move verification; attempt=\(attempt, privacy: .public), enumeratedItems=\(liveItems.count, privacy: .public), settleDuration=\(String(describing: settledDuration), privacy: .public), verified=\(verified, privacy: .public), retry=\(!verified && attempt < Self.maximumAttempts, privacy: .public)
                """
            )
            if verified {
                return
            }
        }

        Self.logger.error("Synthetic menu bar move failed after two fresh-coordinate attempts")
        throw EventError.moveVerificationFailed
    }

    private func enumerateItems() async throws -> [MenuBarItem] {
        let snapshot = await itemProvider.menuBarItems(
            on: displayID,
            option: [.onScreen, .activeSpace]
        )
        guard snapshot.outcome == .loaded else {
            let message = snapshot.diagnosticMessage ?? "Accessibility enumeration did not load."
            Self.logger.error(
                "Fresh AX snapshot failed; outcome=\(snapshot.outcome.logString, privacy: .public), reason=\(message, privacy: .public)"
            )
            throw EventError.invalidAccessibilitySnapshot(message)
        }
        Self.logger.debug(
            "Fresh AX snapshot loaded; displayID=\(displayID, privacy: .public), items=\(snapshot.items.count, privacy: .public)"
        )
        return snapshot.items
    }

    private func resolve(
        _ staleItem: MenuBarItem,
        in liveItems: [MenuBarItem]
    ) throws -> MenuBarItem {
        guard
            let staleIdentity = staleItem.accessibilityIdentity,
            !staleIdentity.isAmbiguous
        else {
            throw EventError.ambiguousItemIdentity(staleItem)
        }

        let exactMatches = liveItems.filter { $0.tag == staleItem.tag }
        if exactMatches.count == 1, let match = exactMatches.first {
            guard match.accessibilityIdentity?.isAmbiguous == false else {
                throw EventError.ambiguousItemIdentity(staleItem)
            }
            return match
        }
        if exactMatches.count > 1 {
            throw EventError.ambiguousItemIdentity(staleItem)
        }

        let stableMatches = liveItems.filter { candidate in
            guard let identity = candidate.accessibilityIdentity else {
                return false
            }
            return identity.namespace == staleIdentity.namespace &&
            identity.stableIdentity == staleIdentity.stableIdentity
        }
        guard !stableMatches.isEmpty else {
            throw EventError.missingItemBounds(staleItem)
        }

        if let sourcePID = staleItem.sourcePID {
            let pidMatches = stableMatches.filter { $0.sourcePID == sourcePID }
            if pidMatches.count == 1, let match = pidMatches.first {
                return match
            }
            if pidMatches.count > 1 {
                throw EventError.ambiguousItemIdentity(staleItem)
            }
        }

        if stableMatches.count == 1, let match = stableMatches.first {
            return match
        }

        // Duplicate base identities are deliberately not resolved by frame.
        // Their instance indices can change when macOS changes the live order.
        throw EventError.ambiguousItemIdentity(staleItem)
    }

    private func validateCapabilities(
        source: MenuBarItem,
        target: MenuBarItem
    ) throws {
        guard MacOS27MenuBarMovementPolicy.canMoveSource(source) else {
            throw EventError.itemNotMovable(source)
        }
        guard MacOS27MenuBarMovementPolicy.canUseAsTarget(target) else {
            throw EventError.itemNotMovable(target)
        }
    }

    private func dragPoints(
        source: MenuBarItem,
        destination: MoveDestination,
        liveItems: [MenuBarItem],
        attempt: Int
    ) throws -> (start: CGPoint, end: CGPoint) {
        let target = destination.targetItem
        let displayBounds = CGDisplayBounds(displayID)
        let menuBarBand = CGRect(
            x: displayBounds.minX,
            y: displayBounds.minY,
            width: displayBounds.width,
            height: min(Self.menuBarHeight, displayBounds.height)
        )
        let start = CGPoint(x: source.bounds.midX, y: source.bounds.midY)
        // The cursor starts at the source center. Dropping just outside the
        // target edge leaves half of the source overlapping the target, which
        // macOS 27's MenuBarAgent rejects. Place the complete source frame on
        // the requested side instead, and move the retry slightly farther.
        let retryInset = attempt > 1 ? Self.dropInset * 2 : 0
        let sourceHalfWidth = source.bounds.width / 2
        let dropX: CGFloat = switch destination {
        case .leftOfItem:
            target.bounds.minX - sourceHalfWidth - Self.dropInset - retryInset
        case .rightOfItem:
            target.bounds.maxX + sourceHalfWidth + Self.dropInset + retryInset
        }
        let end = CGPoint(
            x: dropX,
            y: target.bounds.midY
        )

        let sourceDisplay = displayContaining(point: start)
        let targetDisplay = displayContaining(point: CGPoint(
            x: target.bounds.midX,
            y: target.bounds.midY
        ))
        let visibleCandidates = liveItems.filter { candidate in
            candidate.isOnScreen &&
            MacOS27MenuBarMovementPolicy.hasValidFrame(candidate.bounds) &&
            menuBarBand.intersects(candidate.bounds)
        }
        let minimumStatusItemX = visibleCandidates.map(\.bounds.minX).min() ?? menuBarBand.minX
        let maximumStatusItemX = visibleCandidates.map(\.bounds.maxX).max() ?? menuBarBand.maxX

        guard
            sourceDisplay == displayID,
            targetDisplay == displayID,
            menuBarBand.contains(start),
            menuBarBand.contains(end),
            end.x >= minimumStatusItemX - sourceHalfWidth - Self.dropInset - retryInset,
            end.x <= maximumStatusItemX + sourceHalfWidth + Self.dropInset + retryInset
        else {
            Self.logger.error(
                """
                Unsafe synthetic drag geometry; displayID=\(displayID, privacy: .public), sourceDisplay=\(sourceDisplay ?? 0, privacy: .public), targetDisplay=\(targetDisplay ?? 0, privacy: .public), displayFrame=\(String(describing: displayBounds), privacy: .public), start=\(String(describing: start), privacy: .public), end=\(String(describing: end), privacy: .public)
                """
            )
            throw EventError.invalidMoveGeometry
        }
        return (start, end)
    }

    private func displayContaining(point: CGPoint) -> CGDirectDisplayID? {
        var displayCount: UInt32 = 0
        var displayID: CGDirectDisplayID = 0
        let error = CGGetDisplaysWithPoint(point, 1, &displayID, &displayCount)
        guard error == .success, displayCount == 1 else {
            return nil
        }
        return displayID
    }

    private func verificationItems(
        in liveItems: [MenuBarItem],
        target: MenuBarItem
    ) -> [MenuBarItem] {
        liveItems
            .filter { candidate in
                MacOS27MenuBarMovementPolicy.canMoveSource(candidate) ||
                candidate.hasSameStableIdentity(as: target)
            }
            .sorted { lhs, rhs in
                if lhs.bounds.midX == rhs.bounds.midX {
                    return lhs.tag.description < rhs.tag.description
                }
                return lhs.bounds.midX < rhs.bounds.midX
            }
    }

    private func destinationIsSatisfied(
        item: MenuBarItem,
        destination: MoveDestination,
        in liveItems: [MenuBarItem]
    ) throws -> Bool {
        let order = verificationItems(in: liveItems, target: destination.targetItem)
        guard
            let sourceIndex = order.firstIndex(where: { $0.hasSameStableIdentity(as: item) }),
            let targetIndex = order.firstIndex(where: {
                $0.hasSameStableIdentity(as: destination.targetItem)
            })
        else {
            throw EventError.invalidAccessibilitySnapshot(
                "The source or target was missing from the sortable AX order."
            )
        }
        return switch destination {
        case .leftOfItem:
            sourceIndex == targetIndex - 1
        case .rightOfItem:
            sourceIndex == targetIndex + 1
        }
    }

    private func postCommandDrag(from start: CGPoint, to end: CGPoint) async throws {
        var didPostMouseDown = false
        var didPostMouseUp = false
        var lastLocation = start
        defer {
            if didPostMouseDown && !didPostMouseUp {
                Self.postBestEffortMouseUp(
                    at: lastLocation,
                    source: eventSource
                )
            }
        }

        try post(type: .mouseMoved, at: start)
        await noncancellableSleep(for: .milliseconds(30))
        try post(type: .leftMouseDown, at: start)
        didPostMouseDown = true
        await noncancellableSleep(for: .milliseconds(60))

        let steps = 24
        for index in 1...steps {
            let progress = CGFloat(index) / CGFloat(steps)
            lastLocation = CGPoint(
                x: start.x + (end.x - start.x) * progress,
                y: start.y + (end.y - start.y) * progress
            )
            try post(type: .leftMouseDragged, at: lastLocation)
            await noncancellableSleep(for: .milliseconds(16))
        }

        // Give MenuBarAgent time to display and commit its insertion point
        // before ending the gesture.
        await noncancellableSleep(for: .milliseconds(100))
        try post(type: .leftMouseUp, at: end)
        didPostMouseUp = true
        await noncancellableSleep(for: .milliseconds(40))
    }

    private func post(type: CGEventType, at location: CGPoint) throws {
        guard let event = CGEvent(
            mouseEventSource: eventSource,
            mouseType: type,
            mouseCursorPosition: location,
            mouseButton: .left
        ) else {
            throw EventError.cannotComplete
        }
        event.flags = .maskCommand
        event.post(tap: .cghidEventTap)
    }

    private func noncancellableSleep(for duration: Duration) async {
        let task = Task {
            try? await Task.sleep(for: duration)
        }
        await task.value
    }

    private static func postBestEffortMouseUp(
        at location: CGPoint,
        source: CGEventSource
    ) {
        guard let event = CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseUp,
            mouseCursorPosition: location,
            mouseButton: .left
        ) else {
            logger.error("Failed to create best-effort synthetic mouse-up")
            return
        }
        event.flags = .maskCommand
        event.post(tap: .cghidEventTap)
        logger.info("Posted best-effort synthetic mouse-up during cleanup")
    }

    private func logOrder(prefix: String, items: [MenuBarItem]) {
        let order = items.map { item in
            guard let identity = item.accessibilityIdentity else {
                return item.tag.description
            }
            return "\(identity.namespace):\(identity.stableIdentity)"
        }
        .joined(separator: " -> ")
        Self.logger.info("\(prefix, privacy: .public): \(order, privacy: .public)")
    }
}

@available(macOS 27.0, *)
private extension MenuBarItem {
    func hasSameStableIdentity(as other: MenuBarItem) -> Bool {
        guard
            let lhs = accessibilityIdentity,
            let rhs = other.accessibilityIdentity,
            !lhs.isAmbiguous,
            !rhs.isAmbiguous,
            lhs.namespace == rhs.namespace,
            lhs.stableIdentity == rhs.stableIdentity
        else {
            return false
        }
        if let sourcePID, let otherSourcePID = other.sourcePID {
            return sourcePID == otherSourcePID
        }
        return true
    }
}

private extension MenuBarItemManager.MoveDestination {
    func replacingTarget(
        with target: MenuBarItem
    ) -> MenuBarItemManager.MoveDestination {
        switch self {
        case .leftOfItem:
            .leftOfItem(target)
        case .rightOfItem:
            .rightOfItem(target)
        }
    }
}

private extension MenuBarItemSnapshot.Outcome {
    var logString: String {
        switch self {
        case .loaded: "loaded"
        case .empty: "empty"
        case .permissionMissing: "permissionMissing"
        case .failed: "failed"
        }
    }
}
