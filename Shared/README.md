# Shared code

Code every Lumio app uses. Nothing here draws a screen or plays video; each app brings its own
(the Mac app's are in [`Mac/LumioMac`](../Mac/LumioMac)).

- [`LumioCore/`](LumioCore): a Swift package with two libraries.
  - `IPTVCore`: providers and their server links, the Xtream client, catalog sync, guide (XMLTV)
    import, the database, search, favorites and history, connection slots, and the playback state
    machine (reconnects and fallbacks).
  - `LumioUpdate`: checking and installing signed updates.
  - `Tests/`: the test suites and their example provider data (`Tests/IPTVCoreTests/Fixtures`).

Run the tests with `swift test --package-path Shared/LumioCore`. The design is described in
[Docs/Shared](../Docs/Shared).
