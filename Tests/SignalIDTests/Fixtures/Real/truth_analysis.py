#!/usr/bin/env python3
"""Repeats the corpus's hand truth from the clips beside it, with numpy only and none of Signal ID's code.

    python3 truth_analysis.py sync    # FT8 and FT4 sync searches: the labels whose `how` says "sync"
    python3 truth_analysis.py fsk     # the 11.7 MHz FSK's tones and keying lines
    python3 truth_analysis.py empty   # what lies within 500 Hz of each empty point
    python3 truth_analysis.py table   # rewrites truth-table.tsv from manifest.json

The manifest's scores came from the same search on the recordings cut by an FFT (not `Channel.extract`), so these
differ from them a little. FT8's decoded labels are repeated by `RealCorpusTruthTests` (SUBFLOOR_SIGNALID_REAL=1).
"""
import csv, json, os, sys
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
RATE = 62500.0
MANIFEST = json.load(open(os.path.join(HERE, "manifest.json")))


def clip(name):
    d = np.fromfile(os.path.join(HERE, name + ".wav"), dtype="<i2", offset=44).astype(np.float32) / 32768
    return d[0::2] + 1j * d[1::2]


def recording(tag):
    r = next(r for r in MANIFEST["recordings"] if r["tag"] == tag)
    return np.concatenate([clip(c["name"]) for c in r["clips"]]), r["clipCenterHz"]


