"""Menu-bar and app icons from the mark (art/source/mark.png, a side-profile loaf).
One cat, never swapped: solid means the Mac is kept awake (working or winding down), the same silhouette
traced as an even hollow line means asleep. No drawn eyes. Run: python3 art/icons.py"""
import os, subprocess, tempfile
from PIL import Image, ImageChops, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, '..', 'loaf')
INK, PAPER = (59, 34, 22), (241, 236, 224)

def silhouette(name='mark.png'):             # (mark as drawn, mark with its inner holes filled)
    g = Image.open(os.path.join(HERE, 'source', name)).convert('L')
    m = g.point(lambda v: 255 if v < 128 else 0).transpose(Image.FLIP_LEFT_RIGHT)   # faces left, like the panel cat
    m = m.crop(m.getbbox())
    p = Image.new('L', (m.width + 2, m.height + 2), 0); p.paste(m, (1, 1)); ImageDraw.floodfill(p, (0, 0), 128)
    return m, p.point(lambda v: 0 if v == 128 else 255).crop((1, 1, m.width + 1, m.height + 1))

def menu(mark, h=48, padv=3, width=None):       # @3x of a 16 pt tall template image, centered in a fixed width
    s = (h - 2 * padv) / mark.height
    r = mark.resize((round(mark.width * s), h - 2 * padv), Image.LANCZOS)
    w = width or r.width + 2
    a = Image.new('L', (w, h), 0); a.paste(r, ((w - r.width) // 2, padv))
    o = Image.new('RGBA', a.size, (0, 0, 0, 255)); o.putalpha(a); return o

def grow(m, r):                                 # round dilation (r > 0) or erosion (r < 0) by about |r| px
    b = m.filter(ImageFilter.GaussianBlur(abs(r) / 2))
    return b.point(lambda v: 255 if (v > 6 if r > 0 else v > 249) else 0)

def largest(mask):                              # the biggest connected blob of a mask
    lab = mask.copy(); px = lab.load(); n = 0
    for y in range(0, lab.height, 2):
        for x in range(0, lab.width, 2):
            if px[x, y] == 255 and n < 250:
                n += 1; ImageDraw.floodfill(lab, (x, y), n)
    hist = lab.histogram(); best = max(range(1, n + 1), key=lambda i: hist[i]) if n else 0
    return lab.point(lambda v: 255 if best and v == best else 0)

def hollow(filled, px, stroke=3.0, tail=0.4):  # the same silhouette traced as an even line; px = source px per output px
    P = round(12 * px); big = Image.new('L', (filled.width + 2 * P, filled.height + 2 * P), 0); big.paste(filled, (P, P))
    groove = largest(ImageChops.subtract(grow(grow(big, 1.5 * px), -1.5 * px), big))   # only the tail groove, so ears and chin stay sharp
    body = ImageChops.lighter(big, groove)
    ring = ImageChops.subtract(body, grow(body, -stroke * px))
    line = ImageChops.lighter(ring, ImageChops.multiply(grow(groove, tail * px), body))
    return line.crop((P, P, P + filled.width, P + filled.height))

def app_icon(mark, size=1024, inset=100, radius=185):
    body = Image.new('RGBA', (size - 2 * inset,) * 2, INK + (255,))   # light cat on dark, as on the menu bar
    mark = mark.crop(mark.getbbox())   # center the cat itself, not its padding
    w = int(body.width * 0.74); mk = mark.resize((w, round(mark.height * w / mark.width)), Image.LANCZOS)
    body.paste(Image.new('RGBA', mk.size, PAPER + (255,)), ((body.width - w) // 2, (body.height - mk.height) // 2), mk)
    mask = Image.new('L', body.size, 0); ImageDraw.Draw(mask).rounded_rectangle((0, 0, *body.size), radius, fill=255)
    icon = Image.new('RGBA', (size, size), (0, 0, 0, 0)); shadow = icon.copy()
    ImageDraw.Draw(shadow).rounded_rectangle((inset, inset + 12, size - inset, size - inset + 12), radius, fill=(40, 20, 10, 90))
    icon = Image.alpha_composite(icon, shadow.filter(ImageFilter.GaussianBlur(18)))
    icon.paste(body, (inset, inset), mask); return icon

def write_icns(icon, path):
    with tempfile.TemporaryDirectory() as t:
        iset = os.path.join(t, 'AppIcon.iconset'); os.makedirs(iset)
        for s in (16, 32, 128, 256, 512):
            icon.resize((s, s), Image.LANCZOS).save(f'{iset}/icon_{s}x{s}.png')
            icon.resize((2 * s, 2 * s), Image.LANCZOS).save(f'{iset}/icon_{s}x{s}@2x.png')
        subprocess.check_call(['iconutil', '-c', 'icns', iset, '-o', path])

if __name__ == '__main__':
    m, loaf = silhouette()
    awake = menu(loaf)
    asleep = menu(hollow(loaf, loaf.height / (awake.height - 6)))
    for k, im in (('awake', awake), ('asleep', asleep)):
        im.save(os.path.join(OUT, f'menu-{k}.png'))
    icon = app_icon(loaf)                      # same eyeless mark as the menu bar
    icon.save(os.path.join(HERE, 'AppIcon.png')); write_icns(icon, os.path.join(HERE, 'AppIcon.icns'))
