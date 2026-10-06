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

        populateExistingFiles(in: folderURL)

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

        let folderName = folderURL.lastPathComponent.lowercased()
        let isDedicated = folderName.contains("screenshot")
            || CFPreferencesCopyAppValue("location" as CFString, "com.apple.screencapture" as CFString) != nil
            || CFPreferencesCopyAppValue("location-screenshot" as CFString, "com.apple.screencapture" as CFString) != nil

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            captureAnchorMouseLocation = nil
            return
        }

        let now = Date()
        var pendingScreenshots: [(url: URL, identifier: String, date: Date)] = []

        for fileURL in contents {
            let fileName = fileURL.lastPathComponent
            guard Self.isPotentialScreenshot(fileName: fileName, isInDedicatedScreenshotFolder: isDedicated) else {
                continue
            }

            guard let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey, .fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let fileSize = values.fileSize, fileSize > 0 else {
                continue
            }

            let fileDate = values.contentModificationDate ?? values.creationDate ?? .distantPast
            // Only process recent files (created/modified within last 15 seconds)
            guard now.timeIntervalSince(fileDate) <= 15.0 else {
                continue
            }

            let fileIdentifier = "\(fileURL.path)_\(fileDate.timeIntervalSince1970)_\(fileSize)"
            guard !processedFileIdentifiers.contains(fileIdentifier) else {
                continue
            }

            pendingScreenshots.append((fileURL, fileIdentifier, fileDate))
        }

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

        for (_, group) in grouped {
            if group.count == 1 {
                verifyAndCopyScreenshot(at: group[0].url, fileIdentifier: group[0].identifier, attempt: 0)
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
                verifyAndCopyScreenshot(at: targetURL, fileIdentifier: targetIdentifier, attempt: 0)
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

    private func verifyAndCopyScreenshot(at url: URL, fileIdentifier: String, attempt: Int) {
        guard isEnabled else { return }

        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           CGImageSourceGetStatus(source) == .statusComplete {
            copyScreenshotToClipboard(from: url, fileIdentifier: fileIdentifier)
            return
        }

        if attempt < 10 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.verifyAndCopyScreenshot(at: url, fileIdentifier: fileIdentifier, attempt: attempt + 1)
            }
        }
    }

    func copyScreenshotToClipboard(from url: URL, fileIdentifier: String) {
        guard isEnabled else { return }
        guard !processedFileIdentifiers.contains(fileIdentifier) else { return }

        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return }

        let ext = url.pathExtension.lowercased()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        let item = NSPasteboardItem()

        if ext == "png" {
            item.setData(data, forType: .png)
        } else if ext == "jpg" || ext == "jpeg" {
            item.setData(data, forType: .init("public.jpeg"))
        } else if ext == "heic" {
            item.setData(data, forType: .init("public.heic"))
        } else if ext == "tiff" || ext == "tif" {
            item.setData(data, forType: .tiff)
        }

        if let image = NSImage(contentsOf: url), let tiff = image.tiffRepresentation {
            item.setData(tiff, forType: .tiff)
            if item.data(forType: .png) == nil,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                item.setData(png, forType: .png)
            }
        }

        item.setString(url.absoluteString, forType: .fileURL)

        pasteboard.writeObjects([item])

        lastCopiedFileURL = url
        recordProcessedIdentifier(fileIdentifier)
        dockAwayDebugLog("Screenshot automatically copied to clipboard: \(url.lastPathComponent)")
    }

    func isProcessed(fileIdentifier: String) -> Bool {
        processedFileIdentifiers.contains(fileIdentifier)
    }

    private func populateExistingFiles(in folderURL: URL) {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for fileURL in contents {
            if let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey, .fileSizeKey]),
               let fileSize = values.fileSize {
                let fileDate = values.contentModificationDate ?? values.creationDate ?? .distantPast
                let identifier = "\(fileURL.path)_\(fileDate.timeIntervalSince1970)_\(fileSize)"
                processedFileIdentifiers.insert(identifier)
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

    static let supportedExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "tif"]

    static func isPotentialScreenshot(fileName: String, isInDedicatedScreenshotFolder: Bool) -> Bool {
        let ext = (fileName as NSString).pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else { return false }
        guard !fileName.hasPrefix(".") else { return false }

        if isInDedicatedScreenshotFolder {
            return true
        }

        if let customName = CFPreferencesCopyAppValue("name" as CFString, "com.apple.screencapture" as CFString) as? String,
           !customName.isEmpty,
           fileName.localizedCaseInsensitiveContains(customName) {
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

        if fileName.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil {
            return true
        }

        return false
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
