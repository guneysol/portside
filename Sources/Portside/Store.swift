import AppKit
import Observation

@MainActor @Observable
final class Store {
    static let shared = Store()

    private(set) var processes: [DevProcess] = []
    private(set) var stopping: Set<Int32> = []
    var showSystem = UserDefaults.standard.bool(forKey: "showSystem") {
        didSet { UserDefaults.standard.set(showSystem, forKey: "showSystem") }
    }

    @ObservationIgnored private let scanner = Scanner()
    @ObservationIgnored private var isOpen = false
    @ObservationIgnored private var inFlight: Task<Void, Never>?
    @ObservationIgnored private var demoMode = false

    var visible: [DevProcess] { processes.filter { showSystem || !$0.isSystem } }
    var hiddenCount: Int { processes.count - visible.count }

    var groups: [ProcessGroup] {
        Dictionary(grouping: visible) { $0.project?.root ?? "" }
            .map { root, procs in
                ProcessGroup(id: root, project: procs.first?.project,
                             processes: procs.sorted { ($0.ports.first?.number ?? 0) < ($1.ports.first?.number ?? 0) })
            }
            .sorted { a, b in
                // Projects alphabetically, loose services last.
                if (a.project == nil) != (b.project == nil) { return a.project != nil }
                let order = a.title.localizedStandardCompare(b.title)
                if order != .orderedSame { return order == .orderedAscending }
                return a.project?.isWorktree == false && b.project?.isWorktree == true
            }
    }

    private init() {
        // The app has no other windows, so a key window means the popover is open.
        let center = NotificationCenter.default
        center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                Store.shared.isOpen = true
                Task { await Store.shared.refresh() }
            }
        }
        center.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Store.shared.isOpen = false }
        }
        Task { await pollForever() }
    }

    /// 2s while you're looking; 10s in the background, only to keep the menu
    /// bar count fresh. Tolerance lets macOS coalesce wakeups with other timers.
    private func pollForever() async {
        while true {
            await refresh()
            let open = isOpen
            try? await Task.sleep(for: .seconds(open ? 2 : 10), tolerance: .seconds(open ? 0.2 : 3))
        }
    }

    /// Coalesces: callers during a scan wait for that scan instead of starting another.
    func refresh() async {
        if demoMode { return }
        if let inFlight { return await inFlight.value }
        let scanner = scanner, includeForeign = isOpen || showSystem
        let task = Task {
            let fresh = await Task.detached(priority: .utility) {
                scanner.scan(includeForeign: includeForeign).sorted { $0.pid < $1.pid }
            }.value
            if !demoMode, fresh != processes { processes = fresh } // no-op scans don't touch SwiftUI
            inFlight = nil
        }
        inFlight = task
        await task.value
    }

    /// Replaces live data with fixed rows (used for README screenshots).
    func showDemo(_ rows: [DevProcess]) {
        demoMode = true
        processes = rows
    }

    func stop(_ processes: [DevProcess], force: Bool = false) {
        let targets = processes.filter { !stopping.contains($0.pid) }
        guard !targets.isEmpty else { return }
        stopping.formUnion(targets.map(\.pid))
        Task {
            await Task.detached {
                await withTaskGroup(of: Void.self) { group in
                    for p in targets { group.addTask { Terminator.stop(p, force: force) } }
                }
            }.value
            await refresh()
            stopping.subtract(targets.map(\.pid))
        }
    }
}

enum Terminator {
    static func stop(_ p: DevProcess, force: Bool) {
        // brew services have KeepAlive — a plain kill just gets them restarted.
        if !force, let label = p.launchdLabel, label.hasPrefix("homebrew.mxcl."),
           let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first(where: FileManager.default.isExecutableFile) {
            Shell.run(brew, ["services", "stop", String(label.dropFirst("homebrew.mxcl.".count))])
            if !alive(p.pid) { return }
        }

        let pids = p.tree
        pids.forEach { kill($0, force ? SIGKILL : SIGTERM) }
        guard !force else { return }

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if !pids.contains(where: alive) { return }
            usleep(100_000)
        }
        pids.filter(alive).forEach { kill($0, SIGKILL) }
    }

    private static func alive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }
}
