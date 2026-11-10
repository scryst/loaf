"""The README's loop: the real card, rendered by `LOAF_RENDER`, with the real clips playing in its print, through
every state in the order the app moves through them. Agents working, agents finished, settling into sleep, asleep,
and waking when an agent starts again (the wake clip ends where the first clip begins, so the loop has no seam).

Run: LOAF_RENDER=<dir> Loaf (with the poster PNGs in <dir>), then
     uv run --with pillow --with numpy python art/readme_loop.py <dir> docs
"""
import os, subprocess, sys
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
CLIPS = os.path.join(HERE, '..', 'loaf')
CAT = (16, 16, 568, 379)        # the print inside a 2x panel render: 8 pt inset, 284 x 189.3 pt
CAT_R, CARD_R = 20, 28          # corner radii at 2x (10 pt and the card's 14 pt)
PAD = 40                        # room for the card's shadow
STEP = 2                        # every 2nd frame of the 24 fps clips: 12 fps
SCALE = 0.75                    # 2x renders shown at 1.5x
SEQUENCE = [('awake', 'idle_a'), ('winding', 'blink'),
            ('asleep', 'settle'), ('asleep', 'sleeptail'), ('awake', 'wake')]
FADE = 4                        # frames to cross-fade the card when its state changes


def rounded(size, r):
    m = Image.new('L', size, 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, size[0] - 1, size[1] - 1), r, fill=255)
    return m


def clip_frames(name, dark):
    path = os.path.join(CLIPS, f"{'dark' if dark else 'light'}-{name}.mp4")
    raw = subprocess.run(['ffmpeg', '-v', 'error', '-i', path, '-pix_fmt', 'rgb24', '-f', 'rawvideo', '-'],
                         check=True, capture_output=True).stdout
    frames = np.frombuffer(raw, np.uint8).reshape(-1, 400, 600, 3)
    return [Image.fromarray(f).resize(CAT[2:], Image.LANCZOS) for f in frames[::STEP]]


def card(panel, frame):
    c = panel.copy()
    c.paste(frame, CAT[:2], rounded(CAT[2:], CAT_R))
    out = c.convert('RGBA')
    out.putalpha(rounded(c.size, CARD_R))
    return out


def main(render_dir, out_dir):
    for dark in (False, True):
        panels = {}
        for state in {s for s, _ in SEQUENCE}:
            p = Image.open(os.path.join(render_dir, f"panel-{state}-{'dark' if dark else 'light'}.png")).convert('RGB')
            p.paste(p.crop((0, 1, p.width, 2)), (0, 0))   # the render's top row is the window edge, not the card
            panels[state] = p
        w = max(p.width for p in panels.values()) + 2 * PAD
        h = max(p.height for p in panels.values()) + 2 * PAD
        shadow_alpha = 110 if dark else 46
        cards = []
        for state, clip in SEQUENCE:
            cards += [(state, card(panels[state], f)) for f in clip_frames(clip, dark)]
        frames, prev, fade_from, fade_left = [], None, None, 0
        for i, (state, c) in enumerate(cards):
            img = Image.new('RGBA', (w, h), (0, 0, 0, 0))
            sh = Image.new('RGBA', (w, h), (0, 0, 0, 0))
            sh.paste((0, 0, 0, shadow_alpha), (PAD, PAD + 10), c.getchannel('A'))
            img.alpha_composite(sh.filter(ImageFilter.GaussianBlur(18)))
            layer = Image.new('RGBA', (w, h), (0, 0, 0, 0)); layer.paste(c, (PAD, PAD))
            if prev is not None and prev[0] != state:      # the state just changed: fade from the last card over FADE frames
                fade_from, fade_left = prev[1], FADE
            if fade_left > 0:
                layer = Image.blend(fade_from, layer, 1 - fade_left / (FADE + 1)); fade_left -= 1
            img.alpha_composite(layer)
            frames.append(img.resize((round(w * SCALE), round(h * SCALE)), Image.LANCZOS))
            prev = (state, layer)
        out = os.path.join(out_dir, f"loaf-{'dark' if dark else 'light'}.webp")
        frames[0].save(out, save_all=True, append_images=frames[1:], duration=round(1000 * STEP / 24), loop=0,
                       quality=40, method=6, minimize_size=True, allow_mixed=True)
        print(f"{out}: {len(frames)} frames, {frames[0].size[0]}x{frames[0].size[1]}, {os.path.getsize(out):,} bytes")


if __name__ == '__main__':
    main(*sys.argv[1:3])
