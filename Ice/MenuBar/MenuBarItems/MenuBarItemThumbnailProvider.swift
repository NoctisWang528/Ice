//
//  MenuBarItemThumbnailProvider.swift
//  Ice
//

import Cocoa
import CoreVideo
import OSLog
import ScreenCaptureKit

// MARK: - MenuBarItemThumbnailProviding

/// A type that captures thumbnails for menu bar items.
protocol MenuBarItemThumbnailProviding: Sendable {
    /// Whether the provider needs separate captures for each menu bar section.
    var capturesSectionsIndividually: Bool { get }

    func captureImages(
        for items: [MenuBarItem],
        displayID: CGDirectDisplayID
    ) async -> [MenuBarItemTag: MenuBarItemImageCache.CapturedImage]
}

// MARK: - MenuBarItemThumbnailProviderFactory

enum MenuBarItemThumbnailProviderFactory {
    static func makeProvider(appState: AppState) -> any MenuBarItemThumbnailProviding {
        if #available(macOS 27.0, *) {
            MacOS27MenuBarThumbnailProvider()
        } else {
            LegacyWindowThumbnailProvider(appState: appState)
        }
    }
}

// MARK: - LegacyWindowThumbnailProvider

/// Captures real WindowServer menu bar item windows on macOS 14 through 26.
private final class LegacyWindowThumbnailProvider: MenuBarItemThumbnailProviding, @unchecked Sendable {
    let capturesSectionsIndividually = true

    private struct CaptureResult {
        var images = [MenuBarItemTag: MenuBarItemImageCache.CapturedImage]()
        var excluded = [MenuBarItem]()
    }

    private weak var appState: AppState?
    private let captureOption: CGWindowImageOption = [.boundsIgnoreFraming, .bestResolution]
    private let logger = Logger(category: "LegacyWindowThumbnailProvider")

    init(appState: AppState) {
        self.appState = appState
    }

    func captureImages(
        for items: [MenuBarItem],
        displayID: CGDirectDisplayID
    ) async -> [MenuBarItemTag: MenuBarItemImageCache.CapturedImage] {
        guard let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) else {
            logger.error("Could not resolve screen for display \(displayID, privacy: .public)")
            return [:]
        }

        let scale = screen.backingScaleFactor
        let syntheticItems = items.filter { !$0.hasRealWindowID }
        let realItems = items.filter(\.hasRealWindowID)
        let movedRecently = if let appState {
            await appState.itemManager.lastMoveOperationOccurred(within: .seconds(2))
        } else {
            false
        }

        var result: CaptureResult
        if movedRecently {
            logger.debug("Capturing individually due to recent item movement")
            result = individualCapture(realItems, scale: scale)
        } else {
            let compositeResult = compositeCapture(realItems, scale: scale)
            if compositeResult.excluded.isEmpty {
                result = compositeResult
            } else {
                logger.notice(
                    "Composite capture excluded \(compositeResult.excluded.count, privacy: .public) items; retrying individually"
                )
                result = individualCapture(compositeResult.excluded, scale: scale)
                result.images.merge(compositeResult.images) { _, new in new }
            }
        }

        result.excluded.append(contentsOf: syntheticItems)
        let realFailures = result.excluded.filter(\.hasRealWindowID)
        if !realFailures.isEmpty {
            logger.error("Some real-window thumbnails failed capture: \(realFailures, privacy: .public)")
        }
        return result.images
    }

    private func compositeCapture(_ items: [MenuBarItem], scale: CGFloat) -> CaptureResult {
        var result = CaptureResult()
        var windowIDs = [CGWindowID]()
        var storage = [CGWindowID: (MenuBarItem, CGRect)]()
        var boundsUnion = CGRect.null

        for item in items {
            guard
                item.hasRealWindowID,
                let bounds = Bridging.getWindowBounds(for: item.windowID)
            else {
                result.excluded.append(item)
                continue
            }
            windowIDs.append(item.windowID)
            storage[item.windowID] = (item, bounds)
            boundsUnion = boundsUnion.union(bounds)
        }

        guard
            !windowIDs.isEmpty,
            let compositeImage = ScreenCapture.captureWindows(with: windowIDs, option: captureOption),
            CGFloat(compositeImage.width) == boundsUnion.width * scale,
            !compositeImage.isTransparent()
        else {
            result.excluded = items
            return result
        }

        for windowID in windowIDs {
            guard let (item, bounds) = storage[windowID] else {
                continue
            }
            let cropRect = CGRect(
                x: (bounds.minX - boundsUnion.minX) * scale,
                y: (bounds.minY - boundsUnion.minY) * scale,
                width: bounds.width * scale,
                height: bounds.height * scale
            )
            guard
                let image = compositeImage.cropping(to: cropRect),
                !image.isTransparent()
            else {
                result.excluded.append(item)
                continue
            }
            result.images[item.tag] = .init(cgImage: image, scale: scale)
        }

        return result
    }

    private func individualCapture(_ items: [MenuBarItem], scale: CGFloat) -> CaptureResult {
        var result = CaptureResult()
        for item in items {
            guard
                item.hasRealWindowID,
                let image = ScreenCapture.captureWindow(with: item.windowID, option: captureOption),
                !image.isTransparent()
            else {
                result.excluded.append(item)
                continue
            }
            result.images[item.tag] = .init(cgImage: image, scale: scale)
        }
        return result
    }
}

