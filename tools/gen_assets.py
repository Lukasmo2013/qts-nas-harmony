# -*- coding: utf-8 -*-
"""Generate deterministic image assets for the HarmonyOS project.

- app_icon.png : launcher / start-window icon (pure-Python PNG writer, no deps)
- ic_*.svg     : monochrome line icons used by ArkUI Image components

Run: python tools/gen_assets.py
"""
import os
import struct
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MEDIA_DIRS = [
    os.path.join(ROOT, 'AppScope', 'resources', 'base', 'media'),
    os.path.join(ROOT, 'entry', 'src', 'main', 'resources', 'base', 'media'),
]

SIZE = 512


def inside_round_rect(x, y, x0, y0, x1, y1, r):
    if x < x0 or x > x1 or y < y0 or y > y1:
        return False
    cx = min(max(x, x0 + r), x1 - r)
    cy = min(max(y, y0 + r), y1 - r)
    dx, dy = x - cx, y - cy
    if (x < x0 + r or x > x1 - r) and (y < y0 + r or y > y1 - r):
        return dx * dx + dy * dy <= r * r
    return True


def make_app_icon():
    pixels = [[(0, 0, 0, 0) for _ in range(SIZE)] for _ in range(SIZE)]
    for y in range(SIZE):
        t = y / float(SIZE - 1)
        base = (
            int(10 + (46 - 10) * t),
            int(89 + (130 - 89) * t),
            int(247 + (255 - 247) * t),
            255,
        )
        for x in range(SIZE):
            if inside_round_rect(x, y, 16, 16, 495, 495, 108):
                pixels[y][x] = base

    # three drive bays
    for idx, top in enumerate((150, 226, 302)):
        bottom = top + 60
        for y in range(top, bottom):
            for x in range(118, 394):
                if inside_round_rect(x, y, 118, top, 393, bottom - 1, 14):
                    pixels[y][x] = (255, 255, 255, 255)
        # status leds
        for cx in (150, 174):
            for dy in range(-7, 8):
                for dx in range(-7, 8):
                    if dx * dx + dy * dy <= 49:
                        pixels[top + 30 + dy][cx + dx] = (49, 183, 115, 255) if idx < 2 else (245, 166, 35, 255)
        # vent lines
        for vy in (top + 16, top + 30, top + 44):
            for vx in range(220, 360):
                pixels[vy][vx] = (214, 228, 255, 255)
    return pixels


def write_png(path, pixels):
    raw = bytearray()
    for row in pixels:
        raw.append(0)
        for r, g, b, a in row:
            raw.extend(struct.pack('4B', r, g, b, a))

    def chunk(tag, data):
        body = tag + data
        return struct.pack('>I', len(data)) + body + struct.pack('>I', zlib.crc32(body) & 0xffffffff)

    ihdr = struct.pack('>IIBBBBB', SIZE, SIZE, 8, 6, 0, 0, 0)
    png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', ihdr) + chunk(b'IDAT', zlib.compress(bytes(raw), 9)) + chunk(b'IEND', b'')
    with open(path, 'wb') as f:
        f.write(png)


HEADER = ('<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" '
          'fill="none" stroke="#5A5F6A" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">')
FOOTER = '</svg>'

