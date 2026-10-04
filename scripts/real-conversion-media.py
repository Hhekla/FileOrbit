#!/usr/bin/env python3
"""Real-file audio/video acceptance through the shipping CLI, retaining all evidence.

Requires ffmpeg and ffprobe. Creates its own non-private, moving-picture/stereo-tone
fixtures. A pass requires the produced media to fully decode, retain its duration,
contain nonblank changing frames/non-silent sound, and preserve the source bytes.
No files are deleted. Pass a fresh --output directory for each independent run.
"""
import argparse
import array
import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import statistics
import struct
import subprocess
import time
import zlib

VIDEO = {
    "mp4": ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac"],
    "mov": ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac"],
    "mkv": ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac"],
    "webm": ["-c:v", "libvpx-vp9", "-deadline", "realtime", "-cpu-used", "8", "-c:a", "libopus"],
    "avi": ["-c:v", "mpeg4", "-q:v", "3", "-c:a", "libmp3lame"],
    "wmv": ["-c:v", "wmv2", "-c:a", "wmav2", "-ar", "44100", "-ac", "2"],
}
AUDIO = {
    "wav": ["-c:a", "pcm_s16le"], "m4a": ["-c:a", "aac"],
    "mp3": ["-c:a", "libmp3lame"], "flac": ["-c:a", "flac"],
    "ogg": ["-c:a", "libopus"], "opus": ["-c:a", "libopus"],
    "aiff": ["-c:a", "pcm_s16be"],
    "wma": ["-c:a", "wmav2", "-ar", "44100", "-ac", "2"],
}


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def save_rgb_preview(path, pixels, width=80, height=45):
    def chunk(kind, data):
        return struct.pack("!I", len(data)) + kind + data + struct.pack("!I", zlib.crc32(kind + data) & 0xffffffff)
    scanlines = b"".join(b"\0" + pixels[y * width * 3:(y + 1) * width * 3] for y in range(height))
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack("!IIBBBBB", width, height, 8, 2, 0, 0, 0))
                     + chunk(b"IDAT", zlib.compress(scanlines)) + chunk(b"IEND", b""))


def command(args, timeout=90):
    return subprocess.run(list(map(str, args)), capture_output=True, timeout=timeout)


def checked(args, timeout=90):
    process = command(args, timeout)
    if process.returncode:
        raise RuntimeError(f"command failed ({process.returncode}): {args}\n{process.stderr.decode(errors='replace')[-4000:]}")
    return process.stdout


def visibility(path):
    flags = getattr(path.stat(), "st_flags", 0)
    finder_hidden = False
    attributes = command(["/usr/bin/xattr", "-px", "com.apple.FinderInfo", path])
    if attributes.returncode == 0:
        info = bytes.fromhex(attributes.stdout.decode())
        finder_hidden = len(info) >= 10 and bool(int.from_bytes(info[8:10], "big") & 0x4000)
    return {"uf_hidden": bool(flags & 0x8000), "finder_invisible": finder_hidden,
            "filename_hidden": path.name.startswith(".")}


