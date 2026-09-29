import Foundation

enum DisplayListOrder: String, CaseIterable {
    case numerical, activeFirst, lastUsed
    static let preferenceKey = "displayListOrder"
    static let historyKey = "displayListRecentDisplays"
    static var current: Self {
        Self(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "") ?? .activeFirst
    }
    var title: String {
        switch self {
        case .numerical: "Off (Numerical)"
        case .activeFirst: "Active First"
        case .lastUsed: "Last Used (3+ Displays)"
        }
    }
    func indices(keys: [String], active: String?, recent: [String]) -> [Int] {
        let original = Array(keys.indices)
        guard self != .numerical else { return original }
        let priority: [String]
        if self == .activeFirst || keys.count < 3 {
            priority = active.map { [$0] } ?? []
        } else {
            var list: [String] = []
            if let active { list.append(active) }
            for key in recent where !list.contains(key) {
                list.append(key)
            }
            priority = list
        }
        return original.sorted {
            let left = priority.firstIndex(of: keys[$0]) ?? Int.max
            let right = priority.firstIndex(of: keys[$1]) ?? Int.max
            return left == right ? $0 < $1 : left < right
        }
    }
}