def symbol_map(y, center, lo, hi, symbol):
    """Log power, each row over its median, in symbol-long Hann frames: an eighth of a symbol and a quarter bin apart."""
    n = int(round(symbol * RATE))
    size, hop = 4 * n, n // 8
    f = np.fft.fftshift(np.fft.fftfreq(size, 1 / RATE)) + center
    keep = (f >= lo) & (f <= hi)
    win = np.hanning(n)
    p = np.empty(((len(y) - n) // hop, keep.sum()), dtype=np.float32)
    for i in range(len(p)):
        p[i] = np.abs(np.fft.fftshift(np.fft.fft(y[i * hop:i * hop + n] * win, size))[keep]) ** 2
    p /= np.median(p, axis=1, keepdims=True)
    return np.log(p + 1e-3), hop / RATE, f[1] - f[0], f[keep][0]


def search(L, dt, df, f0, symbol, spacing, tones, blocks, slot, span, threshold, label, use=None):
    """Sync score per start time and tone-0 frequency: a sync tone's log power over the mean of the tones, averaged."""
    ts, fs = symbol / dt, int(round(spacing / df))
    grid = np.arange(int((slot + span[0]) / dt), int((slot + span[1]) / dt))
    per = []
    for start, pattern in blocks:
        total = 0
        for k, tone in enumerate(pattern):
            rows = L[np.round(grid + (start + k) * ts).astype(int)]
            a = [rows[:, i * fs:L.shape[1] - (tones - 1) * fs + i * fs] for i in range(tones)]
            total = total + a[tone] - sum(a) / tones
        per.append(total / len(pattern))
    per = np.array(per)
    score = (np.sort(per, axis=0)[-use:] if use else per).mean(axis=0)
    print(f"{label}: noise at 50/99/99.99%: {np.round(np.percentile(score, [50, 99, 99.99]), 2)}")
    left, found = score.copy(), []
    while True:
        i = np.unravel_index(np.argmax(left), left.shape)
        if left[i] < threshold:
            break
        found.append((grid[i[0]] * dt, f0 + i[1] * df, left[i], np.round(per[:, i[0], i[1]], 2)))
        left[max(0, i[0] - 40):i[0] + 40, max(0, i[1] - 3 * fs):i[1] + 3 * fs] = -9
    for on, hz, s, each in sorted(found, key=lambda x: x[1]):
        print(f"  on {on:6.2f} s  tone 0 {hz:11.1f} Hz  score {s:.2f}  per array {each}")


def sync():
    y, center = recording("14MHz")
    costas = [3, 1, 4, 0, 6, 5, 2]
    L, dt, df, f0 = symbol_map(y, center, 14072700, 14076600, 0.16)
    for slot in (1, 16):  # slot 16's hits should land on its decodes: that is what the tuning slot's labels lean on
        search(L, dt, df, f0, 0.16, 6.25, 8, [(36, costas), (72, costas)], slot, (0, 1.5), 2.0, f"FT8 slot t={slot}")
    ft4 = [(1, [0, 1, 3, 2]), (34, [1, 0, 2, 3]), (67, [2, 3, 1, 0]), (100, [3, 2, 0, 1])]
    symbol, spacing = 576 / 12000, 12000 / 576
    L, dt, df, f0 = symbol_map(y, center, 14078500, 14083500, symbol)
    # Slot 8.5's middle arrays fall in the receiver's gain drop (10.3-12.3 s): its best two arrays are scored.
    search(L, dt, df, f0, symbol, spacing, 4, ft4, 8.5, (-1, 1.2), 1.4, "FT4 slot t=8.5", use=2)
    for slot in (16, 23.5, 31):
        search(L, dt, df, f0, symbol, spacing, 4, ft4, slot, (-1, 1.2), 1.05, f"FT4 slot t={slot}")


def fsk():
    y, center = recording("11.7MHz")
    t = np.arange(len(y)) / RATE
    Y, f = np.fft.fft(y), np.fft.fftfreq(len(y), 1 / RATE)
    low, high = 11687797.0, 11688646.0

    def band(hz, width):
        return np.fft.ifft(Y * (np.abs(f - (hz - center)) < width / 2)) * np.exp(-2j * np.pi * (hz - center) * t)

    def lines(x, rate, label):
        x = x - x.mean()
        size = 1 << int(np.ceil(np.log2(len(x) * 8)))
        F, q = np.abs(np.fft.rfft(x * np.hanning(len(x)), size)) ** 2, np.fft.rfftfreq(size, 1 / rate)
        keep = (q > 10) & (q < 400)
        F, q = F[keep], q[keep]
        peaks = sorted((i for i in range(1, len(F) - 1) if F[i - 1] < F[i] > F[i + 1]), key=lambda i: -F[i])[:6]
        print(label, [(round(q[i], 2), f"{F[i] / np.median(F):.0f}x median") for i in peaks])

    dec = 4
    rate = RATE / dec
    z = band((low + high) / 2, 1500)[::dec]
    disc = np.angle(z[1:] * np.conj(z[:-1])) * rate / (2 * np.pi)
    smooth = np.convolve(disc, np.ones(int(0.003 * rate)) / int(0.003 * rate), "same")
    lines(np.diff(smooth) ** 2, rate, "squared change of the demodulated frequency:")
    a, b = np.abs(band(low, 300)[::dec]) ** 2, np.abs(band(high, 300)[::dec]) ** 2
    k = np.ones(int(0.002 * rate)) / int(0.002 * rate)
    a, b = np.convolve(a, k, "same"), np.convolve(b, k, "same")
    lines(np.diff((a - b) / (a + b + 1e-12)) ** 2, rate, "tone-power difference:")
    size = int(0.005 * rate)
    m = len(a) // size
    corr = np.corrcoef(a[:m * size].reshape(m, size).mean(axis=1), b[:m * size].reshape(m, size).mean(axis=1))[0, 1]
    print(f"tone powers' correlation in 5 ms blocks: {corr:.2f}")
    edges = np.nonzero(np.diff(np.sign(np.convolve(disc, np.ones(int(0.004 * rate)) / int(0.004 * rate), "same"))))[0] / rate
    bauds = np.arange(30, 160, 0.01)
    r = np.array([np.abs(np.exp(2j * np.pi * x * edges).mean()) for x in bauds])
    print("tone edges' phase coherence peaks at", round(float(bauds[np.argmax(r)]), 2), "Bd")


def empty():
    for rec in MANIFEST["recordings"]:
        for c in rec["clips"]:
            z = clip(c["name"])
            print(c["name"])
            size, hop = 8192, 4096
            frames = np.array([np.abs(np.fft.fftshift(np.fft.fft(z[i:i + size] * np.hanning(size)))) ** 2
                               for i in range(0, len(z) - size, hop)])
            f = np.fft.fftshift(np.fft.fftfreq(size, 1 / RATE)) + rec["clipCenterHz"]
            n = len(frames) // 8
            half = 10 * np.log10(frames[:n * 8].reshape(n, 8, -1).mean(axis=1) + 1e-20)
            half -= np.median(half, axis=1, keepdims=True)
            mean = 10 * np.log10(frames.mean(axis=0) + 1e-20)
            mean -= np.median(mean)
            one = 31250  # a single 0.5 s FFT, 2 Hz bins
            f1 = np.fft.fftshift(np.fft.fftfreq(one, 1 / RATE)) + rec["clipCenterHz"]
            single = np.array([np.abs(np.fft.fftshift(np.fft.fft(z[i:i + one] * np.hanning(one)))) ** 2
                               for i in range(0, len(z) - one, one // 2)])
            single = 10 * np.log10(single + 1e-20)
            single -= np.median(single, axis=1, keepdims=True)
            for hz in sorted({p["atHz"] for p in MANIFEST["points"] if p["clip"] == c["name"] and p["truth"] == "none"}):
                near, near1 = np.abs(f - hz) < 500, np.abs(f1 - hz) < 500
                print(f"  {hz:.0f}: average {mean[near].max():.1f} dB; 0.5 s of averaged frames {half[:, near].max():.1f} dB; "
                      f"single 0.5 s FFT {single[:, near1].max():.1f} dB; one bin over 8 dB in "
                      f"{(half[:, near] > 8).sum(axis=0).max()} of {n} half-seconds")


def table():
    starts = {c["name"]: (c["startSeconds"], c["part"]) for r in MANIFEST["recordings"] for c in r["clips"]}
    rows = {}
    for p in MANIFEST["points"]:
        at = p.get("parameters") or {}
        key = (p["truth"], p["atHz"], at.get("onSeconds", at.get("slotSeconds", -1)))
        row = rows.setdefault(key, {"truth": p["truth"], "part": starts[p["clip"]][1], "atHz": p["atHz"],
                                    "toneZeroHz": at.get("toneZeroHz", ""), "onSeconds": at.get("onSeconds", ""),
                                    "points": 0, "counted": 0, "how": p["how"].split("; this window")[0]})
        row["points"] += 1
        row["counted"] += int(p["transmitting"] or p["truth"] == "none")
    with open(os.path.join(HERE, "truth-table.tsv"), "w", newline="") as out:
        w = csv.DictWriter(out, fieldnames=["truth", "part", "atHz", "toneZeroHz", "onSeconds", "points", "counted", "how"],
                           delimiter="\t", lineterminator="\n")
        w.writeheader()
        for key in sorted(rows, key=lambda k: (k[0], k[1], k[2])):
            w.writerow(rows[key])
    print(len(rows), "rows")


if __name__ == "__main__":
    {"sync": sync, "fsk": fsk, "empty": empty, "table": table}[sys.argv[1] if len(sys.argv) > 1 else "sync"]()
