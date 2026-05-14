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
from pathlib import Path
from typing import Iterable, Sequence
from urllib.parse import parse_qs, urlparse


HEIGHTS = (720, 1080, 1440, 2160, 4320)
YOUTUBE_HOST_MARKERS = (
    "youtube.com/",
    "youtu.be/",
    "music.youtube.com/",
)


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


def format_for_height(height: int) -> str:
    """Return the yt-dlp format selector for a maximum video height."""
    return f"bv*[height<={height}]+ba/b[height<={height}]/bv*+ba/b"


def ytdl_raw_options(cookies_from_browser: str) -> list[str]:
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

    return raw_options


def playlist_end_args(limit: int) -> list[str]:
    """Return yt-dlp arguments for an optional playlist item limit."""
    if limit <= 0:
        return []

    return ["--playlist-end", str(limit)]


def expand_youtube_playlist(
    url: str,
    yt_dlp: str | None,
    playlist_limit: int,
) -> list[str]:
    """Return individual video URLs for a YouTube playlist/radio URL."""
    if not yt_dlp or not is_youtube_playlist_url(url):
        return [url]

    command = [
        yt_dlp,
        "--flat-playlist",
        "--yes-playlist",
        "--ignore-errors",
        "--no-warnings",
        "--print",
        "%(webpage_url)s",
        *playlist_end_args(playlist_limit),
        url,
    ]

    try:
        result = subprocess.run(
            command,
            check=False,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
    except OSError as error:
        print(f"Warning: could not expand playlist URL: {error}", file=sys.stderr)
        return [url]

    if result.returncode != 0:
        detail = (result.stderr or "").strip()
        if detail:
            print(f"Warning: could not expand playlist URL: {detail}", file=sys.stderr)
        return [url]

    entries: list[str] = []
    seen: set[str] = set()
    for line in result.stdout.splitlines():
        entry = line.strip()
        if is_youtube_url(entry) and entry not in seen:
            entries.append(entry)
            seen.add(entry)

    return entries or [url]


def expand_media_items(
    media: Sequence[str],
    yt_dlp: str | None,
    playlist_limit: int,
) -> list[str]:
    """Expand playlist/radio media arguments into playable video URLs."""
    expanded: list[str] = []
    for item in media:
        if is_youtube_playlist_url(item):
            expanded.extend(expand_youtube_playlist(item, yt_dlp, playlist_limit))
        else:
            expanded.append(item)

    return expanded


def expand_launch_args(
    launch_args: Sequence[str],
    yt_dlp: str | None,
    playlist_limit: int,
) -> list[str]:
    """Expand media URLs while preserving non-media mpv arguments in place."""
    expanded: list[str] = []
    for item in launch_args:
        if is_media_argument(item):
            expanded.extend(expand_media_items([item], yt_dlp, playlist_limit))
        else:
            expanded.append(item)

    return expanded


def build_mpv_args(
    config_dir: Path,
    endpoint: str,
    yt_dlp: str | None,
    height: int,
    cookies_from_browser: str,
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

    args.extend(ytdl_raw_options(cookies_from_browser))
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
) -> int:
    """Start mpv either attached for debugging or detached for daily use."""
    command = [mpv_path, *mpv_args]

    if wait:
        return subprocess.call(command)

    kwargs: dict[str, object] = {
        "stdin": subprocess.DEVNULL,
        "stdout": subprocess.DEVNULL,
        "stderr": subprocess.DEVNULL,
        "close_fds": True,
    }

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

    subprocess.call([yt_dlp, "-U"])


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
        "--playlist-limit",
        type=int,
        default=0,
        help="Maximum YouTube playlist/radio items to add; 0 means all available.",
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
    namespace, mpv_args = parser.parse_known_args(argv)
    if mpv_args and mpv_args[0] == "--":
        mpv_args = mpv_args[1:]
    namespace.mpv_args = mpv_args
    return namespace


def main(argv: Sequence[str] | None = None) -> int:
    """Run the launcher."""
    args = parse_args(sys.argv[1:] if argv is None else argv)
    root = script_root()
    config_dir = default_config_dir(root)
    endpoint = ipc_endpoint(args.ipc_name)
    mpv_path = find_mpv(root, args.mpv_path)
    yt_dlp = find_yt_dlp(config_dir)
    launch_args = list(args.mpv_args)
    youtube_url = first_youtube_url(launch_args)

    if youtube_url and args.wait and not args.no_update:
        update_yt_dlp(yt_dlp)

    if youtube_url and not yt_dlp:
        print(
            "Warning: yt-dlp was not found. Install yt-dlp for YouTube URLs.",
            file=sys.stderr,
        )

    if not args.dry_run:
        launch_args = expand_launch_args(launch_args, yt_dlp, args.playlist_limit)

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
        launch_args=launch_args,
    )

    if args.dry_run:
        print(mpv_path)
        for item in mpv_args:
            print(item)
        return 0

    return start_mpv(mpv_path, mpv_args, args.wait)


if __name__ == "__main__":
    raise SystemExit(main())
