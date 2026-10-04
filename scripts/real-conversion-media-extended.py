#!/usr/bin/env python3
"""Retained real-media matrix for additional input extensions and difficult media.

Calls the supplied shipping binary, not converter mocks. Every case retains its
input, output, CLI log, full-decode evidence, stream metadata, and source hashes.
Requires ffmpeg/ffprobe. The optional AMR fixture is an actual FFmpeg public sample
(https://samples.ffmpeg.org/A-codecs/amr/sample2.amr), never a renamed WAV file.
No fixtures or prior reports are removed. Choose a new output directory per run.
"""
import argparse
import array
import datetime
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import shutil
import statistics
import subprocess
import time

spec = importlib.util.spec_from_file_location('base_media', Path(__file__).with_name('real-conversion-media.py'))
base = importlib.util.module_from_spec(spec)
spec.loader.exec_module(base)
VIDEOS = ['mp4', 'mov', 'mkv', 'webm', 'avi', 'wmv', 'gif']
AUDIOS = ['m4a', 'mp3', 'wav', 'flac', 'ogg', 'opus', 'aiff', 'wma']
EXT_VIDEO = {
    'm4v': ['-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-f', 'mp4'],
    'flv': ['-c:v', 'flv', '-q:v', '3', '-c:a', 'libmp3lame', '-ar', '44100', '-f', 'flv'],
    'mpg': ['-c:v', 'mpeg1video', '-q:v', '3', '-c:a', 'mp2', '-ar', '44100', '-f', 'mpeg'],
    'mpeg': ['-c:v', 'mpeg2video', '-q:v', '3', '-c:a', 'mp2', '-ar', '48000', '-f', 'mpeg'],
    '3gp': ['-c:v', 'mpeg4', '-q:v', '3', '-c:a', 'aac', '-f', '3gp'],
    'ts': ['-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-f', 'mpegts'],
    'mts': ['-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-c:a', 'ac3', '-f', 'mpegts'],
    'm2ts': ['-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-c:a', 'ac3', '-mpegts_m2ts_mode', '1', '-f', 'mpegts'],
}
EXT_AUDIO = {
    'aac': ['-c:a', 'aac', '-f', 'adts'],
    'wave': ['-c:a', 'pcm_s16le', '-f', 'wav'],
    'aif': ['-c:a', 'pcm_s16be', '-f', 'aiff'],
    'aifc': ['-c:a', 'adpcm_ima_qt', '-f', 'aiff'],
    'caf': ['-c:a', 'alac', '-f', 'caf'],
    'oga': ['-c:a', 'vorbis', '-strict', 'experimental', '-f', 'ogg'],
}
ALIASES = {'wave': 'wav', 'aif': 'aiff', 'aifc': 'aiff'}


def checked(args, timeout=300):
    return base.checked(args, timeout)


def probe(path, ffprobe):
    return json.loads(checked([ffprobe, '-v', 'error', '-show_format', '-show_streams', '-of', 'json', path]))


def duration(metadata):
    return float(metadata['format'].get('duration') or max(float(s.get('duration', 0)) for s in metadata['streams']))