ICONS = {
    'ic_home': '<path d="M3 10.4 12 3l9 7.4V20a1 1 0 0 1-1 1h-5v-7H9v7H4a1 1 0 0 1-1-1z"/>',
    'ic_folder': '<path d="M3 6.5A2.5 2.5 0 0 1 5.5 4H9l2 2.5h7.5A2.5 2.5 0 0 1 21 9v9.5a2.5 2.5 0 0 1-2.5 2.5h-13A2.5 2.5 0 0 1 3 18.5z"/>',
    'ic_folder_add': '<path d="M3 6.5A2.5 2.5 0 0 1 5.5 4H9l2 2.5h7.5A2.5 2.5 0 0 1 21 9v9.5a2.5 2.5 0 0 1-2.5 2.5h-13A2.5 2.5 0 0 1 3 18.5z"/><path d="M12 11v6M9 14h6"/>',
    'ic_storage': '<rect x="3" y="4" width="18" height="6" rx="2"/><rect x="3" y="14" width="18" height="6" rx="2"/><path d="M7 7h.01M7 17h.01M11 7h6M11 17h6"/>',
    'ic_docker': '<rect x="3" y="9" width="4" height="4" rx="1"/><rect x="8" y="9" width="4" height="4" rx="1"/><rect x="13" y="9" width="4" height="4" rx="1"/><rect x="8" y="4" width="4" height="4" rx="1"/><rect x="3" y="14" width="14" height="6" rx="2"/><path d="M20 15c1.6.4 2.5 1.5 2.5 3s-1 2.5-2.5 2.5"/>',
    'ic_person': '<circle cx="12" cy="8" r="4"/><path d="M4 21c0-4 3.6-6.5 8-6.5s8 2.5 8 6.5"/>',
    'ic_settings': '<circle cx="12" cy="12" r="3.2"/><path d="M19.4 15a1.7 1.7 0 0 0 .34 1.87l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06A1.7 1.7 0 0 0 15 19.4a1.7 1.7 0 0 0-1 1.56V21a2 2 0 1 1-4 0v-.09A1.7 1.7 0 0 0 9 19.4a1.7 1.7 0 0 0-1.87.34l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06A1.7 1.7 0 0 0 4.6 15a1.7 1.7 0 0 0-1.56-1H3a2 2 0 1 1 0-4h.09A1.7 1.7 0 0 0 4.6 9a1.7 1.7 0 0 0-.34-1.87l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06A1.7 1.7 0 0 0 9 4.6a1.7 1.7 0 0 0 1-1.56V3a2 2 0 1 1 4 0v.09A1.7 1.7 0 0 0 15 4.6a1.7 1.7 0 0 0 1.87-.34l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06A1.7 1.7 0 0 0 19.4 9v.09a1.7 1.7 0 0 0 1.56 1H21a2 2 0 1 1 0 4h-.09A1.7 1.7 0 0 0 19.4 15z"/>',
    'ic_search': '<circle cx="11" cy="11" r="7"/><path d="m20 20-4-4"/>',
    'ic_refresh': '<path d="M20 11a8 8 0 1 0-2.3 6.3"/><path d="M20 4v7h-7"/>',
    'ic_add': '<path d="M12 5v14M5 12h14"/>',
    'ic_more': '<circle cx="5" cy="12" r="1.4"/><circle cx="12" cy="12" r="1.4"/><circle cx="19" cy="12" r="1.4"/>',
    'ic_chevron': '<path d="m9 5 7 7-7 7"/>',
    'ic_chevron_left': '<path d="m15 5-7 7 7 7"/>',
    'ic_warning': '<path d="M10.3 3.6 2.5 17.2A2 2 0 0 0 4.2 20h15.6a2 2 0 0 0 1.7-2.8L13.7 3.6a2 2 0 0 0-3.4 0z"/><path d="M12 9v4M12 17h.01"/>',
    'ic_wifi_off': '<path d="M2 2 22 22"/><path d="M8.5 15.5a5 5 0 0 1 7 0M5 12a10 10 0 0 1 3.5-2.3M2 8.5A15 15 0 0 1 6 6.3M12 20h.01"/><path d="M16.5 12.6A10 10 0 0 1 19 12M19.5 8.9A15 15 0 0 0 17 7.6"/>',
    'ic_lock': '<rect x="4" y="10" width="16" height="11" rx="2"/><path d="M8 10V7a4 4 0 0 1 8 0v3M12 15v2"/>',
    'ic_empty_box': '<path d="M3 8 12 4l9 4-9 4z"/><path d="M3 8v9l9 4 9-4V8M12 12v9"/><path d="M8 5.5 17 9.5"/>',
    'ic_logout': '<path d="M10 4H6a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h4"/><path d="M15 8l4 4-4 4M19 12H9"/>',
    'ic_language': '<circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3c2.5 2.6 3.8 5.7 3.8 9s-1.3 6.4-3.8 9c-2.5-2.6-3.8-5.7-3.8-9S9.5 5.6 12 3z"/>',
    'ic_bell': '<path d="M18 8a6 6 0 1 0-12 0c0 7-3 8-3 8h18s-3-1-3-8"/><path d="M10 21h4"/>',
    'ic_info': '<circle cx="12" cy="12" r="9"/><path d="M12 11v5M12 8h.01"/>',
    'ic_play': '<path d="M8 5.5 19 12 8 18.5z"/>',
    'ic_stop': '<rect x="6" y="6" width="12" height="12" rx="2"/>',
    'ic_trash': '<path d="M4 7h16M9 7V4h6v3M6 7l1 13h10l1-13M10 11v6M14 11v6"/>',
    'ic_upload': '<path d="M12 16V4M7 9l5-5 5 5"/><path d="M4 16v3a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-3"/>',
    'ic_download': '<path d="M12 4v12M7 11l5 5 5-5"/><path d="M4 18v1a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-1"/>',
    'ic_grid': '<rect x="3" y="3" width="7" height="7" rx="1.5"/><rect x="14" y="3" width="7" height="7" rx="1.5"/><rect x="3" y="14" width="7" height="7" rx="1.5"/><rect x="14" y="14" width="7" height="7" rx="1.5"/>',
    'ic_list': '<path d="M8 6h13M8 12h13M8 18h13M3.5 6h.01M3.5 12h.01M3.5 18h.01"/>',
    'ic_sort': '<path d="M4 6h16M7 12h10M10 18h4"/>',
    'ic_copy': '<rect x="8" y="8" width="12" height="12" rx="2"/><path d="M16 8V6a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h2"/>',
    'ic_edit': '<path d="M4 20h4l11-11a2.8 2.8 0 0 0-4-4L4 16z"/><path d="M13.5 6.5 17.5 10.5"/>',
    'ic_share': '<circle cx="18" cy="5" r="2.5"/><circle cx="6" cy="12" r="2.5"/><circle cx="18" cy="19" r="2.5"/><path d="m8.2 10.8 7.6-4.4M8.2 13.2l7.6 4.4"/>',
    'ic_cpu': '<rect x="6" y="6" width="12" height="12" rx="2"/><rect x="9.5" y="9.5" width="5" height="5" rx="1"/><path d="M9 2v4M15 2v4M9 18v4M15 18v4M2 9h4M2 15h4M18 9h4M18 15h4"/>',
    'ic_temp': '<path d="M10 14V5a2 2 0 1 1 4 0v9a4 4 0 1 1-4 0z"/><path d="M12 11v5"/>',
    'ic_network': '<circle cx="12" cy="12" r="2"/><path d="M5.5 8.5a8 8 0 0 0 0 7M18.5 8.5a8 8 0 0 1 0 7M2.5 5.5a12 12 0 0 0 0 13M21.5 5.5a12 12 0 0 1 0 13"/>',
    'ic_shield': '<path d="M12 3 4 6v6c0 5 3.4 8 8 9 4.6-1 8-4 8-9V6z"/><path d="m9 12 2 2 4-4"/>',
    'ic_check': '<path d="m4 12 5 5L20 6"/>',
    'ic_close': '<path d="M6 6l12 12M18 6 6 18"/>',
    'ic_layers': '<path d="M12 3 3 8l9 5 9-5z"/><path d="m3 13 9 5 9-5M3 17.5l9 5 9-5"/>',
    'ic_monitor': '<rect x="3" y="4" width="18" height="13" rx="2"/><path d="M8 21h8M12 17v4"/><path d="m7 12 2.5-3 2.5 2 2-3.5L17 12"/>',
    'ic_clock': '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3.5 2"/>',
    'ic_cloud': '<path d="M6.5 19a4.5 4.5 0 0 1-.4-9A6 6 0 0 1 18 10.5a4 4 0 0 1-.5 8.5z"/>',
    'ic_file': '<path d="M6 3h8l4 4v14H6z"/><path d="M14 3v5h4M9 13h6M9 17h6"/>',
    'ic_image': '<rect x="3" y="4" width="18" height="16" rx="2"/><circle cx="8.5" cy="9" r="1.5"/><path d="m4 17 5-5 4 4 3-3 4 4"/>',
    'ic_arrow_right': '<path d="M4 12h16M14 6l6 6-6 6"/>',
    'ic_eye': '<path d="M2 12s3.6-6 10-6 10 6 10 6-3.6 6-10 6-10-6-10-6z"/><circle cx="12" cy="12" r="2.5"/>',
    'ic_eye_off': '<path d="M2 2 22 22"/><path d="M9.5 5.4A11 11 0 0 1 12 5c6.4 0 10 6 10 6a17 17 0 0 1-3 3.5M6.3 6.8C3.5 8.6 2 11 2 11s3.6 6 10 6a11 11 0 0 0 3.2-.5"/>',
}


def main():
    for d in MEDIA_DIRS:
        os.makedirs(d, exist_ok=True)
        write_png(os.path.join(d, 'app_icon.png'), make_app_icon())
        for name, body in ICONS.items():
            with open(os.path.join(d, name + '.svg'), 'w', encoding='utf-8') as f:
                f.write(HEADER + body + FOOTER + '\n')
    print('app_icon.png x %d, %d icons x %d = %d files' % (
        len(MEDIA_DIRS), len(ICONS), len(MEDIA_DIRS), len(MEDIA_DIRS) * (1 + len(ICONS))))


if __name__ == '__main__':
    main()
