import AppKit
import Observation
import ServiceManagement

@MainActor @Observable
final class Store {
    static let shared = Store()

    private(set) var processes: [DevProcess] = [] { didSet { regroup() } }
    private(set) var stopping: Set<Int32> = []
    var showSystem = UserDefaults.standard.bool(forKey: "showSystem") {
        didSet {
            UserDefaults.standard.set(showSystem, forKey: "showSystem")
            regroup()
        }
    }

    // Derived once per change rather than on every read: the menu bar label,
    // list, footer and empty state all read these.
    private(set) var visible: [DevProcess] = []
    private(set) var groups: [ProcessGroup] = []
    var hiddenCount: Int { processes.count - visible.count }

    /// Mirrors SMAppService, which SwiftUI can't observe, so the checkmark
    /// updates the moment it's toggled. Re-read on open in case it was changed
    /// in System Settings.
    private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled

    func setLaunchAtLogin(_ on: Bool) {
        try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    @ObservationIgnored private let scanner = Scanner()
    @ObservationIgnored private var isOpen = false
    @ObservationIgnored private var inFlight: Task<Void, Never>?
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private var demoMode = false
    /// When the scan behind `processes` finished; Stop only signals pids at least that old.
    @ObservationIgnored private var scannedAt = Date.distantPast

    private func regroup() {
        visible = processes.filter { showSystem || !$0.isSystem }
        groups = Dictionary(grouping: visible) { $0.project?.root ?? "" }
            .map { root, procs in
                ProcessGroup(id: root, project: procs.first?.project,
                             processes: procs.sorted { ($0.ports.first?.number ?? 0) < ($1.ports.first?.number ?? 0) })
            }
            .sorted { a, b in
                // Projects alphabetically, loose services last.
                if (a.project == nil) != (b.project == nil) { return a.project != nil }
                let order = a.title.localizedStandardCompare(b.title)
                if order != .orderedSame { return order == .orderedAscending }
                if a.project?.isWorktree != b.project?.isWorktree { return a.project?.isWorktree == false }
                return a.id < b.id // stable order for same-named worktrees
            }
    }

    private init() {
        // The app has no other windows, so a key window means the popover is open.
        let center = NotificationCenter.default
        center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let store = Store.shared
                store.isOpen = true
                store.launchAtLogin = SMAppService.mainApp.status == .enabled
                store.startPolling() // refresh now, and cut short a 10s background sleep
            }
        }
        center.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Store.shared.isOpen = false }
        }
        startPolling()
    }

    /// 2s while you're looking; 10s in the background, only to keep the menu
    /// bar count fresh. Tolerance lets macOS coalesce wakeups with other timers.
    private func startPolling() {
        poller?.cancel()
        poller = Task {
            while !Task.isCancelled {
                await refresh()
                let open = isOpen
                try? await Task.sleep(for: .seconds(open ? 2 : 10), tolerance: .seconds(open ? 0.2 : 3))
            }
        }
    }

    /// Always reflects a scan started after the call. Scans never overlap (the
    /// Scanner isn't thread-safe): a caller arriving mid-scan waits for it, then
    /// shares one follow-up scan with anyone else who arrived meanwhile.
    func refresh() async {
        if demoMode { return }
        if let inFlight { await inFlight.value }
        if let inFlight { return await inFlight.value }
        let scanner = scanner, includeForeign = isOpen || showSystem
        let task = Task {
            let fresh = await Task.detached(priority: .utility) {
                scanner.scan(includeForeign: includeForeign).sorted { $0.pid < $1.pid }
            }.value
            if !demoMode {
                scannedAt = Date()
                if fresh != processes { processes = fresh } // no-op scans don't touch SwiftUI
            }
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
        let scannedAt = scannedAt
        Task {
            await withTaskGroup(of: Void.self) { group in
                for p in targets { group.addTask { await Terminator.stop(p, force: force, asOf: scannedAt) } }
            }
            await refresh()
            stopping.subtract(targets.map(\.pid))
        }
    }
}

enum Terminator {
    /// SIGTERM the tree, SIGKILL whatever is left after 3s. Only pids that already
    /// existed at `scanned` are signalled, so a pid reused since then is left alone.
    static func stop(_ p: DevProcess, force: Bool, asOf scanned: Date) async {
        // brew services have KeepAlive — a plain kill just gets them restarted.
        if !force, let label = p.launchdLabel, label.hasPrefix("homebrew.mxcl."),
           let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first(where: FileManager.default.isExecutableFile) {
            let name = String(label.dropFirst("homebrew.mxcl.".count))
            // brew can take seconds; keep it off Swift's small cooperative pool.
            await withCheckedContinuation { done in
                DispatchQueue.global(qos: .userInitiated).async {
                    Shell.run(brew, ["services", "stop", name])
                    done.resume()
                }
            }
            if !isRunning(p.pid, startedBy: scanned) { return }
        }

        let pids = p.tree.filter { $0 > 1 && isRunning($0, startedBy: scanned) }
        pids.forEach { kill($0, force ? SIGKILL : SIGTERM) }
        guard !force else { return }

        for _ in 0..<30 {
            if !pids.contains(where: { isRunning($0, startedBy: scanned) }) { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        pids.filter { isRunning($0, startedBy: scanned) }.forEach { kill($0, SIGKILL) }
    }

    /// Alive, not a zombie waiting to be reaped, and started no later than `scanned`.
    private static func isRunning(_ pid: Int32, startedBy scanned: Date) -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0,
              Int32(info.kp_proc.p_stat) != SZOMB else { return false }
        let t = info.kp_proc.p_starttime
        return Double(t.tv_sec) + Double(t.tv_usec) / 1e6 <= scanned.timeIntervalSince1970
    }
}
