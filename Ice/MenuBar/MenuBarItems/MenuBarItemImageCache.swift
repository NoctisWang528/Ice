//
//  MenuBarItemImageCache.swift
//  Ice
//

import Cocoa
import Combine
import OSLog

/// Cache for menu bar item images.
final class MenuBarItemImageCache: ObservableObject {
    /// A representation of a captured menu bar item image.
    struct CapturedImage: Hashable {
        /// The base image.
        let cgImage: CGImage

        /// The scale factor of the image at the time of capture.
        let scale: CGFloat

        /// The image's size, applying ``scale``.
        var scaledSize: CGSize {
            CGSize(
                width: CGFloat(cgImage.width) / scale,
                height: CGFloat(cgImage.height) / scale
            )
        }

        /// The base image, converted to an `NSImage` and applying ``scale``.
        var nsImage: NSImage {
            NSImage(cgImage: cgImage, size: scaledSize)
        }
    }

    /// Context associated with a cached image.
    private struct CacheContext {
        let displayID: CGDirectDisplayID
        let scale: CGFloat
        let appearance: String
        let bounds: CGRect
        let windowReference: MenuBarItem.WindowReference
    }

    /// The cached item images, keyed by their corresponding tags.
    @Published private(set) var images = [MenuBarItemTag: CapturedImage]()

    /// Capture context for each cached image.
    private var cacheContexts = [MenuBarItemTag: CacheContext]()

    /// Logger for the menu bar item image cache.
    private let logger = Logger(category: "MenuBarItemImageCache")

    /// The shared app state.
    private weak var appState: AppState?

    /// The operating-system-specific thumbnail provider.
    private var thumbnailProvider: (any MenuBarItemThumbnailProviding)?

    /// A token used to prevent stale asynchronous captures from updating the cache.
    private var captureGeneration = 0

    /// The time the most recent capture began.
    private var lastCaptureStart: ContinuousClock.Instant?

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    // MARK: Setup

    /// Sets up the cache.
    @MainActor
    func performSetup(with appState: AppState) {
        self.appState = appState
        self.thumbnailProvider = MenuBarItemThumbnailProviderFactory.makeProvider(appState: appState)
        configureCancellables()
    }

