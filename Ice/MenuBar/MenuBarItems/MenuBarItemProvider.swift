//
//  MenuBarItemProvider.swift
//  Ice
//

import AXSwift
import Cocoa
import OSLog

/// A snapshot returned by a menu bar item enumeration backend.
struct MenuBarItemSnapshot {
    enum Source: String {
        case legacyWindowServer
        case accessibility
    }

    enum Outcome {
        case loaded
        case empty
        case permissionMissing
        case failed
    }

    let items: [MenuBarItem]
    let source: Source
    let outcome: Outcome
    let diagnosticMessage: String?
}

/// A backend that enumerates menu bar items.
protocol MenuBarItemProviding: Sendable {
    var source: MenuBarItemSnapshot.Source { get }

    func menuBarItems(
        on display: CGDirectDisplayID?,
        option: MenuBarItem.ListOption
    ) async -> MenuBarItemSnapshot
}

/// Selects the enumeration backend appropriate for the current operating
/// system without leaking availability checks into menu bar business logic.
enum MenuBarItemProvider {
    static func current() -> any MenuBarItemProviding {
        if #available(macOS 27.0, *) {
            MacOS27AccessibilityMenuBarItemProvider()
        } else {
            LegacyWindowServerMenuBarItemProvider()
        }
    }
}

/// The WindowServer-backed provider used by macOS 14 through macOS 26.
struct LegacyWindowServerMenuBarItemProvider: MenuBarItemProviding {
    let source = MenuBarItemSnapshot.Source.legacyWindowServer

    private let logger = Logger(category: "LegacyMenuBarItemProvider")

    func menuBarItems(
        on display: CGDirectDisplayID?,
        option: MenuBarItem.ListOption
    ) async -> MenuBarItemSnapshot {
        logger.info(
            """
            Legacy menu bar enumeration started; macOS=\(ProcessInfo.processInfo.operatingSystemVersionString, privacy: .public)
            """
        )

        let items = await MenuBarItem.getLegacyMenuBarItems(on: display, option: option)
        let sourcePIDSuccessCount = items.lazy.filter { $0.sourcePID != nil }.count
        let sourcePIDFailureCount = items.count - sourcePIDSuccessCount
        logger.info(
            """
            Legacy menu bar enumeration finished; items=\(items.count, privacy: .public), sourcePIDSuccess=\(sourcePIDSuccessCount, privacy: .public), sourcePIDFailure=\(sourcePIDFailureCount, privacy: .public)
            """
        )

        return MenuBarItemSnapshot(
            items: items,
            source: .legacyWindowServer,
            outcome: items.isEmpty ? .empty : .loaded,
            diagnosticMessage: items.isEmpty ? "WindowServer returned no menu bar item windows." : nil
        )
    }
}

/// The public Accessibility-backed provider used by macOS 27 and later.
@available(macOS 27.0, *)
struct MacOS27AccessibilityMenuBarItemProvider: MenuBarItemProviding {
    private struct Candidate {
        let namespace: String
        let stableIdentity: String
        let displayTitle: String?
        let ownerPID: pid_t
        let sourcePID: pid_t?
        let frame: CGRect
        let isOnScreen: Bool
        let isMenuBarAgent: Bool
    }

    private struct Metrics {
        var runningApplicationCount = 0
        var extrasMenuBarApplicationCount = 0
        var childCount = 0
        var validCandidateCount = 0
        var missingFrameCount = 0
        var heightFilteredCount = 0
        var directApplicationCount = 0
        var menuBarAgentCount = 0
        var deduplicatedCount = 0
        var overflowFilteredCount = 0
        var iceControlItemCount = 0
    }

    private static let menuBarAgentBundleIdentifier = "com.apple.MenuBarAgent"
    private static let maximumItemHeight: CGFloat = 40
    private static let syntheticIDMask: UInt32 = 0x8000_0000

    private let logger = Logger(category: "MacOS27AXMenuBarItemProvider")

    let source = MenuBarItemSnapshot.Source.accessibility