// MARK: - MacOS27MenuBarThumbnailProvider

/// Captures Accessibility-backed menu bar items from shared ScreenCaptureKit images.
@available(macOS 27.0, *)
private struct MacOS27MenuBarThumbnailProvider: MenuBarItemThumbnailProviding {
    let capturesSectionsIndividually = false

    private enum CaptureSource: String {
        case hostingWindow
        case displayStrip
    }

    private struct MenuBarCaptureFrame {
        let image: CGImage
        let pointFrame: CGRect
        let scale: CGFloat
        let source: CaptureSource
    }

    private struct CaptureMetrics {
        var cropOutOfBounds = 0
        var blankCrops = 0
        var cleanupSucceeded = 0
        var cleanupFallback = 0
        var hostingToStripFallback = 0
        var stripToHostingFallback = 0
    }

    private struct BackgroundRemovalResult {
        let image: CGImage
        let didRemoveBackground: Bool
    }

    private let logger = Logger(category: "MacOS27MenuBarThumbnailProvider")

    func captureImages(
        for items: [MenuBarItem],
        displayID: CGDirectDisplayID
    ) async -> [MenuBarItemTag: MenuBarItemImageCache.CapturedImage] {
        guard !items.isEmpty else {
            return [:]
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
            logger.info(
                "SCShareableContent succeeded; displays=\(content.displays.count, privacy: .public), applications=\(content.applications.count, privacy: .public), windows=\(content.windows.count, privacy: .public)"
            )
        } catch {
            let nsError = error as NSError
            logger.error(
                "SCShareableContent failed: \(error.localizedDescription, privacy: .public), domain=\(nsError.domain, privacy: .public), code=\(nsError.code, privacy: .public)"
            )
            return [:]
        }

        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            logger.error("SCDisplay not found for displayID \(displayID, privacy: .public)")
            return [:]
        }

        logger.info(
            "Capturing menu bar thumbnails; displayID=\(displayID, privacy: .public), frame=\(String(describing: display.frame), privacy: .public), items=\(items.count, privacy: .public)"
        )

        let hostingWindow = selectHostingWindow(in: content.windows, for: display)
        async let hostingCapture = captureHostingWindow(hostingWindow, display: display)
        async let stripCapture = captureDisplayStrip(display)
        let (hosting, strip) = await (hostingCapture, stripCapture)

        var images = [MenuBarItemTag: MenuBarItemImageCache.CapturedImage]()
        var metrics = CaptureMetrics()
        var hostingCount = 0
        var stripCount = 0

        for item in items {
            let prefersHosting = isAppleSystemItem(item)
            let primary = prefersHosting ? hosting : strip
            let secondary = prefersHosting ? strip : hosting

            if let captured = crop(item, from: primary, metrics: &metrics) {
                images[item.tag] = captured
                if primary?.source == .hostingWindow {
                    hostingCount += 1
                } else {
                    stripCount += 1
                }
                continue
            }

            if let captured = crop(item, from: secondary, metrics: &metrics) {
                images[item.tag] = captured
                if secondary?.source == .hostingWindow {
                    hostingCount += 1
                    metrics.stripToHostingFallback += 1
                } else {
                    stripCount += 1
                    metrics.hostingToStripFallback += 1
                }
            }
        }

