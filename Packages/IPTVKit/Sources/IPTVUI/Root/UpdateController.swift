import AppKit
import Observation
import SwiftUI
import IPTVCore

/// Checks for new releases when the app opens and, if the user agrees, downloads, verifies and
/// installs the update, then relaunches.
///
/// It does nothing unless the build has a release feed: the `IPTVUpdateRepository` Info.plist key
/// ("owner/repo", set from `UPDATE_REPOSITORY` in project.yml). Installing in place also needs the
/// release key (`LumioUpdatePublicKey`) and a release with a signed .zip; otherwise the app offers
/// the release page instead. The app is sandboxed, so the actual swap is done by its installer
/// service (App/LumioInstaller), which checks the signature again before touching anything.
@MainActor
@Observable
public final class UpdateController {
    public let feed: UpdateFeed?
    public let currentVersion: SemanticVersion?
    public private(set) var isChecking = false
    public private(set) var lastChecked: Date?
    /// While an update is being installed (shown in the progress window).
    public private(set) var phase: Phase?

    public enum Phase: Equatable {
        case downloading(version: String, received: Int64, total: Int64)
        case installing(version: String)
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let publicKey: String
    @ObservationIgnored private var download: UpdateDownload?
    @ObservationIgnored private var progressWindow: NSWindow?
    @ObservationIgnored private var relaunchFailed = false
    private enum Key {
        static let automatic = "automaticUpdateChecks"
        static let lastChecked = "lastUpdateCheck"
        static let skipped = "skippedUpdateVersion"
        /// Written just before relaunching after an update: the old copy's pid and when. (Launch
        /// arguments would be simpler, but macOS drops them when a sandboxed app opens an app.)
        static let relaunchAfter = "relaunchAfterPID"
        static let relaunchAt = "relaunchAfterUpdateAt"
    }

    /// Updates over this size are refused (the app is about 50 MB).
    static let maxArchiveBytes: Int64 = 1 << 30

    public init(bundle: Bundle = .main, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        feed = UpdateFeed(gitHubRepository: bundle.object(forInfoDictionaryKey: "IPTVUpdateRepository") as? String)
        currentVersion = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(SemanticVersion.init)
        publicKey = bundle.object(forInfoDictionaryKey: "LumioUpdatePublicKey") as? String ?? ""
        lastChecked = defaults.object(forKey: Key.lastChecked) as? Date
        automaticChecks = defaults.object(forKey: Key.automatic) as? Bool ?? true
    }

    /// True when this build knows where its releases are published.
    public var isConfigured: Bool { feed != nil && currentVersion != nil }

