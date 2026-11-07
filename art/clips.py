"""Cut the cat film into the short clips the app strings together.

Every awake clip starts on the same awake frame (the "hub") and eases back to it, every sleep clip does the same
on the sleep hub, so the app can play them in any order with no jump. Settle runs awake -> asleep, wake the reverse.
The yawn is left out: its open mouth reads as a snarl at panel size.
Run: uv run --with numpy python art/clips.py <cat.mp4> <cat-dark.mp4>
"""
import os, subprocess, sys
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, '..', 'loaf')
W, H = 600, 400                                    # 300 pt panel at 2x
CROP = 'crop=900:600:190:60'                       # the cat with a little paper round it, 3:2
STARTS = dict(idle_a=0, blink=73, idle_b=141, earflick=209, lookaround=277, idle_c=369, tilt=437, squint=505,
              yawn=573, settle=665, sleep_idle=781, sleepear=849, sleeptail=917, wake=985, end=1077)
AWAKE_HUB, SLEEP_HUB = 0, 781
EASE = 6                                           # frames spent easing out of and back into the hub
CLIPS = {                                          # name: (start hub, end hub)
    'idle_a': ('a', 'a'), 'blink': ('a', 'a'), 'idle_b': ('a', 'a'), 'earflick': ('a', 'a'),
    'lookaround': ('a', 'a'), 'idle_c': ('a', 'a'), 'tilt': ('a', 'a'), 'squint': ('a', 'a'),
    'settle': ('a', 's'), 'sleep_idle': ('s', 's'), 'sleepear': ('s', 's'), 'sleeptail': ('s', 's'), 'wake': ('s', 'a'),
}

def frames(path):
    raw = subprocess.run(['ffmpeg', '-v', 'error', '-i', path, '-vf', f'{CROP},scale={W}:{H}:flags=lanczos',
                          '-pix_fmt', 'rgb24', '-f', 'rawvideo', '-'], check=True, capture_output=True).stdout
    return np.frombuffer(raw, np.uint8).reshape(-1, H, W, 3)

def clip(film, name):
    names = list(STARTS)
    s, e = STARTS[name], STARTS[names[names.index(name) + 1]]
    hub = {'a': film[AWAKE_HUB], 's': film[SLEEP_HUB]}
    first, last = (hub[k].astype(np.float32) for k in CLIPS[name])
    out = film[s:e].astype(np.float32)
    n = len(out)
    for i in range(EASE + 1):                      # frame 0 is the hub itself; the next clip's frame 0 closes the loop
        w = (EASE + 1 - i) / (EASE + 1)
        out[i] = w * first + (1 - w) * out[i]
        j = n - 1 - i
        w = (EASE + 1 - i) / (EASE + 2)
        out[j] = w * last + (1 - w) * out[j]
    return np.clip(out.round(), 0, 255).astype(np.uint8)

def encode(rgb, path):
    p = subprocess.Popen(['ffmpeg', '-v', 'error', '-y', '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-s', f'{W}x{H}', '-r', '24',
                          '-i', '-', '-c:v', 'libx265', '-preset', 'slow', '-tag:v', 'hvc1',
                          # constant quantiser: every clip's opening hub frame decodes to the same pixels, so joins don't shimmer
                          '-x265-params', 'log-level=error:qp=16:aq-mode=0:no-cutree=1', '-pix_fmt', 'yuv420p',
                          '-vf', 'scale=out_color_matrix=bt709:out_range=tv', '-color_primaries', 'bt709',
                          '-color_trc', 'bt709', '-colorspace', 'bt709', '-movflags', '+faststart', path],
                         stdin=subprocess.PIPE)
    p.stdin.write(rgb.tobytes()); p.stdin.close()
    assert p.wait() == 0, path

def main(light, dark):
    for theme, src in (('light', light), ('dark', dark)):
        film = frames(src)
        assert len(film) == STARTS['end'], len(film)
        for name in CLIPS:
            encode(clip(film, name), os.path.join(OUT, f'{theme}-{name}.mp4'))
        print(theme, 'done')

if __name__ == '__main__':
    main(*sys.argv[1:3])
