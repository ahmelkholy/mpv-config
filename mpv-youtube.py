#!/usr/bin/env python3
"""Cross-platform mpv launcher for persistent YouTube queues."""

from __future__ import annotations

import argparse
import json
import os
import platform
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import zipfile
from pathlib import Path
from typing import Iterable, Mapping, Sequence
from urllib.parse import parse_qs, urlencode, urlparse, urlunparse
from xml.etree import ElementTree


HEIGHTS = (720, 1080, 1440, 2160, 4320)
USER_AGENT = "mpv-portable-updater"
YOUTUBE_HOST_MARKERS = (
    "youtube.com/",
    "youtu.be/",
    "music.youtube.com/",
)
SCRIPT_UPDATES = (
    ("po5/memo", "memo.lua", "scripts/memo.lua"),
    ("po5/evafast", "evafast.lua", "scripts/evafast.lua"),
    ("mpv-player/mpv", "TOOLS/lua/autoload.lua", "scripts/autoload.lua"),
    ("mpv-player/mpv", "TOOLS/lua/autodeint.lua", "scripts/autodeint.lua"),
)
PS_OPTION_ALIASES = {
    "cookies": "--cookies",
    "cookiesfrombrowser": "--cookies-from-browser",
    "nocookies": "--no-cookies",
    "clearyoutubequeue": "--clear-youtube-queue",
    "clearqueue": "--clear-youtube-queue",
    "dryrun": "--dry-run",
    "forceclosempv": "--force-close-mpv",
    "height": "--height",
    "ipcname": "--ipc-name",
    "mpv": "--mpv",
    "nopause": "--no-pause",
    "noupdate": "--no-update",
    "playlistdir": "--playlist-dir",
    "playlistlimit": "--playlist-limit",
    "saveplaylist": "--save-playlist",
    "skipmpv": "--skip-mpv",
    "skipscripts": "--skip-scripts",
    "update": "--update",
    "wait": "--wait",
    "ytdlponly": "--yt-dlp-only",
}
CLEAR_QUEUE_COMMANDS = {
    "clear",
    "clear-queue",
    "clear-youtube",
    "clear-youtube-queue",
}


def is_windows() -> bool:
    """Return True when running on Windows."""
    return platform.system().lower() == "windows"


def is_url(value: str) -> bool:
    """Return True if a value looks like an HTTP URL."""
    return value.startswith(("http://", "https://"))


def is_youtube_url(value: str) -> bool:
    """Return True if a value looks like a YouTube URL."""
    return is_url(value) and any(marker in value for marker in YOUTUBE_HOST_MARKERS)


def is_youtube_playlist_url(value: str) -> bool:
    """Return True if a YouTube URL points at a playlist or radio mix."""
    if not is_youtube_url(value):
        return False

    parsed = urlparse(value)
    query = parse_qs(parsed.query)
    return bool(query.get("list")) or parsed.path.rstrip("/").endswith("/playlist")


def first_query_value(url: str, key: str) -> str | None:
    """Return the first query-string value for a URL key."""
    values = parse_qs(urlparse(url).query).get(key)
    if not values:
        return None

    return values[0] or None


def youtube_video_id(url: str) -> str | None:
    """Return the YouTube video id from common video URL shapes."""
    if not is_youtube_url(url):
        return None

    parsed = urlparse(url)
    host = parsed.netloc.lower()
    path = parsed.path.strip("/")
    if "youtu.be" in host:
        return path.split("/", 1)[0] or None

    if path == "watch":
        return first_query_value(url, "v")

    for prefix in ("shorts/", "embed/", "live/"):
        if path.startswith(prefix):
            return path.removeprefix(prefix).split("/", 1)[0] or None

    return None


def youtube_playlist_id(url: str) -> str | None:
    """Return the YouTube playlist id from a playlist/radio URL."""
    if not is_youtube_url(url):
        return None

    return first_query_value(url, "list")


def canonical_youtube_playlist_url(url: str) -> str | None:
    """Return a canonical /playlist URL for links containing a list id."""
    playlist_id = youtube_playlist_id(url)
    if not playlist_id:
        return None

    parsed = urlparse(url)
    host = (
        "music.youtube.com"
        if "music.youtube.com" in parsed.netloc.lower()
        else "www.youtube.com"
    )
    return urlunparse(
        (
            parsed.scheme or "https",
            host,
            "/playlist",
            "",
            urlencode({"list": playlist_id}),
            "",
        )
    )


def youtube_playlist_expansion_urls(url: str) -> list[str]:
    """Return yt-dlp URL candidates that should expose playlist entries."""
    candidates: list[str] = []
    canonical = canonical_youtube_playlist_url(url)
    if canonical:
        candidates.append(canonical)
    candidates.append(url)

    unique: list[str] = []
    seen: set[str] = set()
    for candidate in candidates:
        if candidate not in seen:
            unique.append(candidate)
            seen.add(candidate)

    return unique


def is_media_argument(value: str) -> bool:
    """Return True if an mpv argument is a URL or an existing local path."""
    if not value or value.startswith("-"):
        return False

    return is_url(value) or Path(value).exists()


def first_youtube_url(values: Iterable[str]) -> str | None:
    """Return the first YouTube URL from an argument list."""
    for value in values:
        if is_youtube_url(value):
            return value

    return None


def first_youtube_playlist_url(values: Iterable[str]) -> str | None:
    """Return the first YouTube playlist/radio URL from an argument list."""
    for value in values:
        if is_youtube_playlist_url(value):
            return value

    return None


def find_first_executable(names: Sequence[str]) -> str | None:
    """Return the first executable found in PATH."""
    for name in names:
        path = shutil.which(name)
        if path:
            return path

    return None


def script_root() -> Path:
    """Return the directory containing this launcher."""
    return Path(__file__).resolve().parent


def default_config_dir(root: Path) -> Path:
    """Return the preferred mpv config directory."""
    portable_config = root / "portable_config"
    if portable_config.exists():
        return portable_config

    return root


