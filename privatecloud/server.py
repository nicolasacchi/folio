#!/usr/bin/env python3
"""Small self-hosted Kindle library server.

This intentionally avoids dependencies. It exposes a private manifest and
serves files from a local books directory.
"""

from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import mimetypes
import os
import sys
import threading
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import quote, unquote


SUPPORTED_EXTENSIONS = {
    ".azw",
    ".azw3",
    ".kfx",
    ".mobi",
    ".pdf",
    ".txt",
}


def guess_title_author(path: Path) -> tuple[str, str]:
    stem = path.stem.strip()
    for separator in (" -- ", " - "):
        if separator in stem:
            title, author = stem.split(separator, 1)
            return title.strip() or stem, author.strip()
    return stem, ""


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def make_id(relative_path: str) -> str:
    return hashlib.sha1(relative_path.encode("utf-8")).hexdigest()[:20]


def tsv_field(value: object) -> str:
    return str(value).replace("\t", " ").replace("\r", " ").replace("\n", " ")


def manifest_json_payload(items: list[dict[str, object]]) -> bytes:
    payload = {
        "version": 1,
        "items": items,
    }
    return json.dumps(payload, ensure_ascii=False, indent=2).encode("utf-8")


def manifest_tsv_payload(items: list[dict[str, object]]) -> bytes:
    lines = ["id\ttitle\tauthor\tsize\tsha256\tmime\turl\tfilename"]
    for item in items:
        lines.append(
            "\t".join(
                tsv_field(item[key])
                for key in (
                    "id",
                    "title",
                    "author",
                    "size",
                    "sha256",
                    "mime",
                    "url",
                    "filename",
                )
            )
        )
    return ("\n".join(lines) + "\n").encode("utf-8")


class Library:
    def __init__(self, root: Path) -> None:
        self.root = root.resolve()
        self._lock = threading.Lock()
        self._fingerprint: list[tuple[str, int, int]] | None = None
        self._items: list[dict[str, object]] = []
        self._json_body = b""
        self._tsv_body = b""

    def fingerprint(self) -> list[tuple[str, int, int]]:
        entries: list[tuple[str, int, int]] = []
        for path in sorted(self.root.rglob("*")):
            if not path.is_file() or path.suffix.lower() not in SUPPORTED_EXTENSIONS:
                continue
            stat = path.stat()
            entries.append((path.relative_to(self.root).as_posix(), stat.st_mtime_ns, stat.st_size))
        return entries

    def build_items(self) -> list[dict[str, object]]:
        entries: list[dict[str, object]] = []
        for path in sorted(self.root.rglob("*")):
            if not path.is_file() or path.suffix.lower() not in SUPPORTED_EXTENSIONS:
                continue
            relative = path.relative_to(self.root).as_posix()
            title, author = guess_title_author(path)
            mime = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
            entries.append(
                {
                    "id": make_id(relative),
                    "title": title,
                    "author": author,
                    "filename": path.name,
                    "relative_path": relative,
                    "size": path.stat().st_size,
                    "sha256": file_sha256(path),
                    "mime": mime,
                    "url": "/books/" + quote(relative, safe="/"),
                }
            )
        return entries

    def _refresh_locked(self) -> None:
        fingerprint = self.fingerprint()
        if fingerprint == self._fingerprint:
            return
        self._items = self.build_items()
        self._json_body = manifest_json_payload(self._items)
        self._tsv_body = manifest_tsv_payload(self._items)
        self._fingerprint = fingerprint
        print("Rebuilt library manifest: %d item(s) hashed" % len(self._items))

    def items(self) -> list[dict[str, object]]:
        with self._lock:
            self._refresh_locked()
            return self._items

    def manifest_json(self) -> bytes:
        with self._lock:
            self._refresh_locked()
            return self._json_body

    def manifest_tsv(self) -> bytes:
        with self._lock:
            self._refresh_locked()
            return self._tsv_body

    def resolve_book(self, raw_relative_path: str) -> Path | None:
        relative_path = unquote(raw_relative_path)
        candidate = (self.root / relative_path).resolve()
        try:
            candidate.relative_to(self.root)
        except ValueError:
            return None
        if not candidate.is_file() or candidate.suffix.lower() not in SUPPORTED_EXTENSIONS:
            return None
        return candidate


