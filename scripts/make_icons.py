import os, glob
from PIL import Image, ImageDraw

RES = 'android/app/src/main/res'
LEGACY = {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192}
FORE = {'mdpi': 108, 'hdpi': 162, 'xhdpi': 216, 'xxhdpi': 324, 'xxxhdpi': 432}


from PIL import ImageFilter, ImageOps

ARMS = [([(104, 116), (200, 116), (306, 388), (216, 388)], (67, 214, 255), (58, 61, 240)),
        ([(312, 116), (408, 116), (300, 388), (210, 388)], (127, 91, 255), (240, 70, 200)),
        ([(257, 262), (210, 388), (306, 388)], (43, 47, 184), (138, 47, 208))]


def ribbon(n, k=1.0, white=False):
    """The V Text ribbon-V logo on a transparent square (white=True gives a flat white silhouette)."""
    S = 4
    N = n * S
    im = Image.new('RGBA', (N, N), (0, 0, 0, 0))
    f = N / 512 * k
    c = N / 2
    for pts, c1, c2 in ARMS:
        P = [(c + (x - 256) * f, c + (y - 252) * f) for x, y in pts]
        m = Image.new('L', (N, N), 0)
        ImageDraw.Draw(m).polygon(P, fill=255)
        if white:
            im.paste((255, 255, 255, 255), (0, 0), m)
            continue
        x0, y0 = int(min(p[0] for p in P)), int(min(p[1] for p in P))
        x1, y1 = int(max(p[0] for p in P)) + 1, int(max(p[1] for p in P)) + 1
        g = ImageOps.colorize(Image.linear_gradient('L').resize((x1 - x0, y1 - y0)), c1, c2).convert('RGBA')
        im.paste(g, (x0, y0), m.crop((x0, y0, x1, y1)))
    return im.resize((n, n), Image.LANCZOS)


def backdrop(n):
    big = n * 2
    im = Image.new('RGBA', (big, big), (5, 6, 11, 255))
    glow = Image.new('RGBA', (big, big), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse([big * .12, big * .12, big * .88, big * .88], fill=(109, 61, 245, 110))
    im.alpha_composite(glow.filter(ImageFilter.GaussianBlur(big * .1)))
    return im.resize((n, n), Image.LANCZOS)


def legacy(n, round_):
    big = n * 4
    im = backdrop(big)
    im.alpha_composite(ribbon(big, 0.95))
    mask = Image.new('L', (big, big), 0)
    md = ImageDraw.Draw(mask)
    if round_:
        md.ellipse([0, 0, big - 1, big - 1], fill=255)
    else:
        md.rounded_rectangle([0, 0, big - 1, big - 1], radius=int(big * 0.22), fill=255)
    im.putalpha(mask)
    return im.resize((n, n), Image.LANCZOS)


def foreground(n):
    return ribbon(n, 0.85)


for d, n in LEGACY.items():
    folder = os.path.join(RES, 'mipmap-' + d)
    os.makedirs(folder, exist_ok=True)
    for f in glob.glob(os.path.join(folder, 'ic_launcher*.webp')):
        os.remove(f)
    legacy(n, False).save(os.path.join(folder, 'ic_launcher.png'))
    legacy(n, True).save(os.path.join(folder, 'ic_launcher_round.png'))
    foreground(FORE[d]).save(os.path.join(folder, 'ic_launcher_foreground.png'))

os.makedirs(os.path.join(RES, 'values'), exist_ok=True)
open(os.path.join(RES, 'values', 'ic_launcher_background.xml'), 'w').write(
    '<?xml version="1.0" encoding="utf-8"?>\n<resources>\n    <color name="ic_launcher_background">#05060B</color>\n</resources>\n')
print('launcher icons written')

import wave, math
os.makedirs(os.path.join(RES, 'raw'), exist_ok=True)
SR = 22050
buf = [0.0] * int(SR * 0.7)
for f, start in ((880, 0.0), (1318, 0.14)):
    for i in range(int(SR * 0.45)):
        t = i / SR
        env = min(1.0, t / 0.015) * math.exp(-7 * t)
        j = int((start + t) * SR)
        if j < len(buf):
            buf[j] += 0.45 * env * math.sin(2 * math.pi * f * t)
with wave.open(os.path.join(RES, 'raw', 'vtext_msg.wav'), 'wb') as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
    w.writeframes(b''.join(int(max(-1, min(1, x)) * 32000).to_bytes(2, 'little', signed=True) for x in buf))
print('notification sound written')

# ---- status-bar (notification) icon: white chat bubble with a transparent V ----
STAT = {'mdpi': 24, 'hdpi': 36, 'xhdpi': 48, 'xxhdpi': 72, 'xxxhdpi': 96}
for d, n in STAT.items():
    folder = os.path.join(RES, 'drawable-' + d)
    os.makedirs(folder, exist_ok=True)
    ribbon(n * 4, 1.12, white=True).resize((n, n), Image.LANCZOS).save(os.path.join(folder, 'ic_stat_vtext.png'))
print('status-bar icons written')

# ---- launch (splash) screens: near-black background with the ribbon-V in the middle ----
sp = sorted(set(glob.glob(os.path.join(RES, '**', 'splash*.png'), recursive=True)))
for fp in sp:
    try:
        w, h = Image.open(fp).size
    except Exception:
        w, h = 480, 320
    m = min(w, h)
    bg = Image.new('RGBA', (w, h), (5, 6, 11, 255))
    glow = Image.new('RGBA', (w, h), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse([w / 2 - m * .38, h / 2 - m * .38, w / 2 + m * .38, h / 2 + m * .38], fill=(109, 61, 245, 100))
    bg.alpha_composite(glow.filter(ImageFilter.GaussianBlur(m * .09)))
    n = int(m * 0.46)
    bg.alpha_composite(ribbon(n, 1.0), (w // 2 - n // 2, h // 2 - n // 2))
    bg.convert('RGB').save(fp)
print('splash screens written (%d)' % len(sp))
