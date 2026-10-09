import AppKit
import SwiftUI

/// Command-line flags run before any UI exists, so a status bar polling `--json`
/// pays for a scan, not an app launch. Everything else starts the menu bar app.
@main
enum Entry {
    @MainActor
    static func main() {
        let args = CommandLine.arguments
        guard CLI.handles(args) else { return PortsideApp.main() }
        Task { exit(await CLI.run(args)) }
        dispatchMain()
    }
}

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

/// `Portside --json [--all]` prints the scan for scripts and status bars; `--stop <pid> [--force]`
/// stops one like Stop (or Force Quit) does. `--list` and `--bench` are for debugging.
enum CLI {
    static func handles(_ args: [String]) -> Bool {
        ["--json", "--list", "--stop", "--bench"].contains(where: args.contains)
    }

    @MainActor
    static func run(_ args: [String]) async -> Int32 {
        // Off the main thread, like Store.refresh: there, Process.waitUntilExit (netstat)
        // is ~30x slower and autoreleased objects are never drained.
        let scanner = Scanner()
        if args.contains("--bench") {
            for foreign in [false, true] {
                let clock = ContinuousClock(), n = 50
                _ = await Task.detached { scanner.scan(includeForeign: foreign) }.value // warm up
                let start = clock.now
                for _ in 0..<n { _ = await Task.detached { scanner.scan(includeForeign: foreign) }.value }
                print("scan(includeForeign: \(foreign)): \((clock.now - start) / n) per scan")
            }
            return 0
        }
        // Other users' listeners cost a netstat spawn and can't be stopped, so only --list and --all ask.
        let foreign = args.contains("--list") || args.contains("--all")
        let scanned = Date() // before the scan, as in Store.refresh: a pid reused mid-scan is never "ours"
        let procs = await Task.detached { scanner.scan(includeForeign: foreign) }.value

        if let i = args.firstIndex(of: "--stop") {
            guard i + 1 < args.count, let pid = Int32(args[i + 1]),
                  let p = procs.first(where: { $0.pid == pid }) else {
                FileHandle.standardError.write(Data("no listener with that pid\n".utf8))
                return 1
            }
            guard p.canStop else {
                FileHandle.standardError.write(Data("\(pid) can't be stopped from here\n".utf8))
                return 1
            }
            await Terminator.stop(p, force: args.contains("--force"), asOf: scanned)
            print("stopped \(pid) (tree \(p.tree.sorted()))")
        } else if args.contains("--json") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            guard let data = try? encoder.encode(Output(processes: procs.sorted { $0.pid < $1.pid }.map(Row.init))) else {
                return 1
            }
            FileHandle.standardOutput.write(data + Data("\n".utf8))
        } else {
            for p in procs.sorted(by: { $0.pid < $1.pid }) {
                let project = p.project.map { "\($0.name)\($0.isWorktree ? " (worktree)" : "")@\($0.branch ?? "-")" } ?? "-"
                print("\(p.pid)\t\(p.isOwned ? "" : "root ")\(p.isSystem ? "sys" : "dev")\t\(p.name)\t\(p.ports.map(\.number))\t\(project)\t\(p.summary)\t\(p.origin ?? "-")\ttree=\(p.tree)")
            }
        }
        return 0
    }

    /// The `--json` format. Fields are only ever added, never renamed or removed;
    /// optional ones are left out when empty.
    private struct Output: Encodable {
        let processes: [Row]
    }

    private struct Row: Encodable {
        struct Port: Encodable {
            let port: Int
            let exposed: Bool
        }
        struct Repo: Encodable {
            let name: String
            let root: String
            let branch: String?
            let worktree: Bool
        }
        /// Negative for a Docker container, which has no host pid; `--stop` takes it all the same.
        let pid: Int32
        let name: String
        let kind: String
        let ports: [Port]
        let summary: String
        let command: String
        let cwd: String?
        let subpath: String?
        /// Unix time in seconds.
        let started: Int
        let origin: String?
        let project: Repo?
        let container: String?
        let system: Bool
        let owned: Bool
        let stoppable: Bool

        init(_ p: DevProcess) {
            pid = p.pid
            name = p.name
            kind = p.kind.rawValue
            ports = p.ports.map { Port(port: $0.number, exposed: $0.exposed) }
            summary = p.summary
            command = p.command
            cwd = p.cwd.isEmpty ? nil : p.cwd
            subpath = p.subpath
            started = Int(p.started.timeIntervalSince1970)
            origin = p.origin
            project = p.project.map { Repo(name: $0.name, root: $0.root, branch: $0.branch, worktree: $0.isWorktree) }
            container = p.container?.name
            system = p.isSystem
            owned = p.isOwned
            stoppable = p.canStop
        }
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
            row(110, "PostgreSQL", .database, [5433], "db · postgres:16", 95, api, "", "docker compose",
                container: "acme-api-db-1"),
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
                            exposed: Bool = false, owned: Bool = true, system: Bool = false,
                            container: String? = nil) -> DevProcess {
        var row = DevProcess(pid: pid, name: name, kind: kind, command: summary, summary: summary, exePath: "",
                             cwd: project.map { $0.root + subdir } ?? "",
                             ports: ports.map { ListenPort(number: $0, exposed: exposed) },
                             started: Date().addingTimeInterval(-minutes * 60), project: project, origin: origin,
                             tree: [pid], launchdLabel: nil, isSystem: system, isOwned: owned)
        row.container = container.map {
            Container(id: "", name: $0, image: "", command: summary, created: row.started, ports: row.ports,
                      composeProject: nil, composeService: nil, composeDirectory: nil, socket: "")
        }
        return row
    }
}
