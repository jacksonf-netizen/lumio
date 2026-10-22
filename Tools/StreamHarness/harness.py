#!/usr/bin/env python3
"""
Local fake Xtream Codes provider for testing playback reliability without a real provider.

Serves:
  player_api.php   account, categories, channels, a movie and a series (credentials: test / test)
  xmltv.php        a generated guide for the test channels (now ±12 h)
  /live/test/test/<id>.ts     endless live MPEG-TS from one shared ffmpeg encoder per channel; like a
                              real server, new viewers first get the last few seconds, then live data
  /live/test/test/<id>.m3u8   live HLS (ffmpeg writes segments into ./media)
  /movie/test/test/900.mp4    a 2-minute test movie
  /series/test/test/<id>.mp4  episodes (same file)

Channels:
  1  H.264 720p25 + AAC        (the easy case)
  2  HEVC 1080p25 + AC-3       (what AVPlayer can't do over raw TS)
  3  H.264 720p50 + E-AC-3

Fault injection (curl these while the app plays):
  /control/normal                  back to healthy
  /control/stall                   keep connections open but stop sending bytes
  /control/drop                    close every open stream connection now
  /control/throttle?kbps=300       slow every stream down
  /control/status?code=403         answer new stream requests with this HTTP status
  /control/maxconn?n=1&code=458    refuse streams beyond n concurrent connections
  /control/state                   show current settings and open connections

Add --region-prefixes to name the groups like many real providers do ("UK | News", "US | Entertainment"),
or --region-prefixes=alt for another provider's spellings of the same regions ("GB: News", "NA - Entertainment").

Run two of these on different ports to simulate two providers:
  python3 Tools/StreamHarness/harness.py --port 8088 --name "Harness A"
  python3 Tools/StreamHarness/harness.py --port 8089 --name "Harness B" --max-connections 1
"""

import argparse
import collections
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

USERNAME = "test"
PASSWORD = "test"
HERE = os.path.dirname(os.path.abspath(__file__))

CHANNELS = {
    1: {"name": "Harness News HD", "epg": "harness.news", "category": "1",
        "video": ["-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency", "-g", "50", "-b:v", "2500k"],
        "audio": ["-c:a", "aac", "-b:a", "128k"], "size": "1280x720", "rate": 25, "tone": 440},
    2: {"name": "Harness Sport HEVC FHD", "epg": "harness.sport", "category": "2",
        "video": ["-c:v", "libx265", "-preset", "ultrafast", "-tune", "zerolatency", "-x265-params", "log-level=error:keyint=50", "-b:v", "3500k"],
        "audio": ["-c:a", "ac3", "-b:a", "192k"], "size": "1920x1080", "rate": 25, "tone": 660},
    3: {"name": "Harness Movies 50fps", "epg": "harness.movies", "category": "2",
        "video": ["-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency", "-g", "100", "-b:v", "3000k"],
        "audio": ["-c:a", "eac3", "-b:a", "192k"], "size": "1280x720", "rate": 50, "tone": 880},
}


class Faults:
    """Shared, thread-safe fault-injection state."""

    def __init__(self, max_connections):
        self.lock = threading.Lock()
        self.mode = "normal"          # normal | stall
        self.kbps = 0                 # 0 = unthrottled
        self.status = 0               # 0 = no forced status
        self.max_connections = max_connections
        self.maxconn_code = 458
        self.generation = 0           # bumped by /control/drop
        self.open_streams = 0
        self.refused = 0              # streams refused for being over max_connections

    def snapshot(self):
        with self.lock:
            return {"mode": self.mode, "kbps": self.kbps, "status": self.status,
                    "max_connections": self.max_connections, "maxconn_code": self.maxconn_code,
                    "open_streams": self.open_streams, "refused": self.refused, "generation": self.generation}


def ffmpeg_live_command(channel, output_args):
    c = CHANNELS[channel]
    return [
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-re",
        "-f", "lavfi", "-i", f"testsrc2=size={c['size']}:rate={c['rate']}",
        "-f", "lavfi", "-i", f"sine=frequency={c['tone']}:sample_rate=48000",
        *c["video"], "-pix_fmt", "yuv420p", *c["audio"], *output_args,
    ]


