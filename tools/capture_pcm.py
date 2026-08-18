#!/usr/bin/env python3
"""Capture PCM from the OpenPendant GATT notify characteristic and write a WAV.

Disconnect nRF Connect first (the board allows only one BLE connection).
"""

from __future__ import annotations

import argparse
import asyncio
import struct
import wave

from bleak import BleakClient, BleakScanner

SVC_UUID = "70301101-4a1b-4c8d-9e0f-a1b2c3d4e5f6"
PCM_CHAR_UUID = "70301102-4a1b-4c8d-9e0f-a1b2c3d4e5f6"
DEVICE_NAMES = ("OpenPendant", "AI Pendant")
SAMPLE_RATE = 16000
CHUNK_BYTES = 1024


def _device_name(device, adv) -> str:
    return (device.name or adv.local_name or "").strip()


def _is_pendant(device, adv) -> bool:
    name = _device_name(device, adv).lower()
    if name in {n.lower() for n in DEVICE_NAMES} or "pendant" in name:
        return True
    uuids = [str(u).lower() for u in (adv.service_uuids or [])]
    return SVC_UUID.lower() in uuids


def _describe(device, adv) -> str:
    name = _device_name(device, adv) or "(no name)"
    uuids = ",".join(str(u) for u in (adv.service_uuids or [])[:2]) or "-"
    return f"{name} rssi={adv.rssi} uuids={uuids} [{device.address}]"


async def find_device(timeout: float, address: str | None):
    if address:
        print(f"Using BLE address {address}")
        return address

    print("Scanning for OpenPendant (name or service UUID)...")
    seen: dict[str, str] = {}
    found = None
    done = asyncio.Event()

    def on_detect(device, adv) -> None:
        nonlocal found
        seen[device.address] = _describe(device, adv)
        if found is None and _is_pendant(device, adv):
            found = device
            done.set()

    async with BleakScanner(detection_callback=on_detect):
        try:
            await asyncio.wait_for(done.wait(), timeout=timeout)
        except asyncio.TimeoutError:
            pass

    if found is None:
        nearby = "\n  ".join(seen.values()) or "none"
        raise SystemExit(
            "Did not find OpenPendant. It is not advertising under that name.\n"
            "Usually nRF Connect (or another app) still holds the only BLE "
            "connection — force-quit it on the phone, then retry.\n"
            "If the board is in bootloader (XIAO-SENSE drive), flash "
            "build/ai_pendent/zephyr/zephyr.uf2 first.\n"
            f"Nearby BLE:\n  {nearby}"
        )
    print(f"Found {found.name or found.address} ({found.address})")
    return found


def analyze_pcm(pcm: bytes) -> None:
    if len(pcm) < 2:
        print("No PCM captured.")
        return
    samples = struct.unpack("<" + "h" * (len(pcm) // 2), pcm[: len(pcm) // 2 * 2])
    n = len(samples)
    dc = sum(samples) / n
    rms = (sum((s - dc) ** 2 for s in samples) / n) ** 0.5
    peak = max(abs(s) for s in samples)
    clips = sum(1 for s in samples if s <= -32767 or s >= 32767)
    duration = n / SAMPLE_RATE
    print("\n--- capture stats ---")
    print(f"duration: {duration:.2f}s  samples: {n}")
    print(f"DC offset: {dc:.1f}  (0 is ideal; |DC| > 2000 is a strong bias)")
    print(f"RMS (AC):  {rms:.1f}  (quiet room often 50-400; speech often 500-4000)")
    print(f"peak:      {peak}  clips: {clips} ({100 * clips / n:.2f}%)")
    if rms < 80:
        print("Note: very quiet — mic may be muted, far away, or a gain issue.")
    elif dc > 2000:
        print("Note: large DC offset is common on raw PDM; a high-pass can remove it.")


async def capture(seconds: float, outfile: str, address: str | None) -> None:
    device = await find_device(timeout=20.0, address=address)
    chunks: dict[int, bytearray] = {}
    complete: list[bytes] = []
    last_seq = None
    missing = 0
    notify_count = 0

    def on_notify(_handle: int, data: bytearray) -> None:
        nonlocal last_seq, missing, notify_count
        if len(data) < 4:
            return
        seq, frag, frag_count = struct.unpack_from("<HBB", data, 0)
        payload = bytes(data[4:])
        notify_count += 1
        buf = chunks.setdefault(seq, bytearray())
        # Fragments are sent in order; append is enough if none are lost.
        if frag == 0:
            buf.clear()
        buf.extend(payload)
        if frag + 1 == frag_count:
            complete.append(bytes(buf))
            chunks.pop(seq, None)
            if last_seq is not None and seq != ((last_seq + 1) & 0xFFFF):
                missing += 1
            last_seq = seq

    async with BleakClient(device, timeout=20.0) as client:
        print("Connected. Enabling notify...")
        await client.start_notify(PCM_CHAR_UUID, on_notify)
        print(f"Recording {seconds:.1f}s — speak near the board...")
        await asyncio.sleep(seconds)
        await client.stop_notify(PCM_CHAR_UUID)

    pcm = b"".join(complete)
    print(f"notifies: {notify_count}  complete chunks: {len(complete)}  seq gaps: {missing}")
    analyze_pcm(pcm)

    with wave.open(outfile, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(SAMPLE_RATE)
        wav.writeframes(pcm)
    print(f"Wrote {outfile}")
    print(f"Listen with: afplay {outfile}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seconds", type=float, default=5.0)
    parser.add_argument("--out", default="capture.wav")
    parser.add_argument(
        "--address",
        help="Connect to this BLE address instead of scanning by name",
    )
    args = parser.parse_args()
    asyncio.run(capture(args.seconds, args.out, args.address))


if __name__ == "__main__":
    main()
