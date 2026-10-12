"""
Synthesize lo-fi (22 kHz, 16-bit mono) PS1-style sound effects for the player and
the world, written straight into the Godot project at godot/assets/sfx/.

  footstep_1..5.wav  short grass/dirt steps (random variants)
  jump.wav           soft air whoosh (slow attack, no transient)
  land_soft.wav      landing thud
  land_hard.wav      heavy landing with debris
  slide_loop.wav     gravel slide, seamless loop
  wind_loop.wav      outdoor ambience, seamless loop
  pistol/shotgun/rifle/rocket/plasma.wav   weapon fire
  explosion_small/large.wav, dry_fire.wav, pickup_weapon/ammo.wav, respawn.wav, heal.wav
  eye_alert/charge/fire/hurt/die.wav, player_hurt.wav   enemy and pain sounds

Loop files get a .import that tells Godot to loop them. Run from the repo root:
  python3 tools/generate_sfx.py
"""
import math
import os
import random
import struct
import wave

RATE = 22050
OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "godot", "assets", "sfx")

LOOP_IMPORT = """[remap]

importer="wav"
type="AudioStreamWAV"

[params]

edit/loop_mode=2
edit/loop_begin=0
edit/loop_end=-1
"""


def lowpass(x, a):
    """One-pole lowpass; a in (0, 1], smaller = darker."""
    y, out = 0.0, []
    for s in x:
        y += a * (s - y)
        out.append(y)
    return out


def highpass(x, a):
    return [s - l for s, l in zip(x, lowpass(x, a))]


def noise(n, rng):
    return [rng.uniform(-1, 1) for _ in range(n)]


def env(n, attack, decay):
    """Attack/exponential-decay envelope, times in seconds."""
    a, d = max(1, int(attack * RATE)), decay * RATE
    return [(i / a) if i < a else math.exp(-(i - a) / d) for i in range(n)]


def mix(*tracks):
    n = max(len(t) for t in tracks)
    return [sum(t[i] for t in tracks if i < len(t)) for i in range(n)]


def thud(n, freq, attack, decay):
    """Steady low sine with a soft attack: body without the pitch sweep of a kick drum."""
    e = env(n, attack, decay)
    return [math.sin(2 * math.pi * freq * i / RATE) * e[i] for i in range(n)]


def rustle(n, rng, window, density, a_lo=0.55, a_hi=0.2):
    """Sparse, faint crackle of grass and grit, band-limited to the low-mid range."""
    x = [0.0] * n
    for _ in range(int(density * window)):
        start = int(rng.uniform(0, window) * RATE)
        amp = rng.uniform(0.2, 1.0) * math.exp(-start / (0.05 * RATE))
        for j in range(rng.randint(15, 60)):
            if start + j < n:
                x[start + j] += rng.uniform(-1, 1) * amp * math.exp(-j / 12)
    return highpass(lowpass(x, a_lo), a_hi)


def scuff(n, rng, delay, attack, decay, darkness, gain):
    """Muffled contact: dark filtered noise with a soft (not instant) attack."""
    d = int(delay * RATE)
    body = [s * e * gain for s, e in zip(lowpass(lowpass(noise(n, rng), darkness), darkness), env(n, attack, decay))]
    return ([0.0] * d + body)[:n]


def loopable(x, fade):
    """Crossfade the tail into the head so the sample loops seamlessly."""
    f = int(fade * RATE)
    body = x[:-f]
    for i in range(f):
        t = i / f
        body[i] = body[i] * t + x[len(x) - f + i] * (1 - t)
    return body