def normalize_cli_args(argv: Sequence[str]) -> list[str]:
    """Accept common PowerShell-style single-dash option names."""
    normalized: list[str] = []
    for item in argv:
        if item.startswith("-") and not item.startswith("--"):
            alias = PS_OPTION_ALIASES.get(item.lstrip("-").lower())
            normalized.append(alias or item)
        else:
            normalized.append(item)

    return normalized


def print_step(message: str) -> None:
    """Print a visible updater step."""
    print(f"\n==> {message}")


def print_ok(message: str) -> None:
    """Print a successful updater line."""
    print(f"OK  {message}")


def print_warn(message: str) -> None:
    """Print a warning updater line."""
    print(f"WARN {message}")


def request_url(url: str, method: str = "GET") -> urllib.request.Request:
    """Build an HTTP request with the updater user agent."""
    return urllib.request.Request(
        url,
        method=method,
        headers={"User-Agent": USER_AGENT},
    )


def read_url_text(url: str) -> str:
    """Read a URL as UTF-8 text."""
    with urllib.request.urlopen(request_url(url), timeout=60) as response:
        return response.read().decode("utf-8", errors="replace")


def read_url_json(url: str) -> object:
    """Read a URL and parse its JSON response."""
    return json.loads(read_url_text(url))


def download_file(url: str, destination: Path) -> None:
    """Download a URL to a local path."""
    destination.parent.mkdir(parents=True, exist_ok=True)
    with urllib.request.urlopen(request_url(url), timeout=120) as response:
        with destination.open("wb") as file:
            shutil.copyfileobj(response, file)


