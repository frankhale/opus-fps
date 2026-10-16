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
  hitmarker.wav, killmarker.wav   hit confirmation ticks
  portal_hum.wav     portal drone, seamless loop
  teleport.wav       rising shimmer whoosh when passing through a portal
  golem_hum.wav      the golem's electric buzz, seamless loop
  golem_alert/charge/fire/shock/hurt/die.wav   the golem: grinding stone and electricity
  shield_up.wav      invulnerability pickup: a bright rising chord with a shimmer
  shield_hum.wav     the shield's glassy shimmer while it lasts, seamless loop
  shield_down.wav    the shield fading: a falling, thinning chord
  spider_alert/charge/spit/hurt/die/step.wav   the spider: chittering, hissing and its toxin spray

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

    # Hit marker: a short, bright tick; kill confirm: a lower, fuller double tick.
    n = int(0.06 * RATE)
    tick = [s * e for s, e in zip(highpass(noise(n, rng), 0.4), env(n, 0.0005, 0.006))]
    write("hitmarker.wav", mix(tick, tone(n, 2400, 0.012, 0.0005, (0.6, 0.0, 0.0))), 0.5)
    n = int(0.14 * RATE)
    write("killmarker.wav", mix(tone(n, 1500, 0.03, 0.0005, (0.8, 0.3, 0.0)),
                                [0.0] * int(0.05 * RATE) + tone(n, 1100, 0.04, 0.0005, (0.8, 0.3, 0.0))), 0.55)


def portal_sounds(rng):
    """The portal: a beating, airy drone and a rising whoosh for going through."""
    length = 4.0
    n = int((length + 0.5) * RATE)
    # Detuned pairs beat slowly; whole-cycle frequencies over `length` keep the loop seamless.
    drone = [0.5 * math.sin(2 * math.pi * 55 * i / RATE) + 0.35 * math.sin(2 * math.pi * 110 * i / RATE)
             + 0.35 * math.sin(2 * math.pi * 111.5 * i / RATE) + 0.12 * math.sin(2 * math.pi * 331.25 * i / RATE)
             for i in range(n)]
    air = highpass(lowpass(noise(n, rng), 0.25), 0.05)
    wob = [0.8 + 0.2 * math.sin(2 * math.pi * 0.5 * i / RATE) for i in range(n)]
    write("portal_hum.wav", loopable([(d + a * 0.5) * w for d, a, w in zip(drone, air, wob)], 0.5), 0.5)

    n = int(1.0 * RATE)
    rise, ph = [], 0.0
    for i in range(n):
        ph += 2 * math.pi * (180 + 1500 * (i / n) ** 2) / RATE
        rise.append(math.sin(ph) + 0.4 * math.sin(2 * ph) + 0.2 * math.sin(3.01 * ph))
    swell = [min(i / (0.35 * RATE), 1.0) * math.exp(-max(i - 0.35 * RATE, 0) / (0.18 * RATE)) for i in range(n)]
    whoosh = [s * e for s, e in zip(lowpass(noise(n, rng), 0.3), swell)]
    sparkle = mix(*[[0.0] * int((0.25 + k * 0.06) * RATE) + tone(n, f, 0.12, 0.003, (1.0, 0.0, 0.2))
                    for k, f in enumerate((1046, 1318, 1568, 2093))])
    write("teleport.wav", mix([r * e * 0.6 for r, e in zip(rise, swell)], whoosh, [x * 0.35 for x in sparkle])[:n], 0.75)


def shield_sounds(rng):
    """The invulnerability shield: a glassy, ringing chord."""
    n = int(1.1 * RATE)
    chord = mix(*[[0.0] * int(k * 0.05 * RATE) + tone(n, f, 0.5, 0.01, (1.0, 0.25, 0.1))
                  for k, f in enumerate((523, 784, 1046, 1568))])
    rise, ph = [], 0.0
    for i in range(n):
        ph += 2 * math.pi * (300 + 900 * (i / n)) / RATE
        rise.append(math.sin(ph) * math.exp(-i / (0.3 * RATE)) * min(i / (0.05 * RATE), 1.0))
    sparkle = mix(*[[0.0] * int((0.15 + k * 0.05) * RATE) + tone(n, f, 0.08, 0.002, (1.0, 0.0, 0.2))
                    for k, f in enumerate((2093, 2637, 3136, 4186))])
    write("shield_up.wav", mix(chord, [r * 0.5 for r in rise], [x * 0.3 for x in sparkle])[:n], 0.6)

    # Hum: high detuned pairs that beat slowly, plus faint airy shimmer. Whole cycles over
    # `length` keep the loop seamless.
    length = 2.0
    n = int((length + 0.3) * RATE)
    hum = [0.3 * math.sin(2 * math.pi * 523 * i / RATE) + 0.3 * math.sin(2 * math.pi * 525 * i / RATE)
           + 0.2 * math.sin(2 * math.pi * 784 * i / RATE) + 0.2 * math.sin(2 * math.pi * 787.5 * i / RATE)
           + 0.1 * math.sin(2 * math.pi * 130.5 * i / RATE)
           for i in range(n)]
    air = highpass(noise(n, rng), 0.6)
    write("shield_hum.wav", loopable([h + a * 0.08 for h, a in zip(hum, air)], 0.3), 0.35)

    n = int(0.8 * RATE)
    fall, ph = [], 0.0
    for i in range(n):
        ph += 2 * math.pi * (1046 - 700 * (i / n)) / RATE
        fall.append((math.sin(ph) + 0.3 * math.sin(1.5 * ph)) * math.exp(-i / (0.25 * RATE)))
    write("shield_down.wav", mix(fall, [s * 0.4 for s in lowpass(noise(n, rng), 0.2)][:n]), 0.5)


