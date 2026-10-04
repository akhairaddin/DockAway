import Foundation

/// Keep a stable ring even though raising a window changes its stacking order.
/// Selection is advanced only by a completed click, never by a cancelled drag.
struct DockAppWindowCycle {
    private(set) var orderedWindowIDs: [UInt32] = []
    private(set) var requestedWindowID: UInt32?

    mutating func nextWindow(availableWindowIDs: [UInt32], focusedWindowID: UInt32?,
                             operationInFlight: Bool) -> UInt32? {
        var seen = Set<UInt32>()
        let available = availableWindowIDs.filter { $0 != 0 && seen.insert($0).inserted }
        let liveIDs = Set(available)
        orderedWindowIDs.removeAll { !liveIDs.contains($0) }
        let retained = Set(orderedWindowIDs)
        orderedWindowIDs.append(contentsOf: available.filter { !retained.contains($0) })

        guard orderedWindowIDs.count > 1 else {
            requestedWindowID = nil
            return nil
        }
        // While the last raise is still running, follow the most recent click
        // rather than a stale AX focus snapshot from before that raise.
        let anchor = operationInFlight ? (requestedWindowID ?? focusedWindowID) : focusedWindowID
        let next: UInt32
        if let anchor, let index = orderedWindowIDs.firstIndex(of: anchor) {
            next = orderedWindowIDs[(index + 1) % orderedWindowIDs.count]
        } else {
            next = orderedWindowIDs[0]
        }
        requestedWindowID = next
        return next
    }

    mutating func finished(windowID: UInt32) {
        guard requestedWindowID == windowID else { return }
        requestedWindowID = nil
    }
}