def inspect(path, ffmpeg, ffprobe, want_video, want_audio, duration=2.0):
    probe = json.loads(checked([ffprobe, "-v", "error", "-show_format", "-show_streams", "-of", "json", path]))
    path.with_name(path.name + ".probe.json").write_text(json.dumps(probe, indent=2))
    vs = [s for s in probe["streams"] if s["codec_type"] == "video"]
    aus = [s for s in probe["streams"] if s["codec_type"] == "audio"]
    info = {"bytes": path.stat().st_size, "sha256": digest(path), "probe": probe,
            "visibility": visibility(path)}
    assert info["bytes"] > 100, "empty/implausibly small media"
    assert not any(info["visibility"].values()), "output is hidden in Finder"
    assert bool(vs) == want_video, f"expected video={want_video}, got {len(vs)} streams"
    assert bool(aus) == want_audio, f"expected audio={want_audio}, got {len(aus)} streams"
    actual_duration = float(probe["format"].get("duration") or max(float(s.get("duration", 0)) for s in probe["streams"]))
    info["duration_seconds"] = actual_duration
    assert abs(actual_duration - duration) < 0.30, f"duration changed: expected {duration}, got {actual_duration}"
    checked([ffmpeg, "-v", "error", "-xerror", "-i", path, "-map", "0:v?", "-map", "0:a?", "-f", "null", "-"])
    info["full_decode"] = True
    if want_video:
        width, height = vs[0]["width"], vs[0]["height"]
        if path.suffix.lower() == ".gif":
            # The configured GIF preset permits upscaling to an 800px long edge.
            assert 2 <= max(width, height) <= 800 and abs(width / height - 320 / 180) < 0.015, "GIF aspect ratio or preset dimensions invalid"
        else:
            assert width == 320 and height == 180, "video dimensions changed"
        raw = checked([ffmpeg, "-v", "error", "-i", path, "-an", "-vf", "fps=2,scale=80:45", "-pix_fmt", "rgb24", "-f", "rawvideo", "-"])
        frame_size = 80 * 45 * 3
        frames = [raw[i:i + frame_size] for i in range(0, len(raw), frame_size)]
        assert len(frames) >= 3 and all(len(frame) == frame_size for frame in frames), "missing video frames"
        deviations = [statistics.pstdev(frame) for frame in frames]
        differences = [statistics.mean(abs(a - b) for a, b in zip(frames[0], frame)) for frame in frames[1:]]
        assert min(deviations) > 10, "blank or uniform video frame"
        assert max(differences) > 2, "video has no temporal changes"
        info["video_content"] = {"sampled_frames": len(frames), "frame_stddev": deviations,
                                 "mean_change_from_first_frame": differences}
        info["preview_frames"] = []
        for i in [0, len(frames) - 1]:
            preview = path.with_name(path.name + f".preview-{i + 1}.png")
            save_rgb_preview(preview, frames[i])
            info["preview_frames"].append(str(preview))
    if want_audio:
        raw = checked([ffmpeg, "-v", "error", "-i", path, "-vn", "-ar", "8000", "-ac", "2", "-f", "f32le", "-"])
        samples = array.array("f")
        samples.frombytes(raw)
        assert len(samples) > 24000, "audio is truncated"
        rms = math.sqrt(sum(sample * sample for sample in samples) / len(samples))
        assert 0.02 < rms < 0.95, f"audio silent or clipped: RMS={rms}"
        assert aus[0]["channels"] == 2, "stereo channel count changed"
        frequencies = []
        tone_strengths = []
        for channel, expected_frequency in enumerate([440, 660]):
            # Analyze a middle window, avoiding codec priming/padding. Goertzel
            # distinguishes the tones despite lossy-codec zero-crossing noise.
            signal = samples[channel::2][2000:6000]
            strengths = {}
            for frequency in [220, 330, 440, 550, 660, 880]:
                coefficient = 2 * math.cos(2 * math.pi * frequency / 8000)
                s1 = s2 = 0.0
                for sample in signal:
                    s0 = sample + coefficient * s1 - s2
                    s2, s1 = s1, s0
                strengths[frequency] = math.sqrt(max(0, s1 * s1 + s2 * s2 - coefficient * s1 * s2))
            dominant = max(strengths, key=strengths.get)
            assert dominant == expected_frequency and strengths[dominant] > 20, f"audio channel {channel} lost its {expected_frequency}Hz tone: {strengths}"
            frequencies.append(dominant)
            tone_strengths.append(strengths)
        info["audio_content"] = {"decoded_frames_at_8khz": len(samples) // 2, "rms": rms,
                                 "peak": max(map(abs, samples)), "channels": aus[0]["channels"],
                                 "channel_tone_frequencies_hz": frequencies, "tone_strengths": tone_strengths}
    return info


