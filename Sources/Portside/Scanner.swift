import Darwin
import Foundation

/// Builds a snapshot of every process listening on a TCP port, enriched with
/// project, origin and the process tree needed to stop it cleanly.
///
/// Everything is read in-process from the kernel (sysctl + libproc) — no
/// `lsof`/`ps` subprocesses — so a scan costs about a millisecond.
///
/// Not thread-safe (it reuses buffers and caches between scans); `Store.refresh`
/// guarantees scans never overlap, which is what makes the unchecked Sendable sound.
final class Scanner: @unchecked Sendable {
    private struct Proc {
        let pid: Int32
        let ppid: Int32
        let uid: uid_t
        let started: Date
        let comm: String
    }

    private let uid = getuid()
    /// launchd label per pid (nil = not a launchd job), valid while the start time matches.
    private var labelCache: [Int32: (started: Date, label: String?)] = [:]
    private var argsBuffer = [UInt8](repeating: 0, count: Scanner.argMax)
    private var fdBuffer = [proc_fdinfo](repeating: proc_fdinfo(), count: 256)

    /// Per-scan lookups, reset at the start of every scan: listeners share
    /// ancestors (the same shell, terminal, agent), so each is inspected once.
    private struct Memo {
        var args: [Int32: String] = [:]
        var exe: [Int32: String] = [:]
        var boundary: [Int32: Bool] = [:]
        var origin: [Int32: String?] = [:]
        var project: [String: Project] = [:] // per scan, so branch switches show up
    }
    private var memo = Memo()

    /// - Parameter includeForeign: also report listeners owned by other users
    ///   (root daemons…). Costs one `netstat` spawn, so it only runs while the
    ///   popover is open.
    func scan(includeForeign: Bool) -> [DevProcess] {
        memo = Memo()

        let procs = Self.processTable()
        var listening: [Int32: [ListenPort]] = [:]
        for p in procs.values where p.uid == uid {
            let ports = listeningPorts(p.pid)
            if !ports.isEmpty { listening[p.pid] = ports }
        }
        if includeForeign {
            let seen = Set(listening.values.joined().map(\.number))
            for (pid, ports) in Self.foreignListeners() where listening[pid] == nil {
                let unseen = ports.filter { !seen.contains($0.number) }
                if !unseen.isEmpty { listening[pid] = unseen }
            }
        }
        guard !listening.isEmpty else { return [] }

        var children: [Int32: [Int32]] = [:]
        for p in procs.values { children[p.ppid, default: []].append(p.pid) }

        // Memoized: sibling listeners climb through the same ancestors.
        var treeMemo: [Int32: Set<Int32>] = [:]
        func descendants(_ pid: Int32) -> Set<Int32> {
            if let memo = treeMemo[pid] { return memo }
            var out: Set<Int32> = [pid], stack = [pid]
            while let next = stack.popLast() {
                for c in children[next] ?? [] where out.insert(c).inserted { stack.append(c) }
            }
            treeMemo[pid] = out
            return out
        }

        let listeningPids = Set(listening.keys)
        // Never in a stop tree: this app and whatever launched it (`Portside --stop` from a shell).
        var protected: Set<Int32> = []
        var ancestor = procs[getpid()]
        while let a = ancestor, a.pid > 1, protected.insert(a.pid).inserted { ancestor = procs[a.ppid] }
        labelCache = labelCache.filter { procs[$0.key]?.started == $0.value.started }
        let daemons = listening.keys.compactMap { procs[$0] }.filter { $0.ppid == 1 }
        if daemons.contains(where: { labelCache[$0.pid] == nil }) {
            let labels = Self.launchdLabels()
            for p in daemons { labelCache[p.pid] = (p.started, labels[p.pid]) }
        }

        return listening.compactMap { pid, ports -> DevProcess? in
            guard let proc = procs[pid] else { return nil }
            let exe = executablePath(pid)
            let command = commandLine(proc)
            let owned = proc.uid == uid

            // Climb through wrappers (npm, sh -c, turbo…) so Stop takes the whole
            // chain down — but never into a sibling server's tree.
            var chain = [proc]
            var rootTree = descendants(pid)
            while owned, let parent = procs[chain.last!.ppid], parent.pid > 1, parent.uid == uid,
                  !isBoundary(parent) {
                let parentTree = descendants(parent.pid)
                guard !listeningPids.contains(where: { parentTree.contains($0) && !rootTree.contains($0) }) else { break }
                chain.append(parent)
                rootTree = parentTree
            }

            let summarySource = chain.reversed().first { !Self.isShellWrapper(commandLine($0)) } ?? proc
            let (name, kind) = Classifier.describe(command: command, exePath: exe)
            let cwd = owned ? Self.workingDirectory(pid) : ""
            let label = labelCache[pid]?.label

            return DevProcess(
                pid: pid,
                name: name,
                kind: kind,
                command: command,
                summary: Classifier.summarize(commandLine(summarySource)),
                exePath: exe,
                cwd: cwd,
                ports: ports.sorted(),
                started: proc.started,
                project: label == nil ? project(for: cwd) : nil,
                origin: label.map { $0.hasPrefix("homebrew.mxcl.") ? "brew services" : "launchd" }
                    ?? (owned ? origin(of: chain.last!.ppid, procs: procs) : "root"),
                tree: owned ? rootTree.subtracting(protected).sorted() : [pid],
                launchdLabel: label,
                isSystem: !owned || Self.isSystemExecutable(exe),
                isOwned: owned
            )
        }
    }

