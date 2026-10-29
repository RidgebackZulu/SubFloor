"""Throwaway NR spike: classic methods on a real 11.175 clip, for listening. Not product code."""
import sys, wave, numpy as np

FS = 48000

def load(p, start, dur):
    b = open(p, 'rb').read(); i = b.find(b'data'); n = int.from_bytes(b[i+4:i+8], 'little')
    x = np.frombuffer(b[i+8:i+8+n], dtype='<i2').astype(np.float64) / 32768
    return x[int(start*FS):int((start+dur)*FS)]

def save(p, x):
    x = np.clip(x, -1, 1)
    with wave.open(p, 'wb') as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(FS)
        w.writeframes((x * 32767).astype('<i2').tobytes())

def stft(x, n=1024, hop=256):
    win = np.sqrt(np.hanning(n + 1)[:n])
    frames = [np.fft.rfft(win * x[i:i+n]) for i in range(0, len(x) - n, hop)]
    return np.array(frames), win

def istft(X, win, length, n=1024, hop=256):
    y = np.zeros(length); norm = np.zeros(length)
    for k, F in enumerate(X):
        i = k * hop
        y[i:i+n] += win * np.fft.irfft(F, n); norm[i:i+n] += win ** 2
    return y / np.maximum(norm, 1e-9)

def noise_track(P, hop=256, win_s=1.5):
    """Minimum statistics, simplified: smoothed power, running minimum over win_s, bias-corrected."""
    S = np.empty_like(P); s = P[0]
    for k in range(len(P)):
        s = 0.85 * s + 0.15 * P[k]; S[k] = s
    L = int(win_s * FS / hop); N = np.empty_like(P)
    for k in range(len(P)):
        N[k] = S[max(0, k - L):k + 1].min(axis=0)
    return np.maximum(N * 1.8, 1e-12)

def exp1(v):
    """E1(v), Abramowitz & Stegun 5.1.53/5.1.56."""
    small = -0.57721566 - np.log(v) + 0.99999193*v - 0.24991055*v**2 + 0.05519968*v**3 - 0.00976004*v**4 + 0.00107857*v**5
    vv = np.maximum(v, 1)
    big = np.exp(-vv) / vv * (vv**2 + 2.334733*vv + 0.250621) / (vv**2 + 3.330657*vv + 1.681534)
    return np.where(v < 1, small, big)

def mmse_lsa(x, floor_db, over):
    """Ephraim–Malah log-spectral amplitude with decision-directed a-priori SNR."""
    X, win = stft(x); P = np.abs(X) ** 2; N = noise_track(P) * over
    G = np.ones_like(P); prev = np.zeros(P.shape[1]); gmin = 10 ** (floor_db / 20)
    for k in range(len(P)):
        g = np.maximum(P[k] / N[k], 1e-6)                       # a-posteriori SNR
        xi = np.maximum(0.98 * prev / N[k] + 0.02 * np.maximum(g - 1, 0), 10 ** (-25 / 10))
        v = xi / (1 + xi) * g
        gk = xi / (1 + xi) * np.exp(0.5 * exp1(np.maximum(v, 1e-8)))
        gk = np.clip(gk, gmin, 1); G[k] = gk; prev = (gk ** 2) * P[k]
    return istft(X * G, win, len(x))

def spectral_subtraction(x, over):
    X, win = stft(x); P = np.abs(X) ** 2; N = noise_track(P)
    G = np.sqrt(np.maximum(1 - over * N / np.maximum(P, 1e-12), 0.02))
    return istft(X * G, win, len(x))

def lms_ale(x, taps=64, delay=16, mu=0.002, leak=0.9999):
    """Adaptive line enhancer (classic ham-radio 'NR'): predicts the correlated (voice) part."""
    w = np.zeros(taps); y = np.zeros_like(x); buf = np.zeros(taps)
    for i in range(delay + taps, len(x)):
        buf = x[i - delay - taps:i - delay][::-1]
        yi = w @ buf; e = x[i] - yi
        w = leak * w + 2 * mu * e * buf / (buf @ buf + 1e-6); y[i] = yi
    return y

if __name__ == '__main__':
    src, out, start, dur = sys.argv[1], sys.argv[2], float(sys.argv[3]), float(sys.argv[4])
    x = load(src, start, dur)
    peak = lambda y: y / max(np.abs(y).max(), 1e-9) * 0.7
    save(f'{out}/0-original.wav', peak(x))
    save(f'{out}/1-mmse-light.wav', peak(mmse_lsa(x, -8, 1.0)))
    save(f'{out}/2-mmse-medium.wav', peak(mmse_lsa(x, -14, 1.5)))
    save(f'{out}/3-mmse-strong.wav', peak(mmse_lsa(x, -20, 2.5)))
    save(f'{out}/4-spectral-subtraction.wav', peak(spectral_subtraction(x, 2.0)))
    save(f'{out}/5-lms-ale.wav', peak(lms_ale(x)))
    print('done')