def run_process(
    args: Sequence[str | Path],
    *,
    check: bool = False,
    capture: bool = False,
) -> subprocess.CompletedProcess[str]:
    """Run a subprocess with consistent string conversion."""
    result = subprocess.run(
        [str(arg) for arg in args],
        check=False,
        capture_output=capture,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    if check and result.returncode != 0:
        detail = (result.stderr or result.stdout or "").strip()
        raise RuntimeError(detail or f"command failed: {args[0]}")
    return result


def github_latest_release(repo: str) -> dict[str, object]:
    """Return the latest GitHub release JSON for a repository."""
    data = read_url_json(f"https://api.github.com/repos/{repo}/releases/latest")
    if not isinstance(data, dict):
        raise RuntimeError(f"Unexpected GitHub release response for {repo}")
    return data


def find_release_asset(
    release: dict[str, object],
    predicate: object,
) -> dict[str, object] | None:
    """Return the first release asset matching a predicate."""
    assets = release.get("assets", [])
    if not isinstance(assets, list):
        return None

    for asset in assets:
        if not isinstance(asset, dict):
            continue
        name = str(asset.get("name", ""))
        if callable(predicate) and predicate(name):
            return asset
        if isinstance(predicate, str) and name == predicate:
            return asset

    return None


def asset_download_url(asset: dict[str, object]) -> str:
    """Return an asset browser download URL or raise."""
    url = asset.get("browser_download_url")
    if not isinstance(url, str) or not url:
        raise RuntimeError("Release asset has no browser download URL")
    return url


def find_mpv(root: Path, mpv_path: str | None) -> str:
    """Find the mpv executable for this platform."""
    if mpv_path:
        return mpv_path

    config_dir = default_config_dir(root)
    candidates: list[Path | str] = []

    if is_windows():
        candidates.extend(
            [
                config_dir / "mpv.exe",
                config_dir / "mpv.com",
                "mpv.exe",
                "mpv",
            ]
        )
    else:
        candidates.extend([config_dir / "mpv", "mpv"])

    for candidate in candidates:
        if isinstance(candidate, Path) and candidate.exists():
            return str(candidate)
        if isinstance(candidate, str):
            resolved = shutil.which(candidate)
            if resolved:
                return resolved

    raise FileNotFoundError("mpv was not found")


def find_yt_dlp(config_dir: Path) -> str | None:
    """Find yt-dlp in the portable config or PATH."""
    local_names = ("yt-dlp.exe", "yt-dlp") if is_windows() else ("yt-dlp",)

    for name in local_names:
        candidate = config_dir / name
        if candidate.exists():
            return str(candidate)

    return find_first_executable(["yt-dlp.exe", "yt-dlp"])


def ipc_endpoint(ipc_name: str) -> str:
    """Return the mpv IPC endpoint path for the current platform."""
    if is_windows():
        return rf"\\.\pipe\{ipc_name}"

    runtime_dir = os.environ.get("XDG_RUNTIME_DIR") or tempfile.gettempdir()
    uid = getattr(os, "getuid", lambda: 0)()
    return str(Path(runtime_dir) / f"{ipc_name}-{uid}.sock")


def send_ipc_command(endpoint: str, command: Sequence[str]) -> bool:
    """Send one JSON IPC command to an existing mpv instance."""
    payload = (json.dumps({"command": list(command)}) + "\n").encode("utf-8")

    if is_windows():
        deadline = time.monotonic() + 0.25
        while True:
            try:
                with open(endpoint, "wb", buffering=0) as pipe:
                    pipe.write(payload)
                return True
            except OSError:
                if time.monotonic() >= deadline:
                    return False
                time.sleep(0.03)

    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(0.25)
    try:
        client.connect(endpoint)
        client.sendall(payload)
        return True
    except OSError:
        return False
    finally:
        client.close()


def send_media_to_running_mpv(endpoint: str, media: Sequence[str]) -> bool:
    """Append media to a running mpv process, if one is listening."""
    if not media:
        return False

    sent_any = False
    for item in media:
        if send_ipc_command(endpoint, ["loadfile", item, "append-play"]):
            sent_any = True
            continue

        if not sent_any:
            return False

    return sent_any


def youtube_queue_path(root: Path) -> Path:
    """Return the persistent YouTube queue file path."""
    return default_config_dir(root) / "cache" / "youtube-queue.m3u"


def watch_later_dir(root: Path) -> Path:
    """Return mpv's saved watch-later/session state directory."""
    return default_config_dir(root) / "cache" / "watch_later"


def clear_watch_later(root: Path) -> int:
    """Delete mpv watch-later state files without touching saved playlists."""
    path = watch_later_dir(root)
    if not path.exists():
        return 0

    removed = 0
    for item in path.iterdir():
        if item.is_file():
            item.unlink()
            removed += 1

    return removed


def clear_running_mpv_state(endpoint: str) -> bool:
    """Clear live mpv playlist/session state through IPC when available."""
    commands = (
        ["script-message", "queue-clear"],
        ["set", "save-position-on-quit", "no"],
        ["delete-watch-later-config"],
        ["playlist-clear"],
        ["stop"],
        ["show-text", "mpv YouTube buffer cleared", "2500"],
    )
    sent_any = False
    for command in commands:
        sent_any = send_ipc_command(endpoint, command) or sent_any

    return sent_any


def clear_youtube_queue(root: Path, ipc_name: str, dry_run: bool) -> int:
    """Clear saved queue, watch-later state, and running mpv playlist buffer."""
    queue_path = youtube_queue_path(root)
    state_dir = watch_later_dir(root)
    endpoint = ipc_endpoint(ipc_name)

    if dry_run:
        print(queue_path)
        print(state_dir)
        print(endpoint)
        return 0

    removed_file = False
    try:
        queue_path.unlink()
        removed_file = True
    except FileNotFoundError:
        pass
    except OSError as error:
        print(f"Could not delete {queue_path}: {error}", file=sys.stderr)
        return 1

    try:
        removed_watch_later = clear_watch_later(root)
    except OSError as error:
        print(f"Could not clear {state_dir}: {error}", file=sys.stderr)
        return 1

    cleared_running = clear_running_mpv_state(endpoint)

    if removed_file:
        print(f"Deleted saved YouTube queue: {queue_path}")
    else:
        print("No saved YouTube queue file was present.")

    print(f"Deleted {removed_watch_later} mpv watch-later state file(s).")

    if cleared_running:
        print("Cleared running mpv playlist buffer.")
    else:
        print("No running mpv IPC instance was found.")

    return 0


def format_for_height(height: int) -> str:
    """Return the yt-dlp format selector for a maximum video height."""
    return f"bv*[height<={height}]+ba/b[height<={height}]/bv*+ba/b"


def normalize_cli_path(value: str) -> str:
    """Return an absolute-ish path for forwarding to child processes."""
    path = Path(value).expanduser()
    return str(path.resolve(strict=False))


def usable_cookie_file(path: Path) -> bool:
    """Return True when a cookie file exists and has content."""
    try:
        return path.is_file() and path.stat().st_size > 0
    except OSError:
        return False


def default_cookie_candidates(root: Path) -> list[Path]:
    """Return cookie files to try when --cookies was not provided."""
    downloads = Path.home() / "Downloads"
    config_dir = default_config_dir(root)
    values = [
        os.environ.get("MPV_YOUTUBE_COOKIES", ""),
        downloads / "youtube.com_cookies.txt",
        downloads / "cookies.txt",
        root / "cookies.txt",
        root / "youtube.com_cookies.txt",
        config_dir / "cookies.txt",
        config_dir / "youtube.com_cookies.txt",
    ]

    candidates: list[Path] = []
    seen: set[str] = set()
    for value in values:
        if not value:
            continue
        path = Path(value).expanduser()
        key = str(path.resolve(strict=False)).lower()
        if key not in seen:
            candidates.append(path)
            seen.add(key)

    return candidates


def find_default_cookies_file(root: Path) -> str:
    """Return the first usable automatic cookies.txt path."""
    for candidate in default_cookie_candidates(root):
        if usable_cookie_file(candidate):
            return normalize_cli_path(str(candidate))

    return ""


def yt_dlp_temp_dir() -> Path:
    """Return the local temp base used by PyInstaller yt-dlp builds."""
    return default_config_dir(script_root()) / "cache" / "yt-dlp-temp"


def yt_dlp_process_env() -> dict[str, str]:
    """Return an environment that keeps yt-dlp temp files local."""
    env = os.environ.copy()
    temp_dir = yt_dlp_temp_dir()
    temp_dir.mkdir(parents=True, exist_ok=True)
    env["TEMP"] = str(temp_dir)
    env["TMP"] = str(temp_dir)
    env["TMPDIR"] = str(temp_dir)
    return env


def ytdl_raw_options(cookies_from_browser: str, cookies_file: str) -> list[str]:
    """Build mpv ytdl raw option arguments."""
    raw_options: list[str] = []

    runtime = find_first_executable(["deno", "node", "bun", "qjs", "quickjs"])
    if runtime:
        runtime_name = Path(runtime).stem
        if runtime_name == "qjs":
            runtime_name = "quickjs"
        raw_options.append(
            "--ytdl-raw-options-append="
            f"js-runtimes={runtime_name}:{runtime.replace(os.sep, '/')}"
        )

    ffmpeg = find_first_executable(["ffmpeg"])
    if ffmpeg:
        raw_options.append(
            "--ytdl-raw-options-append="
            f"ffmpeg-location={ffmpeg.replace(os.sep, '/')}"
        )

    if cookies_from_browser:
        raw_options.append(
            "--ytdl-raw-options-append="
            f"cookies-from-browser={cookies_from_browser}"
        )

    if cookies_file:
        cookies_path = normalize_cli_path(cookies_file).replace(os.sep, "/")
        raw_options.append("--ytdl-raw-options-append=" f"cookies={cookies_path}")

    return raw_options


def is_dpapi_cookie_error(detail: str) -> bool:
    """Return True when yt-dlp hit Chromium/Edge DPAPI cookie decryption."""
    return "Failed to decrypt with DPAPI" in detail


def playlist_end_args(limit: int) -> list[str]:
    """Return yt-dlp arguments for an optional playlist item limit."""
    if limit <= 0:
        return []

    return ["--playlist-end", str(limit)]


def expand_youtube_playlist(
    url: str,
    yt_dlp: str | None,
    playlist_limit: int,
    cookies_from_browser: str = "",
    cookies_file: str = "",
) -> list[str]:
    """Return individual video URLs for a YouTube playlist/radio URL."""
    if not yt_dlp or not is_youtube_playlist_url(url):
        return [url]

    failures: list[str] = []
    original_video_id = youtube_video_id(url)
    for expansion_url in youtube_playlist_expansion_urls(url):
        command = [
            yt_dlp,
            "--flat-playlist",
            "--yes-playlist",
            "--ignore-errors",
            "--no-warnings",
            "--print",
            "%(webpage_url)s",
            *playlist_end_args(playlist_limit),
        ]
        if cookies_from_browser:
            command.extend(["--cookies-from-browser", cookies_from_browser])
        if cookies_file:
            command.extend(["--cookies", normalize_cli_path(cookies_file)])
        command.append(expansion_url)

        try:
            result = subprocess.run(
                command,
                check=False,
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                env=yt_dlp_process_env(),
            )
        except OSError as error:
            failures.append(str(error))
            continue

        if result.returncode != 0:
            detail = (result.stderr or "").strip()
            if is_dpapi_cookie_error(detail):
                failures.append(
                    "Chromium/Edge cookie decryption failed with DPAPI"
                )
                break
            failures.append(detail or f"yt-dlp exited with {result.returncode}")
            continue

        entries: list[str] = []
        seen: set[str] = set()
        for line in result.stdout.splitlines():
            entry = line.strip()
            if is_youtube_url(entry) and entry not in seen:
                entries.append(entry)
                seen.add(entry)

        if (
            expansion_url == url
            and len(entries) == 1
            and original_video_id
            and youtube_video_id(entries[0]) == original_video_id
        ):
            failures.append("yt-dlp returned only the current video")
            continue

        if entries:
            return entries

    if failures:
        print(
            "Warning: could not expand playlist URL: " + "; ".join(failures),
            file=sys.stderr,
        )

    return [url]


def expand_media_items(
    media: Sequence[str],
    yt_dlp: str | None,
    playlist_limit: int,
    cookies_from_browser: str = "",
    cookies_file: str = "",
) -> list[str]:
    """Expand playlist/radio media arguments into playable video URLs."""
    expanded: list[str] = []
    for item in media:
        if is_youtube_playlist_url(item):
            expanded.extend(
                expand_youtube_playlist(
                    item,
                    yt_dlp,
                    playlist_limit,
                    cookies_from_browser,
                    cookies_file,
                )
            )
        else:
            expanded.append(item)

    return expanded


def expand_launch_args(
    launch_args: Sequence[str],
    yt_dlp: str | None,
    playlist_limit: int,
    cookies_from_browser: str = "",
    cookies_file: str = "",
) -> list[str]:
    """Expand media URLs while preserving non-media mpv arguments in place."""
    expanded: list[str] = []
    for item in launch_args:
        if is_media_argument(item):
            expanded.extend(
                expand_media_items(
                    [item],
                    yt_dlp,
                    playlist_limit,
                    cookies_from_browser,
                    cookies_file,
                )
            )
        else:
            expanded.append(item)

    return expanded


def sanitize_playlist_name(name: str) -> str:
    """Return a safe filename stem for a saved playlist."""
    sanitized = "".join(
        " " if char in '<>:"/\\|?*' or ord(char) < 32 else char
        for char in name
    )
    sanitized = " ".join(sanitized.split()).strip(" .")
    return sanitized or "YouTube Playlist"


def saved_playlist_path(root: Path, playlist_dir: str | None, name: str) -> Path:
    """Return the target m3u path for a saved playlist name."""
    base_dir = Path(playlist_dir).expanduser() if playlist_dir else root / "PlayList"
    if not base_dir.is_absolute():
        base_dir = root / base_dir

    filename = sanitize_playlist_name(name)
    if Path(filename).suffix.lower() not in {".m3u", ".m3u8"}:
        filename += ".m3u"

    return base_dir / filename


def write_m3u(path: Path, entries: Sequence[str]) -> None:
    """Write entries as an extended m3u file."""
    path.parent.mkdir(parents=True, exist_ok=True)
    content = "#EXTM3U\n" + "\n".join(entries) + "\n"
    path.write_text(content, encoding="utf-8", newline="\n")


def save_youtube_playlist(
    name: str,
    playlist_dir: str | None,
    launch_args: Sequence[str],
    root: Path,
    yt_dlp: str | None,
    playlist_limit: int,
    cookies_from_browser: str,
    cookies_file: str,
    dry_run: bool,
) -> int:
    """Save a YouTube playlist/radio URL to PlayList/NAME.m3u."""
    url = first_youtube_playlist_url(launch_args)
    if not url:
        print(
            "No YouTube playlist/radio URL found. Single video URLs are not saved.",
            file=sys.stderr,
        )
        return 2

    if not yt_dlp:
        print("yt-dlp was not found. Cannot save the playlist.", file=sys.stderr)
        return 1

    entries = expand_youtube_playlist(
        url,
        yt_dlp,
        playlist_limit,
        cookies_from_browser,
        cookies_file,
    )
    if not entries or entries == [url]:
        print("Could not expand the YouTube playlist/radio URL.", file=sys.stderr)
        if not cookies_from_browser and not cookies_file:
            print(
                "If the playlist opens in your signed-in browser, retry with "
                "-CookiesFromBrowser firefox or -Cookies .\\cookies.txt.",
                file=sys.stderr,
            )
        elif cookies_from_browser and not cookies_file:
            print(
                "Chromium/Edge cookie decryption can fail on Windows. Export "
                "cookies to a Netscape cookies.txt file and retry with "
                "-Cookies .\\cookies.txt.",
                file=sys.stderr,
            )
        elif cookies_file:
            print(
                "The cookies file did not grant playlist access. Export fresh "
                "YouTube cookies from the signed-in browser/account and replace: "
                f"{cookies_file}",
                file=sys.stderr,
            )
        return 1

    path = saved_playlist_path(root, playlist_dir, name)
    if dry_run:
        print(path)
        for entry in entries:
            print(entry)
        return 0

    write_m3u(path, entries)
    print(f"Saved {len(entries)} item(s) to {path}")
    return 0


def infer_playlist_save(
    launch_args: Sequence[str],
) -> tuple[str, list[str]] | None:
    """Infer `name + playlist URL` as a request to save an m3u file."""
    if len(launch_args) < 2:
        return None

    name = launch_args[0]
    if is_url(name) or Path(name).exists():
        return None

    if not any(is_youtube_playlist_url(item) for item in launch_args[1:]):
        return None

    return name, list(launch_args[1:])


def is_clear_queue_request(launch_args: Sequence[str]) -> bool:
    """Return True for shorthand commands that clear the YouTube queue."""
    return len(launch_args) == 1 and launch_args[0].lower() in CLEAR_QUEUE_COMMANDS


def build_mpv_args(
    config_dir: Path,
    endpoint: str,
    yt_dlp: str | None,
    height: int,
    cookies_from_browser: str,
    cookies_file: str,
    launch_args: Sequence[str],
) -> list[str]:
    """Build the final mpv argument vector."""
    args = [
        f"--config-dir={config_dir}",
        f"--input-ipc-server={endpoint}",
        "--idle=yes",
        "--force-window=yes",
        "--ytdl=yes",
        "--script-opts-append=ytdl_hook-try_ytdl_first=yes",
        f"--ytdl-format={format_for_height(height)}",
        "--cache=yes",
        "--demuxer-readahead-secs=20",
        "--demuxer-max-bytes=512MiB",
        "--demuxer-max-back-bytes=128MiB",
    ]

    if yt_dlp:
        args.append(
            "--script-opts-append="
            f"ytdl_hook-ytdl_path={yt_dlp.replace(os.sep, '/')}"
        )

    args.extend(ytdl_raw_options(cookies_from_browser, cookies_file))
    args.extend(launch_args)
    return args


def remove_stale_unix_socket(endpoint: str) -> None:
    """Remove a stale Unix socket before starting a new mpv server."""
    if is_windows():
        return

    path = Path(endpoint)
    if path.exists():
        try:
            path.unlink()
        except OSError:
            pass


def start_mpv(
    mpv_path: str,
    mpv_args: Sequence[str],
    wait: bool,
    env: Mapping[str, str] | None = None,
) -> int:
    """Start mpv either attached for debugging or detached for daily use."""
    command = [mpv_path, *mpv_args]

    if wait:
        return subprocess.call(command, env=env)

    kwargs: dict[str, object] = {
        "stdin": subprocess.DEVNULL,
        "stdout": subprocess.DEVNULL,
        "stderr": subprocess.DEVNULL,
        "close_fds": True,
    }
    if env:
        kwargs["env"] = env

    if is_windows():
        kwargs["creationflags"] = (
            subprocess.CREATE_NEW_PROCESS_GROUP | subprocess.DETACHED_PROCESS
        )
    else:
        kwargs["start_new_session"] = True

    subprocess.Popen(command, **kwargs)
    return 0


def update_yt_dlp(yt_dlp: str | None) -> None:
    """Update yt-dlp when a concrete executable is available."""
    if not yt_dlp:
        return

    subprocess.call([yt_dlp, "-U"], env=yt_dlp_process_env())


def repair_config_folders(install_dir: Path) -> None:
    """Create local mpv folders expected by the portable config."""
    print_step("Repairing local folders")
    for relative in (
        "cache",
        "cache/watch_later",
        "cache/shaders_cache",
        "subtitles",
        "script-opts",
        "scripts",
    ):
        path = install_dir / relative
        if not path.exists():
            path.mkdir(parents=True, exist_ok=True)
            print_ok(f"created {relative}")


def show_tool_status() -> None:
    """Print helper tool availability."""
    print_step("Checking helper tools")
    ffmpeg = find_first_executable(["ffmpeg"])
    runtime = find_first_executable(["deno", "node", "bun", "qjs", "quickjs"])

    if ffmpeg:
        print_ok(f"ffmpeg found: {ffmpeg}")
    else:
        print_warn("external ffmpeg not found; mpv still uses bundled FFmpeg")

    if runtime:
        print_ok(f"JavaScript runtime for yt-dlp found: {runtime}")
    else:
        print_warn("no JS runtime found; YouTube extraction can miss formats")


def install_or_update_yt_dlp(install_dir: Path) -> None:
    """Install yt-dlp if needed, then run its built-in updater."""
    print_step("Updating yt-dlp")
    exe = install_dir / ("yt-dlp.exe" if is_windows() else "yt-dlp")

    if not exe.exists():
        release = github_latest_release("yt-dlp/yt-dlp")
        asset_name = "yt-dlp.exe" if is_windows() else "yt-dlp"
        asset = find_release_asset(release, asset_name)
        if not asset:
            raise RuntimeError(f"{asset_name} asset was not found")
        download_file(asset_download_url(asset), exe)
        if not is_windows():
            exe.chmod(0o755)
        print_ok(f"installed {asset_name}")

    run_process([exe, "-U"], check=True)
    version = run_process([exe, "--version"], check=True, capture=True)
    print_ok(f"yt-dlp {(version.stdout or '').strip()}")


def is_mpv_running() -> bool:
    """Return True when an mpv process is currently running."""
    if is_windows():
        result = run_process(
            ["tasklist", "/FI", "IMAGENAME eq mpv.exe", "/NH"],
            capture=True,
        )
        return "mpv.exe" in (result.stdout or "").lower()

    result = run_process(["pgrep", "-x", "mpv"], capture=True)
    return result.returncode == 0


def stop_mpv_for_update(force_close: bool) -> bool:
    """Stop mpv when requested before replacing mpv binaries."""
    if not is_mpv_running():
        return True

    if not force_close:
        print_warn("mpv is running. Close it or use --force-close-mpv.")
        return False

    if is_windows():
        run_process(["taskkill", "/IM", "mpv.exe", "/F"], capture=True)
    else:
        run_process(["pkill", "-x", "mpv"], capture=True)

    time.sleep(1)
    return not is_mpv_running()


def mpv_console_candidates(root: Path, install_dir: Path) -> list[Path | str]:
    """Return mpv executable candidates in preferred order."""
    if is_windows():
        names = ("mpv.com", "mpv.exe")
    else:
        names = ("mpv",)

    candidates: list[Path | str] = []
    for base in (install_dir, root):
        candidates.extend(base / name for name in names)
    candidates.extend(names)
    return candidates


def find_mpv_console(root: Path, install_dir: Path) -> str | None:
    """Find an mpv executable suitable for console checks."""
    for candidate in mpv_console_candidates(root, install_dir):
        if isinstance(candidate, Path) and candidate.exists():
            return str(candidate)
        if isinstance(candidate, str):
            resolved = shutil.which(candidate)
            if resolved:
                return resolved
    return None


def ensure_7zr(install_dir: Path) -> Path:
    """Ensure the standalone 7zr extractor exists."""
    exe = install_dir / "7z" / "7zr.exe"
    if not exe.exists():
        print_step("Installing 7zr extractor")
        download_file("https://www.7-zip.org/a/7zr.exe", exe)
    return exe


def extract_archive(archive: Path, destination: Path, install_dir: Path) -> None:
    """Extract zip or 7z archives."""
    destination.mkdir(parents=True, exist_ok=True)
    if archive.suffix.lower() == ".zip":
        with zipfile.ZipFile(archive) as zip_file:
            zip_file.extractall(destination)
        return

    seven_zip = ensure_7zr(install_dir)
    run_process([seven_zip, "x", "-y", f"-o{destination}", archive], check=True)


def latest_mpv_download_url() -> tuple[str, str]:
    """Return the latest Windows mpv archive URL and filename."""
    rss_text = read_url_text(
        "https://sourceforge.net/projects/mpv-player-windows/rss?path=/64bit"
    )
    rss = ElementTree.fromstring(rss_text)
    item = rss.find("./channel/item")
    if item is None:
        raise RuntimeError("Could not read mpv release feed")

    link = item.findtext("link", default="").strip()
    if not link:
        raise RuntimeError("Latest mpv release link was empty")

    parts = [part for part in link.split("/") if part]
    filename = parts[-2] if parts and parts[-1] == "download" else parts[-1]
    return f"https://download.sourceforge.net/mpv-player-windows/{filename}", filename


def update_mpv(root: Path, install_dir: Path, force_close: bool) -> None:
    """Download and extract the latest Windows mpv build."""
    if not is_windows():
        print_warn("automatic mpv binary update is only implemented on Windows")
        return

    print_step("Updating mpv")
    if not stop_mpv_for_update(force_close):
        return

    download_url, filename = latest_mpv_download_url()
    archive = install_dir / filename
    download_file(download_url, archive)
    try:
        extract_archive(archive, install_dir, install_dir)
    finally:
        archive.unlink(missing_ok=True)

    mpv = find_mpv_console(root, install_dir)
    if mpv:
        version = run_process([mpv, "--version"], capture=True)
        first_line = (version.stdout or version.stderr or "").splitlines()[0]
        print_ok(first_line)
    else:
        print_warn("mpv binary was not found after extraction")


def raw_github_file_url(repo: str, path: str) -> str:
    """Return a raw GitHub URL for the first branch containing a path."""
    for branch in ("master", "main"):
        url = f"https://raw.githubusercontent.com/{repo}/{branch}/{path}"
        try:
            with urllib.request.urlopen(request_url(url, "HEAD"), timeout=30):
                return url
        except urllib.error.URLError:
            continue
    raise RuntimeError(f"Could not locate {path} in {repo}")


def backup_file(install_dir: Path, path: Path) -> None:
    """Back up a file under cache/update-backups before replacing it."""
    if not path.exists():
        return

    try:
        relative = path.resolve().relative_to(install_dir.resolve())
    except ValueError:
        relative = Path(path.name)

    stamp = time.strftime("%Y%m%d-%H%M%S")
    backup_path = install_dir / "cache" / "update-backups" / stamp / relative
    backup_path.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(path, backup_path)


def update_script_file(
    install_dir: Path,
    repo: str,
    remote_path: str,
    local_path: str,
) -> Path:
    """Download one Lua/Python script from GitHub."""
    destination = install_dir / Path(local_path)
    url = raw_github_file_url(repo, remote_path)
    backup_file(install_dir, destination)
    download_file(url, destination)
    print_ok(local_path)
    return destination


def patch_thumbfast_portable_path(path: Path) -> None:
    """Patch thumbfast so it can find the portable mpv binary."""
    content = path.read_text(encoding="utf-8")
    needle = 'mp.options.read_options(options, "thumbfast")'
    if "Portable mpv path detection" in content:
        return
    if needle not in content:
        print_warn("thumbfast portable path patch anchor was not found")
        return

    patch = r'''

-- Portable mpv path detection.
if options.mpv_path == "mpv" then
    for _, candidate in ipairs({"~~/mpv.exe", "~~/mpv.com", "~~/../mpv.exe", "~~/../mpv.com"}) do
        local path = mp.command_native({"expand-path", candidate})
        local info = mp.utils.file_info(path)
        if info and info.is_file then
            options.mpv_path = path:gsub("\\", "/")
            break
        end
    end
end
'''
    path.write_text(content.replace(needle, needle + patch), encoding="utf-8")
    print_ok("patched thumbfast portable mpv path")


def update_lua_scripts(install_dir: Path) -> None:
    """Update selected mpv Lua scripts."""
    print_step("Updating selected Lua scripts")
    thumbfast = update_script_file(
        install_dir,
        "po5/thumbfast",
        "thumbfast.lua",
        "scripts/thumbfast.lua",
    )
    patch_thumbfast_portable_path(thumbfast)

    for repo, remote_path, local_path in SCRIPT_UPDATES:
        update_script_file(install_dir, repo, remote_path, local_path)

    update_sponsorblock_if_present(install_dir)


def find_uosc_source(work_dir: Path) -> Path:
    """Find scripts/uosc inside an extracted uosc archive."""
    for path in work_dir.rglob("uosc"):
        if path.is_dir() and path.parent.name == "scripts":
            return path
    raise RuntimeError("uosc archive did not contain scripts/uosc")


def update_uosc(install_dir: Path) -> None:
    """Update uosc while preserving local script options."""
    print_step("Updating uosc without touching settings")
    release = github_latest_release("tomasklaen/uosc")
    asset = find_release_asset(release, lambda name: name.endswith(".zip"))
    if not asset:
        raise RuntimeError("Could not find uosc zip asset in latest release")

    with tempfile.TemporaryDirectory(prefix="mpv-uosc-") as temp_dir:
        work_dir = Path(temp_dir)
        archive = work_dir / "uosc.zip"
        download_file(asset_download_url(asset), archive)
        extract_archive(archive, work_dir, install_dir)

        source_uosc = find_uosc_source(work_dir)
        destination = install_dir / "scripts" / "uosc"
        if destination.exists():
            stamp = time.strftime("%Y%m%d-%H%M%S")
            backup = install_dir / "cache" / "update-backups" / stamp / "scripts"
            backup.mkdir(parents=True, exist_ok=True)
            shutil.copytree(destination, backup / "uosc", dirs_exist_ok=True)

        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(source_uosc, destination, dirs_exist_ok=True)

        fonts_dir = install_dir / "fonts"
        fonts_dir.mkdir(parents=True, exist_ok=True)
        for font in ("uosc_icons.otf", "uosc_textures.ttf"):
            source_font = next(work_dir.rglob(font), None)
            if source_font:
                shutil.copy2(source_font, fonts_dir / font)

    print_ok("uosc updated; script-opts/uosc.conf was preserved")


def patch_sponsorblock_lua(path: Path) -> None:
    """Apply local SponsorBlock Lua compatibility patches."""
    content = path.read_text(encoding="utf-8")
    replacements = {
        'mp.add_key_binding("g", "set_segment", set_segment)':
            'mp.add_key_binding(nil, "set_segment", set_segment)',
        'mp.add_key_binding("G", "submit_segment", submit_segment)':
            'mp.add_key_binding(nil, "submit_segment", submit_segment)',
        'mp.add_key_binding("h", "upvote_segment", function() return vote("1") end)':
            'mp.add_key_binding(nil, "upvote_segment", function() return vote("1") end)',
        'mp.add_key_binding("H", "downvote_segment", function() return vote("0") end)':
            'mp.add_key_binding(nil, "downvote_segment", function() return vote("0") end)',
        "local speed_timer = nil\nlocal fade_timer = nil":
            "---@type any\nlocal speed_timer = nil\n---@type any\nlocal fade_timer = nil",
        "        speed_timer:kill()":
            "        if speed_timer ~= nil then speed_timer:kill() end",
        'youtube_id = youtube_id or string.match(video_path, options.local_pattern)':
            'youtube_id = youtube_id or string.match(video_path, options["local_pattern"])',
        "if not youtube_id or string.len(youtube_id) < 11 or "
        "(local_pattern and string.len(youtube_id) ~= 11) then return end":
            "if not youtube_id or string.len(youtube_id) < 11 or "
            '(options["local_pattern"] ~= "" and string.len(youtube_id) ~= 11) then return end',
        'local cur_time = os.time(os.date("*t"))':
            "local cur_time = os.time()",
    }
    for old, new in replacements.items():
        content = content.replace(old, new)
    path.write_text(content, encoding="utf-8")
    print_ok("patched SponsorBlock compatibility fixes")


def patch_sponsorblock_python(path: Path) -> None:
    """Apply local SponsorBlock Python compatibility patches."""
    content = path.read_text(encoding="utf-8")
    if "import urllib.request" not in content:
        content = content.replace(
            "import urllib.parse\n",
            "import urllib.parse\nimport urllib.request\n",
        )
    replacements = {
        "except (TimeoutError, urllib.error.URLError) as e:":
            "except (TimeoutError, urllib.error.URLError):",
        "    except:":
            "    except Exception:",
    }
    for old, new in replacements.items():
        content = content.replace(old, new)
    path.write_text(content, encoding="utf-8")
    print_ok("patched SponsorBlock Python compatibility fixes")


def update_sponsorblock_if_present(install_dir: Path) -> None:
    """Update SponsorBlock files only when the script is installed."""
    script_path = install_dir / "scripts" / "sponsorblock.lua"
    shared_path = install_dir / "scripts" / "sponsorblock_shared"
    if not script_path.exists() and not shared_path.exists():
        print_warn("SponsorBlock is not installed; skipping optional update")
        return

    print_step("Updating installed SponsorBlock script")
    script = update_script_file(
        install_dir,
        "po5/mpv_sponsorblock",
        "sponsorblock.lua",
        "scripts/sponsorblock.lua",
    )
    update_script_file(
        install_dir,
        "po5/mpv_sponsorblock",
        "sponsorblock_shared/main.lua",
        "scripts/sponsorblock_shared/main.lua",
    )
    python_script = update_script_file(
        install_dir,
        "po5/mpv_sponsorblock",
        "sponsorblock_shared/sponsorblock.py",
        "scripts/sponsorblock_shared/sponsorblock.py",
    )
    patch_sponsorblock_lua(script)
    patch_sponsorblock_python(python_script)


def test_mpv_config(root: Path, install_dir: Path) -> None:
    """Run a light mpv config check."""
    print_step("Checking mpv config")
    mpv = find_mpv_console(root, install_dir)
    if not mpv:
        print_warn("mpv binary was not found; config parse check skipped")
        return

    result = run_process([mpv, "--version"], capture=True)
    output = f"{result.stdout or ''}{result.stderr or ''}"
    for line in output.splitlines():
        if (
            "Error parsing option" in line
            or "setting option" in line and "failed" in line
            or "Error loading script" in line
        ):
            print_warn(line)
            raise RuntimeError("mpv reported config errors")

    first_line = output.splitlines()[0] if output.splitlines() else mpv
    print_ok(first_line)


def run_update(root: Path, args: argparse.Namespace) -> int:
    """Run the consolidated updater."""
    install_dir = default_config_dir(root)
    print(f"Target: {install_dir}")
    repair_config_folders(install_dir)
    show_tool_status()
    install_or_update_yt_dlp(install_dir)

    if not args.yt_dlp_only:
        if not args.skip_mpv:
            update_mpv(root, install_dir, args.force_close_mpv)
        if not args.skip_scripts:
            update_uosc(install_dir)
            update_lua_scripts(install_dir)

    test_mpv_config(root, install_dir)
    print("\nAll requested updates completed.")
    return 0


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    """Parse command-line arguments."""
    parser = argparse.ArgumentParser(
        description="Launch mpv with a persistent YouTube queue."
    )
    parser.add_argument(
        "--height",
        type=int,
        choices=HEIGHTS,
        default=2160,
        help="Maximum YouTube video height.",
    )
    parser.add_argument(
        "--cookies-from-browser",
        default="",
        help="Pass yt-dlp cookies-from-browser, for example firefox.",
    )
    parser.add_argument(
        "--cookies",
        default="",
        help=(
            "Pass a Netscape cookies.txt file to yt-dlp. If omitted, the "
            "launcher auto-detects common cookie export paths."
        ),
    )
    parser.add_argument(
        "--no-cookies",
        action="store_true",
        help="Disable automatic cookies.txt detection.",
    )
    parser.add_argument(
        "--playlist-limit",
        type=int,
        default=0,
        help="Maximum YouTube playlist/radio items to add; 0 means all available.",
    )
    parser.add_argument(
        "--save-playlist",
        metavar="NAME",
        default="",
        help="Save a YouTube playlist/radio URL as PlayList/NAME.m3u and exit.",
    )
    parser.add_argument(
        "--playlist-dir",
        default=None,
        help="Directory for --save-playlist output. Defaults to ./PlayList.",
    )
    parser.add_argument(
        "--clear-youtube-queue",
        action="store_true",
        help="Clear the saved YouTube queue and queued YouTube items in mpv.",
    )
    parser.add_argument(
        "--update",
        action="store_true",
        help="Update yt-dlp, mpv, and selected bundled scripts, then exit.",
    )
    parser.add_argument(
        "--yt-dlp-only",
        action="store_true",
        help="With --update, update only yt-dlp.",
    )
    parser.add_argument(
        "--skip-mpv",
        action="store_true",
        help="With --update, skip the mpv binary update.",
    )
    parser.add_argument(
        "--skip-scripts",
        action="store_true",
        help="With --update, skip bundled Lua script updates.",
    )
    parser.add_argument(
        "--force-close-mpv",
        action="store_true",
        help="With --update, close running mpv processes before updating mpv.",
    )
    parser.add_argument(
        "--no-pause",
        action="store_true",
        help=argparse.SUPPRESS,
    )
    parser.add_argument(
        "--no-update",
        action="store_true",
        help="Skip foreground yt-dlp update checks.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print the mpv command instead of running it.",
    )
    parser.add_argument(
        "--wait",
        action="store_true",
        help="Keep the terminal attached until mpv exits.",
    )
    parser.add_argument(
        "--ipc-name",
        default="mpv-youtube-queue",
        help="Name for the mpv IPC pipe/socket.",
    )
    parser.add_argument(
        "--mpv",
        dest="mpv_path",
        default=None,
        help="Path to a specific mpv executable.",
    )
    namespace, mpv_args = parser.parse_known_args(normalize_cli_args(argv))
    if mpv_args and mpv_args[0] == "--":
        mpv_args = mpv_args[1:]
    namespace.mpv_args = mpv_args
    return namespace


def main(argv: Sequence[str] | None = None) -> int:
    """Run the launcher."""
    args = parse_args(sys.argv[1:] if argv is None else argv)
    root = script_root()
    config_dir = default_config_dir(root)
    yt_dlp = find_yt_dlp(config_dir)
    launch_args = list(args.mpv_args)
    cookies_file = args.cookies

    if cookies_file and not usable_cookie_file(Path(cookies_file).expanduser()):
        print(
            f"Cookies file was not found or is empty: {cookies_file}",
            file=sys.stderr,
        )
        print(
            "Export fresh YouTube cookies in Netscape cookies.txt format and retry.",
            file=sys.stderr,
        )
        return 1

    if not cookies_file and not args.cookies_from_browser and not args.no_cookies:
        cookies_file = find_default_cookies_file(root)

    if args.update:
        try:
            return run_update(root, args)
        except Exception as error:
            print(f"\nUpdate failed: {error}", file=sys.stderr)
            return 1

    if args.clear_youtube_queue or is_clear_queue_request(launch_args):
        return clear_youtube_queue(root, args.ipc_name, args.dry_run)

    if not args.save_playlist:
        inferred_save = infer_playlist_save(launch_args)
        if inferred_save:
            args.save_playlist, launch_args = inferred_save

    youtube_url = first_youtube_url(launch_args)

    if args.save_playlist:
        return save_youtube_playlist(
            name=args.save_playlist,
            playlist_dir=args.playlist_dir,
            launch_args=launch_args,
            root=root,
            yt_dlp=yt_dlp,
            playlist_limit=args.playlist_limit,
            cookies_from_browser=args.cookies_from_browser,
            cookies_file=cookies_file,
            dry_run=args.dry_run,
        )

    endpoint = ipc_endpoint(args.ipc_name)
    mpv_path = find_mpv(root, args.mpv_path)

    if youtube_url and args.wait and not args.no_update:
        update_yt_dlp(yt_dlp)

    if youtube_url and not yt_dlp:
        print(
            "Warning: yt-dlp was not found. Install yt-dlp for YouTube URLs.",
            file=sys.stderr,
        )

    if not args.dry_run:
        launch_args = expand_launch_args(
            launch_args,
            yt_dlp,
            args.playlist_limit,
            args.cookies_from_browser,
            cookies_file,
        )

    if not args.dry_run and not args.wait:
        media_args = [value for value in launch_args if is_media_argument(value)]
        if send_media_to_running_mpv(endpoint, media_args):
            print("Added to the running mpv queue.")
            return 0
        remove_stale_unix_socket(endpoint)

    mpv_args = build_mpv_args(
        config_dir=config_dir,
        endpoint=endpoint,
        yt_dlp=yt_dlp,
        height=args.height,
        cookies_from_browser=args.cookies_from_browser,
        cookies_file=cookies_file,
        launch_args=launch_args,
    )

    if args.dry_run:
        print(mpv_path)
        for item in mpv_args:
            print(item)
        return 0

    return start_mpv(mpv_path, mpv_args, args.wait, yt_dlp_process_env())


if __name__ == "__main__":
    raise SystemExit(main())
