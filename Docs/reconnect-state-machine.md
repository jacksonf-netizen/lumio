# Playback reliability: the reconnect state machine

Source: `Packages/IPTVKit/Sources/IPTVCore/Playback/PlaybackController.swift` (state machine),
`PlaybackItem.swift` (fallback ladder), `PlaybackDependencies.swift` (settings and seams),
`Connections/ConnectionManager.swift` (slot accounting). Tests:
`Tests/IPTVCoreTests/PlaybackControllerTests.swift` (fake engine, controllable clock) and
`Tests/IPTVPlaybackTests/HarnessIntegrationTests.swift` (real engines against the harness).

The controller depends only on a `PlaybackEngine` protocol, a `ConnectionManager`, a URL resolver,
a history store, a system-event source and a clock. It contains no AppKit or AVFoundation code, so it
can be reimplemented on another platform by following this document.

## Concepts

- **Item**: what the user asked to play. For live TV it is a *logical channel*: the same channel on
  one or more providers (*sources*).
- **Plan (rung)**: one way to play it: `(source, format, engine)`, e.g. `(Provider A, .ts, mpv)`.
- **Ladder**: the ordered list of plans to try (see below).
- **Attempt**: one open of one plan. Each rung gets `attemptsPerRung` attempts (default 3).
- **Lease**: a connection slot from `ConnectionManager`. A controller holds at most one, for the
  provider of the current plan, and gives it back whenever the stream is closed.

## The fallback ladder

For each source, in ranked order (free slot, then provider priority, then reliability):

1. What worked last time for this channel (`playbackHistory.lastWorkingFormat/Engine`), else the
   preferred format (per-channel override, else the global default `.ts`) on the default engine (mpv).
2. The other format on the same engine, if the provider's `allowed_output_formats` includes it.
3. The other engine. AVPlayer is only offered HLS (`.m3u8`) for live, and only MP4/MOV-style
   containers for VOD. A per-channel engine override disables this step.

Then the next source (another provider). Duplicate plans are removed.

## States (`PlaybackPhase`)

| State | Meaning | UI |
|---|---|---|
| `idle` | Nothing loaded | — |
| `connecting` | Getting a slot / opening the first attempt | Spinner + title |
| `playing` | Frames are being presented | Video |
| `buffering` | Was playing, engine is refilling | Small "Buffering…" pill |
| `paused` | User paused | — |
| `reconnecting(n)` | Recovering automatically | Small "Reconnecting…" pill over the last frame (never an error screen) |
| `waitingForNetwork` | Offline; no attempts are spent | "Waiting for network…" pill |
| `suspended` | Mac asleep; slot released | "Paused for sleep" |
| `preempted` | Gave its slot to another player (preview → full screen) | Small notice |
| `ended` | VOD reached the end | — |
| `failed(f)` | Ladder exhausted, or no slot anywhere (`f.noConnection`) | Card with a specific message and Try Again |

## Transitions

```
play(item) ──► connecting
   (the previous session is cancelled first; its stream is closed and its lease released
    before anything new opens; with debounce, wait zapDebounce (0.35 s) and abandon if superseded)

for each rung in ladder:
    if rung's provider ≠ held lease's provider:
        close stream, release lease
        acquire lease for rung's provider (purpose main/preview/tile)
           └─ no slot ─► skip all rungs of that provider
        if not the first rung: notice "Switching to <provider>…"   (cross-provider failover)
    attempt = 0
    while attempt < attemptsPerRung:
        if offline: waitingForNetwork until network returns   (attempt not spent)
        open stream (engine.load) ──► connecting / reconnecting
        supervise until one of:
            engine .playing         ──► playing (record success for this rung, once)
            engine .buffering(b)    ──► buffering / playing
            engine .failed(e)       ──► FAIL(e)        (offline? ──► NETWORK_LOST)
            engine .endOfStream     ──► live: FAIL(endOfStream)   VOD: ended (done)
            tick, not yet playing, t > openTimeout (15 s) ──► FAIL(timeout)
            tick, playing, no position/buffer/byte progress for stallTimeout (8 s) ──► FAIL(stalled)
            system willSleep        ──► SUSPEND
        FAIL(e):
            stop engine (close before reopen)
            if it had been playing ≥ stableAfter (20 s): attempt = 0   (a working stream gets a fresh budget)
            if e skips the rung (404, 401/403, 456/458/509, unsupported, decoder): record failure, then
                if e is a provider refusal (401/403/404/456/458/509) and a later rung is on another provider:
                    jump straight to that provider's first rung (its other formats would fail the same way)
                else: next rung
            attempt += 1; if attempt == attemptsPerRung: record failure, next rung
            reconnecting(attempt); wait backoff(attempt); retry same rung
        NETWORK_LOST: stop engine ──► waitingForNetwork ──(network up)──► retry same rung, attempt unchanged
        SUSPEND: close stream, release lease ──► suspended ──(didWake)──► re-acquire, restart this rung

ladder exhausted ──► failed(last error)  (or failed(noConnection) if every provider was full)
stop() ──► close stream, release lease ──► idle
preempted by ConnectionManager ──► session cancelled, stream closed ──► preempted
```

### Backoff

`delay(attempt) = min(cap, base · 2^(attempt−1)) · (0.5 + 0.5 · jitter)` with `base = 1 s`,
`cap = 15 s`, `jitter ∈ [0, 1)`. After a stream that was working stalls, the first retry waits 0.5 s.

### Stall watchdog

Sampled every `watchdogInterval` (1 s) while playing and not paused. Progress means any of: the
media position advanced, buffered seconds grew, or the engine's received-byte counter grew. No
progress for `stallTimeout` seconds triggers a reconnect. Engines report their own errors as well;
the watchdog catches the silent case where the socket stays open but no data arrives.

### Connection slots

- `ConnectionManager` tracks leases per provider against `max_connections` (unknown or 0 → 1).
- A lease is held from just before `load` until the stream is closed: on failure (before the
  retry), on zap, on stop, on sleep and on preemption.
- Preview leases are preemptible. When the main player or a tile needs a slot and the provider is
  full, the preview's slot is reassigned immediately, then its controller is told to stop and the
  request waits until the preview's stream has closed.
- Releasing an unknown or reassigned lease is a no-op, so a late release can't free someone else's slot.

### What is remembered

`playbackHistory(providerID, streamID)`: success/failure counts, an exponentially weighted
reliability score (weight 0.3), the last working format and engine, and the last error. A failure
on the remembered configuration clears it, so the next play starts from the defaults.

## Logging

Every transition is logged with `os.Logger` (subsystem `com.jackson.iptvstreamer`, category
`playback`): old state → new state and the reason. URLs and engine log lines are passed through
`CredentialRedactor`. View them live in Console.app.
