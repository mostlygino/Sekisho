import Darwin
import Foundation
import NIOConcurrencyHelpers

/// The process on this Mac that opened a connection to Sekisho.
public struct ClientApp: Sendable, Hashable, Codable {
    public var pid: Int32
    public var executablePath: String
    /// The outermost `.app` the executable lives in, so helpers group under their app.
    public var bundlePath: String?
    public var name: String

    public var key: String { bundlePath ?? executablePath }

    public init(pid: Int32, executablePath: String, bundlePath: String?, name: String) {
        self.pid = pid; self.executablePath = executablePath; self.bundlePath = bundlePath; self.name = name
    }
}

/// Finds which process owns the client end of a loopback connection, by its source port, and reports it
/// per connection id (ports are reused; connection ids are not).
/// One scan of the process table answers every port waiting at that moment.
public final class ClientLookup: @unchecked Sendable {
    private let queue = DispatchQueue(label: "sekisho.client-lookup", qos: .utility)
    private let pending = NIOLockedValueBox<[Int: Int]>([:])  // port: connection
    private let proxyPort: @Sendable () -> Int
    private let found: @Sendable (Int, ClientApp) -> Void

    public init(proxyPort: @escaping @Sendable () -> Int, found: @escaping @Sendable (Int, ClientApp) -> Void) {
        self.proxyPort = proxyPort
        self.found = found
    }

    public func resolve(port: Int, connection: Int) {
        let first = pending.withLockedValue { waiting -> Bool in
            let wasEmpty = waiting.isEmpty
            waiting[port] = connection
            return wasEmpty
        }
        guard first else { return }
        queue.async { [self] in
            let waiting = pending.withLockedValue { all -> [Int: Int] in defer { all.removeAll() }; return all }
            for (port, app) in Self.owners(of: Set(waiting.keys), proxyPort: proxyPort()) {
                if let connection = waiting[port] { found(connection, app) }
            }
        }
    }

    /// ponytail: scans every process's sockets per batch (a few ms); keep a pid cache if it ever shows up in a profile.
    static func owners(of ports: Set<Int>, proxyPort: Int) -> [Int: ClientApp] {
        var result: [Int: ClientApp] = [:]
        let me = getpid()
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        guard capacity > 64 else { return result }
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        for pid in pids.prefix(count) where pid > 0 && pid != me {
            let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard size > 0 else { continue }
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.stride)
            let used = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, size)
            guard used > 0 else { continue }
            for fd in fds.prefix(Int(used) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
                var info = socket_fdinfo()
                let got = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, Int32(MemoryLayout<socket_fdinfo>.size))
                guard got == Int32(MemoryLayout<socket_fdinfo>.size), info.psi.soi_kind == SOCKINFO_TCP else { continue }
                let ini = info.psi.soi_proto.pri_tcp.tcpsi_ini
                let local = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_lport)))
                let foreign = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_fport)))
                guard foreign == proxyPort, ports.contains(local), result[local] == nil else { continue }
                result[local] = app(pid)
            }
            if result.count == ports.count { break }
        }
        return result
    }

    static func app(_ pid: pid_t) -> ClientApp {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        let path = length > 0 ? String(cString: buffer) : ""
        var bundle: String?
        if let range = path.range(of: ".app/") {
            bundle = String(path[..<range.lowerBound]) + ".app"
        }
        let name = bundle.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }
            ?? (path.isEmpty ? "pid \(pid)" : (path as NSString).lastPathComponent)
        return ClientApp(pid: pid, executablePath: path, bundlePath: bundle, name: name)
    }
}