    func menuBarItems(
        on display: CGDirectDisplayID?,
        option: MenuBarItem.ListOption
    ) async -> MenuBarItemSnapshot {
        // AXExtrasMenuBar represents the current menu bar state. Keep
        // offscreen-X items even when `.onScreen` is requested, because macOS
        // can place hidden status items outside a display's horizontal bounds.
        _ = option
        guard AXHelpers.isProcessTrusted() else {
            logger.error("AX menu bar enumeration unavailable: Accessibility permission is missing")
            return MenuBarItemSnapshot(
                items: [],
                source: .accessibility,
                outcome: .permissionMissing,
                diagnosticMessage: "Accessibility permission is required to enumerate menu bar items."
            )
        }

        let displayBounds = display.map(CGDisplayBounds)
        return await Task.detached(priority: .userInitiated) {
            enumerate(displayBounds: displayBounds)
        }.value
    }

    private func enumerate(displayBounds: CGRect?) -> MenuBarItemSnapshot {
        var metrics = Metrics()
        var candidates = [Candidate]()
        let runningApplications = NSWorkspace.shared.runningApplications
        metrics.runningApplicationCount = runningApplications.count

        logger.info(
            """
            AX menu bar enumeration started; macOS=\(ProcessInfo.processInfo.operatingSystemVersionString, privacy: .public), runningApplications=\(runningApplications.count, privacy: .public)
            """
        )

        for runningApplication in runningApplications {
            guard
                !runningApplication.isTerminated,
                let application = AXHelpers.application(for: runningApplication),
                let extrasMenuBar = AXHelpers.extrasMenuBar(for: application)
            else {
                continue
            }

            metrics.extrasMenuBarApplicationCount += 1
            guard let children = AXHelpers.childrenIfAvailable(for: extrasMenuBar) else {
                continue
            }
            metrics.childCount += children.count

            let publisherBundleIdentifier = runningApplication.bundleIdentifier
            let isMenuBarAgent = publisherBundleIdentifier?.caseInsensitiveCompare(
                Self.menuBarAgentBundleIdentifier
            ) == .orderedSame

            for (childIndex, child) in children.enumerated() {
                let nestedChildren = AXHelpers.children(for: child)
                let directIdentifier = AXHelpers.identifier(for: child)
                let directDescription = AXHelpers.description(for: child)
                let directTitle = AXHelpers.title(for: child)
                let nestedIdentifiers = nestedChildren.compactMap(AXHelpers.identifier)
                let nestedDescriptions = nestedChildren.compactMap(AXHelpers.description)
                let nestedTitles = nestedChildren.compactMap(AXHelpers.title)

                // Read these attributes for diagnostics and future capability
                // checks. A disabled item remains a valid layout candidate.
                _ = AXHelpers.role(for: child)
                _ = AXHelpers.enabledIfAvailable(for: child)

                let identifiers = [directIdentifier].compactMap { $0 } + nestedIdentifiers
                let descriptions = [directDescription].compactMap { $0 } + nestedDescriptions
                let titles = [directTitle].compactMap { $0 } + nestedTitles

                if isOverflowPlaceholder(
                    identifiers: identifiers,
                    descriptions: descriptions,
                    titles: titles
                ) {
                    metrics.overflowFilteredCount += 1
                    continue
                }

                guard let frame = AXHelpers.frame(for: child) else {
                    metrics.missingFrameCount += 1
                    continue
                }
                guard
                    frame.width > 0,
                    frame.height > 0,
                    frame.height <= Self.maximumItemHeight
                else {
                    metrics.heightFilteredCount += 1
                    continue
                }
                guard belongsToDisplay(frame: frame, displayBounds: displayBounds) else {
                    continue
                }

                let allIdentityValues = identifiers + descriptions + titles
                let controlIdentifier = allIdentityValues.first { value in
                    value.hasPrefix("Ice.ControlItem.")
                }
                let publisherIsIce = publisherBundleIdentifier == Constants.bundleIdentifier
                let isIceControlItem = controlIdentifier != nil && (publisherIsIce || isMenuBarAgent)

                let namespace: String
                let sourcePID: pid_t?
                if isIceControlItem {
                    namespace = Constants.bundleIdentifier
                    sourcePID = NSRunningApplication.current.processIdentifier
                    metrics.iceControlItemCount += 1
                    logger.info(
                        """
                        Ice control item found; identifier=\(directIdentifier ?? "nil", privacy: .public), description=\(directDescription ?? "nil", privacy: .public), title=\(directTitle ?? "nil", privacy: .public), frame=\(String(describing: frame), privacy: .public), ownerPID=\(runningApplication.processIdentifier, privacy: .public), normalizedTag=\(controlIdentifier ?? "unknown", privacy: .public)
                        """
                    )
                } else if isMenuBarAgent {
                    namespace = Self.menuBarAgentBundleIdentifier
                    sourcePID = runningApplication.processIdentifier
                } else {
                    namespace = publisherBundleIdentifier ??
                    runningApplication.localizedName ??
                    "pid-\(runningApplication.processIdentifier)"
                    sourcePID = runningApplication.processIdentifier
                }

                let stableIdentity = controlIdentifier ??
                    identifiers.first ??
                    descriptions.first ??
                    titles.first ??
                    "Item-\(childIndex)"
                let displayTitle = directTitle ?? nestedTitles.first ?? directDescription
                let ownerPID = AXHelpers.pid(for: child) ?? runningApplication.processIdentifier
                let isOnScreen = displayBounds.map { bounds in
                    bounds.intersects(frame)
                } ?? true

                candidates.append(
                    Candidate(
                        namespace: namespace,
                        stableIdentity: stableIdentity,
                        displayTitle: displayTitle,
                        ownerPID: ownerPID,
                        sourcePID: sourcePID,
                        frame: frame,
                        isOnScreen: isOnScreen,
                        isMenuBarAgent: isMenuBarAgent
                    )
                )
                metrics.validCandidateCount += 1
                if isMenuBarAgent {
                    metrics.menuBarAgentCount += 1
                } else {
                    metrics.directApplicationCount += 1
                }
            }
        }

        let deduplicatedCandidates = deduplicate(candidates)
        metrics.deduplicatedCount = candidates.count - deduplicatedCandidates.count
        let items = makeItems(from: deduplicatedCandidates)
        log(metrics: metrics, finalItemCount: items.count)

        if metrics.extrasMenuBarApplicationCount == 0 {
            return MenuBarItemSnapshot(
                items: [],
                source: .accessibility,
                outcome: .failed,
                diagnosticMessage: "AXExtrasMenuBar could not be read from any running application."
            )
        }
        if items.isEmpty {
            return MenuBarItemSnapshot(
                items: [],
                source: .accessibility,
                outcome: .empty,
                diagnosticMessage: "Accessibility enumeration completed but found no menu bar items."
            )
        }
        return MenuBarItemSnapshot(
            items: items,
            source: .accessibility,
            outcome: .loaded,
            diagnosticMessage: nil
        )
    }

