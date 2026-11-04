import Foundation

/// Whether mpv should ask for VideoToolbox. On Apple silicon it decodes H.264 and HEVC at once, but
/// when the system's decoder service is stuck, opening it hangs for about 15 seconds before mpv
/// falls back to software, and every new player (each channel change, each multiview tile) would
/// wait again. After one such hang, players use software decoding until the app restarts.
enum HardwareDecoding {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var avoidValue =
        ProcessInfo.processInfo.environment["IPTV_SOFTWARE_DECODING"] != nil  // testing: force software

    static var avoid: Bool {
        get { lock.withLock { avoidValue } }
        set { lock.withLock { avoidValue = newValue } }
    }

    /// Formats VideoToolbox always handles here, so software decoding for them means it failed.
    static let alwaysHardware: Set<String> = ["h264", "hevc"]

    /// True when a stream VideoToolbox should have decoded ended up on software after a long wait
    /// for the first frame (a hang, not a slow server: a slow server leaves mpv on VideoToolbox).
    static func hung(codec: String?, decoder: String?, secondsToFirstFrame: Double) -> Bool {
        guard let codec, alwaysHardware.contains(codec) else { return false }
        return decoder == "no" && secondsToFirstFrame >= 5
    }
}
