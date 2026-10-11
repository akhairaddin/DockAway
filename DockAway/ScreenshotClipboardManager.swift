import AppKit
import UniformTypeIdentifiers
import ImageIO

@MainActor
final class ScreenshotClipboardManager {
    static let shared = ScreenshotClipboardManager()
    static let preferenceKey = "AutoCopyScreenshotsToClipboard"

    private(set) var isMonitoring = false
    private(set) var watchedDirectoryURL: URL?

    private var directorySource: DispatchSourceFileSystemObject?
    private var directoryFileDescriptor: Int32 = -1
    private var pendingDebounceItem: DispatchWorkItem?
    private var healthCheckTimer: Timer?
    private var processedFileIdentifiers = Set<String>()
    private var recentProcessedOrder: [String] = []
    private var captureAnchorMouseLocation: NSPoint?
    private(set) var lastCopiedFileURL: URL?
    /// Folder scans and image conversion run here, off the main thread that
    /// DockAway's input handling shares. Only the clipboard write is on main.
    private let workQueue = DispatchQueue(label: "AK.DockAway.screenshot-clipboard", qos: .userInitiated)
    /// Lets a newer scan, or a monitoring restart, supersede one in flight.
    private var scanGeneration = 0
    /// The capture date of the screenshot last put on the clipboard. An older
    /// capture that finishes later never replaces a newer one.
    private var newestCopiedCaptureDate: Date?
    private let thumbnailSuppression = ScreenshotThumbnailSuppression()

    var isEnabled: Bool {
        get {
            UserDefaults.standard.bool(forKey: Self.preferenceKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.preferenceKey)
            if newValue {
                startMonitoring()
            } else {
                stopMonitoring()
            }
            thumbnailSuppression.update(clipboardEnabled: newValue)
        }
    }

    /// Copy Instantly: hides macOS's floating thumbnail, which otherwise holds
    /// each screenshot back from being saved, and so copied, for a few seconds.
    var copiesInstantly: Bool {
        get { thumbnailSuppression.isRequested }
        set {
            thumbnailSuppression.isRequested = newValue
            thumbnailSuppression.update(clipboardEnabled: isEnabled)
        }
    }

    /// Re-applies Copy Instantly, noticing if the user turned the thumbnail back on.
    func updateThumbnailSuppression() {
        thumbnailSuppression.update(clipboardEnabled: isEnabled)
    }

    /// Returns the thumbnail to the user's own setting, for when DockAway quits.
    func restoreThumbnail() {
        thumbnailSuppression.restore()
    }

    private init() {}

    func startMonitoring() {
        stopMonitoring()
        guard isEnabled else { return }

        let folderURL = Self.currentScreenshotDirectoryURL()
        let path = folderURL.path
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            dockAwayDebugLog("ScreenshotClipboardManager: Unable to open directory for monitoring: \(path)")
            return
        }

        self.directoryFileDescriptor = fd
        self.watchedDirectoryURL = folderURL
        self.isMonitoring = true

        populateExistingFiles(in: folderURL, scan: scanGeneration)

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.handleDirectoryChange()
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        self.directorySource = source