    private func belongsToDisplay(frame: CGRect, displayBounds: CGRect?) -> Bool {
        guard let displayBounds else {
            return true
        }
        let menuBarBand = CGRect(
            x: -.greatestFiniteMagnitude / 4,
            y: displayBounds.minY,
            width: .greatestFiniteMagnitude / 2,
            height: Self.maximumItemHeight
        )
        return frame.maxY >= menuBarBand.minY && frame.minY <= menuBarBand.maxY
    }

    private func isOverflowPlaceholder(
        identifiers: [String],
        descriptions: [String],
        titles: [String]
    ) -> Bool {
        if identifiers.contains("AXOverflowButton") {
            return true
        }
        let glyphs = Set("<>‹›«»")
        return (descriptions + titles).contains { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && trimmed.count <= 4 && trimmed.allSatisfy(glyphs.contains)
        }
    }

    private func deduplicate(_ candidates: [Candidate]) -> [Candidate] {
        let ordered = candidates.sorted { lhs, rhs in
            if lhs.isMenuBarAgent != rhs.isMenuBarAgent {
                return !lhs.isMenuBarAgent
            }
            if lhs.frame.minX != rhs.frame.minX {
                return lhs.frame.minX < rhs.frame.minX
            }
            return lhs.frame.minY < rhs.frame.minY
        }
        var result = [Candidate]()
        for candidate in ordered {
            let duplicateIndex = result.firstIndex { existing in
                guard existing.isMenuBarAgent != candidate.isMenuBarAgent else {
                    return false
                }
                return abs(existing.frame.minX - candidate.frame.minX) <= 1 &&
                abs(existing.frame.minY - candidate.frame.minY) <= 1
            }
            if let duplicateIndex {
                if result[duplicateIndex].isMenuBarAgent && !candidate.isMenuBarAgent {
                    result[duplicateIndex] = candidate
                }
                continue
            }
            result.append(candidate)
        }
        return result
    }

