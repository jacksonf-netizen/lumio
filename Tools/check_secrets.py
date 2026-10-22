#!/usr/bin/env python3
"""Fails if anything that would be committed contains a credential.

    python3 Tools/check_secrets.py

Checks every file git would track (committed, staged or untracked but not ignored) for:
  * the usernames, passwords and server addresses in your git-ignored LocalSecrets.json,
  * the server addresses of the providers you added in the app (read from its local database;
    usernames and passwords live in the Keychain and never touch the repository),
  * private keys, certificates and access tokens,
  * LocalSecrets.json itself not being ignored.

Run it before every push. To run it automatically before each commit:
    printf '#!/bin/sh\\npython3 Tools/check_secrets.py\\n' > .git/hooks/pre-commit && chmod +x .git/hooks/pre-commit
"""
import json
import os
import re
import sqlite3
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
# Placeholder values used in the example file, docs and tests.
PLACEHOLDERS = {"username", "password", "user", "pass", "test", "example.com", "http://example.com:8080"}
PATTERNS = {
    "private key": re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH |)PRIVATE KEY-----"),
    "GitHub token": re.compile(rb"\b(?:ghp|gho|ghu|ghs|github_pat)_[A-Za-z0-9_]{20,}"),
    "Apple app-specific password": re.compile(rb"\b[a-z]{4}-[a-z]{4}-[a-z]{4}-[a-z]{4}\b"),
}
BINARY_SUFFIXES = {".p12", ".cer", ".mobileprovision", ".provisionprofile", ".keychain", ".keychain-db"}


def committable_files():
    out = subprocess.run(["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
                         cwd=ROOT, capture_output=True, check=True).stdout
    return [f for f in out.decode().split("\0") if f]


def local_secret_values():
    path = os.path.join(ROOT, "LocalSecrets.json")
    if not os.path.exists(path):
        return []
    with open(path) as f:
        data = json.load(f)
    values = set()
    for provider in data.get("providers", []):
        for key in ("username", "password", "serverURL"):
            value = str(provider.get(key, "")).strip()
            if len(value) >= 4 and value.lower() not in PLACEHOLDERS:
                values.add(value)
                if key == "serverURL":
                    # The host alone, e.g. "provider.tv:8080".
                    host = re.sub(r"^[a-z]+://", "", value).rstrip("/")
                    if host.lower() not in PLACEHOLDERS:
                        values.add(host)
    return sorted(values)


APP_DATA = os.path.expanduser(
    "~/Library/Containers/com.jackson.iptvstreamer/Data/Library/Application Support/IPTVStreamer")
LOCAL_HOSTS = ("127.0.0.1", "localhost", "::1")


# The hosts last read from the app's database, kept inside .git (never committed): once Lumio is
# signed with its certificate, macOS stops other apps, Terminal included, from reading its data.
HOSTS_CACHE = os.path.join(ROOT, ".git", "lumio-provider-hosts")


def provider_hosts():
    """Server hosts of providers added in the app (Release and Debug databases)."""
    hosts = set()
    unreadable = False
    for name in ("iptv.sqlite", "dev.sqlite"):
        path = os.path.join(APP_DATA, name)
        try:
            if not os.path.exists(path):
                continue
            db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
            rows = db.execute("SELECT serverURL FROM provider").fetchall()
            db.close()
        except (sqlite3.Error, OSError):
            unreadable = True
            continue
        for (url,) in rows:
            host = re.sub(r"^[a-z]+://", "", str(url)).split("/")[0]
            bare = host.split(":")[0].strip("[]")
            if bare and bare not in LOCAL_HOSTS and not bare.endswith((".test", "example.com")):
                hosts.add(host)
                hosts.add(bare)
    if unreadable:
        try:
            with open(HOSTS_CACHE) as f:
                hosts.update(line.strip() for line in f if line.strip())
            print("Couldn't read Lumio's database (macOS protects it), so the provider addresses saved "
                  "the last time it could are used.")
        except OSError:
            print("Couldn't read Lumio's database (macOS protects it), and no addresses were saved "
                  "earlier: put your providers in LocalSecrets.json to have them checked.")
    elif hosts:
        with open(HOSTS_CACHE, "w") as f:
            f.write("".join(f"{host}\n" for host in sorted(hosts)))
        os.chmod(HOSTS_CACHE, 0o600)
    return sorted(hosts)


def main():
    problems = []
    files = committable_files()
    if "LocalSecrets.json" in files:
        problems.append("LocalSecrets.json is not git-ignored")
    secrets = [v.encode() for v in sorted(set(local_secret_values()) | set(provider_hosts()))]
    for name in files:
        path = os.path.join(ROOT, name)
        if not os.path.isfile(path):
            continue
        if os.path.splitext(name)[1].lower() in BINARY_SUFFIXES:
            problems.append(f"{name}: signing or key file")
            continue
        with open(path, "rb") as f:
            content = f.read()
        for secret in secrets:
            if secret in content:
                problems.append(f"{name}: contains one of your provider addresses or credentials")
                break
        for label, pattern in PATTERNS.items():
            if pattern.search(content):
                problems.append(f"{name}: looks like it contains a {label}")
    checked = f"{len(files)} files, {len(secrets)} private values"
    if problems:
        print(f"Found possible secrets ({checked}):")
        for problem in problems:
            print("  -", problem)
        sys.exit(1)
    print(f"No secrets found ({checked}).")


if __name__ == "__main__":
    main()
