import Foundation
import LumioUpdate

// Lumio's installer: a tiny XPC service inside Lumio.app (Contents/XPCServices). The app is
// sandboxed, so it can't replace itself in /Applications; this helper isn't, and does only that,
// for an update signed with the release key (see UpdateInstaller for every check). Only the app it
// ships inside can connect to it. It never touches the network or anything else on disk.

/// Lumio.app, found from where this service sits (…/Lumio.app/Contents/XPCServices/X.xpc), never
/// from what the caller says.
let hostApp = Bundle.main.bundleURL
    .deletingLastPathComponent()   // XPCServices
    .deletingLastPathComponent()   // Contents
    .deletingLastPathComponent()   // Lumio.app

final class InstallerService: NSObject, InstallerServiceProtocol {
    func installUpdate(archivePath: String, signature: String, reply: @escaping @Sendable (String?, String?) -> Void) {
        do {
            let installer = try UpdateInstaller(installedApp: hostApp)
            let version = try installer.install(archive: URL(fileURLWithPath: archivePath), signature: signature)
            NSLog("Lumio installer: installed %@", version.description)
            reply(version.description, nil)
        } catch {
            NSLog("Lumio installer: %@", error.localizedDescription)
            reply(nil, error.localizedDescription)
        }
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: InstallerServiceProtocol.self)
        connection.exportedObject = InstallerService()
        connection.resume()
        return true
    }
}

let delegate = ListenerDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