def golem_sounds(rng):
    """The golem: grinding, clacking stone and the electricity it floats on."""
    def buzz(n, f0, f1, harm=(1.0, 0.0, 0.5, 0.0, 0.3, 0.0, 0.2)):
        """Mains-style electric buzz (odd harmonics), gliding from f0 to f1."""
        out, ph = [], 0.0
        for i in range(n):
            ph += 2 * math.pi * (f0 + (f1 - f0) * i / n) / RATE
            out.append(sum(a * math.sin((j + 1) * ph) for j, a in enumerate(harm)))
        return out

    def crackle(n, density, gain=1.0):
        """Spitting electric sparks: sharp bright clicks at random."""
        x = [0.0] * n
        for _ in range(int(density * n / RATE)):
            start, amp = rng.randrange(n), rng.uniform(0.3, 1.0) * gain
            for j in range(rng.randint(20, 120)):
                if start + j < n:
                    x[start + j] += rng.uniform(-1, 1) * amp * math.exp(-j / 25)
        return highpass(x, 0.35)

    def clack(n, delay, pitch, gain):
        """One stone knocking on another: a dull click with a short hollow ring."""
        d = int(delay * RATE)
        k = int(0.08 * RATE)
        hit = [s * e for s, e in zip(lowpass(noise(k, rng), 0.5), env(k, 0.0005, 0.008))]
        ring = tone(k, pitch, 0.02, 0.0005, (1.0, 0.0, 0.4))
        body = [(h + r * 0.5) * gain for h, r in zip(hit, ring)]
        return ([0.0] * d + body + [0.0] * n)[:n]

    def rumble(n, darkness, attack, decay):
        return [s * e for s, e in zip(lowpass(lowpass(noise(n, rng), darkness), darkness), env(n, attack, decay))]

    # Hum: a low buzz with a slow throb and sparks; whole cycles over the loop length.
    length = 2.0
    n = int((length + 0.2) * RATE)
    throb = [0.8 + 0.2 * math.sin(2 * math.pi * 2 * i / (length * RATE)) for i in range(n)]
    hum = [b * t * 0.6 for b, t in zip(lowpass(buzz(n, 60, 60), 0.3), throb)]
    write("golem_hum.wav", loopable(mix(hum, crackle(n, 14, 0.35)), 0.2), 0.45)

    # Alert: stone grinding awake, a heavy knock and a snap of current.
    n = int(1.0 * RATE)
    grind = [s * (0.6 + 0.4 * math.sin(2 * math.pi * 7 * i / RATE)) for i, s in enumerate(rumble(n, 0.08, 0.08, 0.35))]
    write("golem_alert.wav", mix(grind, clack(n, 0.05, 260, 0.8), clack(n, 0.3, 180, 1.0),
                                 [b * e * 0.4 for b, e in zip(buzz(n, 90, 140), env(n, 0.2, 0.3))], crackle(n, 30, 0.6)), 0.8)

    # Charge: the buzz rises and the sparks thicken.
    n = int(0.75 * RATE)
    rise = [b * min(i / n * 1.4, 1.0) for i, b in enumerate(buzz(n, 70, 260))]
    write("golem_charge.wav", mix([r * 0.6 for r in rise], [c * (i / n) for i, c in enumerate(crackle(n, 90))]), 0.6)

    # Fire: a zap, a crack falling into a fizz.
    n = int(0.45 * RATE)
    crack = [s * e for s, e in zip(highpass(noise(n, rng), 0.3), env(n, 0.001, 0.02))]
    zap = [b * e * 0.6 for b, e in zip(buzz(n, 900, 150, (1.0, 0.5, 0.3)), env(n, 0.002, 0.08))]
    write("golem_fire.wav", mix(crack, zap, crackle(n, 40, 0.4)), 0.75)

    # Shock: a thunderclap into the ground, a deep thump and crackling all around.
    n = int(1.4 * RATE)
    clap = [s * e for s, e in zip(highpass(noise(n, rng), 0.2), env(n, 0.001, 0.06))]
    write("golem_shock.wav", mix(clap, [s * 0.9 for s in sweep_thump(n, 110, 40, 0.06, 0.25)],
                                 rumble(n, 0.05, 0.005, 0.4), [c * math.exp(-i / (0.4 * RATE)) for i, c in enumerate(crackle(n, 120))]), 0.9)

    # Hurt: chipped stone, two quick knocks and a spit of sparks.
    n = int(0.3 * RATE)
    write("golem_hurt.wav", mix(clack(n, 0.0, 520, 1.0), clack(n, 0.035, 380, 0.6), crackle(n, 40, 0.4)), 0.7)

    # Death: the charge fizzles out and the boulders tumble apart.
    n = int(1.8 * RATE)
    fizzle = [b * e * 0.5 for b, e in zip(buzz(n, 160, 30), env(n, 0.005, 0.4))]
    falls = mix(*[clack(n, rng.uniform(0.05, 1.2), rng.uniform(150, 400), rng.uniform(0.4, 1.0)) for _ in range(14)])
    write("golem_die.wav", mix(fizzle, falls, rumble(n, 0.05, 0.02, 0.6), [c * math.exp(-i / (0.25 * RATE)) for i, c in enumerate(crackle(n, 100))]), 0.85)