    // MARK: - Kernel sources

    private static func processTable() -> [Int32: Proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return [:] }
        size += size / 8 // processes may appear between the two calls
        let stride = MemoryLayout<kinfo_proc>.stride
        var list = [kinfo_proc](repeating: kinfo_proc(), count: size / stride)
        guard sysctl(&mib, 4, &list, &size, nil, 0) == 0 else { return [:] }

        var result: [Int32: Proc] = [:]
        result.reserveCapacity(size / stride)
        for var k in list.prefix(size / stride) {
            let t = k.kp_proc.p_starttime
            let comm = withUnsafeBytes(of: &k.kp_proc.p_comm) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            result[k.kp_proc.p_pid] = Proc(
                pid: k.kp_proc.p_pid,
                ppid: k.kp_eproc.e_ppid,
                uid: k.kp_eproc.e_ucred.cr_uid,
                started: Date(timeIntervalSince1970: Double(t.tv_sec) + Double(t.tv_usec) / 1e6),
                comm: comm
            )
        }
        return result
    }

    /// One PROC_PIDLISTFDS call into a reused buffer (this runs for every process
    /// we own, every scan), growing it only when a process fills it.
    private func listeningPorts(_ pid: Int32) -> [ListenPort] {
        let stride = MemoryLayout<proc_fdinfo>.stride
        var filled: Int32 = 0
        while true {
            let capacity = Int32(fdBuffer.count * stride)
            filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fdBuffer, capacity)
            guard filled > 0 else { return [] }
            if filled < capacity { break }
            fdBuffer = [proc_fdinfo](repeating: proc_fdinfo(), count: fdBuffer.count * 2)
        }

        var ports: [Int: Bool] = [:] // port → exposed (merges IPv4 + IPv6 sockets)
        let infoSize = Int32(MemoryLayout<socket_fdinfo>.size)
        for fd in fdBuffer.prefix(Int(filled) / stride) where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
            var info = socket_fdinfo()
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, infoSize) == infoSize,
                  info.psi.soi_kind == SOCKINFO_TCP else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)))
            ports[port, default: false] = ports[port, default: false] || Self.isWildcard(tcp.tcpsi_ini)
        }
        return ports.map { ListenPort(number: $0.key, exposed: $0.value) }
    }

    private static func isWildcard(_ ini: in_sockinfo) -> Bool {
        var ini = ini
        if ini.insi_vflag & UInt8(INI_IPV6) != 0 {
            return withUnsafeBytes(of: &ini.insi_laddr.ina_6) { $0.allSatisfy { $0 == 0 } }
        }
        return ini.insi_laddr.ina_46.i46a_addr4.s_addr == 0
    }

    /// Listeners of processes we can't inspect (other users). The kernel only
    /// exposes those through netstat's private sysctl, so we ask netstat.
    private static func foreignListeners() -> [Int32: [ListenPort]] {
        var result: [Int32: [Int: Bool]] = [:]
        for line in Shell.run("/usr/sbin/netstat", ["-anv", "-p", "tcp"]).split(separator: "\n") {
            let cols = line.split(separator: " ")
            // "process:pid" starts at column 10, but the name may contain spaces
            // ("Code Helper:123"), so find the first later column with a ":pid" suffix.
            guard cols.count > 10, cols[5] == "LISTEN",
                  let pid = cols[10...].lazy.compactMap(Self.pidSuffix).first,
                  let dot = cols[3].lastIndex(of: "."), let port = Int(cols[3][cols[3].index(after: dot)...])
            else { continue }
            let host = cols[3][..<dot]
            let exposed = host == "*" || host == "0.0.0.0" || host == "::"
            result[pid, default: [:]][port] = (result[pid]?[port] ?? false) || exposed
        }
        return result.mapValues { $0.map { ListenPort(number: $0.key, exposed: $0.value) } }
    }

    /// "node:4242" → 4242
    private static func pidSuffix(_ column: Substring) -> Int32? {
        column.lastIndex(of: ":").flatMap { Int32(column[column.index(after: $0)...]) }
    }

    private static func launchdLabels() -> [Int32: String] {
        var result: [Int32: String] = [:]
        for line in Shell.run("/bin/launchctl", ["list"]).split(separator: "\n") {
            let cols = line.split(separator: "\t")
            if cols.count == 3, let pid = Int32(cols[0]) { result[pid] = String(cols[2]) }
        }
        return result
    }

    private static let argMax: Int = {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctl(&mib, 2, &value, &size, nil, 0) == 0 ? Int(value) : 1 << 20
    }()

    /// Full argv via KERN_PROCARGS2, falling back to the short kernel name.
    private func commandLine(_ proc: Proc) -> String {
        if let hit = memo.args[proc.pid] { return hit }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, proc.pid]
        var size = argsBuffer.count
        var result = proc.comm
        if sysctl(&mib, 3, &argsBuffer, &size, nil, 0) == 0, size > 4 {
            let argc = argsBuffer.withUnsafeBytes { $0.load(as: Int32.self) }
            var i = 4
            while i < size, argsBuffer[i] != 0 { i += 1 } // exec path
            while i < size, argsBuffer[i] == 0 { i += 1 } // padding
            var args: [String] = []
            while args.count < argc, i < size {
                let start = i
                while i < size, argsBuffer[i] != 0 { i += 1 }
                args.append(String(decoding: argsBuffer[start..<i], as: UTF8.self))
                i += 1
            }
            if !args.isEmpty { result = args.joined(separator: " ") }
        }
        memo.args[proc.pid] = result
        return result
    }

    private func executablePath(_ pid: Int32) -> String {
        if let hit = memo.exe[pid] { return hit }
        var buf = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN)) // PROC_PIDPATHINFO_MAXSIZE
        let length = Int(proc_pidpath(pid, &buf, UInt32(buf.count)))
        let path = length > 0 ? String(decoding: buf[..<length], as: UTF8.self) : ""
        memo.exe[pid] = path
        return path
    }

    private static func workingDirectory(_ pid: Int32) -> String {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return "" }
        return withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
    }

    // MARK: - Process tree rules

    private static let shells: Set<String> = ["sh", "bash", "zsh", "fish", "dash"]
    private static let agents: [String: String] = [
        "claude": "Claude Code", "codex": "Codex", "gemini": "Gemini CLI",
        "opencode": "opencode", "aider": "Aider", "amp": "Amp", "cursor-agent": "Cursor Agent",
    ]

    private static func tokens(_ command: String) -> [String] {
        command.split(separator: " ", maxSplits: 2).prefix(2).map {
            $0.basename.trimmingCharacters(in: ["-"]).lowercased()
        }
    }

    private static func isShellWrapper(_ command: String) -> Bool {
        guard let first = command.split(separator: " ", maxSplits: 1).first,
              shells.contains(first.basename.trimmingCharacters(in: ["-"])) else { return false }
        return command.split(separator: " ").contains("-c")
    }

    private static func agentName(_ command: String, exe: String) -> String? {
        guard !isInstalledApp(exe) else { return nil } // Claude.app itself isn't an agent
        if exe.contains("/claude/versions/") { return "Claude Code" }
        if let agent = agents[exe.basename.lowercased()] { return agent }
        return tokens(command).lazy.compactMap { agents[$0] }.first
    }

    /// Where climbing must stop: interactive shells, terminals/IDEs, agents, launchd.
    private func isBoundary(_ proc: Proc) -> Bool {
        if let hit = memo.boundary[proc.pid] { return hit }
        let command = commandLine(proc), exe = executablePath(proc.pid)
        let result: Bool
        if Self.agentName(command, exe: exe) != nil || Self.appName(exe) != nil || Self.isSystemExecutable(exe) {
            result = true
        } else if let first = Self.tokens(command).first {
            result = Self.shells.contains(first) ? !Self.isShellWrapper(command)
                : ["login", "tmux", "screen", "sshd", "zellij"].contains(first)
        } else {
            result = true
        }
        memo.boundary[proc.pid] = result
        return result
    }

    /// The nearest agent, app or multiplexer at or above `pid`.
    private func origin(of pid: Int32, procs: [Int32: Proc]) -> String? {
        guard pid > 1, let p = procs[pid] else { return nil }
        if let hit = memo.origin[pid] { return hit }
        let command = commandLine(p), exe = executablePath(pid)
        let mux = Self.tokens(command).first.flatMap { ["tmux", "screen", "zellij"].contains($0) ? $0 : nil }
        let result = Self.agentName(command, exe: exe) ?? Self.appName(exe) ?? mux ?? origin(of: p.ppid, procs: procs)
        memo.origin.updateValue(result, forKey: pid) // updateValue: a nil result must be stored, not removed
        return result
    }

    /// GUI apps that are really dev infrastructure (Docker's backend is what
    /// listens on every published container port).
    static let devApps = [
        "/Xcode.app/Contents/Developer/", "/Postgres.app/", "/DBngin.app/", "/Redis.app/",
        "/Docker.app/", "/OrbStack.app/", "/Rancher Desktop.app/", "/Podman Desktop.app/",
    ]
    private static let appFolders = ["/Applications/", "/System/Applications/", NSHomeDirectory() + "/Applications/"]

    static func isSystemExecutable(_ exe: String) -> Bool {
        if exe.isEmpty { return true }
        if ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/"].contains(where: exe.hasPrefix) {
            return true
        }
        return isInstalledApp(exe) && !devApps.contains(where: exe.contains)
    }

    /// The app bundle an executable runs from ("Ghostty", "Cursor"), ignoring
    /// bundles inside frameworks, like the Python.app behind every Homebrew `python3`.
    private static func appName(_ exe: String) -> String? {
        for part in exe.split(separator: "/") {
            if part.hasSuffix(".framework") { return nil }
            if part.hasSuffix(".app") { return String(part.dropLast(4)) }
        }
        return nil
    }

    /// Installed GUI apps (Spotify, Cursor…) — but not bundles nested elsewhere,
    /// like the Python.app behind every `python3` or Claude's bundled `claude.app` agent.
    private static func isInstalledApp(_ exe: String) -> Bool {
        guard let app = exe.range(of: ".app/") else { return false }
        let bundleParent = (String(exe[..<app.lowerBound]) as NSString).deletingLastPathComponent + "/"
        return appFolders.contains(bundleParent)
    }

    // MARK: - Projects

    private func project(for cwd: String) -> Project? {
        let home = NSHomeDirectory()
        guard !cwd.isEmpty, cwd != "/", cwd != home else { return nil }
        if let hit = memo.project[cwd] { return hit }

        let fm = FileManager.default
        var dir = URL(fileURLWithPath: cwd)
        var found: Project?
        while dir.path.count > 1, dir.path != home {
            let git = dir.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: git.path, isDirectory: &isDir) {
                found = Self.gitProject(root: dir, git: git, isDirectory: isDir.boolValue)
                break
            }
            dir.deleteLastPathComponent()
        }
        let result = found ?? Project(root: cwd, name: (cwd as NSString).lastPathComponent, branch: nil, isWorktree: false)
        memo.project[cwd] = result
        return result
    }

    private static func gitProject(root: URL, git: URL, isDirectory: Bool) -> Project {
        var gitDir = git
        var name = root.lastPathComponent
        var isWorktree = false
        // A .git file ("gitdir: <path>") is a worktree (<repo>/.git/worktrees/<name>)
        // or a submodule (<repo>/.git/modules/<name>), which keeps its own name.
        if !isDirectory, let contents = try? String(contentsOf: git, encoding: .utf8),
           contents.hasPrefix("gitdir:") {
            let path = contents.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            gitDir = URL(fileURLWithPath: path, relativeTo: root)
            let parts = gitDir.standardized.pathComponents
            if let i = parts.lastIndex(of: ".git"), i > 0, parts.indices.contains(i + 1), parts[i + 1] == "worktrees" {
                name = parts[i - 1]
                isWorktree = true
            }
        }
        let head = (try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8)) ?? ""
        let branch = head.hasPrefix("ref: refs/heads/")
            ? String(head.dropFirst("ref: refs/heads/".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            : String(head.prefix(7))
        return Project(root: root.path, name: name, branch: branch.isEmpty ? nil : branch, isWorktree: isWorktree)
    }
}

enum Shell {
    @discardableResult
    static func run(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
