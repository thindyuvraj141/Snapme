import os, glob, re
from PIL import Image, ImageDraw

RES = 'android/app/src/main/res'
LEGACY = {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192}
FORE = {'mdpi': 108, 'hdpi': 162, 'xhdpi': 216, 'xxhdpi': 324, 'xxxhdpi': 432}


from PIL import ImageFilter, ImageOps

# The Snapme "S": one glowing tube drawn along an S-shaped line (light violet at the top, purple in the middle, green at the bottom).
S_D = 'M340 160C330 125 295 108 256 108C205 108 168 135 168 178C168 222 205 238 256 252C310 266 346 284 346 334C346 380 306 404 256 404C212 404 175 384 164 346'


def _s_points():
    nums = [float(x) for x in re.findall(r'-?\d+(?:\.\d+)?', S_D)]
    cur = (nums[0], nums[1]); pts = [cur]; i = 2
    while i + 5 < len(nums) + 0 and i + 6 <= len(nums):
        p1 = (nums[i], nums[i + 1]); p2 = (nums[i + 2], nums[i + 3]); p3 = (nums[i + 4], nums[i + 5]); i += 6
        for k in range(1, 25):
            t = k / 24; u = 1 - t
            pts.append((u ** 3 * cur[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t ** 3 * p3[0],
                        u ** 3 * cur[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t ** 3 * p3[1]))
        cur = p3
    return pts


NEON = _s_points()
CYAN, VIOLET, MAGENTA = (216, 180, 254), (168, 85, 247), (74, 222, 128)   # names kept: top colour, middle colour, bottom colour


def ribbon(n, k=1.0, white=False):
    """The Snapme neon-S logo on a transparent square (white=True gives a flat white silhouette for the status bar)."""
    S = 3
    N = n * S
    f = N / 512 * k
    c = N / 2
    P = [(c + (x - 256) * f, c + (y - 256) * f) for x, y in NEON]

    def stroke(width):
        m = Image.new('L', (N, N), 0)
        d = ImageDraw.Draw(m)
        w = max(1, int(width * f))
        r = w / 2
        for i in range(len(P) - 1):
            a, b = P[i], P[i + 1]
            d.line([a, b], fill=255, width=w)
        for a in P:
            d.ellipse([a[0] - r, a[1] - r, a[0] + r, a[1] + r], fill=255)
        return m

    if white:
        im = Image.new('RGBA', (N, N), (0, 0, 0, 0))
        im.paste((255, 255, 255, 255), (0, 0), stroke(58))
        return im.resize((n, n), Image.LANCZOS)

    y0, y1 = int(min(p[1] for p in P)), int(max(p[1] for p in P)) + 1
    g = Image.new('RGB', (N, N), CYAN)
    ramp = ImageOps.colorize(Image.linear_gradient("L").resize((N, y1 - y0)), CYAN, MAGENTA, mid=VIOLET)
    g.paste(ramp, (0, y0))
    g.paste(Image.new('RGB', (N, N - y1), MAGENTA), (0, y1))
    g = g.convert('RGBA')
    tube = stroke(38)
    core = stroke(7)
    out = Image.new('RGBA', (N, N), (0, 0, 0, 0))
    for blur, amt in ((26, .5), (11, .85)):
        a = tube.filter(ImageFilter.GaussianBlur(blur * f)).point(lambda v, amt=amt: int(min(255, v * amt * 1.6)))
        layer = g.copy(); layer.putalpha(a)
        out.alpha_composite(layer)
    layer = g.copy(); layer.putalpha(tube)
    out.alpha_composite(layer)
    hot = Image.new('RGBA', (N, N), (255, 255, 255, 0))
    hot.putalpha(core.point(lambda v: int(v * .92)))
    out.alpha_composite(hot)
    return out.resize((n, n), Image.LANCZOS)


def backdrop(n):
    big = n * 2
    im = Image.new('RGBA', (big, big), (9, 9, 11, 255))
    glow = Image.new('RGBA', (big, big), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse([big * .12, big * .12, big * .88, big * .88], fill=(168, 85, 247, 90))
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
    '<?xml version="1.0" encoding="utf-8"?>\n<resources>\n    <color name="ic_launcher_background">#09090B</color>\n</resources>\n')
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

# ---- status-bar (notification) icon: white S ----
STAT = {'mdpi': 24, 'hdpi': 36, 'xhdpi': 48, 'xxhdpi': 72, 'xxxhdpi': 96}
for d, n in STAT.items():
    folder = os.path.join(RES, 'drawable-' + d)
    os.makedirs(folder, exist_ok=True)
    ribbon(n * 4, 1.12, white=True).resize((n, n), Image.LANCZOS).save(os.path.join(folder, 'ic_stat_vtext.png'))
print('status-bar icons written')

# ---- launch (splash) screens: near-black background with the S in the middle ----
sp = sorted(set(glob.glob(os.path.join(RES, '**', 'splash*.png'), recursive=True)))
for fp in sp:
    try:
        w, h = Image.open(fp).size
    except Exception:
        w, h = 480, 320
    m = min(w, h)
    bg = Image.new('RGBA', (w, h), (9, 9, 11, 255))
    glow = Image.new('RGBA', (w, h), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse([w / 2 - m * .38, h / 2 - m * .38, w / 2 + m * .38, h / 2 + m * .38], fill=(168, 85, 247, 85))
    bg.alpha_composite(glow.filter(ImageFilter.GaussianBlur(m * .09)))
    n = int(m * 0.46)
    bg.alpha_composite(ribbon(n, 1.0), (w // 2 - n // 2, h // 2 - n // 2))
    bg.convert('RGB').save(fp)
print('splash screens written (%d)' % len(sp))