    /// Configures the internal observers for the cache.
    @MainActor
    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        if let appState {
            Publishers.Merge3(
                // Refresh dynamic glyphs at a low frequency while a consumer is visible.
                Timer.publish(every: 15, on: .main, in: .default).autoconnect().replace(with: ()),

                // Update when the active space or screen parameters change.
                Publishers.Merge(
                    NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification),
                    NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
                )
                .replace(with: ()),

                // Update when the average menu bar color or cached items change.
                Publishers.Merge(
                    appState.menuBarManager.$averageColorInfo.removeDuplicates().replace(with: ()),
                    appState.itemManager.$itemCache.removeDuplicates().replace(with: ())
                )
            )
            .debounce(for: 0.5, scheduler: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else {
                    return
                }
                Task {
                    await self.updateCache()
                }
            }
            .store(in: &c)
        }

        cancellables = c
    }

    // MARK: Update Cache

    /// Updates the cache for the given sections, without checking whether
    /// caching is necessary.
    func updateCacheWithoutChecks(
        sections: [MenuBarSection.Name],
        force: Bool = false
    ) async {
        guard
            let appState,
            await appState.hasPermission(.screenRecording),
            let thumbnailProvider
        else {
            return
        }

        guard
            let displayID = await appState.itemManager.itemCache.displayID
        else {
            return
        }

        let shouldStart = await MainActor.run {
            let now = ContinuousClock.now
            if
                !force,
                let lastCaptureStart,
                now - lastCaptureStart < .seconds(2)
            {
                return false
            }
            lastCaptureStart = now
            captureGeneration += 1
            return true
        }
        guard shouldStart else {
            logger.debug("Skipping thumbnail refresh inside minimum capture interval")
            return
        }

        let generation = await MainActor.run { captureGeneration }
        let sectionItems = await MainActor.run {
            sections.map { section in
                appState.itemManager.itemCache.managedItems(for: section)
            }
        }
        let items = sectionItems.flatMap { $0 }
        guard !items.isEmpty else {
            return
        }

        var newImages = [MenuBarItemTag: CapturedImage]()
        if thumbnailProvider.capturesSectionsIndividually {
            for items in sectionItems where !items.isEmpty {
                let sectionImages = await thumbnailProvider.captureImages(
                    for: items,
                    displayID: displayID
                )
                newImages.merge(sectionImages) { _, new in new }
            }
        } else {
            newImages = await thumbnailProvider.captureImages(for: items, displayID: displayID)
        }

        await MainActor.run { [newImages, items] in
            guard generation == captureGeneration else {
                logger.debug(
                    "Discarding stale thumbnail capture; generation=\(generation, privacy: .public), current=\(self.captureGeneration, privacy: .public)"
                )
                return
            }

            let requestedTags = Set(items.map(\.tag))
            if #available(macOS 27.0, *) {
                images = images.filter { !requestedTags.contains($0.key) }
                cacheContexts = cacheContexts.filter { !requestedTags.contains($0.key) }
            }
            images.merge(newImages) { _, new in new }

            let screenScale = NSScreen.screens.first(where: { $0.displayID == displayID })?.backingScaleFactor ?? 1
            let appearance = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])?.rawValue ?? "unknown"
            for item in items where newImages[item.tag] != nil {
                cacheContexts[item.tag] = CacheContext(
                    displayID: displayID,
                    scale: newImages[item.tag]?.scale ?? screenScale,
                    appearance: appearance,
                    bounds: item.bounds,
                    windowReference: item.windowReference
                )
            }

            logger.info(
                "Applied thumbnail capture; generation=\(generation, privacy: .public), requested=\(items.count, privacy: .public), captured=\(newImages.count, privacy: .public), fallback=\(items.count - newImages.count, privacy: .public)"
            )
        }
    }

    /// Updates the cache for the given sections, if necessary.
    func updateCache(sections: [MenuBarSection.Name]) async {
        guard let appState else {
            return
        }

        let isIceBarPresented = await appState.navigationState.isIceBarPresented
        let isSearchPresented = await appState.navigationState.isSearchPresented

        if !isIceBarPresented && !isSearchPresented {
            guard
                await appState.navigationState.isAppFrontmost,
                await appState.navigationState.isSettingsPresented,
                await appState.navigationState.settingsNavigationIdentifier == .menuBarLayout
            else {
                return
            }
        }

        guard await !appState.itemManager.lastMoveOperationOccurred(within: .seconds(1)) else {
            logger.debug("Skipping item image cache due to recent item movement")
            return
        }

        await updateCacheWithoutChecks(sections: sections)
    }

    /// Updates the cache for all sections, if necessary.
    func updateCache() async {
        guard let appState else {
            return
        }

        let isIceBarPresented = await appState.navigationState.isIceBarPresented
        let isSearchPresented = await appState.navigationState.isSearchPresented
        let isSettingsPresented = await appState.navigationState.isSettingsPresented

        var sectionsNeedingDisplay = [MenuBarSection.Name]()

        if isSettingsPresented || isSearchPresented {
            sectionsNeedingDisplay = MenuBarSection.Name.allCases
        } else if
            isIceBarPresented,
            let section = await appState.menuBarManager.iceBarPanel.currentSection
        {
            sectionsNeedingDisplay.append(section)
        }

        await updateCache(sections: sectionsNeedingDisplay)
    }

    // MARK: Cache Failed

    /// Returns a Boolean value that indicates whether caching menu bar items
    /// failed for the given section.
    @MainActor
    func cacheFailed(for section: MenuBarSection.Name) -> Bool {
        guard ScreenCapture.cachedCheckPermissions() else {
            return true
        }
        let items = appState?.itemManager.itemCache[section] ?? []
        guard !items.isEmpty else {
            return false
        }
        if items.contains(where: { !$0.hasRealWindowID }) {
            return false // Accessibility-only items use application icon placeholders.
        }
        let keys = Set(images.keys)
        for item in items where keys.contains(item.tag) {
            return false
        }
        return true
    }
}
