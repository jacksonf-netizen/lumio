# Lumio for Mac

Everything only the Mac app uses. It builds on the shared code in [`Shared/`](../Shared).

| | |
|---|---|
| `project.yml` | XcodeGen spec for the app and its installer service; holds the version number |
| `App/` | The app shell (`IPTVMac`: windows, menus) and the update installer (`LumioInstaller`) |
| `LumioMac/` | Swift package with the Mac screens (`IPTVUI`, SwiftUI) and players (`IPTVPlayback`, mpv and AVPlayer) |
| `Config/` | Code-signing settings (`Local.xcconfig` is yours and never committed) |
| `Tools/` | `install.sh` (build and install to /Applications), the app icon, release build and signing |
| `build/` | Build output, not committed |

How to build, test and release: [Docs/Mac/development.md](../Docs/Mac/development.md).