class Handler(BaseHTTPRequestHandler):
    server: "Server"

    def log_message(self, fmt: str, *args: object) -> None:
        print("%s - %s" % (self.address_string(), fmt % args))

    def send_bytes(self, status: HTTPStatus, body: bytes, content_type: str) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def require_auth(self) -> bool:
        token = self.server.token
        if token is None:
            return True
        header = self.headers.get("Authorization", "")
        expected = "Bearer " + token
        if hmac.compare_digest(header.encode("utf-8"), expected.encode("utf-8")):
            return True
        self.send_response(HTTPStatus.UNAUTHORIZED)
        self.send_header("WWW-Authenticate", "Bearer")
        self.send_header("Content-Length", "0")
        self.end_headers()
        return False

    def do_GET(self) -> None:
        if self.path == "/healthz":
            self.send_bytes(HTTPStatus.OK, b"ok\n", "text/plain; charset=utf-8")
            return

        if not self.require_auth():
            return

        if self.path == "/manifest.json":
            body = self.server.library.manifest_json()
            self.send_bytes(HTTPStatus.OK, body, "application/json; charset=utf-8")
            return

        if self.path == "/manifest.tsv":
            body = self.server.library.manifest_tsv()
            self.send_bytes(HTTPStatus.OK, body, "text/tab-separated-values; charset=utf-8")
            return

        if self.path.startswith("/books/"):
            book = self.server.library.resolve_book(self.path.removeprefix("/books/"))
            if book is None:
                self.send_error(HTTPStatus.NOT_FOUND)
                return
            mime = mimetypes.guess_type(book.name)[0] or "application/octet-stream"
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", mime)
            self.send_header("Content-Length", str(book.stat().st_size))
            self.send_header("Content-Disposition", "attachment; filename=%s" % quote(book.name))
            self.end_headers()
            with book.open("rb") as handle:
                for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                    self.wfile.write(chunk)
            return

        self.send_error(HTTPStatus.NOT_FOUND)


class Server(ThreadingHTTPServer):
    def __init__(self, address: tuple[str, int], library: Library, token: str | None) -> None:
        super().__init__(address, Handler)
        self.library = library
        self.token = token


def load_token(args: argparse.Namespace, root: Path) -> str | None:
    token = args.token or os.environ.get("PRIVATECLOUD_TOKEN")
    token_file = Path(args.token_file) if args.token_file else root / ".privatecloud-token"
    if not token and token_file.is_file():
        token = token_file.read_text(encoding="utf-8").strip()
    if token:
        return token
    if args.no_auth:
        print(
            "WARNING: --no-auth is set; anyone who can reach this server can "
            "list and download your whole library.",
            file=sys.stderr,
        )
        return None
    print(
        "No auth token configured. Pass --token, set PRIVATECLOUD_TOKEN, or "
        "write a token to %s (or use --no-auth to disable auth)." % token_file,
        file=sys.stderr,
    )
    raise SystemExit(2)


def main() -> None:
    parser = argparse.ArgumentParser(description="Serve a private Kindle library manifest.")
    parser.add_argument("--books", default="books", help="Directory containing book files")
    parser.add_argument("--host", default="127.0.0.1", help="Bind host")
    parser.add_argument("--port", default=8765, type=int, help="Bind port")
    parser.add_argument("--token", help="Bearer token required on all endpoints")
    parser.add_argument(
        "--token-file",
        help="File containing the bearer token (default: <books>/.privatecloud-token if present)",
    )
    parser.add_argument(
        "--no-auth",
        action="store_true",
        help="Disable token auth (INSECURE, development only)",
    )
    args = parser.parse_args()

    root = Path(args.books)
    root.mkdir(parents=True, exist_ok=True)
    token = load_token(args, root)
    server = Server((args.host, args.port), Library(root), token)
    print("Serving %s on http://%s:%s" % (root.resolve(), args.host, args.port))
    server.serve_forever()


if __name__ == "__main__":
    main()
