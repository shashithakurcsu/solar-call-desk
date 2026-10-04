import Darwin

struct PhoneProbeProcessStart: Sendable, Equatable {
    let seconds: UInt64
    let microseconds: UInt64
}

enum PhoneProbeProcessMetadata {
    /// Public libproc metadata, including helpers launched outside LaunchServices.
    /// No executable arguments, environment, contacts or content are requested.
    static func startTime(pid: Int32) -> PhoneProbeProcessStart? {
        guard pid > 0 else { return nil }
        var information = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let copied = withUnsafeMutablePointer(to: &information) {
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, size)
        }
        guard copied == size, information.pbi_pid == UInt32(pid), information.pbi_start_tvsec > 0,
              information.pbi_start_tvusec < 1_000_000 else { return nil }
        return PhoneProbeProcessStart(seconds: information.pbi_start_tvsec, microseconds: information.pbi_start_tvusec)
    }
}
