import Darwin
import Foundation

/// Builds a snapshot of every process listening on a TCP port, enriched with
/// project, origin and the process tree needed to stop it cleanly.
///
/// Everything is read in-process from the kernel (sysctl + libproc) — no
/// `lsof`/`ps` subprocesses — so a scan costs a few milliseconds.
final class Scanner {
    private struct Proc {
        let pid: Int32
        let ppid: Int32
        let uid: uid_t
        let started: Date
        let comm: String
    }

    private let uid = getuid()
    private var projectCache: [String: Project?] = [:]
    private var labelCache: [Int32: String?] = [:]
    private var argsBuffer = [UInt8](repeating: 0, count: Scanner.argMax)

    // Per-scan memo, cleared at the start of every scan.
    private var argsMemo: [Int32: String] = [:]
    private var exeMemo: [Int32: String] = [:]

    /// - Parameter includeForeign: also report listeners owned by other users
    ///   (root daemons…). Costs one `netstat` spawn, so it only runs while the
    ///   popover is open.
    func scan(includeForeign: Bool) -> [DevProcess] {
        argsMemo.removeAll(keepingCapacity: true)
        exeMemo.removeAll(keepingCapacity: true)

        let procs = Self.processTable()
        var listening: [Int32: [ListenPort]] = [:]
        for p in procs.values where p.uid == uid {
            let ports = Self.listeningPorts(p.pid)
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

        func descendants(_ pid: Int32) -> Set<Int32> {
            var out: Set<Int32> = [pid], stack = [pid]
            while let next = stack.popLast() {
                for c in children[next] ?? [] where out.insert(c).inserted { stack.append(c) }
            }
            return out
        }

        let listeningPids = Set(listening.keys)
        labelCache = labelCache.filter { procs[$0.key] != nil }
        if listening.keys.contains(where: { procs[$0]?.ppid == 1 && labelCache[$0] == nil }) {
            let labels = Self.launchdLabels()
            for pid in listening.keys where procs[pid]?.ppid == 1 { labelCache[pid] = labels[pid] }
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
                guard parentTree.intersection(listeningPids) == rootTree.intersection(listeningPids) else { break }
                chain.append(parent)
                rootTree = parentTree
            }

            let summarySource = chain.reversed().first { !Self.isShellWrapper(commandLine($0)) } ?? proc
            let (name, kind) = Classifier.describe(command: command, exePath: exe)
            let cwd = owned ? Self.workingDirectory(pid) : ""
            let label = labelCache[pid] ?? nil

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
                    ?? (owned ? origin(above: chain.last!, procs: procs) : "root"),
                tree: owned ? rootTree.sorted() : [pid],
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

    private static func listeningPorts(_ pid: Int32) -> [ListenPort] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, bytes)
        guard filled > 0 else { return [] }

        var ports: [Int: Bool] = [:] // port → exposed (merges IPv4 + IPv6 sockets)
        let infoSize = Int32(MemoryLayout<socket_fdinfo>.size)
        for fd in fds.prefix(Int(filled) / stride) where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
            var info = socket_fdinfo()
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, infoSize) == infoSize,
                  info.psi.soi_kind == SOCKINFO_TCP else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)))
            ports[port, default: false] = ports[port, default: false] || isWildcard(tcp.tcpsi_ini)
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
            guard cols.count > 10, cols[5] == "LISTEN",
                  let pidText = cols[10].split(separator: ":").last, let pid = Int32(pidText),
                  let dot = cols[3].lastIndex(of: "."), let port = Int(cols[3][cols[3].index(after: dot)...])
            else { continue }
            let host = cols[3][..<dot]
            let exposed = host == "*" || host == "0.0.0.0" || host == "::"
            result[pid, default: [:]][port] = (result[pid]?[port] ?? false) || exposed
        }
        return result.mapValues { $0.map { ListenPort(number: $0.key, exposed: $0.value) } }
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
        if let memo = argsMemo[proc.pid] { return memo }
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
        argsMemo[proc.pid] = result
        return result
    }

    private func executablePath(_ pid: Int32) -> String {
        if let memo = exeMemo[pid] { return memo }
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let path = proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : ""
        exeMemo[pid] = path
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
        command.split(separator: " ").prefix(2).map {
            (($0 as NSString).lastPathComponent as String).trimmingCharacters(in: ["-"]).lowercased()
        }
    }

    private static func isShellWrapper(_ command: String) -> Bool {
        let t = command.split(separator: " ")
        guard let first = t.first else { return false }
        let name = ((first as NSString).lastPathComponent as String).trimmingCharacters(in: ["-"])
        return shells.contains(name) && t.contains("-c")
    }

    private static func agentName(_ command: String, exe: String) -> String? {
        guard !isInstalledApp(exe) else { return nil } // Claude.app itself isn't an agent
        if exe.contains("/claude/versions/") { return "Claude Code" }
        if let agent = agents[((exe as NSString).lastPathComponent as String).lowercased()] { return agent }
        return tokens(command).lazy.compactMap { agents[$0] }.first
    }

    /// Where climbing must stop: interactive shells, terminals/IDEs, agents, launchd.
    private func isBoundary(_ proc: Proc) -> Bool {
        let command = commandLine(proc), exe = executablePath(proc.pid)
        if Self.agentName(command, exe: exe) != nil || exe.contains(".app/") || Self.isSystemExecutable(exe) { return true }
        guard let first = Self.tokens(command).first else { return true }
        if Self.shells.contains(first) { return !Self.isShellWrapper(command) }
        return ["login", "tmux", "screen", "sshd", "zellij"].contains(first)
    }

    private func origin(above root: Proc, procs: [Int32: Proc]) -> String? {
        var current = procs[root.ppid]
        while let p = current, p.pid > 1 {
            let exe = executablePath(p.pid)
            if let agent = Self.agentName(commandLine(p), exe: exe) { return agent }
            if let app = exe.components(separatedBy: "/").first(where: { $0.hasSuffix(".app") }) {
                return String(app.dropLast(4))
            }
            if let first = Self.tokens(commandLine(p)).first, ["tmux", "screen", "zellij"].contains(first) { return first }
            current = procs[p.ppid]
        }
        return nil
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
        if devApps.contains(where: exe.contains) { return false }
        if ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/"].contains(where: exe.hasPrefix) {
            return true
        }
        return isInstalledApp(exe)
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
        if let cached = projectCache[cwd] { return cached }

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
        projectCache[cwd] = result
        return result
    }

    private static func gitProject(root: URL, git: URL, isDirectory: Bool) -> Project {
        var gitDir = git
        var name = root.lastPathComponent
        if !isDirectory, // worktree: .git is a file pointing at <repo>/.git/worktrees/<name>
           let contents = try? String(contentsOf: git, encoding: .utf8),
           let path = contents.split(separator: " ").last?.trimmingCharacters(in: .whitespacesAndNewlines) {
            gitDir = URL(fileURLWithPath: path, relativeTo: root)
            let parts = gitDir.standardized.pathComponents
            if let i = parts.lastIndex(of: ".git"), i > 0 { name = parts[i - 1] }
        }
        let head = (try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8)) ?? ""
        let branch = head.hasPrefix("ref: refs/heads/")
            ? String(head.dropFirst("ref: refs/heads/".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            : String(head.prefix(7))
        return Project(root: root.path, name: name, branch: branch.isEmpty ? nil : branch, isWorktree: !isDirectory)
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
