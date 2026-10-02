#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["laya-mlx>=0.2,<0.3"]
# ///
"""Jev-compatible HTTP bridge for laya-mlx.

laya-mlx (https://github.com/mizorewww/laya-mlx) runs the open Laya
typed-decision models natively on Apple silicon, but only as an in-process
Python library: it ships no HTTP server. NightMail talks to every System One
provider over TypeSafe's Jev wire (`POST {base}/v1/systemone`), so this script
puts that wire in front of one loaded Laya checkpoint. Its JSON is passed
through unchanged — laya-mlx already returns Jev's `{model, answers, usage}`
shape — so the app's `SystemOneAdapter` needs no special case.

Run it, then add "Laya-MLX (local System One)" from the AI settings catalog
(it defaults to this script's address):

    python3 tool/laya_mlx_server.py                 # laya-mlx already installed
    uv run tool/laya_mlx_server.py                  # uv installs laya-mlx itself
    python3 tool/laya_mlx_server.py --model aac6fef/laya-multilingual-mlx

Routes (all local, no API key — a Bearer header is accepted and ignored):

    GET  /healthz          {"status": "ok", "model": "<checkpoint>"}
    GET  /v1/models        {"object": "list", "data": [{"id": "<checkpoint>", ...}]}
    POST /v1/systemone     Jev request body → Jev response body
    POST /v1/decide        alias of /v1/systemone

Requirements: Apple silicon, macOS 14+, Python 3.11+. The first start downloads
the checkpoint (~850 MB for `aac6fef/laya-mlx`) into the Hugging Face cache;
later starts are offline.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 8766  # local-jev takes 8765; jevlocal 9011; OpenJev 8080
DEFAULT_MODEL = "aac6fef/laya-mlx"

DECIDE_PATHS = {"/v1/systemone", "/systemone", "/v1/decide", "/decide"}
MODELS_PATHS = {"/v1/models", "/models"}
HEALTH_PATHS = {"/healthz", "/health", "/"}

QUESTION_TYPES = {"noul", "choice", "score"}


class LayaPredictor:
    """One loaded laya-mlx Agent behind a tiny `predict(state, questions)` API."""

    def __init__(self, model: str, *, dtype: str, batch_size: int, device: str | None):
        try:
            import laya_mlx as laya
        except ImportError as exc:  # pragma: no cover - environment dependent
            raise SystemExit(
                "laya-mlx is not installed. Run `pip install laya-mlx` (Apple silicon, "
                "macOS 14+, Python 3.11+) or start this script with `uv run`."
            ) from exc

        started = time.perf_counter()
        self.agent = laya.load(model, dtype=dtype, batch_size=batch_size, device=device)
        self.load_seconds = time.perf_counter() - started
        self.model_id = model

    def predict(self, state, questions):
        return self.agent.predict(state, questions)


def validate_request(body) -> tuple[object, dict]:
    """Check the Jev request shape; raise ValueError with a client-facing message."""
    if not isinstance(body, dict):
        raise ValueError("Request body must be a JSON object")
    if "state" not in body:
        raise ValueError("Request is missing `state`")
    questions = body.get("questions")
    if not isinstance(questions, dict) or not questions:
        raise ValueError("`questions` must be a non-empty object keyed by question id")
    for qid, qdef in questions.items():
        if not isinstance(qdef, dict):
            raise ValueError(f"Question {qid!r} must be an object")
        if qdef.get("type") not in QUESTION_TYPES:
            raise ValueError(
                f"Question {qid!r} has type {qdef.get('type')!r}; expected noul, choice or score"
            )
        if "instructions" not in qdef:
            raise ValueError(f"Question {qid!r} is missing `instructions`")
    return body["state"], questions


def make_handler(predictor, *, verbose: bool):
    class Handler(BaseHTTPRequestHandler):
        server_version = "laya-mlx-bridge/1.0"

        # -- helpers -------------------------------------------------------
        def _send_json(self, status: int, payload) -> None:
            data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def _send_error_json(self, status: int, message: str, kind: str) -> None:
            self._send_json(status, {"error": {"message": message, "type": kind}})

        def log_message(self, fmt, *args):  # noqa: N802 - BaseHTTPRequestHandler API
            if verbose:
                super().log_message(fmt, *args)

        # -- routes --------------------------------------------------------
        def do_GET(self):  # noqa: N802
            path = urlparse(self.path).path.rstrip("/") or "/"
            if path in HEALTH_PATHS:
                self._send_json(HTTPStatus.OK, {"status": "ok", "model": predictor.model_id})
            elif path in MODELS_PATHS:
                self._send_json(
                    HTTPStatus.OK,
                    {
                        "object": "list",
                        "data": [
                            {
                                "id": predictor.model_id,
                                "object": "model",
                                "owned_by": "laya-mlx",
                            }
                        ],
                    },
                )
            else:
                self._send_error_json(HTTPStatus.NOT_FOUND, f"No route for GET {path}", "not_found")

        def do_POST(self):  # noqa: N802
            path = urlparse(self.path).path.rstrip("/")
            if path not in DECIDE_PATHS:
                self._send_error_json(HTTPStatus.NOT_FOUND, f"No route for POST {path}", "not_found")
                return

            length = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(length) if length else b""
            try:
                body = json.loads(raw.decode("utf-8")) if raw else None
            except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                self._send_error_json(HTTPStatus.BAD_REQUEST, f"Invalid JSON: {exc}", "invalid_request")
                return

            try:
                state, questions = validate_request(body)
            except ValueError as exc:
                self._send_error_json(HTTPStatus.BAD_REQUEST, str(exc), "invalid_request")
                return

            # Any `model` is accepted (clients send aliases such as `jev-latest`);
            # the response names the checkpoint that actually answered.
            try:
                result = predictor.predict(state, questions)
            except ValueError as exc:
                # laya-mlx rejects malformed criteria / oversized option sets here.
                self._send_error_json(HTTPStatus.UNPROCESSABLE_ENTITY, str(exc), "invalid_request")
                return
            except Exception as exc:  # noqa: BLE001 - surface anything else as a 500
                self._send_error_json(
                    HTTPStatus.INTERNAL_SERVER_ERROR, f"{type(exc).__name__}: {exc}", "server_error"
                )
                return

            # laya-mlx reports the generic upstream name ("laya-rl-agent"); the
            # checkpoint actually serving is what the client should see.
            result["model"] = predictor.model_id
            self._send_json(HTTPStatus.OK, result)

    return Handler


def make_server(predictor, *, host: str, port: int, verbose: bool = False) -> ThreadingHTTPServer:
    return ThreadingHTTPServer((host, port), make_handler(predictor, verbose=verbose))


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        prog="laya_mlx_server",
        description="Serve a laya-mlx checkpoint over TypeSafe's Jev-compatible API.",
    )
    parser.add_argument("--host", default=DEFAULT_HOST)
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument(
        "--model",
        default=DEFAULT_MODEL,
        help="Hugging Face id or local path (default: %(default)s; "
        "aac6fef/laya-multilingual-mlx for non-English mail)",
    )
    parser.add_argument("--dtype", choices=("float16", "float32", "bfloat16"), default="float16")
    parser.add_argument("--batch-size", type=int, default=16)
    parser.add_argument("--device", choices=("gpu", "cpu"), default=None)
    parser.add_argument("--verbose", action="store_true", help="log every request")
    args = parser.parse_args(argv)

    print(f"Loading {args.model} ({args.dtype})…", flush=True)
    predictor = LayaPredictor(
        args.model, dtype=args.dtype, batch_size=args.batch_size, device=args.device
    )
    print(f"Loaded in {predictor.load_seconds:.1f}s", flush=True)

    server = make_server(predictor, host=args.host, port=args.port, verbose=args.verbose)
    base = f"http://{args.host}:{args.port}/v1"
    print(f"Serving Jev-compatible API at {base}/systemone  (models: {base}/models)", flush=True)
    print("In NightMail: Settings › AI › Add provider › From catalog › Laya-MLX", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopping.", flush=True)
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