    /// True when this build can install updates itself (it has the release key).
    public var canInstall: Bool { !publicKey.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Where releases come from, for display ("github.com/owner/repo").
    public var feedDescription: String? {
        switch feed {
        case let .gitHub(owner, repository)?: "github.com/\(owner)/\(repository)"
        case nil: nil
        }
    }

    /// Check each time the app opens. On unless the user turns it off.
    public var automaticChecks: Bool {
        didSet { defaults.set(automaticChecks, forKey: Key.automatic) }
    }

    /// At launch, a few seconds in so it never slows the first window.
    public func checkAtLaunch() {
        guard isConfigured, automaticChecks else { return }
        #if DEBUG
        // Testing the install path against a local server: -updateTestVersion 0.2.0
        // -updateTestArchive http://127.0.0.1:PORT/Lumio.zip -updateTestSignature http://…/Lumio.zip.sig
        if let version = defaults.string(forKey: "updateTestVersion").flatMap(SemanticVersion.init),
           let archive = defaults.string(forKey: "updateTestArchive").flatMap(URL.init(string:)),
           let signature = defaults.string(forKey: "updateTestSignature").flatMap(URL.init(string:)) {
            let page = URL(string: "https://github.com/")!
            return install(AvailableUpdate(version: version, title: "Test", notes: "", pageURL: page,
                                           archiveURL: archive, signatureURL: signature))
        }
        // Development builds (smoke tests, layout checks…) don't check unless asked to.
        guard defaults.bool(forKey: "checkUpdatesAtLaunch") else { return }
        #endif
        Task {
            try? await Task.sleep(for: .seconds(3))
            await check(userInitiated: false)
        }
    }

    /// `userInitiated` checks always report back; background checks stay quiet unless there's an
    /// update the user hasn't chosen to skip.
    public func check(userInitiated: Bool) async {
        guard let feed, let currentVersion else {
            if userInitiated {
                inform("Updates Aren't Set Up", "This build has no release feed, so it can't check for new versions. See “Publishing and updates” in the README.")
            }
            return
        }
        guard !isChecking, phase == nil else { return }
        isChecking = true
        defer { isChecking = false }
        do {
            let result = try await UpdateChecker(feed: feed, currentVersion: currentVersion).check()
            lastChecked = Date()
            defaults.set(lastChecked, forKey: Key.lastChecked)
            switch result {
            case .upToDate:
                Log.app.info("Update check: up to date (\(currentVersion.description, privacy: .public))")
                if userInitiated { inform("You're Up to Date", "Lumio \(currentVersion) is the latest version.") }
            case .available(let update):
                Log.app.info("Update check: \(update.version.description, privacy: .public) available")
                if !userInitiated, defaults.string(forKey: Key.skipped) == update.version.description { return }
                offer(update, current: currentVersion)
            }
        } catch {
            Log.app.error("Update check failed: \(error.localizedDescription, privacy: .public)")
            if userInitiated { inform("Couldn't Check for Updates", error.localizedDescription) }
        }
    }

    private func offer(_ update: AvailableUpdate, current: SemanticVersion) {
        let installable = canInstall && update.canInstall
        #if DEBUG
        // For testing the whole install path without clicking.
        if installable, defaults.bool(forKey: "updateTestAutoInstall") { return install(update) }
        #endif
        let alert = NSAlert()
        alert.messageText = "Lumio \(update.version) Is Available"
        // The release notes, without the install instructions published below a "---" line.
        var notes = (update.notes.components(separatedBy: "\n---").first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if notes.count > 600 { notes = String(notes.prefix(600)) + "…" }
        alert.informativeText = "You have version \(current)."
            + (installable ? " Lumio will download the update, install it and reopen." : "")
            + (notes.isEmpty ? "" : "\n\n\(notes)")
        alert.addButton(withTitle: installable ? "Install and Relaunch" : "View Release")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip This Version")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if installable { install(update) } else { NSWorkspace.shared.open(update.pageURL) }
        case .alertThirdButtonReturn:
            defaults.set(update.version.description, forKey: Key.skipped)
        default:
            break
        }
    }

    // MARK: Installing

    private func install(_ update: AvailableUpdate) {
        guard phase == nil, let archiveURL = update.archiveURL, let signatureURL = update.signatureURL else { return }
        let version = update.version.description
        phase = .downloading(version: version, received: 0, total: 0)
        showProgressWindow()
        Task {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LumioUpdate-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let signature = try await Self.fetchSignature(signatureURL)
                let download = UpdateDownload(limit: Self.maxArchiveBytes) { received, total in
                    Task { @MainActor in
                        guard case .downloading = self.phase else { return }
                        self.phase = .downloading(version: version, received: received, total: total)
                    }
                }
                self.download = download
                let archive = try await download.fetch(archiveURL, to: folder.appendingPathComponent("Lumio-\(version).zip"))
                self.download = nil
                // Checked here for a quick, clear answer; the installer checks again on its own.
                try UpdateSignature.verify(fileAt: archive, signature: signature, publicKey: publicKey)
                phase = .installing(version: version)
                let installed = try await Self.runInstaller(archive: archive, signature: signature)
                Log.app.info("Installed update \(installed, privacy: .public); relaunching")
                relaunch()
            } catch {
                download = nil
                closeProgressWindow()
                phase = nil
                if (error as? URLError)?.code == .cancelled { return }
                Log.app.error("Update failed: \(error.localizedDescription, privacy: .public)")
                let alert = NSAlert()
                alert.messageText = "Couldn't Install the Update"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "Download It Instead")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(update.pageURL) }
            }
        }
    }

    /// Stops a download in progress.
    public func cancelInstall() {
        download?.cancel()
    }

    private static func fetchSignature(_ url: URL) async throws -> String {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 1024,
              let text = String(data: data, encoding: .utf8)
        else { throw UpdateSignature.Failure.invalidSignature }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Asks the installer service to put the update in place; returns the installed version.
    private static func runInstaller(archive: URL, signature: String) async throws -> String {
        let connection = NSXPCConnection(serviceName: installerServiceName)
        connection.remoteObjectInterface = NSXPCInterface(with: InstallerServiceProtocol.self)
        connection.resume()
        defer { connection.invalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                once.run { continuation.resume(throwing: InstallerFailure(message: "The installer couldn't start (\(error.localizedDescription)).")) }
            } as? InstallerServiceProtocol
            guard let proxy else {
                return once.run { continuation.resume(throwing: InstallerFailure(message: "The installer is missing from this copy of Lumio.")) }
            }
            proxy.installUpdate(archivePath: archive.path, signature: signature) { version, message in
                once.run {
                    if let version { continuation.resume(returning: version) }
                    else { continuation.resume(throwing: InstallerFailure(message: message ?? "The installer failed.")) }
                }
            }
        }
    }

    /// Opens the new copy, which waits for this one to quit before it loads anything, and quits as
    /// soon as the new copy's process exists. (Waiting for it to finish launching would deadlock:
    /// it doesn't finish until this copy has quit.)
    private func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        let me = ProcessInfo.processInfo.processIdentifier
        defaults.set(Int(me), forKey: Key.relaunchAfter)
        defaults.set(Date(), forKey: Key.relaunchAt)
        relaunchFailed = false
        let identifier = Bundle.main.bundleIdentifier ?? ""
        let before = Set(NSRunningApplication.runningApplications(withBundleIdentifier: identifier).map(\.processIdentifier))
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            guard let error else { return }
            DispatchQueue.main.async {
                self.relaunchFailed = true
                self.defaults.removeObject(forKey: Key.relaunchAfter)
                Log.app.error("Relaunch failed: \(error.localizedDescription, privacy: .public)")
                self.closeProgressWindow()
                self.phase = nil
                self.inform("Lumio Was Updated", "Quit Lumio and open it again to start the new version.")
            }
        }
        let deadline = Date().addingTimeInterval(10)
        Task {
            while !relaunchFailed {
                let started = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
                    .contains { $0.processIdentifier != me && !before.contains($0.processIdentifier) && !$0.isTerminated }
                if started || Date() > deadline { return NSApp.terminate(nil) }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// In the copy started after an update: waits (up to 15 s) for the old copy to quit, so the two
    /// never use the library at the same time.
    public static func waitForPreviousCopy(defaults: UserDefaults = .standard) {
        let pid = pid_t(defaults.integer(forKey: Key.relaunchAfter))
        let at = defaults.object(forKey: Key.relaunchAt) as? Date ?? .distantPast
        defaults.removeObject(forKey: Key.relaunchAfter)
        defaults.removeObject(forKey: Key.relaunchAt)
        // Only straight after an update (a leftover from a failed relaunch is ignored).
        guard pid > 0, pid != getpid(), Date().timeIntervalSince(at) < 60 else { return }
        Log.app.info("Started after an update; waiting for the previous copy (\(pid)) to quit")
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, let old = NSRunningApplication(processIdentifier: pid), !old.isTerminated {
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    // MARK: Windows

    private func showProgressWindow() {
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 120),
                             styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Updating Lumio"
        window.contentView = NSHostingView(rootView: UpdateProgressView(controller: self))
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        progressWindow = window
    }

    private func closeProgressWindow() {
        progressWindow?.close()
        progressWindow = nil
    }

    private func inform(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}

private struct InstallerFailure: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// Runs a closure at most once (the XPC reply and error handler can both fire).
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { body() }
    }
}

/// Downloads one file with progress, refusing anything over `limit` bytes or that isn't a 200.
private final class UpdateDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let limit: Int64
    private let progress: @Sendable (Int64, Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var destination: URL?
    private var task: URLSessionDownloadTask?
    private var session: URLSession?

    init(limit: Int64, progress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.limit = limit
        self.progress = progress
    }

    func fetch(_ url: URL, to destination: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            self.destination = destination
            let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
            let task = session.downloadTask(with: url)
            self.session = session
            self.task = task
            lock.unlock()
            task.resume()
        }
    }

    func cancel() {
        lock.lock()
        let task = task
        lock.unlock()
        task?.cancel()
    }

    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        let session = session
        self.session = nil
        lock.unlock()
        session?.finishTasksAndInvalidate()
        continuation?.resume(with: result)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > limit || totalBytesExpectedToWrite > limit {
            downloadTask.cancel()
            return finish(.failure(UpdateInstaller.Failure.tooLarge))
        }
        progress(totalBytesWritten, max(totalBytesExpectedToWrite, 0))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else {
            return finish(.failure(URLError(.badServerResponse)))
        }
        lock.lock()
        let destination = destination
        lock.unlock()
        guard let destination else { return }
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(destination))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }
}

/// The small "Updating Lumio" window.
private struct UpdateProgressView: View {
    let controller: UpdateController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch controller.phase {
            case let .downloading(version, received, total)?:
                Text("Downloading Lumio \(version)…").font(.headline)
                if total > 0 {
                    ProgressView(value: Double(received), total: Double(total))
                    Text("\(received.formatted(.byteCount(style: .file))) of \(total.formatted(.byteCount(style: .file)))")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { controller.cancelInstall() }.keyboardShortcut(.cancelAction)
                }
            case let .installing(version)?:
                Text("Installing Lumio \(version)…").font(.headline)
                ProgressView().progressViewStyle(.linear)
                Text("Lumio will reopen in a moment.").font(.caption).foregroundStyle(.secondary)
            case nil:
                EmptyView()
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
