import AppKit
import CoreImage
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@preconcurrency import ApplicationServices

@MainActor
final class QuickLookCopyOrientationManager {
    static let preferenceKey = "correctQuickLookCopyOrientation"
    private static let imagePayloadTypes: [NSPasteboard.PasteboardType] = [
        .png, .tiff, .init(UTType.jpeg.identifier), .init(UTType.heic.identifier)
    ]

    struct CopySource: @unchecked Sendable {
        let url: URL?
        let data: Data?
        var copiedImageData: Data? = nil
    }

    struct CorrectedRepresentations: @unchecked Sendable {
        let png: Data
        let tiff: Data
    }

    private var timer: Timer?
    private var lastPasteboardChangeCount = NSPasteboard.general.changeCount
    private var quickLookWasVisibleUntil = Date.distantPast
    private var previewedFileURL: URL?
    private var nextQuickLookSampleAt: TimeInterval = 0
    private var correctionGeneration: UInt = 0
    private var isWritingPasteboard = false

    func setEnabled(_ enabled: Bool) {
        enabled ? start() : stop()
    }

    func stop() {
        correctionGeneration &+= 1
        timer?.invalidate()
        timer = nil
        quickLookWasVisibleUntil = .distantPast
        previewedFileURL = nil
        nextQuickLookSampleAt = 0
        isWritingPasteboard = false
    }