class LiveRelay:
    """One encoder per channel, shared by every viewer, the way a real IPTV server relays a source.

    New viewers first get the last few seconds (the backlog real servers send on connect, which
    fills the player's buffer), then the data as it's encoded. An encoder stops once nobody has
    watched its channel for a while."""

    BACKLOG_SECONDS = 4
    KEEP_SECONDS = 8
    IDLE_STOP_SECONDS = 15
    PACKET = 188  # MPEG-TS packet size; chunks are cut on packet boundaries

    def __init__(self):
        self.lock = threading.Condition()
        self.channels = {}

    def chunks(self, channel):
        """Yields the stream for one viewer, starting with the backlog."""
        with self.lock:
            state = self.channels.get(channel)
            if state is None or state["ended"]:
                state = self._start(channel)
            state["viewers"] += 1
            cutoff = time.monotonic() - self.BACKLOG_SECONDS
            position = next((seq for seq, at, _ in state["log"] if at >= cutoff), state["seq"])
        try:
            while True:
                with self.lock:
                    while position >= state["seq"] and not state["ended"]:
                        self.lock.wait(1)
                    if position >= state["seq"]:
                        return
                    # A viewer that fell too far behind skips ahead, like a real server would.
                    oldest = state["log"][0][0] if state["log"] else state["seq"]
                    position = max(position, oldest)
                    pending = [chunk for seq, _, chunk in state["log"] if seq >= position]
                    position = state["seq"]
                for chunk in pending:
                    yield chunk
        finally:
            with self.lock:
                state["viewers"] -= 1
                if state["viewers"] == 0:
                    state["idle_since"] = time.monotonic()

    def _start(self, channel):
        proc = subprocess.Popen(ffmpeg_live_command(channel, ["-f", "mpegts", "pipe:1"]),
                                stdout=subprocess.PIPE, stdin=subprocess.DEVNULL)
        state = {"proc": proc, "log": collections.deque(), "seq": 0, "viewers": 0,
                 "idle_since": None, "ended": False}
        self.channels[channel] = state
        threading.Thread(target=self._pump, args=(channel, state), daemon=True).start()
        return state

    def _pump(self, channel, state):
        fd = state["proc"].stdout.fileno()
        pending = b""
        while True:
            data = os.read(fd, 64 * 1024)
            with self.lock:
                idle = state["viewers"] == 0 and state["idle_since"] and time.monotonic() - state["idle_since"] > self.IDLE_STOP_SECONDS
                if not data or idle:
                    state["ended"] = True
                    state["proc"].kill()
                    if self.channels.get(channel) is state:
                        del self.channels[channel]
                    self.lock.notify_all()
                    return
                pending += data
                whole = len(pending) - len(pending) % self.PACKET
                if whole:
                    now = time.monotonic()
                    state["log"].append((state["seq"], now, pending[:whole]))
                    state["seq"] += 1
                    pending = pending[whole:]
                    while state["log"] and state["log"][0][1] < now - self.KEEP_SECONDS:
                        state["log"].popleft()
                    self.lock.notify_all()

    def stop_all(self):
        with self.lock:
            for state in self.channels.values():
                state["proc"].kill()


class HLSManager:
    """Keeps one ffmpeg per channel writing a rolling live HLS playlist."""

    def __init__(self, media_dir):
        self.media_dir = media_dir
        self.processes = {}
        self.lock = threading.Lock()

    def ensure(self, channel):
        with self.lock:
            proc = self.processes.get(channel)
            if proc and proc.poll() is None:
                return
            out = os.path.join(self.media_dir, f"hls{channel}")
            shutil.rmtree(out, ignore_errors=True)
            os.makedirs(out, exist_ok=True)
            cmd = ffmpeg_live_command(channel, [
                "-f", "hls", "-hls_time", "2", "-hls_list_size", "6",
                "-hls_flags", "delete_segments+omit_endlist",
                "-hls_segment_filename", os.path.join(out, "seg%05d.ts"),
                os.path.join(out, "index.m3u8"),
            ])
            self.processes[channel] = subprocess.Popen(cmd, stdin=subprocess.DEVNULL)
        # Wait for the first playlist.
        playlist = os.path.join(self.media_dir, f"hls{channel}", "index.m3u8")
        for _ in range(100):
            if os.path.exists(playlist):
                return
            time.sleep(0.1)

    def stop_all(self):
        with self.lock:
            for proc in self.processes.values():
                proc.terminate()