def spider_sounds(rng):
    """The giant spider: dry chitters and clicks, hisses, and the wet spray of its toxin."""
    def clicks(n, rate, gain=1.0, bright=0.45):
        """Rapid dry clicks of mandibles and leg tips, `rate` per second."""
        x = [0.0] * n
        for _ in range(int(rate * n / RATE)):
            start, amp = rng.randrange(n), rng.uniform(0.4, 1.0) * gain
            for j in range(rng.randint(30, 90)):
                if start + j < n:
                    x[start + j] += rng.uniform(-1, 1) * amp * math.exp(-j / 14)
        return highpass(x, bright)

    def hiss(n, bright=0.25):
        return highpass(noise(n, rng), bright)

    # Alert: a rattling chitter swelling over a sharp hiss.
    n = int(0.8 * RATE)
    chit = [c * (0.6 + 0.4 * math.sin(2 * math.pi * 31 * i / RATE)) for i, c in enumerate(clicks(n, 260))]
    write("spider_alert.wav", [(c + h * 0.45) * e for c, h, e in zip(chit, hiss(n), env(n, 0.04, 0.3))], 0.7)

    # Charge: a hiss drawn in and building, rattling faster toward the end.
    n = int(0.55 * RATE)
    build = [min(i / n * 1.3, 1.0) ** 1.5 for i in range(n)]
    rattle = clicks(n, 180, 0.6)
    write("spider_charge.wav", [(h * 0.8 + r) * b for h, r, b in zip(hiss(n, 0.3), rattle, build)], 0.5)

    # Spit: a wet, pressurised spray, like a hose nozzle opened hard: bright noise that
    # bursts in, gurgles and sputters, then cuts off.
    n = int(0.8 * RATE)
    jet = highpass(lowpass(noise(n, rng), 0.7), 0.12)
    gurgle = [0.7 + 0.3 * math.sin(2 * math.pi * (38 + 9 * math.sin(i / RATE * 11)) * i / RATE) for i in range(n)]
    shape = [min(i / (0.015 * RATE), 1.0) * (1.0 if i < 0.6 * RATE else math.exp(-(i - 0.6 * RATE) / (0.04 * RATE)))
             for i in range(n)]
    sputter = [s * 0.5 for s in clicks(n, 90, 1.0, 0.2)]
    write("spider_spit.wav", [(j * g + p) * e for j, g, p, e in zip(jet, gurgle, sputter, shape)], 0.6)

    # Hurt: a crunchy click burst with a short shrill squeak.
    n = int(0.3 * RATE)
    squeak = [tone(n, 1700, 0.05, 0.004, (1.0, 0.4))[i] * (1 + 0.5 * math.sin(i / RATE * 2 * math.pi * 60)) * 0.4
              for i in range(n)]
    write("spider_hurt.wav", mix(clicks(n, 600, 1.0, 0.3), squeak, [s * e * 0.5 for s, e in zip(hiss(n), env(n, 0.002, 0.05))]), 0.7)

    # Death: a wet crunch, legs rattling and a long falling hiss.
    n = int(1.1 * RATE)
    crunch = [s * e for s, e in zip(lowpass(noise(n, rng), 0.35), env(n, 0.002, 0.07))]
    rattle = [c * math.exp(-i / (0.35 * RATE)) for i, c in enumerate(clicks(n, 400, 0.8))]
    sigh = [h * e * 0.5 for h, e in zip(lowpass(hiss(n, 0.15), 0.6), env(n, 0.05, 0.4))]
    write("spider_die.wav", mix(crunch, rattle, sigh, [s * 0.5 for s in sweep_thump(n, 140, 50, 0.04, 0.1)]), 0.85)

    # Step: one leg tip tapping down, a tiny dry tick.
    n = int(0.05 * RATE)
    write("spider_step.wav", [s * e for s, e in zip(highpass(noise(n, rng), 0.3), env(n, 0.0005, 0.006))], 0.5)


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
    portal_sounds(random.Random(17))
    golem_sounds(random.Random(19))
    shield_sounds(random.Random(23))
    spider_sounds(random.Random(29))

    for name in ("slide_loop.wav", "wind_loop.wav", "portal_hum.wav", "golem_hum.wav", "shield_hum.wav"):
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
