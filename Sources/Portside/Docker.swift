import Foundation

/// A running container behind a published port. Read from the engine's local unix socket
/// (the same API `docker ps` uses), so the docker CLI doesn't need to be installed or on PATH.
struct Container: Hashable {
    let id: String
    let name: String
    let image: String
    let command: String
    let created: Date
    let ports: [ListenPort]
    let composeProject: String?
    let composeService: String?
    let composeDirectory: String?
    let socket: String
}

enum Docker {
    /// Where each engine's Docker-compatible API listens.
    static func sockets(forEngine exePath: String) -> [String] {
        let home = NSHomeDirectory()
        if exePath.contains("/OrbStack.app/") { return [home + "/.orbstack/run/docker.sock"] }
        if exePath.contains("/Rancher Desktop.app/") { return [home + "/.rd/docker.sock"] }
        return [home + "/.docker/run/docker.sock", "/var/run/docker.sock"]
    }

    static func containers(forEngine exePath: String) -> [Container] {
        for socket in sockets(forEngine: exePath) {
            guard let (status, body) = request("GET", "/containers/json", socket: socket, timeout: 2),
                  status == 200, let list = try? JSONDecoder().decode([Summary].self, from: body) else { continue }
            return list.compactMap { $0.container(socket: socket) }
        }
        return []
    }

    /// `docker stop` (SIGTERM, then SIGKILL after 10s) or `docker kill`. Volumes are kept.
    static func stop(_ container: Container, force: Bool) {
        guard isContainerID(container.id) else { return }
        _ = request("POST", "/containers/\(container.id)/\(force ? "kill" : "stop?t=10")",
                    socket: container.socket, timeout: 15)
    }

    private static func isContainerID(_ id: String) -> Bool {
        (12...64).contains(id.count) && id.allSatisfy(\.isHexDigit)
    }

    // MARK: - API

    private struct Summary: Decodable {
        struct Port: Decodable {
            let IP: String?
            let PublicPort: Int?
            let `Type`: String
        }
        let Id: String
        let Names: [String]
        let Image: String
        let Command: String?
        let Created: Double
        let Ports: [Port]
        let Labels: [String: String]?

        func container(socket: String) -> Container? {
            guard Docker.isContainerID(Id) else { return nil }
            var published: [Int: Bool] = [:]
            for port in Ports where port.Type == "tcp" {
                guard let number = port.PublicPort else { continue }
                let exposed = port.IP == nil || port.IP == "0.0.0.0" || port.IP == "::" || port.IP == ""
                published[number] = (published[number] ?? false) || exposed
            }
            guard !published.isEmpty else { return nil }
            let name = Names.first.map { $0.hasPrefix("/") ? String($0.dropFirst()) : $0 } ?? String(Id.prefix(12))
            return Container(
                id: Id, name: name, image: Image, command: Command ?? Image,
                created: Date(timeIntervalSince1970: Created),
                ports: published.map { ListenPort(number: $0.key, exposed: $0.value) }.sorted(),
                composeProject: Labels?["com.docker.compose.project"],
                composeService: Labels?["com.docker.compose.service"],
                composeDirectory: Labels?["com.docker.compose.project.working_dir"],
                socket: socket
            )
        }
    }

    /// One HTTP/1.0 request over a unix socket: the server closes the connection after the
    /// response, so the body is everything after the headers. Bounded in time and size.
    private static func request(_ method: String, _ path: String, socket path_: String,
                                timeout: Int) -> (Int, Data)? {
        var addr = sockaddr_un()
        let bytes = Array(path_.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var limit = timeval(tv_sec: timeout, tv_usec: 0), on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { return nil }

        let request = Array("\(method) \(path) HTTP/1.0\r\nHost: docker\r\nContent-Length: 0\r\n\r\n".utf8)
        guard request.withUnsafeBytes({ write(fd, $0.baseAddress, $0.count) }) == request.count else { return nil }

        var response = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
        while response.count < 4_000_000 {
            let n = read(fd, &buffer, buffer.count)
            guard n > 0 else { break }
            response.append(buffer, count: n)
        }
        guard let split = response.range(of: Data("\r\n\r\n".utf8)),
              let statusLine = String(data: response[..<split.lowerBound], encoding: .utf8)?
                  .split(separator: "\r\n").first,
              let status = statusLine.split(separator: " ").dropFirst().first.flatMap({ Int($0) })
        else { return nil }
        return (status, Data(response[split.upperBound...]))
    }
}