    private func makeItems(from candidates: [Candidate]) -> [MenuBarItem] {
        let ordered = candidates.sorted { lhs, rhs in
            if lhs.frame.minX != rhs.frame.minX {
                return lhs.frame.minX < rhs.frame.minX
            }
            if lhs.frame.minY != rhs.frame.minY {
                return lhs.frame.minY < rhs.frame.minY
            }
            if lhs.namespace != rhs.namespace {
                return lhs.namespace < rhs.namespace
            }
            return lhs.stableIdentity < rhs.stableIdentity
        }
        var instanceCounts = [String: Int]()
        var usedWindowIDs = Set<CGWindowID>()

        return ordered.map { candidate in
            let groupKey = "\(candidate.namespace)\u{1f}\(candidate.stableIdentity)"
            let instanceIndex = instanceCounts[groupKey, default: 0]
            instanceCounts[groupKey] = instanceIndex + 1
            let hashInput = "\(groupKey)\u{1f}\(instanceIndex)"
            var syntheticWindowID = Self.syntheticWindowID(for: hashInput)
            while usedWindowIDs.contains(syntheticWindowID) {
                syntheticWindowID = (syntheticWindowID &+ 1) | Self.syntheticIDMask
            }
            usedWindowIDs.insert(syntheticWindowID)
            let tagTitle = instanceIndex == 0 ?
                candidate.stableIdentity :
                "\(candidate.stableIdentity)#\(instanceIndex)"

            return MenuBarItem(
                accessibilityTag: MenuBarItemTag(
                    namespace: .string(candidate.namespace),
                    title: tagTitle
                ),
                syntheticWindowID: syntheticWindowID,
                ownerPID: candidate.ownerPID,
                sourcePID: candidate.sourcePID,
                bounds: candidate.frame,
                title: candidate.displayTitle,
                isOnScreen: candidate.isOnScreen
            )
        }
    }

    private static func syntheticWindowID(for string: String) -> CGWindowID {
        var hash: UInt32 = 2_166_136_261
        for byte in string.utf8 {
            hash ^= UInt32(byte)
            hash &*= 16_777_619
        }
        return hash | syntheticIDMask
    }

    private func log(metrics: Metrics, finalItemCount: Int) {
        logger.info(
            """
            AX menu bar enumeration finished; runningApplications=\(metrics.runningApplicationCount, privacy: .public), extrasMenuBarApplications=\(metrics.extrasMenuBarApplicationCount, privacy: .public), children=\(metrics.childCount, privacy: .public), validCandidates=\(metrics.validCandidateCount, privacy: .public), missingFrames=\(metrics.missingFrameCount, privacy: .public), heightFiltered=\(metrics.heightFilteredCount, privacy: .public), directApplications=\(metrics.directApplicationCount, privacy: .public), menuBarAgent=\(metrics.menuBarAgentCount, privacy: .public), deduplicated=\(metrics.deduplicatedCount, privacy: .public), overflowFiltered=\(metrics.overflowFilteredCount, privacy: .public), iceControlItems=\(metrics.iceControlItemCount, privacy: .public), syntheticIDs=\(finalItemCount, privacy: .public), finalItems=\(finalItemCount, privacy: .public)
            """
        )
    }
}