    private func start() {
        guard timer == nil else { return }
        lastPasteboardChangeCount = NSPasteboard.general.changeCount
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pollPasteboard()
            }
        }
        timer.tolerance = 0.02
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func pollPasteboard() {
        let frontmostBundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let finderOwnsFrontmostUI = frontmostBundleIdentifier == "com.apple.finder"
            || frontmostBundleIdentifier == "com.apple.quicklook.QuickLookUIService"
        let now = ProcessInfo.processInfo.systemUptime
        var sampledQuickLook = false
        if finderOwnsFrontmostUI, now >= nextQuickLookSampleAt {
            sampleQuickLookVisibility(now: now)
            sampledQuickLook = true
        }

        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount
        guard changeCount != lastPasteboardChangeCount else { return }
        lastPasteboardChangeCount = changeCount
        // A copy made right after Quick Look opened can land between samples.
        let containsImage = pasteboard.types?.contains {
            Self.imagePayloadTypes.contains($0)
        } == true
        if containsImage, !sampledQuickLook {
            sampleQuickLookVisibility(now: now)
        }
        if containsImage {
            dockAwayDebugLog("Quick Look image clipboard change; previewRecentlyVisible=\(Date() <= quickLookWasVisibleUntil); FinderFrontmost=\(finderOwnsFrontmostUI)")
        }

        guard !isWritingPasteboard,
              Date() <= quickLookWasVisibleUntil,
              let source = Self.copySource(
                from: pasteboard,
                preferredFileURL: previewedFileURL ?? Self.finderSelectedImageURL()
              ) else { return }

        dockAwayDebugLog("Quick Look image copy detected; source=\(source.url?.lastPathComponent ?? "clipboard metadata")")
        correctionGeneration &+= 1
        let generation = correctionGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let corrected = Self.correctedRepresentations(from: source) else { return }
            RunLoop.main.perform(inModes: [.default, .eventTracking, .modalPanel]) {
                MainActor.assumeIsolated {
                    guard let self,
                          self.timer != nil,
                          self.correctionGeneration == generation,
                          NSPasteboard.general.changeCount == changeCount else { return }
                    self.write(corrected)
                    dockAwayDebugLog("Quick Look clipboard orientation correction completed")
                }
            }
        }
    }

    /// Quick Look visibility costs Accessibility IPC into Finder, so it is
    /// sampled less often than the pasteboard. The 2 s grace window, which
    /// keeps a copy associated with Quick Look if the panel dismisses as the
    /// pasteboard owner publishes its promised data, also spans the gap.
    private func sampleQuickLookVisibility(now: TimeInterval) {
        nextQuickLookSampleAt = now + 0.25
        if Self.finderQuickLookIsVisible() {
            if Date() > quickLookWasVisibleUntil {
                dockAwayDebugLog("Finder Quick Look preview detected")
            }
            quickLookWasVisibleUntil = Date().addingTimeInterval(2)
            previewedFileURL = Self.finderSelectedImageURL()
        } else if Date() > quickLookWasVisibleUntil {
            previewedFileURL = nil
        }
    }

    private func write(_ corrected: CorrectedRepresentations) {
        let pasteboard = NSPasteboard.general
        let item = NSPasteboardItem()
        item.setData(corrected.png, forType: .png)
        item.setData(corrected.tiff, forType: .tiff)

        isWritingPasteboard = true
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        lastPasteboardChangeCount = pasteboard.changeCount
        isWritingPasteboard = false
        quickLookWasVisibleUntil = .distantPast
        previewedFileURL = nil
    }

    static func copySource(
        from pasteboard: NSPasteboard,
        preferredFileURL: URL?
    ) -> CopySource? {
        let imageTypes = imagePayloadTypes
        let imageItems = (pasteboard.pasteboardItems ?? []).filter { item in
            item.types.contains { imageTypes.contains($0) }
        }
        // Finder file copies contain a file URL and its icon, not an image
        // payload. Never turn those ordinary file copies into flattened images.
        guard imageItems.count == 1 else { return nil }

        // Resolve the preview's original BEFORE a clipboard-supplied file URL.
        // Clipboard managers can attach a history file whose pixels already
        // lost EXIF orientation. That cached file must not outrank the original.
        // Retain the copied bitmap too, so the worker can verify that it really
        // belongs to this preview before replacing it. This also protects an
        // unrelated image copied after focus leaves Quick Look during the grace
        // period, and prevents rotating a bitmap that is already upright.
        let copiedImageData = imageItems.lazy.compactMap { item in
            imageTypes.lazy.compactMap { item.data(forType: $0) }.first
        }.first
        guard let copiedImageData, imageSource(from: copiedImageData) != nil else {
            return nil
        }
        if let preferredFileURL,
           preferredFileURL.isFileURL,
           imageSource(at: preferredFileURL) != nil {
            return CopySource(url: preferredFileURL, data: nil,
                              copiedImageData: copiedImageData)
        }

        if let fileURL = (pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL])?.first,
           imageSource(at: fileURL) != nil {
            return CopySource(url: fileURL, data: nil,
                              copiedImageData: copiedImageData)
        }

        return CopySource(url: nil, data: copiedImageData)
    }

    nonisolated static func normalizedPixelSize(forImageAt url: URL) -> CGSize? {
        guard let representations = correctedRepresentations(
            from: CopySource(url: url, data: nil)
        ), let source = imageSource(from: representations.png),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            return nil
        }
        return CGSize(width: width.doubleValue, height: height.doubleValue)
    }

    nonisolated static func correctedRepresentations(
        from source: CopySource
    ) -> CorrectedRepresentations? {
        let imageSource: CGImageSource?
        if let url = source.url {
            imageSource = self.imageSource(at: url)
        } else if let data = source.data {
            imageSource = self.imageSource(from: data)
        } else {
            return nil
        }

        guard let imageSource, CGImageSourceGetCount(imageSource) > 0 else { return nil }
        if let copiedData = source.copiedImageData {
            guard let copiedSource = self.imageSource(from: copiedData),
                  rawPixelsMatch(imageSource, copiedSource) else { return nil }
        }
        guard
              let rawImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            return nil
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil)
            as? [CFString: Any]
        let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.int32Value ?? 1
        guard (1...8).contains(orientation) else { return nil }
        let orientedImage = CIImage(cgImage: rawImage).oriented(forExifOrientation: orientation)
        let extent = orientedImage.extent.integral
        guard !extent.isEmpty,
              extent.origin.x.isFinite,
              extent.origin.y.isFinite,
              extent.width.isFinite,
              extent.height.isFinite else { return nil }

        let translatedImage = orientedImage.transformed(by: CGAffineTransform(
            translationX: -extent.minX,
            y: -extent.minY
        ))
        let outputBounds = CGRect(origin: .zero, size: extent.size)
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let renderedImage = context.createCGImage(translatedImage, from: outputBounds),
              let png = encodedData(from: renderedImage, type: UTType.png.identifier),
              let tiff = encodedData(from: renderedImage, type: UTType.tiff.identifier) else {
            return nil
        }
        return CorrectedRepresentations(png: png, tiff: tiff)
    }

    private nonisolated static func rawPixelsMatch(
        _ original: CGImageSource,
        _ copied: CGImageSource
    ) -> Bool {
        func dimensions(_ source: CGImageSource) -> CGSize? {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                    as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                  let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
                return nil
            }
            return CGSize(width: width.doubleValue, height: height.doubleValue)
        }
        // Quick Look's broken copy preserves the raw dimensions and pixels,
        // but strips their orientation. Check both without decoding two full
        // photos. Never infer rotation just from portrait/landscape shape.
        guard let size = dimensions(original), size == dimensions(copied) else {
            return false
        }
        func fingerprint(_ source: CGImageSource) -> [UInt8]? {
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: false,
                kCGImageSourceThumbnailMaxPixelSize: 48
            ] as CFDictionary),
                  let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
            var pixels = [UInt8](repeating: 0, count: 48 * 48 * 4)
            let rendered = pixels.withUnsafeMutableBytes { storage -> Bool in
                guard let context = CGContext(data: storage.baseAddress,
                    width: 48, height: 48, bitsPerComponent: 8, bytesPerRow: 48 * 4,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                    return false
                }
                context.draw(thumbnail, in: CGRect(x: 0, y: 0, width: 48, height: 48))
                return true
            }
            return rendered ? pixels : nil
        }
        guard let first = fingerprint(original), let second = fingerprint(copied) else {
            return false
        }
        let differences = zip(first, second).map { abs(Int($0) - Int($1)) }
        // Allow minor JPEG/color-conversion differences, but require the same
        // image content rather than merely matching its resolution.
        return differences.reduce(0, +) < differences.count * 6
            && differences.filter { $0 > 32 }.count < differences.count / 50
    }

    private nonisolated static func encodedData(
        from image: CGImage,
        type: String
    ) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            type as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyOrientation: 1
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private nonisolated static func imageSource(at url: URL) -> CGImageSource? {
        CGImageSourceCreateWithURL(url as CFURL, nil)
    }

    private nonisolated static func imageSource(from data: Data) -> CGImageSource? {
        CGImageSourceCreateWithData(data as CFData, nil)
    }

    private static func finderQuickLookIsVisible() -> Bool {
        if finderAccessibilityShowsQuickLook() {
            return true
        }

        let services = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.quicklook.QuickLookUIService"
        )
        guard !services.isEmpty else { return false }

        let finderServices = services.filter {
            $0.localizedName?.localizedCaseInsensitiveContains("Finder") == true
        }
        let candidates = finderServices.isEmpty ? services : finderServices
        let processIdentifiers = Set(candidates.map(\.processIdentifier))
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return false }

        return windows.contains { window in
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? NSNumber,
                  processIdentifiers.contains(pid_t(ownerPID.int32Value)),
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                  let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(
                    dictionaryRepresentation: boundsDictionary as CFDictionary
                  ) else {
                return false
            }
            return bounds.width >= 100 && bounds.height >= 100
        }
    }

    private static func finderAccessibilityShowsQuickLook() -> Bool {
        guard let finder = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.finder"
        ).first else { return false }
        let application = AXUIElementCreateApplication(finder.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.08)
        return windows(of: application).contains { window in
            window.string(kAXSubroleAttribute) == "Quick Look"
                || window.string(kAXTitleAttribute) == "Quick Look"
        }
    }

    private static func finderSelectedImageURL() -> URL? {
        guard let finder = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.finder"
        ).first else { return nil }
        let application = AXUIElementCreateApplication(finder.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.12)
        let previewedFileName = quickLookPreviewedFileName(in: application)

        for window in windows(of: application) {
            guard window.string(kAXSubroleAttribute)
                    == kAXStandardWindowSubrole as String,
                  let url = selectedFileURL(
                    in: window,
                    matchingFileName: previewedFileName,
                    depth: 0
                  ),
                  imageSource(at: url) != nil else { continue }
            return url
        }
        return nil
    }

    private static func selectedFileURL(
        in element: AXUIElement,
        matchingFileName: String?,
        depth: Int
    ) -> URL? {
        let role = element.string(kAXRoleAttribute)
        if role == kAXOutlineRole as String
            || role == kAXListRole as String
            || role == "AXBrowser" {
            let selectedChildren = element.elements(kAXSelectedChildrenAttribute) ?? []
            let rows = selectedChildren.isEmpty
                ? (element.elements(kAXRowsAttribute)
                    ?? element.elements(kAXChildrenAttribute) ?? []).filter {
                        $0.bool(kAXSelectedAttribute) == true
                    }
                : selectedChildren
            for row in rows {
                if let url = firstFileURL(in: row, depth: 0),
                   matchingFileName == nil || url.lastPathComponent == matchingFileName {
                    return url
                }
            }
            return nil
        }

        guard depth < 7 else { return nil }
        for child in element.elements(kAXChildrenAttribute) ?? [] {
            if let url = selectedFileURL(
                in: child,
                matchingFileName: matchingFileName,
                depth: depth + 1
            ) {
                return url
            }
        }
        return nil
    }

    private static func quickLookPreviewedFileName(
        in application: AXUIElement
    ) -> String? {
        guard let quickLookWindow = windows(of: application).first(where: {
            $0.string(kAXSubroleAttribute) == "Quick Look"
                || $0.string(kAXTitleAttribute) == "Quick Look"
        }) else { return nil }
        return previewedFileName(in: quickLookWindow, depth: 0)
    }

    private static func previewedFileName(
        in element: AXUIElement,
        depth: Int
    ) -> String? {
        let identifier = element.string(kAXIdentifierAttribute) ?? ""
        let identifierPrefix = "Image Preview: "
        if identifier.hasPrefix(identifierPrefix) {
            return String(identifier.dropFirst(identifierPrefix.count))
        }

        let description = element.string(kAXDescriptionAttribute) ?? ""
        let descriptionPrefix = "Preview of "
        if description.hasPrefix(descriptionPrefix) {
            return String(description.dropFirst(descriptionPrefix.count))
        }

        guard depth < 3 else { return nil }
        for child in element.elements(kAXChildrenAttribute) ?? [] {
            if let fileName = previewedFileName(in: child, depth: depth + 1) {
                return fileName
            }
        }
        return nil
    }

    private static func firstFileURL(
        in element: AXUIElement,
        depth: Int
    ) -> URL? {
        if let value = element.attributeValue(kAXURLAttribute) {
            if let url = value as? URL {
                return url
            }
            if let string = value as? String, let url = URL(string: string) {
                return url
            }
        }
        guard depth < 5 else { return nil }
        for child in element.elements(kAXChildrenAttribute) ?? [] {
            if let url = firstFileURL(in: child, depth: depth + 1) {
                return url
            }
        }
        return nil
    }

    private static func windows(of application: AXUIElement) -> [AXUIElement] {
        // Finder can expose an empty AXWindows array while its real windows,
        // including QLPreviewPanel, remain available through AXChildren.
        // Prefer the focused window, then merge both public discovery paths.
        var candidates: [AXUIElement] = []
        if let focused = application.element(kAXFocusedWindowAttribute) {
            candidates.append(focused)
        }
        candidates += application.elements(kAXWindowsAttribute) ?? []
        candidates += (application.elements(kAXChildrenAttribute) ?? []).filter {
            $0.string(kAXRoleAttribute) == kAXWindowRole as String
        }
        return candidates.reduce(into: []) { result, window in
            if !result.contains(where: { CFEqual($0, window) }) {
                result.append(window)
            }
        }
    }
}