        startHealthCheckTimer()
        dockAwayDebugLog("ScreenshotClipboardManager: Monitoring started for \(folderURL.path)")
    }

    func stopMonitoring() {
        pendingDebounceItem?.cancel()
        pendingDebounceItem = nil
        scanGeneration += 1

        healthCheckTimer?.invalidate()
        healthCheckTimer = nil

        if let source = directorySource {
            source.cancel()
            directorySource = nil
            directoryFileDescriptor = -1
        } else if directoryFileDescriptor >= 0 {
            close(directoryFileDescriptor)
            directoryFileDescriptor = -1
        }

        watchedDirectoryURL = nil
        isMonitoring = false
        dockAwayDebugLog("ScreenshotClipboardManager: Monitoring stopped")
    }

    func validateWatchedDirectory() {
        guard isEnabled else { return }
        let currentURL = Self.currentScreenshotDirectoryURL()
        if currentURL != watchedDirectoryURL {
            startMonitoring()
        }
    }

    private func handleDirectoryChange() {
        if captureAnchorMouseLocation == nil {
            captureAnchorMouseLocation = NSEvent.mouseLocation
        }
        pendingDebounceItem?.cancel()
        let debounceInterval = NSScreen.screens.count > 1 ? 0.35 : 0.1
        let item = DispatchWorkItem { [weak self] in
            self?.checkForNewScreenshots()
        }
        pendingDebounceItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: item)
    }

    private func startHealthCheckTimer() {
        healthCheckTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isEnabled else { return }
                self.validateWatchedDirectory()
                self.updateThumbnailSuppression()
                self.checkForNewScreenshots()
            }
        }
        timer.tolerance = 2.0
        healthCheckTimer = timer
    }

    func checkForNewScreenshots() {
        guard isEnabled, let folderURL = watchedDirectoryURL else {
            captureAnchorMouseLocation = nil
            return
        }
        scanGeneration += 1
        let scan = scanGeneration
        workQueue.async {
            let recent = Self.recentScreenshots(in: folderURL, now: Date())
            DispatchQueue.main.async { [weak self] in
                // A newer scan sees the same recent files and any that followed.
                guard let self, self.scanGeneration == scan else { return }
                self.processRecentScreenshots(recent)
            }
        }
    }

    /// Recent screenshots in the folder: files modified in the last 15 seconds
    /// that macOS tagged as screenshots or that have a screenshot name.
    nonisolated static func recentScreenshots(in folderURL: URL, now: Date) -> [(url: URL, identifier: String, date: Date)] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var recent: [(url: URL, identifier: String, date: Date)] = []
        for fileURL in contents {
            let fileName = fileURL.lastPathComponent
            guard isSupportedImage(fileName: fileName),
                  let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey, .fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let fileSize = values.fileSize, fileSize > 0 else { continue }
            let fileDate = values.contentModificationDate ?? values.creationDate ?? .distantPast
            guard now.timeIntervalSince(fileDate) <= 15.0 else { continue }
            // Ordinary images saved to the same folder must never replace the clipboard.
            let isTagged = captureMetadata(for: fileURL)?.isScreenCapture == true
            guard isPotentialScreenshot(fileName: fileName, isTaggedScreenCapture: isTagged) else { continue }
            recent.append((fileURL, "\(fileURL.path)_\(fileDate.timeIntervalSince1970)_\(fileSize)", fileDate))
        }
        return recent
    }

    private func processRecentScreenshots(_ recent: [(url: URL, identifier: String, date: Date)]) {
        let now = Date()
        let pendingScreenshots = recent.filter { !processedFileIdentifiers.contains($0.identifier) }

        guard !pendingScreenshots.isEmpty else {
            captureAnchorMouseLocation = nil
            return
        }

        // When multiple screens are connected, if only 1 file is detected so far,
        // and it was created very recently (< 0.5s ago), wait a brief moment for
        // the remaining monitor screenshot file(s) to finish encoding to disk.
        let screenCount = NSScreen.screens.count
        if screenCount > 1 && pendingScreenshots.count < screenCount {
            if let newestDate = pendingScreenshots.map(\.date).max(),
               now.timeIntervalSince(newestDate) < 0.5 {
                pendingDebounceItem?.cancel()
                let item = DispatchWorkItem { [weak self] in
                    self?.checkForNewScreenshots()
                }
                pendingDebounceItem = item
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
                return
            }
        }

        let anchorPoint = captureAnchorMouseLocation ?? NSEvent.mouseLocation
        captureAnchorMouseLocation = nil

        // Group pending screenshots by base screenshot name (e.g. "Screenshot 2026-09-16 at 05.36.19")
        // so that multi-display screenshots captured in the same second are processed as a single unit.
        let grouped = Dictionary(grouping: pendingScreenshots) { item in
            Self.baseScreenshotName(from: item.url.lastPathComponent)
        }

        // Oldest capture first, so the newest one is copied last.
        let orderedGroups = grouped.values.sorted {
            ($0.map(\.date).max() ?? .distantPast) < ($1.map(\.date).max() ?? .distantPast)
        }
        for group in orderedGroups {
            if group.count == 1 {
                verifyAndCopyScreenshot(at: group[0].url, fileIdentifier: group[0].identifier,
                                        captureDate: group[0].date, attempt: 0)
            } else {
                // Multi-display capture detected!
                // 1. Mark ALL candidate files in this group in processedFileIdentifiers immediately
                //    so that the slower/larger file can NEVER trigger a second copy and overwrite the clipboard!
                for item in group {
                    recordProcessedIdentifier(item.identifier)
                }

                // 2. Select the screenshot corresponding to the screen where the cursor was located
                let targetURL = Self.selectBestScreenshot(from: group.map(\.url), mousePoint: anchorPoint) ?? group[0].url
                let targetIdentifier = group.first(where: { $0.url == targetURL })?.identifier ?? group[0].identifier

                // 3. Unmark only the chosen target and copy it
                processedFileIdentifiers.remove(targetIdentifier)
                let targetDate = group.first(where: { $0.url == targetURL })?.date ?? group[0].date
                verifyAndCopyScreenshot(at: targetURL, fileIdentifier: targetIdentifier, captureDate: targetDate, attempt: 0)
            }
        }
    }

    static func baseScreenshotName(from filename: String) -> String {
        let nameWithoutExt = (filename as NSString).deletingPathExtension
        if let regex = try? NSRegularExpression(pattern: #" \(\d+\)$"#) {
            let range = NSRange(nameWithoutExt.startIndex..., in: nameWithoutExt)
            return regex.stringByReplacingMatches(in: nameWithoutExt, options: [], range: range, withTemplate: "")
        }
        return nameWithoutExt
    }

    static func selectBestScreenshot(from urls: [URL], mousePoint: NSPoint? = nil) -> URL? {
        guard !urls.isEmpty else { return nil }
        guard urls.count > 1 else { return urls[0] }

        let point = mousePoint ?? NSEvent.mouseLocation
        // Each display's file records the area it captured, which identifies
        // the display exactly, even when two share a resolution.
        if let primary = NSScreen.screens.first {
            let globalPoint = CGPoint(x: point.x, y: primary.frame.maxY - point.y)
            if let match = screenshot(containing: globalPoint, in: urls, captureRect: { captureMetadata(for: $0)?.globalRect }) {
                return match
            }
        }

        // Without that record, fall back to the display's pixel size.
        let activeScreen = NSScreen.screens.first(where: { NSPointInRect(point, $0.frame) }) ?? NSScreen.main
        guard let activeScreen else { return urls[0] }

        let targetPixelWidth = activeScreen.frame.width * activeScreen.backingScaleFactor
        let targetPixelHeight = activeScreen.frame.height * activeScreen.backingScaleFactor

        var bestURL: URL?
        var bestDifference: CGFloat = .greatestFiniteMagnitude

        for url in urls {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let pixelWidth = properties[kCGImagePropertyPixelWidth] as? CGFloat,
                  let pixelHeight = properties[kCGImagePropertyPixelHeight] as? CGFloat else {
                continue
            }

            // Exact pixel match for the active display (or rotated orientation)
            if (abs(pixelWidth - targetPixelWidth) < 2 && abs(pixelHeight - targetPixelHeight) < 2) ||
               (abs(pixelWidth - targetPixelHeight) < 2 && abs(pixelHeight - targetPixelWidth) < 2) {
                return url
            }

            // Closest dimension match fallback
            let diff = abs(pixelWidth - targetPixelWidth) + abs(pixelHeight - targetPixelHeight)
            if diff < bestDifference {
                bestDifference = diff
                bestURL = url
            }
        }

        return bestURL ?? urls[0]
    }

    private func verifyAndCopyScreenshot(at url: URL, fileIdentifier: String, captureDate: Date, attempt: Int) {
        guard isEnabled, !isOlderThanCopiedCapture(captureDate) else { return }

        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           CGImageSourceGetStatus(source) == .statusComplete {
            copyScreenshotToClipboard(from: url, fileIdentifier: fileIdentifier, captureDate: captureDate)
            return
        }

        if attempt < 10 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.verifyAndCopyScreenshot(at: url, fileIdentifier: fileIdentifier,
                                              captureDate: captureDate, attempt: attempt + 1)
            }
        }
    }

    private func isOlderThanCopiedCapture(_ captureDate: Date?) -> Bool {
        guard let captureDate, let newestCopiedCaptureDate else { return false }
        return captureDate < newestCopiedCaptureDate
    }

    /// Loads and converts the image off the main thread, then puts it on the
    /// clipboard. `completion` runs on the main thread once that's done or skipped.
    func copyScreenshotToClipboard(from url: URL, fileIdentifier: String, captureDate: Date? = nil,
                                   completion: (() -> Void)? = nil) {
        guard isEnabled, !processedFileIdentifiers.contains(fileIdentifier),
              !isOlderThanCopiedCapture(captureDate) else {
            completion?()
            return
        }
        // Claimed now so a later scan doesn't start a second copy of the same file.
        recordProcessedIdentifier(fileIdentifier)
        workQueue.async {
            let representations = Self.pasteboardRepresentations(for: url)
            DispatchQueue.main.async { [weak self] in
                defer { completion?() }
                guard let self else { return }
                guard let representations else {
                    // Let a later scan try again once the file is readable.
                    self.processedFileIdentifiers.remove(fileIdentifier)
                    return
                }
                guard self.isEnabled, !self.isOlderThanCopiedCapture(captureDate) else { return }

                let item = NSPasteboardItem()
                for (type, data) in representations {
                    item.setData(data, forType: type)
                }
                item.setString(url.absoluteString, forType: .fileURL)
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.writeObjects([item])

                if let captureDate {
                    self.newestCopiedCaptureDate = max(self.newestCopiedCaptureDate ?? captureDate, captureDate)
                }
                self.lastCopiedFileURL = url
                dockAwayDebugLog("Screenshot automatically copied to clipboard: \(url.lastPathComponent)")
            }
        }
    }

    /// The clipboard data for an image file, original format first.
    nonisolated static func pasteboardRepresentations(for url: URL) -> [(NSPasteboard.PasteboardType, Data)]? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        var representations: [(NSPasteboard.PasteboardType, Data)] = []
        switch url.pathExtension.lowercased() {
        case "png": representations.append((.png, data))
        case "jpg", "jpeg": representations.append((.init("public.jpeg"), data))
        case "heic": representations.append((.init("public.heic"), data))
        case "tiff", "tif": representations.append((.tiff, data))
        default: break
        }
        if let image = NSImage(data: data), let tiff = image.tiffRepresentation {
            representations.removeAll { $0.0 == .tiff }
            representations.append((.tiff, tiff))
            if !representations.contains(where: { $0.0 == .png }),
               let bitmap = NSBitmapImageRep(data: tiff),
               let png = bitmap.representation(using: .png, properties: [:]) {
                representations.append((.png, png))
            }
        }
        return representations
    }

    func isProcessed(fileIdentifier: String) -> Bool {
        processedFileIdentifiers.contains(fileIdentifier)
    }

    /// Marks files that were already recent when monitoring started, so they
    /// aren't copied as if they were new. Older files are skipped by the
    /// 15-second window anyway, which keeps this list small.
    private func populateExistingFiles(in folderURL: URL, scan: Int) {
        workQueue.async {
            let existing = Self.recentScreenshots(in: folderURL, now: Date()).map(\.identifier)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.scanGeneration == scan else { return }
                existing.forEach(self.recordProcessedIdentifier)
            }
        }
    }

    private func recordProcessedIdentifier(_ id: String) {
        guard !processedFileIdentifiers.contains(id) else { return }
        processedFileIdentifiers.insert(id)
        recentProcessedOrder.append(id)
        if recentProcessedOrder.count > 1000 {
            let oldest = recentProcessedOrder.removeFirst()
            processedFileIdentifiers.remove(oldest)
        }
    }

    nonisolated static let supportedExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "tif"]

    nonisolated static func isSupportedImage(fileName: String) -> Bool {
        supportedExtensions.contains((fileName as NSString).pathExtension.lowercased()) && !fileName.hasPrefix(".")
    }

    /// A file counts when macOS tagged it as a screenshot, or when it has a
    /// standard or custom screenshot name. An ordinary image saved to the same
    /// folder, or one with a date in its name, doesn't.
    nonisolated static func isPotentialScreenshot(fileName: String, isTaggedScreenCapture: Bool) -> Bool {
        guard isSupportedImage(fileName: fileName) else { return false }
        if isTaggedScreenCapture { return true }

        if let customName = CFPreferencesCopyAppValue("name" as CFString, "com.apple.screencapture" as CFString) as? String,
           !customName.isEmpty,
           fileName.range(of: customName, options: [.caseInsensitive, .anchored]) != nil {
            return true
        }

        let standardPrefixes = [
            "Screenshot",
            "Screen Shot",
            "Capture d’écran",
            "Capture d'écran",
            "Bildschirmfoto",
            "Captura de pantalla",
            "Captura de ecrã",
            "Captura de Tela",
            "Schermata",
            "Schermafbeelding",
            "Снимок экрана",
            "スクリーンショット",
            "스크린샷",
            "屏幕快照"
        ]
        for prefix in standardPrefixes {
            if fileName.hasPrefix(prefix) {
                return true
            }
        }

        return false
    }

    /// What macOS records on each screenshot it saves: whether the file is a
    /// screenshot, and the screen area it captured, in global coordinates with
    /// the origin at the top left of the main display.
    struct CaptureMetadata: Equatable {
        let isScreenCapture: Bool
        let globalRect: CGRect?
    }

    nonisolated static func captureMetadata(for url: URL) -> CaptureMetadata? {
        let isCapture = extendedAttribute("com.apple.metadata:kMDItemIsScreenCapture", of: url) as? Bool
        let rectValues = extendedAttribute("com.apple.metadata:kMDItemScreenCaptureGlobalRect", of: url) as? [NSNumber]
        guard isCapture != nil || rectValues != nil else { return nil }
        let rect = rectValues.flatMap { values in
            values.count == 4
                ? CGRect(x: values[0].doubleValue, y: values[1].doubleValue,
                         width: values[2].doubleValue, height: values[3].doubleValue)
                : nil
        }
        return CaptureMetadata(isScreenCapture: isCapture ?? false, globalRect: rect)
    }

    /// The file whose captured area contains the point, for multi-display captures.
    nonisolated static func screenshot(containing globalPoint: CGPoint, in urls: [URL],
                                       captureRect: (URL) -> CGRect?) -> URL? {
        urls.first { captureRect($0)?.contains(globalPoint) == true }
    }

    private nonisolated static func extendedAttribute(_ name: String, of url: URL) -> Any? {
        url.withUnsafeFileSystemRepresentation { path -> Any? in
            guard let path else { return nil }
            let size = getxattr(path, name, nil, 0, 0, 0)
            guard size > 0 else { return nil }
            var data = Data(count: size)
            let read = data.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, size, 0, 0) }
            guard read == size else { return nil }
            return try? PropertyListSerialization.propertyList(from: data, format: nil)
        }
    }

    static func currentScreenshotDirectoryURL() -> URL {
        if let location = CFPreferencesCopyAppValue("location-screenshot" as CFString, "com.apple.screencapture" as CFString) as? String,
           !location.isEmpty {
            let expanded = (location as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
                return URL(fileURLWithPath: expanded)
            }
        }
        if let location = CFPreferencesCopyAppValue("location" as CFString, "com.apple.screencapture" as CFString) as? String,
           !location.isEmpty {
            let expanded = (location as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
                return URL(fileURLWithPath: expanded)
            }
        }
        let desktop = (NSHomeDirectory() as NSString).appendingPathComponent("Desktop")
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: desktop, isDirectory: &isDir), isDir.boolValue {
            return URL(fileURLWithPath: desktop)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}
