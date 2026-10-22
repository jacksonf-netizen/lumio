import os

/// Structured loggers. View in Xcode's console or Console.app (filter: subsystem
/// `com.jackson.iptvstreamer`). Never log credentials; pass URLs through `CredentialRedactor`.
public enum Log {
    public static let subsystem = "com.jackson.iptvstreamer"

    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let database = Logger(subsystem: subsystem, category: "database")
    public static let network = Logger(subsystem: subsystem, category: "network")
    public static let sync = Logger(subsystem: subsystem, category: "sync")
    public static let epg = Logger(subsystem: subsystem, category: "epg")
    public static let connections = Logger(subsystem: subsystem, category: "connections")
    public static let playback = Logger(subsystem: subsystem, category: "playback")
    public static let security = Logger(subsystem: subsystem, category: "security")
}
