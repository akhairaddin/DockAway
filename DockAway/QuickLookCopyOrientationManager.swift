import AppKit
import CoreImage
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@preconcurrency import ApplicationServices

@MainActor
final class QuickLookCopyOrientationManager {
    static let preferenceKey = "correctQuickLookCopyOrientation"

    private struct CopySource: @unchecked Sendable {
        let url: URL?
        let data: Data?
    }

    private struct CorrectedRepresentations: @unchecked Sendable {
        let png: Data
        let tiff: Data
    }

    private var timer: Timer?
    private var lastPasteboardChangeCount = NSPasteboard.general.changeCount
    private var quickLookWasVisibleUntil = Date.distantPast
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
        if finderOwnsFrontmostUI, !sampledQuickLook, Date() > quickLookWasVisibleUntil {
            sampleQuickLookVisibility(now: now)
        }

        guard !isWritingPasteboard,
              Date() <= quickLookWasVisibleUntil,
              let source = Self.copySource(
                from: pasteboard,
                preferredFileURL: Self.finderSelectedImageURL()
              ) else { return }

        correctionGeneration &+= 1
        let generation = correctionGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let corrected = Self.correctedRepresentations(from: source) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self,
                          self.timer != nil,
                          self.correctionGeneration == generation,
                          NSPasteboard.general.changeCount == changeCount else { return }
                    self.write(corrected)
                }
            }
        }
    }

    /// Quick Look visibility costs Accessibility IPC into Finder, so it is
    /// sampled less often than the pasteboard. The 0.6 s grace window, which
    /// keeps a copy associated with Quick Look if the panel dismisses as the
    /// pasteboard owner publishes its promised data, also spans the gap.
    private func sampleQuickLookVisibility(now: TimeInterval) {
        nextQuickLookSampleAt = now + 0.25
        if Self.finderQuickLookIsVisible() {
            quickLookWasVisibleUntil = Date().addingTimeInterval(0.6)
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
    }

    private static func copySource(
        from pasteboard: NSPasteboard,
        preferredFileURL: URL?
    ) -> CopySource? {
        let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff]
        let copiedImageData = (pasteboard.pasteboardItems ?? []).lazy.compactMap { item in
            imageTypes.lazy.compactMap { item.data(forType: $0) }.first
        }.first

        if let fileURL = (pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL])?.first,
           imageSource(at: fileURL) != nil {
            return CopySource(url: fileURL, data: nil)
        }

        // Finder's Quick Look publishes a flattened PNG with no orientation
        // metadata. Use the selected source file when available so ImageIO can
        // apply its original EXIF/TIFF orientation instead of preserving the
        // sideways Quick Look bitmap.
        if copiedImageData != nil,
           let preferredFileURL,
           imageSource(at: preferredFileURL) != nil {
            return CopySource(url: preferredFileURL, data: nil)
        }

        if let copiedImageData, imageSource(from: copiedImageData) != nil {
            return CopySource(url: nil, data: copiedImageData)
        }
        return nil
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

    private nonisolated static func correctedRepresentations(
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

        guard let imageSource,
              CGImageSourceGetCount(imageSource) > 0,
              let rawImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            return nil
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil)
            as? [CFString: Any]
        let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.int32Value ?? 1
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
            let rows = element.elements(kAXRowsAttribute)
                ?? element.elements(kAXChildrenAttribute)
                ?? []
            for row in rows where row.bool(kAXSelectedAttribute) == true {
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
        application.elements(kAXWindowsAttribute) ?? []
    }
}
