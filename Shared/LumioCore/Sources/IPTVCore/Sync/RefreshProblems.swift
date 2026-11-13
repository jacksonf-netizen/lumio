import Foundation

/// A provider's last refresh problems, read back from `Provider.lastError`.
///
/// `CatalogSyncService` saves a refresh that failed outright (a refused login, an unreachable
/// server) as the message alone, and part failures as one "part: message" line each ("guide: …",
/// "live: …"). This splits them, so an app can tell a provider that doesn't work from one that only
/// has no guide: channels and films play without a guide, so that's a note, not a fault.
public struct RefreshProblems: Equatable, Sendable {
    /// What stops something working (the login, channels, films, series), or nil.
    public var serious: String?
    /// Why the guide didn't load, or nil.
    public var guide: String?
    /// What went wrong with the guide links the user added, or nil. A note, like `guide`.
    public var guideLinks: String?
    /// The parts that failed, by `SyncStep` raw value ("live", "guide"…). Empty when the whole
    /// refresh failed (see `failedOutright`) or nothing did.
    public var failedParts: [String]

    /// The refresh stopped before loading anything: the login or the server.
    public var failedOutright: Bool { serious != nil && failedParts.isEmpty }

    public init(lastError: String?) {
        serious = nil
        guide = nil
        guideLinks = nil
        failedParts = []
        guard let lastError, !lastError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        var entries: [(part: String?, text: String)] = []
        for line in lastError.components(separatedBy: "\n") {
            if let part = Self.part(of: line) {
                entries.append((part, String(line.dropFirst(part.count + 2))))
            } else if !entries.isEmpty {
                // A message that ran over more than one line.
                entries[entries.count - 1].text += "\n" + line
            } else {
                entries.append((nil, line))
            }
        }
        var serious: [String] = []
        for entry in entries {
            if let part = entry.part {
                failedParts.append(part)
                if part == SyncStep.guide.rawValue {
                    guide = entry.text
                } else if part == SyncStep.guideLinks.rawValue {
                    guideLinks = entry.text
                } else {
                    serious.append(entry.text)
                }
            } else {
                serious.append(entry.text)
            }
        }
        self.serious = serious.isEmpty ? nil : serious.joined(separator: "\n")
    }

    /// The part a "part: message" line is about, or nil for any other line.
    private static func part(of line: String) -> String? {
        let steps: [SyncStep] = [.account, .live, .movies, .series, .guideLinks, .guide, .matching]
        return steps.map(\.rawValue).first { line.hasPrefix($0 + ": ") }
    }
}
