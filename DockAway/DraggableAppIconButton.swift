import AppKit

/// A normal icon button on click, and a native app-file drag on movement.
/// Permission changes remain entirely under System Settings' control.
final class DraggableAppIconButton: NSButton, NSDraggingSource {
    var applicationURL = Bundle.main.bundleURL
    static let dragThreshold: CGFloat = 4

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    static func shouldStartDrag(from origin: NSPoint, to point: NSPoint) -> Bool {
        hypot(point.x - origin.x, point.y - origin.y) >= dragThreshold
    }

    func applicationPasteboardWriter() -> NSURL? {
        let url = applicationURL.standardizedFileURL
        var isDirectory = ObjCBool(false)
        guard url.isFileURL, url.pathExtension.lowercased() == "app",
              FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return url as NSURL
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let window, let writer = applicationPasteboardWriter() else {
            super.mouseDown(with: event)
            return
        }
        let origin = event.locationInWindow
        highlight(true)
        defer { highlight(false) }
        // NSButton's cell otherwise consumes the drag in its click tracking
        // loop. Track the same two native events until click or drag is known.
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let point = convert(next.locationInWindow, from: nil)
            if next.type == .leftMouseUp {
                if bounds.contains(point), isEnabled { performClick(nil) }
                return
            }
            guard Self.shouldStartDrag(from: origin, to: next.locationInWindow) else { continue }
            highlight(false)
            let item = NSDraggingItem(pasteboardWriter: writer)
            // Preserve the pointer's position on the icon as it lifts off.
            var dragFrame = bounds
            dragFrame.origin.x += next.locationInWindow.x - origin.x
            dragFrame.origin.y += next.locationInWindow.y - origin.y
            let dragImage = image ?? NSWorkspace.shared.icon(forFile: writer.path ?? applicationURL.path)
            item.setDraggingFrame(dragFrame, contents: dragImage)
            let session = beginDraggingSession(with: [item], event: next, source: self)
            session.animatesToStartingPositionsOnCancelOrFail = true
            return
        }
    }

    static func allowedOperation(in context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        Self.allowedOperation(in: context)
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
}
