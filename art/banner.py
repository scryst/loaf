"""The README banner: the cat's clips, in an order the app can play them, pulled through a line
screen in GitHub's blues with one accent, the way the scryst profile banner is printed. The page shows through
wherever there is no ink, so it sits on GitHub's own background in either theme.

Run: uv run --with pillow --with numpy --with scipy python art/banner.py docs [--clips idle_a,blink]
"""
import os, subprocess, sys
import numpy as np
from PIL import Image
from scipy import ndimage

HERE = os.path.dirname(os.path.abspath(__file__))
CLIPS = os.path.join(HERE, '..', 'loaf')
W, H = 1280, 480
PHONE = (285, 995)                   # what a phone shows: the cat, edge to edge
STEP = 3                             # every 3rd frame of the 24 fps clips: 8 fps
# a day in clips the card loop below does not use, so the page between them shows most of the film: awake looks,
# settling, sleeping, and waking (each clip starts on the pose the last one ended on, so the loop has no seam)
ORDER = ['earflick', 'lookaround', 'tilt', 'settle', 'sleep_idle', 'sleepear', 'wake']
THEMES = {
    'dark': dict(clip='dark', inks=[(31, 111, 235), (121, 192, 255), (240, 246, 252)], accent=(247, 120, 186)),
    'light': dict(clip='light', inks=[(84, 174, 255), (9, 105, 218), (10, 48, 105)], accent=(191, 57, 137)),
}
CAT = (W - 690) // 2, 10, 690, 460   # where the 3:2 film sits in the banner


def frames(name, theme):
    path = os.path.join(CLIPS, f"{THEMES[theme]['clip']}-{name}.mp4")
    raw = subprocess.run(['ffmpeg', '-v', 'error', '-i', path, '-vf', f'scale={CAT[2]}:{CAT[3]}:flags=lanczos',
                          '-pix_fmt', 'rgb24', '-f', 'rawvideo', '-'], check=True, capture_output=True).stdout
    return np.frombuffer(raw, np.uint8).reshape(-1, CAT[3], CAT[2], 3)[::STEP]


def screens(seed=11):
    """Static line screens (a 3 px triangle with a little ranked noise), one per ink and one for the accent."""
    g = np.random.default_rng(seed)
    yy = np.arange(H)[:, None] + 0 * np.arange(W)[None, :]
    tri = np.abs(((yy / 3.0) % 1.0) * 2 - 1)
    out = []
    for _ in range(4):
        n = ndimage.gaussian_filter(g.random((H, W)), .5)
        r = np.empty(n.size); r[np.argsort(n, axis=None)] = np.arange(n.size) / n.size
        out.append(.80 * tri + .20 * r.reshape(H, W))
    return out


def tones(rgb):
    """Ink (0 paper .. 1 the darkest stroke) and accent (the deepest, most saturated orange: eyes and stripes)."""
    f = rgb.astype(np.float32) / 255
    lum = f @ np.array([.299, .587, .114], np.float32)
    paper = np.percentile(lum, 92)                        # the film's paper, whatever its grain
    ink = np.clip((paper - .05 - lum) / (paper - .23), 0, 1)        # .05 below the paper: its grain prints nothing
    ink = ndimage.gaussian_filter(ink, .7)
    sat = f.max(-1) - f.min(-1)
    acc = np.clip((sat - .55) / .3, 0, 1) * np.clip((.62 - lum) / .3, 0, 1)
    T = np.zeros((H, W), np.float32); A = np.zeros((H, W), np.float32)
    x, y, w, h = CAT
    T[y:y + h, x:x + w] = ink ** .85
    A[y:y + h, x:x + w] = acc
    return T, A


def pull(T, A, s):
    idx = np.zeros((H, W), np.uint8)
    idx[T > .05 + .22 * s[0]] = 1
    idx[T > .30 + .36 * s[1]] = 2
    idx[T > .66 + .45 * s[2]] = 3
    idx[A > .10 + .95 * s[3]] = 4
    return idx


def rgba(idx, theme):
    c = THEMES[theme]
    pal = np.array([(0, 0, 0)] + c['inks'] + [c['accent']], np.uint8)
    return Image.fromarray(np.dstack([pal[idx], np.where(idx > 0, 255, 0).astype(np.uint8)]), 'RGBA')


def steady(tone_frames, keep=.05):
    """Hold each pixel's tone until it moves by more than `keep`: the film's grain shifts every pixel a little every
    frame, which would redraw the whole cat each frame (about 26 KB a frame); held, only the moving parts redraw."""
    held = None
    for T, A in tone_frames:
        if held is None: held = [T.copy(), A.copy()]
        else:
            # redraw only where the ink moves together (a blink, an ear, a breath), not single grains of the print
            m = ndimage.gaussian_filter(np.abs(T - held[0]), 2.5) > keep
            for h, x in zip(held, (T, A)): h[m] = x[m]
        yield held[0], held[1]


def main(out, clips=ORDER):
    s = screens()
    for theme in THEMES:
        idxs = [pull(T, A, s) for T, A in steady(tones(f) for name in clips for f in frames(name, theme))]
        full = [rgba(i, theme) for i in idxs]
        for name, ims in ((f'banner-{theme}.webp', full), (f'banner-phone-{theme}.webp', [im.crop((PHONE[0], 0, PHONE[1], H)) for im in full])):
            path = os.path.join(out, name)
            ims[0].save(path, save_all=True, append_images=ims[1:], duration=round(1000 * STEP / 24), loop=0,
                        lossless=True, method=4, minimize_size=True)
            print(f"{name}: {len(ims)} frames, {os.path.getsize(path):,} bytes")


if __name__ == '__main__':
    args = sys.argv[1:]
    clips = ORDER
    if '--clips' in args:
        i = args.index('--clips'); clips = args[i + 1].split(','); del args[i:i + 2]
    main(args[0], clips)
