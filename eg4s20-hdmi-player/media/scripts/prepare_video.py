"""Build the fixed sector-aligned FPGA media file; --check validates it again."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import struct
import zlib

import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageFont

MEDIA = Path(__file__).resolve().parents[1]
PROJECT = MEDIA.parent
SECTOR = 512
WIDTH, HEIGHT, FPS, RATE = 320, 240, 10, 48000
VIDEO_BYTES, AUDIO_BYTES, RECORD_SECTORS = 153600, 9600, 319
RECORD_BYTES = RECORD_SECTORS * SECTOR
FIELDS = ('audio_rate samples_per_frame frame_count cue_count glyph_count '
          'text_length cue_sector text_sector glyph_sector av_sector '
          'record_sectors video_bytes audio_bytes duration_ms play_samples flags').split()


def sha256(path):
    with path.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def pad(data):
    return data + bytes((-len(data)) % SECTOR)


def subtitles():
    cues = []
    for line in (PROJECT / 'Video_txt.txt').read_text(encoding='utf-8-sig').splitlines():
        if not line.strip():
            continue
        match = re.fullmatch(r'\[(\d{2}):(\d{2})\.(\d{3})\](.*)', line)
        if not match:
            raise ValueError(f'Invalid timestamp line: {line!r}')
        mm, ss, ms = map(int, match.group(1, 2, 3))
        assert ss < 60 and (not cues or (mm * 60000 + ss * 1000 + ms) * 48 > cues[-1][0])
        cues.append(((mm * 60000 + ss * 1000 + ms) * 48, match[4].strip()))
    return cues


def font_data(cues):
    chars = list(dict.fromkeys(''.join(text for _, text in cues)))
    assert 0 < len(chars) <= 256
    font = ImageFont.truetype('C:/Windows/Fonts/msyh.ttc', 14)
    glyphs = bytearray()
    for char in chars:
        tile = Image.new('1', (16, 16))
        draw = ImageDraw.Draw(tile)
        box = draw.textbbox((0, 0), char, font=font)
        draw.text(((16 - (box[2] - box[0])) // 2 - box[0], -box[1]), char, font=font, fill=1)
        glyphs.extend(tile.tobytes())  # row-major, MSB = leftmost pixel
    text_data = bytearray()
    cue_data = bytearray()
    for tick, text in cues:
        cue_data.extend(struct.pack('<IHH', tick, len(text_data), len(text)))
        text_data.extend(chars.index(char) for char in text)
    assert len(text_data) <= 65535
    return chars, bytes(cue_data), bytes(text_data), bytes(glyphs)


def check(path):
    with path.open('rb') as f:
        header = f.read(SECTOR)
        assert header[:8] == b'ALAV0001'
        assert zlib.crc32(header[:508]) == struct.unpack_from('<I', header, 508)[0]
        assert struct.unpack_from('<4H', header, 8) == (WIDTH, HEIGHT, FPS, 1)
        meta = dict(zip(FIELDS, struct.unpack_from('<16I', header, 16)))
        assert (meta['audio_rate'], meta['samples_per_frame'], meta['record_sectors']) == (RATE, RATE // FPS, RECORD_SECTORS)
        assert (meta['video_bytes'], meta['audio_bytes'], meta['flags']) == (VIDEO_BYTES, AUDIO_BYTES, 1)
        assert struct.unpack_from('<2H', header, 80) == (16, 16)
        valid_samples = struct.unpack_from('<I', header, 84)[0]
        assert meta['play_samples'] == meta['frame_count'] * RATE // FPS
        assert 0 <= meta['play_samples'] - valid_samples < RATE // FPS
        assert path.stat().st_size == (meta['av_sector'] + meta['frame_count'] * RECORD_SECTORS) * SECTOR
        assert meta['cue_sector'] == 1
        assert meta['text_sector'] == 1 + math.ceil(meta['cue_count'] * 8 / SECTOR)
        assert meta['glyph_sector'] == meta['text_sector'] + math.ceil(meta['text_length'] / SECTOR)
        assert meta['av_sector'] == meta['glyph_sector'] + math.ceil(meta['glyph_count'] * 32 / SECTOR)
        f.seek(meta['cue_sector'] * SECTOR)
        cue_data = f.read(meta['cue_count'] * 8)
        previous = -1
        for tick, offset, length in struct.iter_unpack('<IHH', cue_data):
            assert previous < tick <= meta['play_samples']
            assert offset + length <= meta['text_length']
            previous = tick
        f.seek(meta['text_sector'] * SECTOR)
        assert all(index < meta['glyph_count'] for index in f.read(meta['text_length']))
        f.seek(meta['av_sector'] * SECTOR)
        for _ in range(meta['frame_count']):
            record = f.read(RECORD_BYTES)
            assert len(record) == RECORD_BYTES and record[VIDEO_BYTES + AUDIO_BYTES:] == bytes(128)
        assert not f.read(1)
    return meta


def build():
    audio = (MEDIA / 'work/audio_s16le.pcm').read_bytes()
    audio_info = json.loads((MEDIA / 'work/audio_info.json').read_text(encoding='utf-8-sig'))
    valid_samples = int(audio_info['sample_count'])
    assert audio_info['sample_rate'] == RATE and valid_samples == audio_info['sample_count']
    assert len(audio) == valid_samples * 2
    frame_count = math.ceil(valid_samples / (RATE // FPS))
    cues = subtitles()
    chars, cue_data, text_data, glyphs = font_data(cues)
    cue_sector = 1
    text_sector = cue_sector + len(pad(cue_data)) // SECTOR
    glyph_sector = text_sector + len(pad(text_data)) // SECTOR
    av_sector = glyph_sector + len(pad(glyphs)) // SECTOR
    values = [RATE, RATE // FPS, frame_count, len(cues), len(chars), len(text_data), cue_sector, text_sector,
              glyph_sector, av_sector, RECORD_SECTORS, VIDEO_BYTES, AUDIO_BYTES,
              round(valid_samples * 1000 / RATE), frame_count * RATE // FPS, 1]
    header = bytearray(SECTOR)
    header[:8] = b'ALAV0001'
    struct.pack_into('<4H16I2HI', header, 8, WIDTH, HEIGHT, FPS, 1, *values, 16, 16, valid_samples)
    struct.pack_into('<I', header, 508, zlib.crc32(header[:508]))
    cap = cv2.VideoCapture(str(PROJECT / 'Video.mp4'))
    assert cap.isOpened()
    ok, current = cap.read()
    assert ok
    current_pts = cap.get(cv2.CAP_PROP_POS_MSEC)
    decoded = 1

    def read_next():
        nonlocal decoded
        good, frame = cap.read()
        if not good:
            return None, None
        decoded += 1
        return frame, cap.get(cv2.CAP_PROP_POS_MSEC)

    following, next_pts = read_next()
    assert current_pts == 0
    aspect = current.shape[1] / current.shape[0]
    scaled_w, scaled_h = (WIDTH, round(WIDTH / aspect)) if aspect >= WIDTH / HEIGHT else (round(HEIGHT * aspect), HEIGHT)
    path = MEDIA / 'VIDEO.AVP'
    assert not path.exists(), 'Existing output: remove only after deciding to rebuild.'
    preview_time = 65.1
    with path.open('xb') as f:
        f.write(header + pad(cue_data) + pad(text_data) + pad(glyphs))
        for n in range(frame_count):
            target_ms = n * 1000 / FPS
            while following is not None and next_pts <= target_ms:
                assert next_pts >= current_pts
                current, current_pts = following, next_pts
                following, next_pts = read_next()
            canvas = np.zeros((HEIGHT, WIDTH, 3), dtype=np.uint8)
            y, x = (HEIGHT - scaled_h) // 2, (WIDTH - scaled_w) // 2
            canvas[y:y + scaled_h, x:x + scaled_w] = cv2.resize(current, (scaled_w, scaled_h), interpolation=cv2.INTER_AREA)
            b, g, r = (canvas[:, :, i].astype(np.uint16) for i in range(3))
            pixels = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)
            f.write(pixels[::-1].astype('<u2').tobytes())
            chunk = audio[n * AUDIO_BYTES:(n + 1) * AUDIO_BYTES]
            f.write(chunk + bytes(AUDIO_BYTES - len(chunk)) + bytes(128))
            if n == round(preview_time * FPS):
                rgb = np.stack((((pixels >> 11) * 255 // 31), (((pixels >> 5) & 63) * 255 // 63), ((pixels & 31) * 255 // 31)), axis=2).astype(np.uint8)
                preview = Image.fromarray(rgb).resize((640, 480), Image.Resampling.NEAREST)
                text = next((text for tick, text in reversed(cues) if tick <= n * RATE // FPS), '')
                overlay = ImageDraw.Draw(preview)
                overlay.rectangle((0, 440, 639, 463), fill='black')
                for i, char in enumerate(text):
                    tile = Image.frombytes('1', (16, 16), glyphs[chars.index(char) * 32:(chars.index(char) + 1) * 32])
                    preview.paste('white', ((640 - len(text) * 16) // 2 + i * 16, 444), tile)
                preview.save(MEDIA / 'preview.png')
            if n % 500 == 0:
                print(f'Converted {n}/{frame_count}', flush=True)
    # Drain the decoder to detect truncation and record the actual end timestamp.
    while following is not None:
        assert next_pts >= current_pts
        current_pts = next_pts
        following, next_pts = read_next()
    cap.release()
    assert current_pts >= audio_info['sample_count'] * 1000 / RATE - 100
    meta = check(path)
    meta.update({'file': path.name, 'file_bytes': path.stat().st_size, 'sha256': sha256(path),
                 'source_video_sha256': sha256(PROJECT / 'Video.mp4'),
                 'source_subtitle_sha256': sha256(PROJECT / 'Video_txt.txt'),
                 'source_decoded_frames': decoded, 'source_last_pts_ms': current_pts,
                 'scaled_width': scaled_w, 'scaled_height': scaled_h, 'glyph_characters': ''.join(chars),
                 'audio': audio_info})
    (MEDIA / 'manifest.json').write_text(json.dumps(meta, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps({k: meta[k] for k in ('file', 'file_bytes', 'frame_count', 'cue_count', 'glyph_count', 'sha256')}, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--check', type=Path, help='Validate an existing package, without rebuilding')
    args = parser.parse_args()
    print(json.dumps(check(args.check), indent=2)) if args.check else build()
