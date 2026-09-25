import AppKit
import SwiftUI

@main
struct PortsideApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    private let store = Store.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent(store: store)
        } label: {
            // One steady glyph; the count appears only when something is running.
            let count = store.visible.count
            Image(systemName: "server.rack")
            if count > 0 { Text("\(count)") }
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if args.contains("--list") || args.contains("--stop") || args.contains("--bench") {
            Task { @MainActor in await Debug.run(args) }
            return
        }
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        Task { @MainActor in
            if let h = args.firstIndex(of: "--hover"), h + 1 < args.count { Snapshot.debugHoverPID = Int32(args[h + 1]) }
            Snapshot.debugConfirm = args.contains("--confirm")
            let rows = args.contains("--demo-empty") ? Demo.emptyRows : args.contains("--demo") ? Demo.rows : nil
            await Snapshot.write(to: args[i + 1], dark: args.contains("--dark"), demo: rows)
        }
    }
}

/// `Portside --snapshot out.png [--dark] [--demo | --demo-empty] [--hover <pid>] [--confirm]`
/// renders the popover, then quits. `--demo` uses made-up rows, so screenshots never leak real projects.
enum Snapshot {
    // Debug only: snapshots can't hover or click, so these force those states.
    @MainActor static var debugHoverPID: Int32?
    @MainActor static var debugConfirm = false

    @MainActor
    static func write(to path: String, dark: Bool, demo: [DevProcess]?) async {
        if let demo { Store.shared.showDemo(demo) } else { await Store.shared.refresh() }
        let host = NSHostingView(rootView: MenuContent(store: .shared).background(.windowBackground))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame.size = host.fittingSize
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        try? await Task.sleep(for: .milliseconds(400))
        host.frame.size = host.fittingSize
        host.layoutSubtreeIfNeeded()
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        NSApp.terminate(nil)
    }
}

/// `Portside --list` prints the scan; `Portside --stop <pid>` stops one like the UI does.
enum Debug {
    @MainActor
    static func run(_ args: [String]) async {
        if args.contains("--bench") {
            let scanner = Scanner()
            for foreign in [false, true] {
                _ = scanner.scan(includeForeign: foreign) // warm up
                let clock = ContinuousClock(), n = 50
                let t = clock.measure { for _ in 0..<n { _ = scanner.scan(includeForeign: foreign) } }
                print("scan(includeForeign: \(foreign)): \(t / n) per scan")
            }
            exit(0)
        }
        let procs = Scanner().scan(includeForeign: true)
        if let i = args.firstIndex(of: "--stop"), i + 1 < args.count, let pid = Int32(args[i + 1]),
           let p = procs.first(where: { $0.pid == pid }) {
            await Task.detached { Terminator.stop(p, force: false) }.value
            print("stopped \(pid) (tree \(p.tree.sorted()))")
        } else {
            for p in procs.sorted(by: { $0.pid < $1.pid }) {
                print("\(p.pid)\t\(p.isOwned ? "" : "root ")\(p.isSystem ? "sys" : "dev")\t\(p.name)\t\(p.ports.map(\.number))\t\(p.project?.name ?? "-")\t\(p.summary)\t\(p.origin ?? "-")\ttree=\(p.tree.sorted())")
            }
        }
        exit(0)
    }
}

enum Demo {
    static let rows: [DevProcess] = {
        let web = Project(root: "/demo/acme-web", name: "acme-web", branch: "main", isWorktree: false)
        let checkout = Project(root: "/demo/acme-web-checkout", name: "acme-web",
                               branch: "claude/checkout-redesign-stripe-elements", isWorktree: true)
        let api = Project(root: "/demo/acme-api", name: "acme-api", branch: "main", isWorktree: false)
        return [
            row(101, "Next.js", .web, [3000], "pnpm dev", 42, web, "/apps/web", "Ghostty"),
            row(102, "Next.js", .web, [3002], "pnpm dev", 42, web, "/apps/docs", "Ghostty"),
            row(103, "Next.js", .web, [3001], "pnpm dev", 7, checkout, "/apps/web", "Claude Code"),
            row(104, "Uvicorn", .web, [8000], "uvicorn app.main:app --reload --host 0.0.0.0", 95, api, "", "Codex",
                exposed: true),
            row(105, "PostgreSQL", .database, [5432], "postgres -D /opt/homebrew/var/postgresql@17", 4320, nil, "",
                "brew services"),
            row(106, "Redis", .database, [6379], "redis-server 127.0.0.1:6379", 4320, nil, "", "brew services"),
            row(107, "Mailpit", .service, [1025, 8025], "mailpit", 180, nil, "", "brew services"),
            row(108, "nginx", .web, [80], "nginx: master process", 4400, nil, "", nil, owned: false),
            row(109, "AirPlay Receiver", .service, [7000], "ControlCenter", 4400, nil, "", nil, system: true),
        ]
    }()

    /// Nothing visible, one hidden system listener.
    static let emptyRows = [row(109, "AirPlay Receiver", .service, [7000], "ControlCenter", 4400, nil, "", nil, system: true)]

    private static func row(_ pid: Int32, _ name: String, _ kind: Kind, _ ports: [Int], _ summary: String,
                            _ minutes: Double, _ project: Project?, _ subdir: String, _ origin: String?,
                            exposed: Bool = false, owned: Bool = true, system: Bool = false) -> DevProcess {
        DevProcess(pid: pid, name: name, kind: kind, command: summary, summary: summary, exePath: "",
                   cwd: project.map { $0.root + subdir } ?? "",
                   ports: ports.map { ListenPort(number: $0, exposed: exposed) },
                   started: Date().addingTimeInterval(-minutes * 60), project: project, origin: origin,
                   tree: [pid], launchdLabel: nil, isSystem: system, isOwned: owned)
    }
}