def run(args):
    output = Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    if (output / "results.json").exists():
        raise SystemExit("Refusing to overwrite an earlier report; choose a fresh --output directory.")
    fixtures = output / "fixtures"
    fixtures.mkdir(exist_ok=True)
    report = {"started_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "executable": str(Path(args.executable).resolve()), "executable_sha256": digest(args.executable),
              "ffmpeg": checked([args.ffmpeg, "-version"]).decode().splitlines()[0],
              "fixture_design": "2 seconds; 320x180 at 12 fps testsrc2; stereo 440Hz/660Hz tones at 48kHz",
              "fixtures": {}, "cases": []}

    def save():
        report["summary"] = {"total": len(report["cases"]),
                             "passed": sum(c["status"] == "passed" for c in report["cases"]),
                             "failed": sum(c["status"] != "passed" for c in report["cases"]),
                             "distinct_directions": len({(c["source_format"], c["target_format"]) for c in report["cases"]})}
        (output / "results.json").write_text(json.dumps(report, ensure_ascii=False, indent=2))

    tone = "aevalsrc=0.2*sin(2*PI*440*t)|0.2*sin(2*PI*660*t):s=48000:d=2"
    for fmt, encoding in list(VIDEO.items()) + list(AUDIO.items()):
        path = fixtures / f"source.{fmt}"
        generation = [args.ffmpeg, "-nostdin", "-v", "error", "-n"]
        if fmt in VIDEO:
            generation += ["-f", "lavfi", "-i", "testsrc2=size=320x180:rate=12:duration=2"]
        generation += ["-f", "lavfi", "-i", tone, *encoding, "-t", "2", path]
        if not path.exists():
            checked(generation)
        report["fixtures"][fmt] = {"path": str(path), "generation_command": list(map(str, generation)),
                                   "checks": inspect(path, args.ffmpeg, args.ffprobe, fmt in VIDEO, True)}
    save()
    priority = [("mp4", f) for f in [*VIDEO, "gif", *AUDIO] if f != "mp4"]
    priority += [(f, "mp4") for f in VIDEO if f != "mp4"]
    priority += [("wav", f) for f in AUDIO if f != "wav"] + [(f, "wav") for f in AUDIO if f != "wav"]
    matrix = [(s, t) for s in VIDEO for t in [*VIDEO, "gif", *AUDIO] if s != t]
    matrix += [(s, t) for s in AUDIO for t in AUDIO if s != t]
    directions = list(dict.fromkeys(priority + matrix))
    for source_format, target_format in directions:
        case_folder = output / "cases" / f"{source_format}-to-{target_format}"
        case_folder.mkdir(parents=True)
        source = case_folder / f"fixture.{source_format}"
        shutil.copyfile(fixtures / f"source.{source_format}", source)
        before = digest(source)
        cli = [args.executable, "convert", str(source), "--to", target_format, "--json"]
        case = {"source_format": source_format, "target_format": target_format,
                "input": str(source), "outputs": [], "command": cli, "checks": {}, "error": None}
        start = time.monotonic()
        try:
            process = command(cli, timeout=90)
            (case_folder / "stdout.json").write_bytes(process.stdout)
            (case_folder / "stderr.txt").write_bytes(process.stderr)
            case["exit_code"] = process.returncode
            result = json.loads(process.stdout)
            case["cli_result"] = result
            case["outputs"] = result.get("outputs", [])
            assert process.returncode == 0 and result.get("succeededInputs") == 1, f"CLI conversion failed: {result}"
            assert len(case["outputs"]) == 1, f"unexpected output count: {case['outputs']}"
            case["checks"]["outputs"] = [inspect(Path(p), args.ffmpeg, args.ffprobe,
                                                   target_format in VIDEO or target_format == "gif",
                                                   target_format != "gif") for p in case["outputs"]]
            case["status"] = "passed"
        except Exception as error:
            case["status"] = "failed"
            case["error"] = str(error)
            case["failure_classification"] = "requires_triage"
        case["checks"]["input_sha256_before"] = before
        case["checks"]["input_sha256_after"] = digest(source)
        case["checks"]["input_unchanged"] = before == case["checks"]["input_sha256_after"]
        if not case["checks"]["input_unchanged"]:
            case["status"] = "failed"
            case["error"] = (case["error"] or "") + " original file changed"
        case["seconds"] = round(time.monotonic() - start, 3)
        report["cases"].append(case)
        save()
        print(f"{len(report['cases'])}/{len(directions)} {source_format} -> {target_format}: {case['status']} {case['error'] or ''}", flush=True)
    report["completed_at"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    save()
    print(json.dumps(report["summary"]), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("executable")
    parser.add_argument("--output", required=True)
    parser.add_argument("--ffmpeg", default=shutil.which("ffmpeg"))
    parser.add_argument("--ffprobe", default=shutil.which("ffprobe"))
    run(parser.parse_args())