def make_movie(media_dir):
    path = os.path.join(media_dir, "movie.mp4")
    if not os.path.exists(path):
        print("Generating test movie (once)…", flush=True)
        subprocess.run([
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=25:duration=120",
            "-f", "lavfi", "-i", "sine=frequency=330:sample_rate=48000:duration=120",
            "-c:v", "libx264", "-preset", "veryfast", "-pix_fmt", "yuv420p", "-c:a", "aac",
            "-movflags", "+faststart", path,
        ], check=True)
    return path


def xmltv(now):
    def fmt(t):
        return time.strftime("%Y%m%d%H%M%S +0000", time.gmtime(t))
    start = int(now // 1800 * 1800) - 12 * 3600
    lines = ['<?xml version="1.0" encoding="UTF-8"?>', '<tv generator-info-name="harness">']
    for cid, c in CHANNELS.items():
        lines.append(f'<channel id="{c["epg"]}"><display-name>{c["name"]}</display-name></channel>')
    for cid, c in CHANNELS.items():
        for n in range(48):
            s = start + n * 1800
            lines.append(f'<programme start="{fmt(s)}" stop="{fmt(s + 1800)}" channel="{c["epg"]}">'
                         f'<title>{c["name"]} programme {n}</title>'
                         f'<desc>Test programme number {n} on channel {cid} &amp; friends.</desc></programme>')
    lines.append("</tv>")
    return "\n".join(lines).encode()


def make_handler(args, faults, hls, relay, movie_path):
    # --renumber: the same catalog as another panel would list it (new IDs, other name style).
    R = 500 if args.renumber else 0

    def label(name):
        return name.upper().replace(" HD", "") + " FHD" if args.renumber else name

    def cat(category_id):
        return f"c{category_id}" if args.renumber else category_id

    base_url = f"http://127.0.0.1:{args.port}"

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *a):
            if not args.quiet:
                sys.stderr.write(f"[{args.name}] {self.address_string()} {fmt % a}\n")

        # --- helpers ---
        def send_json(self, obj, status=200):
            body = json.dumps(obj).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def send_bytes(self, body, content_type, status=200):
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def send_status(self, code):
            self.send_bytes(f"HTTP {code}\n".encode(), "text/plain", code)

        def authorised(self, query):
            return query.get("username", [""])[0] == USERNAME and query.get("password", [""])[0] == PASSWORD

        # --- routing ---
        def do_GET(self):
            url = urlparse(self.path)
            query = parse_qs(url.query)
            parts = [p for p in url.path.split("/") if p]
            try:
                if url.path.startswith("/control/"):
                    return self.control(parts[1], query)
                if url.path == "/player_api.php":
                    return self.player_api(query)
                if url.path == "/xmltv.php":
                    if not self.authorised(query):
                        return self.send_status(401)
                    return self.send_bytes(xmltv(time.time()), "application/xml")
                if url.path.startswith("/hls"):
                    return self.hls_file(parts)
                if len(parts) == 2 and parts[0] == "logo":
                    return self.logo(parts[1])
                if url.path == "/huge.png":
                    return self.huge_image()
                if len(parts) == 4 and parts[0] in ("live", "movie", "series"):
                    kind, user, password, filename = parts
                    if user != USERNAME or password != PASSWORD:
                        return self.send_status(401)
                    return self.stream(kind, filename)
                self.send_status(404)
            except (BrokenPipeError, ConnectionResetError):
                pass

        def control(self, action, query):
            with faults.lock:
                if action == "normal":
                    faults.mode, faults.kbps, faults.status = "normal", 0, 0
                elif action == "stall":
                    faults.mode = "stall"
                elif action == "drop":
                    faults.generation += 1
                elif action == "throttle":
                    faults.kbps = int(query.get("kbps", ["300"])[0])
                elif action == "status":
                    faults.status = int(query.get("code", ["403"])[0])
                elif action == "maxconn":
                    faults.max_connections = int(query.get("n", ["1"])[0])
                    faults.maxconn_code = int(query.get("code", ["458"])[0])
                elif action != "state":
                    return self.send_status(404)
            state = faults.snapshot()
            print(f"[{args.name}] control/{action} → {state}", flush=True)
            self.send_json(state)

        def player_api(self, query):
            if not self.authorised(query):
                return self.send_json({"user_info": {"auth": 0}})
            action = query.get("action", [None])[0]
            now = int(time.time())
            if action is None:
                return self.send_json({
                    "user_info": {"username": USERNAME, "password": PASSWORD, "auth": 1, "status": "Active",
                                  "exp_date": str(now + 365 * 86400), "is_trial": "0",
                                  "active_cons": str(faults.snapshot()["open_streams"]),
                                  "created_at": str(now - 86400), "max_connections": str(faults.max_connections),
                                  "allowed_output_formats": ["m3u8", "ts"]},
                    "server_info": {"url": "127.0.0.1", "port": str(args.port), "server_protocol": "http",
                                    "timezone": "UTC", "timestamp_now": now},
                })
            if action in ("get_live_categories", "get_vod_categories", "get_series_categories"):
                news, entertainment = {
                    "standard": ("UK | News", "US | Entertainment"),
                    "alt": ("GB: News", "NA - Entertainment"),
                }.get(args.region_prefixes, (f"{args.name} News", f"{args.name} Entertainment"))
                return self.send_json([{"category_id": cat("1"), "category_name": news, "parent_id": 0},
                                       {"category_id": cat("2"), "category_name": entertainment, "parent_id": 0}])
            if action == "get_live_streams":
                return self.send_json([
                    {"num": cid, "name": label(c["name"]), "stream_type": "live", "stream_id": cid + R, "stream_icon": f"{base_url}/logo/{cid}.png",
                     "epg_channel_id": c["epg"], "added": str(now), "category_id": cat(c["category"]),
                     "tv_archive": 0, "tv_archive_duration": 0}
                    for cid, c in CHANNELS.items()])
            if action == "get_vod_streams":
                return self.send_json([{"num": 1, "name": label("Harness Test Movie (2026)"), "stream_type": "movie",
                                        "stream_id": 900 + R, "stream_icon": "", "rating": "7.0", "added": str(now),
                                        "category_id": cat("1"), "container_extension": "mp4"}])
            if action == "get_vod_info":
                return self.send_json({"info": {"plot": "Two minutes of test pattern.", "duration_secs": 120},
                                       "movie_data": {"stream_id": 900 + R, "container_extension": "mp4"}})
            if action == "get_series":
                return self.send_json([{"num": 1, "name": label("Harness Test Series"), "series_id": 950 + R, "cover": "",
                                        "plot": "A series of test patterns.", "category_id": cat("1"),
                                        "last_modified": str(now)}])
            if action == "get_series_info":
                return self.send_json({"seasons": [{"season_number": 1, "name": "Season 1"}],
                                       "info": {"name": "Harness Test Series", "plot": "A series of test patterns."},
                                       "episodes": {"1": [
                                           {"id": str(951 + R), "episode_num": 1, "title": "Pilot", "container_extension": "mp4",
                                            "info": {"duration_secs": 120}, "season": 1},
                                           {"id": str(952 + R), "episode_num": 2, "title": "Second", "container_extension": "mp4",
                                            "info": {"duration_secs": 120}, "season": 1}]}})
            if action == "get_short_epg":
                return self.send_json({"epg_listings": []})
            return self.send_json([])

        def logo(self, name):
            """A small PNG per channel (generated once with ffmpeg)."""
            stem = name.removesuffix(".png")
            if not stem.isdigit() or int(stem) not in CHANNELS:
                return self.send_status(404)
            path = os.path.join(args.media, f"logo{stem}.png")
            if not os.path.exists(path):
                subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi",
                                "-i", f"testsrc2=size=200x120:rate=1", "-frames:v", "1", path], check=True)
            with open(path, "rb") as f:
                self.send_bytes(f.read(), "image/png")

        def huge_image(self):
            """An oversized "logo" (40 MB), for testing that the app refuses it."""
            size = 40 << 20
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(size))
            self.end_headers()
            chunk = b"\x00" * (1 << 20)
            for _ in range(size >> 20):
                self.wfile.write(chunk)

        def hls_file(self, parts):
            path = os.path.join(args.media, *parts)
            if not os.path.abspath(path).startswith(os.path.abspath(args.media)) or not os.path.exists(path):
                return self.send_status(404)
            with open(path, "rb") as f:
                body = f.read()
            ctype = "application/vnd.apple.mpegurl" if path.endswith(".m3u8") else "video/mp2t"
            self.send_bytes(body, ctype)

        def stream(self, kind, filename):
            stem, _, ext = filename.partition(".")
            state = faults.snapshot()
            if state["status"]:
                return self.send_status(state["status"])
            with faults.lock:
                if faults.open_streams >= faults.max_connections:
                    code = faults.maxconn_code
                    print(f"[{args.name}] refusing stream: {faults.open_streams}/{faults.max_connections} in use → HTTP {code}", flush=True)
                    faults.refused += 1
                    refuse = True
                else:
                    faults.open_streams += 1
                    refuse = False
            if refuse:
                return self.send_status(code)
            try:
                channel = int(stem) - R if stem.isdigit() else None
                if kind == "live" and ext == "ts" and channel in CHANNELS:
                    self.live_ts(channel)
                elif kind == "live" and ext == "m3u8" and channel in CHANNELS:
                    self.live_hls_playlist(channel)
                elif kind in ("movie", "series"):
                    self.file(movie_path)
                else:
                    self.send_status(404)
            finally:
                with faults.lock:
                    faults.open_streams -= 1

        def live_hls_playlist(self, channel):
            # HLS clients poll the playlist; count it as a connection only for the request itself.
            hls.ensure(channel)
            with open(os.path.join(args.media, f"hls{channel}", "index.m3u8"), "rb") as f:
                text = f.read().decode()
            text = "\n".join(f"/hls{channel}/{line}" if line.endswith(".ts") else line for line in text.splitlines())
            self.send_bytes(text.encode(), "application/vnd.apple.mpegurl")

        def live_ts(self, channel):
            self.send_response(200)
            self.send_header("Content-Type", "video/mp2t")
            self.send_header("Connection", "close")
            self.end_headers()
            generation = faults.snapshot()["generation"]
            stream = relay.chunks(channel)
            print(f"[{args.name}] live {channel}.ts opened", flush=True)
            try:
                for chunk in stream:
                    state = faults.snapshot()
                    if state["generation"] != generation:
                        print(f"[{args.name}] dropping live {channel}.ts", flush=True)
                        self.connection.shutdown(socket.SHUT_RDWR)
                        break
                    while faults.snapshot()["mode"] == "stall":
                        time.sleep(0.2)  # keep the socket open, send nothing
                        if faults.snapshot()["generation"] != generation:
                            break
                    self.wfile.write(chunk)
                    if state["kbps"]:
                        time.sleep(len(chunk) * 8 / (state["kbps"] * 1000))
            except (BrokenPipeError, ConnectionResetError, OSError):
                pass
            finally:
                stream.close()
                print(f"[{args.name}] live {channel}.ts closed", flush=True)

        def file(self, path):
            size = os.path.getsize(path)
            start, end = 0, size - 1
            rng = self.headers.get("Range")
            if rng and rng.startswith("bytes="):
                a, _, b = rng[6:].partition("-")
                start = int(a) if a else 0
                end = int(b) if b else size - 1
                self.send_response(206)
                self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
            else:
                self.send_response(200)
            self.send_header("Content-Type", "video/mp4")
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Length", str(end - start + 1))
            self.end_headers()
            with open(path, "rb") as f:
                f.seek(start)
                remaining = end - start + 1
                while remaining > 0:
                    chunk = f.read(min(256 * 1024, remaining))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    remaining -= len(chunk)

    return Handler


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--port", type=int, default=8088)
    parser.add_argument("--name", default="Harness")
    parser.add_argument("--max-connections", type=int, default=2)
    parser.add_argument("--media", default=None, help="working folder for generated media")
    parser.add_argument("--quiet", action="store_true")
    parser.add_argument("--region-prefixes", nargs="?", const="standard", choices=["standard", "alt"],
                        help='name groups "UK | News" / "US | Entertainment" (or with "alt": "GB: News" / "NA - Entertainment")')
    parser.add_argument("--renumber", action="store_true",
                        help="serve the same catalog under different IDs and name styles, like a provider that moved to another panel")
    args = parser.parse_args()
    args.media = args.media or os.path.join(HERE, "media", str(args.port))
    os.makedirs(args.media, exist_ok=True)

    if not shutil.which("ffmpeg"):
        sys.exit("ffmpeg is required: brew install ffmpeg")

    faults = Faults(args.max_connections)
    hls = HLSManager(args.media)
    relay = LiveRelay()
    movie = make_movie(args.media)
    server = ThreadingHTTPServer(("127.0.0.1", args.port), make_handler(args, faults, hls, relay, movie))
    server.daemon_threads = True

    def shutdown(*_):
        hls.stop_all()
        relay.stop_all()
        os._exit(0)

    signal.signal(signal.SIGINT, shutdown)
    signal.signal(signal.SIGTERM, shutdown)
    print(f"{args.name}: http://127.0.0.1:{args.port}  (username {USERNAME}, password {PASSWORD}, "
          f"max connections {args.max_connections})", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