        let appIconFallbackCount = items.count - images.count
        logger.info(
            "Thumbnail capture completed; displayID=\(displayID, privacy: .public), covered=\(items.count, privacy: .public), successfulCrops=\(images.count, privacy: .public), hosting=\(hostingCount, privacy: .public), strip=\(stripCount, privacy: .public), cropOutOfBounds=\(metrics.cropOutOfBounds, privacy: .public), blankCrops=\(metrics.blankCrops, privacy: .public), cleanupSucceeded=\(metrics.cleanupSucceeded, privacy: .public), cleanupFallback=\(metrics.cleanupFallback, privacy: .public), hostingToStripFallback=\(metrics.hostingToStripFallback, privacy: .public), stripToHostingFallback=\(metrics.stripToHostingFallback, privacy: .public), appIconFallback=\(appIconFallbackCount, privacy: .public)"
        )
        return images
    }

    private func selectHostingWindow(in windows: [SCWindow], for display: SCDisplay) -> SCWindow? {
        let candidates = windows.filter { window in
            guard window.owningApplication?.bundleIdentifier == "com.apple.MenuBarAgent" else {
                return false
            }
            return isHostingGeometry(window.frame, displayFrame: display.frame)
        }

        logger.info("MenuBarAgent hosting window candidates=\(candidates.count, privacy: .public)")
        for candidate in candidates {
            logger.debug(
                "Hosting candidate; windowID=\(candidate.windowID, privacy: .public), owner=\(candidate.owningApplication?.bundleIdentifier ?? "nil", privacy: .public), frame=\(String(describing: candidate.frame), privacy: .public)"
            )
        }

        let selected = candidates.max { lhs, rhs in
            lhs.windowID < rhs.windowID
        }
        if let selected {
            logger.info(
                "Selected hosting window; windowID=\(selected.windowID, privacy: .public), frame=\(String(describing: selected.frame), privacy: .public)"
            )
        } else {
            logger.notice("No MenuBarAgent hosting window matched display geometry")
        }
        return selected
    }

    private func isHostingGeometry(_ windowFrame: CGRect, displayFrame: CGRect) -> Bool {
        let pointOriginMatches = abs(windowFrame.minX - displayFrame.minX) <= 2 &&
            abs(windowFrame.minY - displayFrame.minY) <= 2
        let pointGeometry = windowFrame.width > displayFrame.width * 0.8 &&
            windowFrame.height > 0 && windowFrame.height <= 40
        if pointOriginMatches, pointGeometry {
            return true
        }

        let candidateScale = windowFrame.width / max(displayFrame.width, 1)
        let pixelOriginMatches = abs(windowFrame.minX - (displayFrame.minX * candidateScale)) <= 4 &&
            abs(windowFrame.minY - (displayFrame.minY * candidateScale)) <= 4
        let pixelGeometry = windowFrame.width > displayFrame.width * 1.5 &&
            windowFrame.height > 40 && windowFrame.height <= 80
        return pixelOriginMatches && pixelGeometry
    }

    private func captureHostingWindow(
        _ window: SCWindow?,
        display: SCDisplay
    ) async -> MenuBarCaptureFrame? {
        guard let window else {
            return nil
        }

        let reportedFrame = window.frame
        let appearsPixelBacked = reportedFrame.height > 40 ||
            reportedFrame.width > display.frame.width * 1.5
        let normalizedPixelScale = max(reportedFrame.width / max(display.frame.width, 1), 1)
        let targetPointFrame = appearsPixelBacked ? CGRect(
            x: display.frame.minX,
            y: display.frame.minY,
            width: display.frame.width,
            height: max(reportedFrame.height / normalizedPixelScale, 1)
        ) : reportedFrame

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.captureDynamicRange = .SDR

        let requestedScale = appearsPixelBacked ?
            normalizedPixelScale :
            CGFloat(filter.pointPixelScale)
        configuration.width = max(Int((targetPointFrame.width * requestedScale).rounded()), 1)
        configuration.height = max(Int((targetPointFrame.height * requestedScale).rounded()), 1)

        do {
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            guard let capture = normalizedCapture(
                image: image,
                reportedPointFrame: targetPointFrame,
                source: .hostingWindow,
                reportedScale: CGFloat(filter.pointPixelScale)
            ) else {
                logger.error("Hosting capture had an invalid normalized scale")
                return nil
            }
            logger.info(
                "Hosting capture succeeded; pixels=\(image.width, privacy: .public)x\(image.height, privacy: .public), reportedPointPixelScale=\(filter.pointPixelScale, privacy: .public), actualScale=\(capture.scale, privacy: .public)"
            )
            return capture
        } catch {
            let nsError = error as NSError
            logger.error(
                "Hosting capture failed: \(error.localizedDescription, privacy: .public), domain=\(nsError.domain, privacy: .public), code=\(nsError.code, privacy: .public)"
            )
            return nil
        }
    }

    private func captureDisplayStrip(_ display: SCDisplay) async -> MenuBarCaptureFrame? {
        let stripFrame = CGRect(
            x: display.frame.minX,
            y: display.frame.minY,
            width: display.frame.width,
            height: min(40, display.frame.height)
        )
        guard stripFrame.width > 0, stripFrame.height > 0 else {
            return nil
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        filter.includeMenuBar = true
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = CGRect(
            x: stripFrame.minX - display.frame.minX,
            y: stripFrame.minY - display.frame.minY,
            width: stripFrame.width,
            height: stripFrame.height
        )
        configuration.showsCursor = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.captureDynamicRange = .SDR
        let reportedScale = CGFloat(filter.pointPixelScale)
        configuration.width = max(Int((stripFrame.width * reportedScale).rounded()), 1)
        configuration.height = max(Int((stripFrame.height * reportedScale).rounded()), 1)

        do {
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            guard let capture = normalizedCapture(
                image: image,
                reportedPointFrame: stripFrame,
                source: .displayStrip,
                reportedScale: reportedScale
            ) else {
                logger.error("Display strip capture had an invalid normalized scale")
                return nil
            }
            logger.info(
                "Display strip capture succeeded; pixels=\(image.width, privacy: .public)x\(image.height, privacy: .public), reportedPointPixelScale=\(filter.pointPixelScale, privacy: .public), actualScale=\(capture.scale, privacy: .public)"
            )
            return capture
        } catch {
            let nsError = error as NSError
            logger.error(
                "Display strip capture failed: \(error.localizedDescription, privacy: .public), domain=\(nsError.domain, privacy: .public), code=\(nsError.code, privacy: .public)"
            )
            return nil
        }
    }

    private func normalizedCapture(
        image: CGImage,
        reportedPointFrame: CGRect,
        source: CaptureSource,
        reportedScale: CGFloat
    ) -> MenuBarCaptureFrame? {
        guard reportedPointFrame.width > 0 else {
            return nil
        }
        let actualScale = CGFloat(image.width) / reportedPointFrame.width
        guard actualScale > 0.5, actualScale < 6 else {
            logger.error(
                "Rejected capture scale; source=\(source.rawValue, privacy: .public), reported=\(reportedScale, privacy: .public), actual=\(actualScale, privacy: .public)"
            )
            return nil
        }
        let normalizedHeight = CGFloat(image.height) / actualScale
        let pointFrame = CGRect(
            x: reportedPointFrame.minX,
            y: reportedPointFrame.minY,
            width: reportedPointFrame.width,
            height: normalizedHeight
        )
        return MenuBarCaptureFrame(
            image: image,
            pointFrame: pointFrame,
            scale: actualScale,
            source: source
        )
    }

    private func crop(
        _ item: MenuBarItem,
        from capture: MenuBarCaptureFrame?,
        metrics: inout CaptureMetrics
    ) -> MenuBarItemImageCache.CapturedImage? {
        guard let capture else {
            return nil
        }

        let itemFrame = item.bounds.insetBy(dx: -1, dy: 0)
        let rawCropRect = CGRect(
            x: (itemFrame.minX - capture.pointFrame.minX) * capture.scale,
            y: (itemFrame.minY - capture.pointFrame.minY) * capture.scale,
            width: itemFrame.width * capture.scale,
            height: itemFrame.height * capture.scale
        ).integral
        let imageBounds = CGRect(x: 0, y: 0, width: capture.image.width, height: capture.image.height)
        let cropRect = rawCropRect.intersection(imageBounds)
        guard !cropRect.isNull, cropRect.width > 0, cropRect.height > 0 else {
            metrics.cropOutOfBounds += 1
            return nil
        }
        if cropRect != rawCropRect {
            metrics.cropOutOfBounds += 1
        }

        guard
            let rawImage = capture.image.cropping(to: cropRect),
            !rawImage.isTransparent()
        else {
            metrics.blankCrops += 1
            return nil
        }

        let image: CGImage
        if capture.source == .displayStrip {
            let result = removeUniformBackground(from: rawImage)
            if result.didRemoveBackground {
                metrics.cleanupSucceeded += 1
            } else {
                metrics.cleanupFallback += 1
            }
            image = result.image
        } else {
            image = rawImage
        }

        return .init(cgImage: image, scale: capture.scale)
    }

    private func isAppleSystemItem(_ item: MenuBarItem) -> Bool {
        let namespace = item.tag.namespace.description
        let sourceBundleID = item.sourceApplication?.bundleIdentifier
        let ownerBundleID = item.owningApplication?.bundleIdentifier
        return namespace.hasPrefix("com.apple.") ||
            sourceBundleID?.hasPrefix("com.apple.") == true ||
            ownerBundleID == "com.apple.MenuBarAgent" ||
            item.tag.isBentoBox
    }

    /// Conservatively removes a near-uniform menu bar background from a crop.
    /// If the edge samples or resulting alpha coverage are ambiguous, the raw
    /// crop is returned unchanged.
    private func removeUniformBackground(from image: CGImage) -> BackgroundRemovalResult {
        let width = image.width
        let height = image.height
        guard width > 2, height > 2 else {
            return .init(image: image, didRemoveBackground: false)
        }

        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return .init(image: image, didRemoveBackground: false)
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var samples = [(Int, Int, Int)]()
        let stride = max(min(width, height) / 8, 1)
        for x in Swift.stride(from: 0, to: width, by: stride) {
            samples.append(rgb(atX: x, y: 0, pixels: pixels, bytesPerRow: bytesPerRow))
            samples.append(rgb(atX: x, y: height - 1, pixels: pixels, bytesPerRow: bytesPerRow))
        }
        for y in Swift.stride(from: 0, to: height, by: stride) {
            samples.append(rgb(atX: 0, y: y, pixels: pixels, bytesPerRow: bytesPerRow))
            samples.append(rgb(atX: width - 1, y: y, pixels: pixels, bytesPerRow: bytesPerRow))
        }
        guard !samples.isEmpty else {
            return .init(image: image, didRemoveBackground: false)
        }

        let background = (
            median(samples.map(\.0)),
            median(samples.map(\.1)),
            median(samples.map(\.2))
        )
        let averageEdgeDistance = samples.reduce(0.0) { partial, sample in
            partial + colorDistance(sample, background)
        } / Double(samples.count)
        guard averageEdgeDistance < 34 else {
            return .init(image: image, didRemoveBackground: false)
        }

        var visiblePixels = 0
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * bytesPerRow) + (x * 4)
                let sample = (Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2]))
                let distance = colorDistance(sample, background)
                let originalAlpha = Int(pixels[offset + 3])
                let alphaMultiplier = min(max((distance - 18) / 34, 0), 1)
                let newAlpha = Int((Double(originalAlpha) * alphaMultiplier).rounded())
                if newAlpha > 12 {
                    visiblePixels += 1
                }
                guard newAlpha != originalAlpha else {
                    continue
                }
                let premultiply = originalAlpha > 0 ? Double(newAlpha) / Double(originalAlpha) : 0
                pixels[offset] = UInt8((Double(pixels[offset]) * premultiply).rounded().clamped(to: 0...255))
                pixels[offset + 1] = UInt8((Double(pixels[offset + 1]) * premultiply).rounded().clamped(to: 0...255))
                pixels[offset + 2] = UInt8((Double(pixels[offset + 2]) * premultiply).rounded().clamped(to: 0...255))
                pixels[offset + 3] = UInt8(newAlpha.clamped(to: 0...255))
            }
        }

        let coverage = Double(visiblePixels) / Double(width * height)
        guard coverage > 0.005, coverage < 0.75 else {
            return .init(image: image, didRemoveBackground: false)
        }
        guard let output = context.makeImage(), !output.isTransparent(alphaThreshold: 0.02) else {
            return .init(image: image, didRemoveBackground: false)
        }
        return .init(image: output, didRemoveBackground: true)
    }

    private func rgb(
        atX x: Int,
        y: Int,
        pixels: [UInt8],
        bytesPerRow: Int
    ) -> (Int, Int, Int) {
        let offset = (y * bytesPerRow) + (x * 4)
        return (Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2]))
    }

    private func median(_ values: [Int]) -> Int {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private func colorDistance(_ lhs: (Int, Int, Int), _ rhs: (Int, Int, Int)) -> Double {
        let red = Double(lhs.0 - rhs.0)
        let green = Double(lhs.1 - rhs.1)
        let blue = Double(lhs.2 - rhs.2)
        return (red * red + green * green + blue * blue).squareRoot()
    }
}
