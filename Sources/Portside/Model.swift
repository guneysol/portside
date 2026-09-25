import Foundation

enum Kind {
    case web, database, service, runtime

    var symbol: String {
        switch self {
        case .web: "globe"
        case .database: "cylinder.split.1x2"
        case .service: "shippingbox"
        case .runtime: "terminal"
        }
    }
}

struct ListenPort: Hashable, Comparable {
    let number: Int
    /// Bound to all interfaces (reachable from the network), not just loopback.
    let exposed: Bool

    static func < (a: ListenPort, b: ListenPort) -> Bool { a.number < b.number }
}

struct Project: Hashable {
    let root: String
    let name: String
    let branch: String?
    let isWorktree: Bool
}

struct DevProcess: Identifiable, Hashable {
    let pid: Int32
    var id: Int32 { pid }
    let name: String
    let kind: Kind
    let command: String
    /// Short, human command — e.g. "npm run dev" rather than the node binary path.
    let summary: String
    let exePath: String
    let cwd: String
    let ports: [ListenPort]
    /// A start date rather than an uptime, so unchanged scans compare equal
    /// and SwiftUI has nothing to redraw.
    let started: Date
    let project: Project?
    /// Who started it: "Claude Code", "Cursor", "Terminal", "brew services"…
    let origin: String?
    /// Every pid that goes down when this is stopped (wrapper root + descendants).
    let tree: [Int32]
    let launchdLabel: String?
    let isSystem: Bool
    /// Owned by another user (root…): visible, but we can't stop it.
    let isOwned: Bool

    /// Working directory relative to the project root ("apps/web"), nil at the root itself.
    var subpath: String? {
        guard let root = project?.root, cwd.hasPrefix(root + "/") else { return nil }
        return String(cwd.dropFirst(root.count + 1))
    }
}

struct ProcessGroup: Identifiable {
    let id: String
    let project: Project?
    let processes: [DevProcess]

    var title: String { project?.name ?? "Services" }
}

enum Format {
    static func uptime(_ t: TimeInterval) -> String {
        let s = Int(t)
        switch s {
        case ..<60: return "<1m"
        case ..<3600: return "\(s / 60)m"
        case ..<86400: return "\(s / 3600)h \(s % 3600 / 60)m"
        default: return "\(s / 86400)d \(s % 86400 / 3600)h"
        }
    }

    static func abbreviatingHome(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

extension StringProtocol {
    /// "/usr/bin/node" → "node". Avoids bridging to NSString: this runs for
    /// every command-line token on every scan.
    var basename: SubSequence {
        var end = endIndex
        while end > startIndex, self[index(before: end)] == "/" { end = index(before: end) }
        let start = self[..<end].lastIndex(of: "/").map(index(after:)) ?? startIndex
        return self[start..<end]
    }
}