def write(name, x, peak=0.9):
    m = max(abs(s) for s in x) or 1.0
    with wave.open(os.path.join(OUT, name), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(b"".join(struct.pack("<h", int(s / m * peak * 32767)) for s in x))


def footstep(seed):
    """Heel then toe on grass/dirt: two soft, dark scuffs plus a faint rustle."""
    rng = random.Random(seed)
    n = int(0.16 * RATE)
    heel = scuff(n, rng, 0.0, rng.uniform(0.006, 0.01), 0.022, 0.16, 1.0)
    toe = scuff(n, rng, rng.uniform(0.045, 0.065), 0.008, 0.02, 0.2, rng.uniform(0.45, 0.65))
    grass = [s * 0.25 for s in rustle(n, rng, 0.09, 120)]
    body = [s * 0.25 for s in thud(n, rng.uniform(85, 110), 0.006, 0.02)]
    return mix(heel, toe, grass, body)


def sweep_thump(n, f0, f1, sweep, decay):
    """Pitch-dropping body thump (the "boom" of a shot or blast)."""
    out, ph = [], 0.0
    for i in range(n):
        f = f1 + (f0 - f1) * math.exp(-i / (sweep * RATE))
        ph += 2 * math.pi * f / RATE
        out.append(math.sin(ph) * math.exp(-i / (decay * RATE)))
    return out


def gunshot(rng, length, crack_decay, crack_tone, body, tail_tone, tail_decay):
    n = int(length * RATE)
    crack = [s * e for s, e in zip(highpass(noise(n, rng), crack_tone), env(n, 0.0005, crack_decay))]
    tail = [s * e for s, e in zip(lowpass(noise(n, rng), tail_tone), env(n, 0.002, tail_decay))]
    return mix(crack, [s * 0.9 for s in sweep_thump(n, *body)], [s * 0.7 for s in tail])


def tone(n, freq, decay, attack=0.002, harmonics=(1.0, 0.0, 0.3)):
    e = env(n, attack, decay)
    return [e[i] * sum(a * math.sin(2 * math.pi * freq * (k + 1) * i / RATE) for k, a in enumerate(harmonics))
            for i in range(n)]


def weapon_sounds(rng):
    write("pistol.wav", gunshot(rng, 0.35, 0.012, 0.5, (190, 70, 0.012, 0.045), 0.3, 0.07), 0.9)
    write("rifle.wav", gunshot(rng, 0.28, 0.008, 0.6, (230, 80, 0.008, 0.03), 0.35, 0.05), 0.85)
    write("shotgun.wav", gunshot(rng, 0.7, 0.02, 0.35, (130, 45, 0.02, 0.1), 0.2, 0.14), 0.95)

    # Rocket: ignition pop, then a rushing whoosh that swells and fades.
    n = int(0.9 * RATE)
    pop = gunshot(rng, 0.2, 0.01, 0.4, (150, 60, 0.01, 0.04), 0.3, 0.04)
    swell = [min(i / (0.12 * RATE), 1.0) * math.exp(-max(i - 0.12 * RATE, 0) / (0.25 * RATE)) for i in range(n)]
    rush = [s * e for s, e in zip(highpass(lowpass(noise(n, rng), 0.3), 0.04), swell)]
    write("rocket.wav", mix([s * 0.8 for s in pop], rush), 0.85)

    # Plasma: a descending synth "pew" with a little fizz.
    n = int(0.26 * RATE)
    out, ph = [], 0.0
    for i in range(n):
        f = 260 + 1300 * math.exp(-i / (0.05 * RATE))
        ph += 2 * math.pi * f / RATE
        out.append((math.sin(ph) + 0.4 * math.sin(2 * ph) + 0.2 * math.sin(3 * ph)) * math.exp(-i / (0.08 * RATE)))
    fizz = [s * e * 0.25 for s, e in zip(highpass(noise(n, rng), 0.3), env(n, 0.001, 0.05))]
    write("plasma.wav", mix(out, fizz), 0.7)

    # Explosions: a deep sweep, a long dark roar and crackling debris.
    for name, length, roar, rdecay, body, crackle in (
            ("explosion_small.wav", 0.9, 0.3, 0.12, (110, 45, 0.03, 0.12), 0.25),
            ("explosion_large.wav", 2.0, 0.16, 0.38, (80, 30, 0.06, 0.3), 0.6)):
        n = int(length * RATE)
        roar_n = [s * e for s, e in zip(lowpass(lowpass(noise(n, rng), roar), 0.5), env(n, 0.003, rdecay))]
        bits = [s * 0.35 for s in rustle(n, rng, crackle, 160, 0.7, 0.25)]
        write(name, mix([s * 1.2 for s in sweep_thump(n, *body)], roar_n, bits), 0.95)

    n = int(0.06 * RATE)
    click = [s * e for s, e in zip(highpass(noise(n, rng), 0.5), env(n, 0.0005, 0.003))]
    write("dry_fire.wav", mix(click, [0.0] * int(0.03 * RATE) + [s * 0.6 for s in click]), 0.5)

    # Weapon pickup: a metallic "chk-chak"; ammo pickup: a two-note PS1-style blip.
    n = int(0.25 * RATE)
    def clank(delay, f):
        d = int(delay * RATE)
        hit = [s * e for s, e in zip(highpass(noise(n, rng), 0.35), env(n, 0.0005, 0.008))]
        ring = tone(n, f, 0.03, 0.0005, (0.5, 0.2, 0.15))
        return ([0.0] * d + mix(hit, ring))[:n]
    write("pickup_weapon.wav", mix(clank(0.0, 1900), clank(0.09, 2400)), 0.7)
    n = int(0.16 * RATE)
    blip = tone(n, 880, 0.04, 0.003, (1.0, 0.0, 0.25))
    blip2 = [0.0] * int(0.06 * RATE) + tone(n, 1320, 0.05, 0.003, (1.0, 0.0, 0.25))
    write("pickup_ammo.wav", mix(blip, blip2), 0.5)
    n = int(0.45 * RATE)
    arp = mix(*[[0.0] * int(k * 0.07 * RATE) + tone(n, f, 0.12, 0.005, (1.0, 0.2, 0.0)) for k, f in enumerate((523, 659, 784, 1046))])
    write("respawn.wav", arp, 0.4)
    n = int(0.5 * RATE)
    heal = mix(*[[0.0] * int(k * 0.06 * RATE) + tone(n, f, 0.15, 0.01, (1.0, 0.3, 0.0)) for k, f in enumerate((392, 523, 659))])
    write("heal.wav", heal, 0.45)


def creature_sounds(rng):
    """The floating eye: wet, organic noises, plus the player's pain grunt."""
    def sweep(n, f0, f1, k, harm=(1.0, 0.5, 0.25)):
        out, ph = [], 0.0
        for i in range(n):
            f = f1 + (f0 - f1) * math.exp(-i / (k * RATE)) if f0 > f1 else f0 + (f1 - f0) * (i / n) ** 1.5
            ph += 2 * math.pi * f / RATE
            out.append(sum(a * math.sin((j + 1) * ph) for j, a in enumerate(harm)))
        return out

    # Alert: a warbling screech that drops in pitch.
    n = int(0.7 * RATE)
    screech = sweep(n, 1400, 380, 0.25, (1.0, 0.6, 0.4, 0.3))
    wob = [1 + 0.35 * math.sin(2 * math.pi * 23 * i / RATE) for i in range(n)]
    hiss = highpass(lowpass(noise(n, rng), 0.5), 0.1)
    write("eye_alert.wav", [(s * w + h * 0.3) * e for s, w, h, e in zip(screech, wob, hiss, env(n, 0.03, 0.25))], 0.7)

    # Charge: a rising whine before each shot.
    n = int(0.4 * RATE)
    whine = sweep(n, 220, 900, 0.0, (1.0, 0.3))
    write("eye_charge.wav", [s * min(i / n * 1.5, 1.0) for i, s in enumerate(whine)], 0.45)

    # Fire: a wet "thwip" spit.
    n = int(0.3 * RATE)
    spit = [s * e for s, e in zip(lowpass(noise(n, rng), 0.35), env(n, 0.002, 0.05))]
    write("eye_fire.wav", mix(spit, [s * 0.7 for s in sweep(n, 700, 160, 0.04)]), 0.7)

    # Hurt: a squelch with a short pained squeal.
    n = int(0.35 * RATE)
    squelch = [s * e for s, e in zip(lowpass(lowpass(noise(n, rng), 0.25), 0.4), env(n, 0.004, 0.06))]
    squeal = [s * e * 0.5 for s, e in zip(sweep(n, 1100, 600, 0.08), env(n, 0.01, 0.07))]
    write("eye_hurt.wav", mix(squelch, squeal), 0.75)

    # Death: a burst of gore and a dying, falling wail.
    n = int(1.1 * RATE)
    burst = [s * e for s, e in zip(lowpass(noise(n, rng), 0.3), env(n, 0.002, 0.12))]
    wail = [s * e * 0.6 for s, e in zip(sweep(n, 900, 120, 0.35, (1.0, 0.5, 0.3)), env(n, 0.02, 0.35))]
    write("eye_die.wav", mix(burst, wail, [s * 0.6 for s in sweep_thump(n, 120, 50, 0.04, 0.12)]), 0.85)

    # Player hurt: a dull body hit and a short, low "hngh".
    n = int(0.3 * RATE)
    hit = [s * e for s, e in zip(lowpass(noise(n, rng), 0.2), env(n, 0.002, 0.03))]
    grunt = [s * e * 0.7 for s, e in zip(sweep(n, 160, 105, 0.1, (1.0, 0.7, 0.5, 0.3, 0.2)), env(n, 0.015, 0.08))]
    write("player_hurt.wav", mix(hit, grunt), 0.7)


def generate():
    os.makedirs(OUT, exist_ok=True)
    for i in range(5):
        write(f"footstep_{i + 1}.wav", footstep(100 + i), 0.8)

    rng = random.Random(7)
    # Jump: only a soft, dark rush of air that swells in over ~70 ms. Anything with a
    # sharp onset (even a quiet scuff) reads as a gunshot in a shooter.
    n = int(0.3 * RATE)
    swell = [min(i / (0.07 * RATE), 1.0) ** 2 * math.exp(-max(i - 0.07 * RATE, 0) / (0.08 * RATE)) for i in range(n)]
    whoosh = highpass(lowpass(lowpass(noise(n, rng), 0.1), 0.1), 0.02)
    write("jump.wav", [s * e for s, e in zip(whoosh, swell)], 0.3)

    # Landings: both feet a beat apart, a muffled body thud and settling grit.
    n = int(0.3 * RATE)
    feet = mix(scuff(n, rng, 0.0, 0.006, 0.04, 0.2, 1.0), scuff(n, rng, 0.022, 0.006, 0.035, 0.2, 0.8))
    write("land_soft.wav", mix(feet, [s * 0.4 for s in thud(n, 85, 0.006, 0.04)], [s * 0.3 for s in rustle(n, rng, 0.12, 150)]), 0.6)

    n = int(0.5 * RATE)
    feet = mix(scuff(n, rng, 0.0, 0.006, 0.07, 0.18, 1.0), scuff(n, rng, 0.018, 0.006, 0.06, 0.18, 0.9))
    grit = [s * 0.4 for s in rustle(n, rng, 0.25, 220)]
    write("land_hard.wav", mix(feet, [s * 0.5 for s in thud(n, 70, 0.008, 0.07)], grit), 0.75)

    # Gravel slide: grainy noise with a gentle wobble; whole cycles over the loop length.
    length = 1.2
    n = int((length + 0.15) * RATE)
    grit = highpass(lowpass(noise(n, rng), 0.45), 0.08)
    wob = [0.75 + 0.25 * math.sin(2 * math.pi * 5 * i / (length * RATE)) for i in range(n)]
    write("slide_loop.wav", loopable([g * w for g, w in zip(grit, wob)], 0.15), 0.55)

    # Wind: brown-ish noise with slow gusts.
    length = 8.0
    n = int((length + 1.0) * RATE)
    brown, acc = [], 0.0
    for s in noise(n, rng):
        acc = acc * 0.996 + s * 0.04
        brown.append(acc)
    air = lowpass(brown, 0.08)
    gust = [0.55 + 0.25 * math.sin(2 * math.pi * i / (length * RATE)) + 0.2 * math.sin(2 * math.pi * 3 * i / (length * RATE) + 1.0)
            for i in range(n)]
    write("wind_loop.wav", loopable([a * g for a, g in zip(air, gust)], 1.0), 0.7)

    weapon_sounds(random.Random(11))
    creature_sounds(random.Random(13))

    for name in ("slide_loop.wav", "wind_loop.wav"):
        path = os.path.join(OUT, name + ".import")
        uid = None
        if os.path.exists(path):
            with open(path) as f:
                uid = next((l for l in f.read().splitlines() if l.startswith("uid=")), None)
        text = LOOP_IMPORT if not uid else LOOP_IMPORT.replace('type="AudioStreamWAV"\n', f'type="AudioStreamWAV"\n{uid}\n')
        with open(path, "w") as f:
            f.write(text)
    print("wrote sfx to", OUT)


if __name__ == "__main__":
    generate()
