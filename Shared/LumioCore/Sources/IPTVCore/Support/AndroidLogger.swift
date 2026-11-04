#if !canImport(os)
#if canImport(Android)
import Android
#endif
import Foundation

/// Stand-in for `os.Logger` where the unified log doesn't exist (Android): writes to logcat with
/// the tag "Lumio.<category>". As with `os.Logger`, interpolated text is redacted unless marked
/// `privacy: .public`; numbers and booleans are shown. Never log credentials either way.
public struct Logger: Sendable {
    private let tag: String

    public init(subsystem: String, category: String) {
        tag = "Lumio.\(category)"
    }

    public func debug(_ message: LogMessage) { write(3, message) }
    public func info(_ message: LogMessage) { write(4, message) }
    public func notice(_ message: LogMessage) { write(4, message) }
    public func warning(_ message: LogMessage) { write(5, message) }
    public func error(_ message: LogMessage) { write(6, message) }
    public func fault(_ message: LogMessage) { write(7, message) }

    /// `priority` is Android's: 3 debug, 4 info, 5 warn, 6 error, 7 fatal.
    private func write(_ priority: Int32, _ message: LogMessage) {
        #if canImport(Android)
        _ = __android_log_write(priority, tag, message.text)
        #else
        print("[\(tag)] \(message.text)")
        #endif
    }
}

public enum LogPrivacy: Sendable, Equatable {
    case `public`, `private`, sensitive, auto
}

public enum LogFloatFormat: Sendable {
    case fixed(precision: Int)
}

public struct LogMessage: ExpressibleByStringInterpolation, Sendable {
    let text: String

    public init(stringLiteral value: String) {
        text = value
    }

    public init(stringInterpolation: Interpolation) {
        text = stringInterpolation.text
    }

    public struct Interpolation: StringInterpolationProtocol, Sendable {
        var text = ""

        public init(literalCapacity: Int, interpolationCount: Int) {
            text.reserveCapacity(literalCapacity)
        }

        public mutating func appendLiteral(_ literal: String) {
            text += literal
        }

        public mutating func appendInterpolation(_ value: some CustomStringConvertible, privacy: LogPrivacy = .private) {
            text += privacy == .public ? value.description : "<private>"
        }

        public mutating func appendInterpolation(_ value: some BinaryInteger, privacy: LogPrivacy = .public) {
            text += privacy == .public ? String(value) : "<private>"
        }

        public mutating func appendInterpolation(_ value: Double, format: LogFloatFormat? = nil, privacy: LogPrivacy = .public) {
            guard privacy == .public else { text += "<private>"; return }
            switch format {
            case .fixed(let precision): text += String(format: "%.\(precision)f", value)
            case nil: text += String(value)
            }
        }

        public mutating func appendInterpolation(_ value: Bool, privacy: LogPrivacy = .public) {
            text += privacy == .public ? String(value) : "<private>"
        }
    }
}
#endif
