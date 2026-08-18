#!/usr/bin/env python3
"""Transcribe a 16 kHz WAV from OpenPendant.

Backends (first match wins unless --backend is set):
  openai  — OpenAI Audio API (OPENAI_API_KEY); verbose_json segments
  mlx     — mlx-whisper on Apple Silicon
  local   — openai-whisper package

    export OPENAI_API_KEY=sk-...
    python3 tools/transcribe.py capture.wav --backend openai
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

MLX_MODELS = {
    "tiny.en": "mlx-community/whisper-tiny.en-mlx",
    "base.en": "mlx-community/whisper-base.en-mlx",
    "small.en": "mlx-community/whisper-small.en-mlx",
}

OPENAI_MODELS = ("gpt-4o-mini-transcribe", "whisper-1")


def _write_outputs(out: Path, text: str, payload: dict) -> None:
    out.write_text(text + "\n", encoding="utf-8")
    json_path = out.with_suffix(".json")
    json_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    print(text)
    print(f"Wrote {out}")
    print(f"Wrote {json_path}")


def transcribe_openai(wav_path: str, model: str, started_at: datetime) -> dict:
    try:
        import httpx
    except ImportError:
        raise SystemExit("openai backend needs httpx: python3 -m pip install httpx")

    key = os.environ.get("OPENAI_API_KEY", "").strip()
    if not key:
        raise SystemExit("Set OPENAI_API_KEY for --backend openai")

    models = (model,) if model in OPENAI_MODELS or model.startswith("gpt-") else OPENAI_MODELS
    if model not in OPENAI_MODELS and not model.startswith("gpt-"):
        models = OPENAI_MODELS

    last_err = None
    for m in models:
        with open(wav_path, "rb") as fh:
            files = {"file": (Path(wav_path).name, fh, "audio/wav")}
            data = {
                "model": m,
                "language": "en",
                "response_format": "verbose_json",
            }
            if m == "whisper-1":
                data["timestamp_granularities[]"] = "segment"
            try:
                r = httpx.post(
                    "https://api.openai.com/v1/audio/transcriptions",
                    headers={"Authorization": f"Bearer {key}"},
                    data=data,
                    files=files,
                    timeout=120.0,
                )
            except httpx.HTTPError as e:
                last_err = e
                continue
        if r.status_code == 400 and m != "whisper-1":
            last_err = r.text
            continue
        if r.status_code >= 400:
            last_err = r.text
            continue
        body = r.json()
        text = (body.get("text") or "").strip()
        segs = []
        for s in body.get("segments") or []:
            start_s = float(s.get("start") or 0)
            end_s = float(s.get("end") or start_s)
            spoken = started_at + timedelta(seconds=start_s)
            segs.append(
                {
                    "start_s": start_s,
                    "end_s": end_s,
                    "spoken_at": spoken.isoformat(),
                    "text": (s.get("text") or "").strip(),
                }
            )
        if not segs and text:
            segs.append(
                {
                    "start_s": 0.0,
                    "end_s": float(body.get("duration") or 0),
                    "spoken_at": started_at.isoformat(),
                    "text": text,
                }
            )
        print(f"Using OpenAI Audio API ({m})...")
        return {"text": text, "stt_model": m, "segments": segs, "raw": body}

    raise SystemExit(f"OpenAI transcription failed: {last_err}")


def transcribe_local(wav_path: str, model: str) -> str:
    decode = {
        "language": "en",
        "temperature": 0.0,
        "condition_on_previous_text": False,
        "hallucination_silence_threshold": 0.5,
    }

    try:
        import mlx_whisper

        repo = MLX_MODELS.get(model, model)
        print(f"Using mlx-whisper ({model})...")
        result = mlx_whisper.transcribe(
            wav_path,
            path_or_hf_repo=repo,
            **decode,
        )
        return (result.get("text") or "").strip()
    except ImportError:
        pass

    try:
        import whisper

        print(f"Using openai-whisper ({model})...")
        loaded = whisper.load_model(model)
        result = loaded.transcribe(wav_path, **decode)
        return (result.get("text") or "").strip()
    except ImportError:
        print(
            "No local Whisper install found.\n"
            "  API:            export OPENAI_API_KEY=... && "
            "python3 tools/transcribe.py wav --backend openai\n"
            "  Apple Silicon:  python3 -m pip install mlx-whisper\n"
            "  Otherwise:      python3 -m pip install openai-whisper",
            file=sys.stderr,
        )
        raise SystemExit(1)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("wav", help="WAV from tools/capture_pcm.py")
    parser.add_argument(
        "-o",
        "--out",
        help="Transcript path (default: same name with .txt)",
    )
    parser.add_argument(
        "--backend",
        choices=("auto", "openai", "local"),
        default="auto",
        help="auto: openai if OPENAI_API_KEY is set, else local",
    )
    parser.add_argument(
        "--model",
        default="small.en",
        help="Local: tiny.en/base.en/small.en. OpenAI: gpt-4o-mini-transcribe or whisper-1",
    )
    parser.add_argument(
        "--started-at",
        help="ISO UTC start of the recording (default: now). Used for spoken_at.",
    )
    args = parser.parse_args()

    wav = Path(args.wav)
    if not wav.is_file():
        raise SystemExit(f"Not a file: {wav}")

    started = (
        datetime.fromisoformat(args.started_at.replace("Z", "+00:00"))
        if args.started_at
        else datetime.now(timezone.utc)
    )
    if started.tzinfo is None:
        started = started.replace(tzinfo=timezone.utc)

    backend = args.backend
    if backend == "auto":
        backend = "openai" if os.environ.get("OPENAI_API_KEY", "").strip() else "local"

    out = Path(args.out) if args.out else wav.with_suffix(".txt")

    if backend == "openai":
        model = args.model if args.model in OPENAI_MODELS or args.model.startswith("gpt-") else "gpt-4o-mini-transcribe"
        payload = transcribe_openai(str(wav), model, started)
        payload.pop("raw", None)
        payload["started_at"] = started.isoformat()
        _write_outputs(out, payload["text"], payload)
        return

    text = transcribe_local(str(wav), args.model)
    _write_outputs(
        out,
        text,
        {
            "text": text,
            "stt_model": args.model,
            "started_at": started.isoformat(),
            "segments": [
                {
                    "start_s": 0.0,
                    "end_s": 0.0,
                    "spoken_at": started.isoformat(),
                    "text": text,
                }
            ],
        },
    )


if __name__ == "__main__":
    main()
