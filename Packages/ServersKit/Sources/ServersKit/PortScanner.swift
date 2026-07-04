import Darwin
import DashCore
import Foundation

/// Scan des ports 3000–9999 par libproc (10 · §3.2, REQ-SRV-01/02) : énumère les process
/// de l'utilisateur courant, leurs descripteurs sockets, et retient les TCP en LISTEN dans
/// la plage. Aucun root requis (périmètre = serveurs de dev de l'utilisateur).
public enum PortScanner {
    public static let portRange: ClosedRange<UInt16> = 3000...9999

    /// Un couple (pid, port) en écoute ; doublons IPv4/IPv6 fusionnés (REQ-SRV-05).
    public struct Listener: Hashable, Sendable {
        public let pid: pid_t
        public let port: UInt16
    }

    public static func scan() -> [Listener] {
        var results = Set<Listener>()
        let uid = getuid()

        // PIDs de l'utilisateur courant uniquement.
        let pidCount = proc_listpids(UInt32(PROC_UID_ONLY), uid, nil, 0)
        guard pidCount > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(pidCount) / MemoryLayout<pid_t>.size + 16)
        let filled = proc_listpids(UInt32(PROC_UID_ONLY), uid, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return [] }

        for pid in pids.prefix(Int(filled) / MemoryLayout<pid_t>.size) where pid > 0 {
            // Descripteurs du process.
            let fdSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard fdSize > 0 else { continue }
            let fdCount = Int(fdSize) / MemoryLayout<proc_fdinfo>.size
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: fdCount + 8)
            let written = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * MemoryLayout<proc_fdinfo>.size))
            guard written > 0 else { continue }

            for fd in fds.prefix(Int(written) / MemoryLayout<proc_fdinfo>.size)
            where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
                var socketInfo = socket_fdinfo()
                let size = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &socketInfo,
                                          Int32(MemoryLayout<socket_fdinfo>.size))
                guard size == MemoryLayout<socket_fdinfo>.size,
                      socketInfo.psi.soi_kind == SOCKINFO_TCP else { continue }
                let tcp = socketInfo.psi.soi_proto.pri_tcp
                // TSI_S_LISTEN = 1 (proc_info.h).
                guard tcp.tcpsi_state == 1 else { continue }
                let rawPort = UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)
                let port = UInt16(bigEndian: rawPort) // insi_lport est en network byte order
                guard portRange.contains(port) else { continue }
                results.insert(Listener(pid: pid, port: port))
            }
        }
        return Array(results)
    }
}