def analyze(path, ffmpeg, ffprobe, video, audio, expected_duration, dimensions=None,
            channels=None, tones=None, duration_tolerance=0.40):
    metadata = probe(path, ffprobe)
    info = {'bytes': path.stat().st_size, 'sha256': base.digest(path), 'probe': metadata,
            'visibility': base.visibility(path), 'full_decode': False}
    assert info['bytes'] > 100, 'empty media'
    assert not any(info['visibility'].values()), 'output hidden in Finder'
    vs = [s for s in metadata['streams'] if s['codec_type'] == 'video']
    aus = [s for s in metadata['streams'] if s['codec_type'] == 'audio']
    assert bool(vs) == video, f'expected video {video}, found {len(vs)}'
    assert bool(aus) == audio, f'expected audio {audio}, found {len(aus)}'
    actual_duration = duration(metadata)
    info['duration_seconds'] = actual_duration
    assert abs(actual_duration - expected_duration) < duration_tolerance, f'duration changed {expected_duration} -> {actual_duration}'
    checked([ffmpeg, '-v', 'error', '-xerror', '-i', path, '-map', '0:v?', '-map', '0:a?', '-f', 'null', '-'], timeout=600)
    info['full_decode'] = True
    if video:
        v = vs[0]
        rotation = next((s.get('rotation', 0) for s in v.get('side_data_list', []) if 'rotation' in s), 0)
        display = (v['height'], v['width']) if abs(int(rotation)) % 180 == 90 else (v['width'], v['height'])
        info['display_dimensions'] = display
        if dimensions:
            if path.suffix == '.gif':
                assert abs(display[0] / display[1] - dimensions[0] / dimensions[1]) < 0.02, 'GIF aspect ratio changed'
            else:
                assert display == tuple(dimensions), f'display dimensions changed: {dimensions} -> {display}'
        # Sample both endpoints and middle; fully decoding above checks the rest.
        frames = []
        for index, t in enumerate([0, max(0, actual_duration / 2 - 0.1), max(0, actual_duration - 0.3)]):
            raw = checked([ffmpeg, '-v', 'error', '-i', path, '-ss', str(t), '-map', '0:v:0', '-frames:v', '1',
                           '-vf', 'scale=80:45', '-pix_fmt', 'rgb24', '-f', 'rawvideo', '-'])
            assert len(raw) == 80 * 45 * 3, f'no valid sample frame at {t}'
            assert statistics.pstdev(raw) > 5, 'uniform/blank video frame'
            base.save_rgb_preview(path.with_name(path.name + f'.preview-{index}.png'), raw)
            frames.append(raw)
        info['video_sample_stddev'] = [statistics.pstdev(f) for f in frames]
        info['video_mean_changes'] = [statistics.mean(abs(a - b) for a, b in zip(frames[0], f)) for f in frames[1:]]
        assert max(info['video_mean_changes']) > 1, 'moving source became static video'
    if audio:
        a = aus[0]
        raw = checked([ffmpeg, '-v', 'error', '-i', path, '-map', '0:a:0', '-ar', '8000', '-f', 'f32le', '-'], timeout=600)
        samples = array.array('f'); samples.frombytes(raw)
        count = a['channels']
        rms = math.sqrt(sum(s * s for s in samples) / max(1, len(samples)))
        assert len(samples) >= 8000 * count * max(.1, expected_duration - .5), 'truncated audio content'
        assert 0.001 < rms < 0.95, f'silent/clipped audio {rms}'
        info['audio_content'] = {'rms': rms, 'channels': count, 'samples_per_channel': len(samples) // count}
        if channels is not None:
            assert count == channels, f'channel count changed: expected {channels}, got {count}'
        if tones:
            strengths = []
            for ch, expected in enumerate(tones):
                signal = samples[ch::count][2000:6000]
                powers = {}
                for f in set([220, 330, 440, 550, 660, 880, *tones]):
                    coefficient = 2 * math.cos(2 * math.pi * f / 8000)
                    s1 = s2 = 0.0
                    for s in signal:
                        s0 = s + coefficient * s1 - s2
                        s2, s1 = s1, s0
                    powers[f] = math.sqrt(max(0, s1*s1 + s2*s2 - coefficient*s1*s2))
                assert max(powers, key=powers.get) == expected, f'channel {ch} tone not retained: {powers}'
                strengths.append(powers)
            info['audio_content']['tone_strengths'] = strengths
    return info


def waveform_correlation(source, output, ffmpeg):
    """Compare real AMR speech waveforms while allowing codec priming offsets."""
    signals = []
    for path in [source, output]:
        raw = checked([ffmpeg, '-v', 'error', '-i', path, '-map', '0:a:0', '-ar', '8000', '-ac', '1', '-f', 'f32le', '-'])
        samples = array.array('f'); samples.frombytes(raw)
        signals.append(samples)
    a, b = signals
    best = -1.0
    for lag in range(-400, 401):
        a_start, b_start = max(0, lag), max(0, -lag)
        length = min(len(a) - a_start, len(b) - b_start)
        if length < 1000: continue
        step = max(1, length // 2000)
        x, y = a[a_start:a_start+length:step], b[b_start:b_start+length:step]
        dot = sum(left * right for left, right in zip(x, y))
        norm = math.sqrt(sum(v * v for v in x) * sum(v * v for v in y))
        if norm: best = max(best, dot / norm)
    assert best > 0.65, f'AMR source speech waveform not retained: correlation={best}'
    return best


def main(args):
    root = Path(args.output).resolve(); root.mkdir(parents=True, exist_ok=True)
    if (root / 'results.json').exists():
        raise SystemExit('Use a fresh --output directory; preserving previous evidence.')
    fixtures = root / 'fixtures'; fixtures.mkdir(exist_ok=True)
    report = {'started_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'executable': str(Path(args.executable).resolve()), 'executable_sha256': base.digest(args.executable),
              'ffmpeg': checked([args.ffmpeg, '-version']).decode().splitlines()[0], 'fixtures': {}, 'cases': []}
    def save():
        report['summary'] = {'total': len(report['cases']),
            'passed': sum(c['status'] == 'passed' for c in report['cases']),
            'failed': sum(c['status'] == 'failed' for c in report['cases']),
            'expected_rejections': sum(c['status'] == 'expected_rejection' for c in report['cases']),
            'passed_with_limitations': sum(c['status'] == 'passed_with_limitations' for c in report['cases']),
            'distinct_directions': len({(c['source_format'], c['target_format']) for c in report['cases']})}
        (root / 'results.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
    def generate(name, fmt, ffargs, video=True, audio=True, seconds=2.0, dimensions=(320, 180), channels=2, tones=(440, 660)):
        path = fixtures / f'{name}.{fmt}'
        cmd = [args.ffmpeg, '-v', 'error', '-nostdin', '-n', *ffargs, path]
        if not path.exists(): checked(cmd, timeout=600)
        data = analyze(path, args.ffmpeg, args.ffprobe, video, audio, seconds, dimensions if video else None, channels if audio else None, tones if audio else None)
        entry = {'path': str(path), 'source_format': fmt, 'fixture_variant': name, 'generation_command': list(map(str, cmd)), 'checks': data,
                 'video': video, 'audio': audio, 'duration': duration(data['probe']), 'dimensions': dimensions,
                 'channels': channels, 'tones': tones}
        report['fixtures'][name] = entry
        save(); return entry
    stereo = 'aevalsrc=0.2*sin(2*PI*440*t)|0.2*sin(2*PI*660*t):s=48000:d=2'
    video_input = ['-f', 'lavfi', '-i', 'testsrc2=size=320x180:rate=25:duration=2']
    audio_input = ['-f', 'lavfi', '-i', stereo]
    plans = []
    if not args.edges_only:
        for fmt, encoding in EXT_VIDEO.items():
            item = generate(f'extended-{fmt}', fmt, [*video_input, *audio_input, *encoding, '-t', '2'])
            plans += [(item, target, None) for target in VIDEOS + AUDIOS]
        for fmt, encoding in EXT_AUDIO.items():
            item = generate(f'extended-{fmt}', fmt, [*audio_input, *encoding, '-t', '2'], video=False)
            plans += [(item, target, None) for target in AUDIOS if target != ALIASES.get(fmt, fmt)]
        if args.amr_fixture:
            path = fixtures / 'ffmpeg-sample2.amr'; shutil.copyfile(args.amr_fixture, path)
            assert path.read_bytes().startswith(b'#!AMR\n'), 'AMR sample lacks AMR magic'
            p = probe(path, args.ffprobe)
            assert p['streams'][0]['codec_name'] == 'amr_nb', 'sample is not AMR-NB encoded'
            data = analyze(path, args.ffmpeg, args.ffprobe, False, True, duration(p), channels=1)
            item = {'path': str(path), 'source_format': 'amr', 'fixture_variant': 'official-amr-sample',
                    'fixture_source': 'https://samples.ffmpeg.org/A-codecs/amr/sample2.amr',
                    'checks': data, 'video': False, 'audio': True, 'duration': duration(p), 'dimensions': None, 'channels': 1, 'tones': None}
            report['fixtures'][item['fixture_variant']] = item
            plans += [(item, target, None) for target in AUDIOS]
        else:
            report['missing_amr_reason'] = 'No actual AMR fixture supplied; this is not counted as tested.'
    if not args.matrix_only:
        common = ['-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-t', '2']
        no_audio = generate('silent-video', 'mp4', [*video_input, '-c:v', 'libx264', '-pix_fmt', 'yuv420p'], audio=False)
        plans += [(no_audio, t, 'no_audio' if t in AUDIOS else None) for t in VIDEOS + AUDIOS if t != 'mp4']
        # Genuine variable frame times, not a renamed constant-frame-rate source.
        vfr = generate('variable-frame-rate', 'mp4', [*video_input, *audio_input,
            '-vf', "select='if(lt(t,1),not(mod(n,2)),1)'", '-fps_mode', 'vfr', *common])
        plans += [(vfr, t, None) for t in VIDEOS + AUDIOS if t != 'mp4']
        base_path = fixtures / 'rotation-base.mp4'
        if not base_path.exists(): checked([args.ffmpeg, '-v', 'error', '-n', *video_input, *audio_input, *common, base_path])
        portrait = generate('rotated-portrait', 'mp4', ['-display_rotation:v:0', '90', '-i', base_path, '-c', 'copy'], dimensions=(180, 320))
        plans += [(portrait, t, None) for t in VIDEOS + AUDIOS if t != 'mp4']
        hdr = generate('hdr10-tagged', 'mp4', [*video_input, *audio_input, '-c:v', 'libx265', '-preset', 'ultrafast',
            '-pix_fmt', 'yuv420p10le', '-color_primaries', 'bt2020', '-color_trc', 'smpte2084', '-colorspace', 'bt2020nc',
            '-x265-params', 'log-level=error:repeat-headers=1:colorprim=9:transfer=16:colormatrix=9:hdr10=1:master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1):max-cll=1000,400', '-tag:v', 'hvc1', '-c:a', 'aac', '-t', '2'])
        hdr_stream = next(s for s in hdr['checks']['probe']['streams'] if s['codec_type'] == 'video')
        assert hdr_stream.get('color_transfer') == 'smpte2084' and hdr_stream.get('color_primaries') == 'bt2020' and '10' in hdr_stream['pix_fmt'], 'fixture is not HDR10'
        plans += [(hdr, t, None) for t in VIDEOS + AUDIOS if t != 'mp4']
        subtitle = fixtures / 'multitrack.srt'
        subtitle.write_text('1\n00:00:00,000 --> 00:00:01,700\nFileOrbit 字幕 SAMPLE\n\n')
        # Two distinct language tracks and a subtitle should not vanish silently.
        multi = generate('two-audio-tracks-subtitle', 'mkv', [*video_input, *audio_input,
            '-f', 'lavfi', '-i', 'sine=frequency=880:sample_rate=48000:duration=2', '-i', subtitle,
            '-map', '0:v', '-map', '1:a', '-map', '2:a', '-map', '3:0',
            '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-c:s', 'srt',
            '-metadata:s:a:0', 'language=eng', '-metadata:s:a:1', 'language=zho', '-t', '2'])
        plans += [(multi, t, None) for t in VIDEOS + AUDIOS if t != 'mkv']
        native_multi = generate('two-audio-tracks-native', 'mp4', ['-i', multi['path'],
            '-map', '0:v', '-map', '0:a', '-map', '0:s', '-c:v', 'copy', '-c:a', 'copy', '-c:s', 'mov_text'])
        plans += [(native_multi, t, None) for t in VIDEOS + AUDIOS if t != 'mp4']
        surround_tones = [220, 330, 440, 60, 660, 880]
        surround = generate('six-channel-surround', 'wav', ['-f', 'lavfi', '-i',
            'aevalsrc=' + '|'.join(f'0.12*sin(2*PI*{f}*t)' for f in surround_tones) + ':s=48000:d=2:c=5.1',
            '-c:a', 'pcm_s16le'], video=False, channels=6, tones=surround_tones)
        plans += [(surround, t, None) for t in AUDIOS if t != 'wav']
        long_file = generate('three-minute-video', 'mp4', ['-f', 'lavfi', '-i', 'testsrc2=size=160x90:rate=6:duration=180',
            '-f', 'lavfi', '-i', 'aevalsrc=0.2*sin(2*PI*440*t)|0.2*sin(2*PI*660*t):s=48000:d=180',
            '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-t', '180'], seconds=180, dimensions=(160, 90))
        plans += [(long_file, t, 'gif_limit' if t == 'gif' else None) for t in VIDEOS + AUDIOS if t != 'mp4']
        for fmt in ['mp4', 'wav']:
            path = fixtures / f'corrupt-media.{fmt}'; path.write_bytes(b'FileOrbit invalid media fixture\n' * 4)
            item = {'path': str(path), 'source_format': fmt, 'fixture_variant': f'corrupt-{fmt}', 'video': fmt == 'mp4', 'audio': True,
                    'duration': 0, 'dimensions': None, 'channels': 2, 'tones': None}
            report['fixtures'][item['fixture_variant']] = item
            plans += [(item, t, 'corrupt') for t in (VIDEOS + AUDIOS if fmt == 'mp4' else AUDIOS) if t != fmt]
    save()
    for item, target, expected_reject in plans:
        name = item['fixture_variant']
        folder = root / 'cases' / f'{name}-to-{target}'; folder.mkdir(parents=True)
        source = folder / Path(item['path']).name; shutil.copyfile(item['path'], source)
        before = base.digest(source)
        cli = [args.executable, 'convert', str(source), '--to', target, '--json']
        case = {'source_format': item['source_format'], 'target_format': target, 'fixture_variant': name,
                'input': str(source), 'outputs': [], 'checks': {}, 'error': None, 'limitations': [],
                'expected_rejection': expected_reject, 'command': list(map(str, cli))}
        start = time.monotonic()
        try:
            process = base.command(cli, timeout=600)
            (folder / 'stdout.json').write_bytes(process.stdout); (folder / 'stderr.txt').write_bytes(process.stderr)
            result = json.loads(process.stdout)
            case['exit_code'] = process.returncode; case['cli_result'] = result; case['outputs'] = result.get('outputs', [])
            if expected_reject:
                assert process.returncode != 0 and result.get('succeededInputs') == 0 and not case['outputs'], f'expected rejection, got {result}'
                assert not [p for p in folder.iterdir() if p.suffix == '.' + target and p != source], 'failed conversion published an output'
                case['status'] = 'expected_rejection'
            else:
                assert process.returncode == 0 and result.get('succeededInputs') == 1, f'conversion failed: {result}'
                assert len(case['outputs']) == 1, 'unexpected output count'
                out = Path(case['outputs'][0])
                channels = item['channels']; tones = item['tones']
                if target == 'wma':
                    if channels != 2: case['limitations'].append('WMAv2 preset converts the source to stereo.')
                    channels = 2
                    if item['channels'] != 2: tones = None
                if item['channels'] > 2 and target == 'mp3':
                    channels = 2; tones = None
                    case['limitations'].append('MP3 is limited to mono/stereo; multichannel input must be downmixed.')
                checks = analyze(out, args.ffmpeg, args.ffprobe, target in VIDEOS,
                    item['audio'] and target != 'gif', item['duration'], item['dimensions'] if target in VIDEOS else None,
                    channels if item['audio'] and target != 'gif' else None, tones if item['audio'] and target != 'gif' else None,
                    duration_tolerance=.5 if item['source_format'] == 'amr' else .4)
                case['checks']['output'] = checks
                if item['source_format'] == 'amr':
                    case['checks']['source_audio_waveform_correlation'] = waveform_correlation(source, out, args.ffmpeg)
                if name == 'hdr10-tagged' and target in VIDEOS:
                    v = next(s for s in checks['probe']['streams'] if s['codec_type'] == 'video')
                    if '10' not in v.get('pix_fmt', '') or v.get('color_transfer') != 'smpte2084' or v.get('color_primaries') != 'bt2020':
                        case['limitations'].append('HDR10 bit depth and/or color metadata not preserved; HDR appearance is not accepted.')
                if name.startswith('two-audio-tracks-') and target in VIDEOS:
                    streams = checks['probe']['streams']
                    audio_count = sum(s['codec_type'] == 'audio' for s in streams)
                    subtitle_count = sum(s['codec_type'] == 'subtitle' for s in streams)
                    case['checks']['stream_counts'] = {'audio': audio_count, 'subtitle': subtitle_count}
                    if target != 'gif' and (audio_count < 2 or subtitle_count < 1):
                        case['limitations'].append('Secondary audio and/or subtitles omitted; multitrack preservation is not accepted.')
                    if target == 'gif': case['limitations'].append('GIF is visual-only; audio and subtitle tracks are not represented.')
                if name.startswith('two-audio-tracks-') and target in AUDIOS:
                    for ch, powers in enumerate(checks['audio_content']['tone_strengths']):
                        leakage = powers[880] / powers[item['tones'][ch]]
                        assert leakage < 0.06, f'alternative language track mixed into the selected audio: relative 880Hz level {leakage}'
                    case['checks']['alternative_track_not_mixed'] = True
                    case['limitations'].append('Audio conversion selects one track; multiple language tracks are not retained.')
                case['checks']['fidelity_accepted'] = not case['limitations']
                case['status'] = 'passed_with_limitations' if case['limitations'] else 'passed'
        except Exception as error:
            case['status'] = 'failed'; case['error'] = str(error)
        case['checks']['input_sha256_before'] = before
        case['checks']['input_sha256_after'] = base.digest(source)
        case['checks']['input_unchanged'] = before == case['checks']['input_sha256_after']
        if not case['checks']['input_unchanged']:
            case['status'] = 'failed'; case['error'] = (case['error'] or '') + ' source changed'
        case['seconds'] = round(time.monotonic() - start, 3)
        report['cases'].append(case); save()
        print(f"{len(report['cases'])}/{len(plans)} {name} -> {target}: {case['status']} {case['error'] or ''}", flush=True)
    report['completed_at'] = datetime.datetime.now(datetime.timezone.utc).isoformat(); save()
    print(json.dumps(report['summary']), flush=True)

if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('executable'); p.add_argument('--output', required=True)
    p.add_argument('--ffmpeg', default=shutil.which('ffmpeg')); p.add_argument('--ffprobe', default=shutil.which('ffprobe'))
    p.add_argument('--amr-fixture'); p.add_argument('--matrix-only', action='store_true'); p.add_argument('--edges-only', action='store_true')
    main(p.parse_args())
