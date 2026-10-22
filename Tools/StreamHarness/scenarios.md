# Reliability scenarios with the stream harness

The harness is a fake Xtream provider on your Mac. It encodes test streams live with ffmpeg
and can misbehave on command.

## Start it

```bash
python3 Tools/StreamHarness/harness.py --port 8088 --name "Harness A"
```

For two providers (failover and multiview capacity), start a second one in another Terminal tab:

```bash
python3 Tools/StreamHarness/harness.py --port 8089 --name "Harness B" --max-connections 1
```

Add each one in the app (Settings → Add Provider…):
server `http://127.0.0.1:8088` (or `:8089`), username `test`, password `test`.

The channels are Harness News HD (H.264/AAC), Harness Sport HEVC FHD (HEVC/AC-3) and
Harness Movies 50fps (H.264/E-AC-3). Press **D** while playing to see the diagnostics overlay.

## Scenarios

| # | Do this while a channel plays | Expect |
|---|---|---|
| 1 | `curl localhost:8088/control/stall` | Video freezes after the buffer drains, then within ~8 s a small **Reconnecting…** pill appears. Then `curl localhost:8088/control/normal`: playback resumes by itself. Diagnostics show Reconnects ≥ 1. |
| 2 | `curl localhost:8088/control/drop` | The connection is cut. Reconnecting… then playing again within a few seconds. |
| 3 | `curl "localhost:8088/control/throttle?kbps=800"` | Buffering, then reconnects. Try Settings → Buffer **Large** and compare. `control/normal` restores. |
| 4 | `curl "localhost:8088/control/status?code=404"`, then change channel | A specific message: "The provider says this stream doesn't exist (HTTP 404)". With two harnesses carrying the same channel, it **switches to Harness B** instead (notice "Switching to Harness B…"). |
| 5 | `curl "localhost:8088/control/status?code=403"` | Specific 403 message (connection limit or user-agent blocked), or failover to B. |
| 6 | `curl "localhost:8088/control/maxconn?n=1&code=458"`, then open the preview and full screen | Preview stops ("Paused while the connection is used elsewhere") and full screen plays; the harness never sees 2 streams. |
| 7 | Turn Wi-Fi off for 30 s, then on | **Waiting for network…**, no retry storm; resumes when Wi-Fi returns. |
| 8 | Close the lid / sleep, then wake | Stream is stopped on sleep (harness logs "closed") and resumes after wake. |
| 9 | Zap quickly up and down through channels (phase 4) | Only the channel you stop on is opened (watch the harness log: one "opened" per settle). |

`curl localhost:8088/control/state` shows the current fault settings and open stream count.

## Automated versions

The same behaviours are covered without the harness by `PlaybackControllerTests` (a fake engine
and a controllable clock), and with real engines by `HarnessIntegrationTests`:

```bash
python3 Tools/StreamHarness/harness.py --port 8098 --quiet &
cd Packages/IPTVKit && swift test --filter HarnessIntegrationTests
```

## Rendering check (four mpv players at once)

With the harness on 8098 and its limit raised (`curl "localhost:8098/control/maxconn?n=8"`), run:

```bash
"build/DerivedData.noindex/Build/Products/Debug/Lumio.app/Contents/MacOS/Lumio" -spikeRender 4 -spikeURL http://127.0.0.1:8098
```

It prints the codec, decoder, dropped frames and memory for each tile every 2 s, then quits.
