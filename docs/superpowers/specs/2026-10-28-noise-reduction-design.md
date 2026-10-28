# Noise reduction for listening, and Skip silence in the player — Design

Date: 2026-10-28. Status: for the owner's approval.

**(user)** marks what the owner decided. **(builder's call)** marks what I decided and the builder may
revisit. Everything else is left to the builder.

## 1. Intent

The owner listens to weak HF voice, mostly USAF HFGCS on 11.175 MHz USB, live and from Auto's
recordings. The voices are there but sit in a lot of hiss, pops and static, which is tiring and hides
words. They want:

1. **Noise reduction (NR)** that strips out what isn't a human voice (hiss, pops, static crashes)
   and brings the voice forward, with one easy control. It has to work for live listening and in the
   Recordings window's player, and look and work the same in both. **(user)**
2. **Skip silence** in the player: while a recording plays, silent stretches are jumped over, so the
   owner hears one transmission after another without waiting through dead air. It can be turned on
   and off. **(user)**

**Success:** the owner plays an 11.175 recording or listens live with NR on Medium and hears the
voice clearly, with only a little hiss left under it and the voice still sounding natural. With Skip
silence on, a recording full of squelch gaps plays as continuous speech.

## 2. Goals, non-goals, anti-goals

Goals:
- One NR control with an on/off and a Light-to-Strong strength, the same in both windows. **(user)**
- Voice accuracy first. When it must choose, NR leaves some hiss rather than make the voice sound
  processed or drop quiet syllables. **(user)**
- Skip silence for every silent gap, short or long. **(user)**

Non-goals for this round:
- AI/neural noise reduction (RNNoise, DeepFilterNet). Possible later as a second engine. **(builder's
  call, from the research)**
- NR controls on the SubFloor Dial. **(user)**
- NR for the modem decoders (FT8, WSPR, CW, PSK31).
- Any change to what gets recorded.

Anti-goals (a failure even if it works):
- **The voice sounds robotic, watery or burbling, or quiet words vanish.** The owner prefers hiss.
  **(user)**
- **NR changes when Auto starts or stops recording.** Squelch and Auto keep using the raw signal level.
- **Recordings are saved with NR baked in.** Files stay as received, so NR can be turned off or
  retuned later and the original heard. **(user)**
- **Skip silence chops words** by jumping a pause inside speech or landing after the first syllable.

## 3. Noise reduction

### 3.1 The method (from the research; the owner picked it by ear)

A statistical spectral noise reducer of the MMSE-LSA family (Ephraim–Malah log-spectral amplitude)
with a decision-directed a-priori SNR estimate and a tracked noise floor (minimum statistics or
MCRA). This is the family HF operators rate best for SSB voice (Thetis NR2/EMNR, SDR Console's
Ephraim–Malah NR, AetherSDR's macOS "MNR"). It works out, many times a second, which frequencies
are mostly hiss and turns those down, never turning anything up.

The owner compared six clips of the same 32 s of 11.175 audio (28 Oct, 16:45Z) and picked **this
method at Medium** over Light and Strong, plain spectral subtraction and an LMS line enhancer.
**(user)** The spike's Medium was: gain floor −14 dB, noise estimate × 1.5, decision-directed
α = 0.98, 1024-point STFT at 48 kHz with hop 256 (√Hann), noise floor = running minimum over 1.5 s
of the smoothed power × 1.8. The spike is `docs/superpowers/research/2026-10-28-nr-spike.py` (Python, not product code); the
research report is `docs/superpowers/research/2026-10-28-noise-reduction-research.md` (summarised in §8). The builder should reproduce that
Medium sound as the reference, then tune.

Required properties:
- **Attenuate only.** Per-frequency gain never above 1, and never below a floor (no hard gating).
- **No musical noise or burbling** at any strength the slider offers. Smooth the gain over time (and,
  if needed, across frequency).
- **Speech onsets are kept.** The first syllable after a pause must not be swallowed.
- **Latency** under about 50 ms. **CPU** small: it runs alongside the waterfall and decoders.
- **Same code live and on files**, so a recording sounds the same through NR as it did live.
- Written in Swift with Accelerate (vDSP). No GPL or LGPL code: that rules out porting WDSP
  (NR2/NNR, GPL) and libspecbleach (NR4, LGPL). **(builder's call, from the research)**

Left to the builder: frame size, hop, sample rate inside the NR (it may work on just the voice
passband at a lower rate), the noise tracker, whether to add a light impulse blanker in front for
crashes and pops (the research recommends one), and the exact maths, provided the result meets the
properties above and sounds at least as good as the spike's Medium on the owner's clip.

### 3.2 The control

- **Strength:** a continuous slider from **Light** to **Strong**, with **Medium** in the middle as
  the default. The slider's Medium must sound like the clip the owner picked. Light is gentler
  (about the spike's −8 dB floor). Strong (about −20 dB) must still meet the anti-goals: no burbling,
  no lost words. Strength maps mainly to the gain floor, perhaps with a little noise
  over-estimation. **(builder's call)** The owner said nothing about the spike's Strong, which also
  over-estimated the noise ×2.5. Keep over-estimation mild across the whole slider.
- **Loudness stays put.** Turning NR on must not sound like turning the volume down. The voice stays
  about as loud as with NR off; only the hiss around it drops.
  - This is needed because NR comes after the AGC. On a weak signal the AGC has levelled mostly hiss,
    so removing it would otherwise drop the overall level by up to about 10 dB.
  - The owner compared clips at matched loudness (the spike scales every clip to the same peak), so
    the product must match what they heard.
  - So add a slow make-up gain after NR that restores the voice level, not the hiss level. For
    example, tie it to the level of the frames NR judges to be speech, or to the gain NR applied
    there. It must never lift the noise floor back up.
  - The live limiter after the volume knob stays as it is.

  **(builder's call)**
- **Modes:** NR is offered in AM, NFM, USB, LSB and CW. In WFM (broadcast music) the button is
  disabled with a tooltip saying why, and NR is bypassed. The setting itself is kept. The player
  applies the same rule using the recording's mode. **(builder's call)**
  - Whether NR works on just the voice passband at a lower rate or full-band is the builder's call,
    as long as it suits every mode it's offered in. AM broadcast audio up to about 5 kHz and a CW tone
    must not be damaged.
- **Off** means bypass: the audio is bit-for-bit what it is today.
- Turning NR on or off, or moving the slider, never clicks. Crossfade or ramp over tens of ms.
- **One setting, shared by both windows**: on/off and strength. Changing it in one changes the other.
  **(user)**
- Saved between launches. It starts off on first launch. **(user)**

### 3.3 Where it appears **(user picked option B in the mockups)**

- **Main window:** an **NR** button in the top bar, alongside the mode, bandwidth and HamItUp
  controls. One click turns NR on or off, and it's green when on, like HamItUp. A small pop-up from
  the button (opened by a click-and-hold, a right-click, or a small chevron, as the builder sees fit)
  holds the strength slider labelled Light … Strong with the current value shown.
- **Recordings window:** the **same** button and pop-up on the player's transport row, at the right
  end, next to the Skip silence toggle. It looks and works the same as in the main window. **(user)**
- Mockup (layout only, not final styling):
  `.superpowers/brainstorm/51491-1793208649/content/nr-controls.html`.
- A menu item and keyboard shortcut for NR on/off is welcome. **(builder's call)**

### 3.4 What NR touches, and what it doesn't

- **Live:** NR acts on the receiver's audio on its way to the speakers, after AGC and the squelch
  gate and before the volume knob. **(user)**
- **Not on recordings.** The audio recorder and Auto's history keep taking the audio exactly as
  today, without NR. **(user)**
- **Not on the modems.** The modem channel's 12 kHz audio is untouched. **(user)**
- **Not on squelch or Auto.** The squelch level, the signal meter and Auto's trigger use the raw
  signal as today. **(user)**
- **Playback:** NR acts on the recording's audio as it plays, using the same processor.
  - The player today is `AVAudioPlayer`, which cannot process audio. The builder replaces or wraps it
    (for example `AVAudioEngine` with a player node and a processing stage) without losing what
    works today:
    - WAV, FLAC and M4A all play;
    - accurate seeking and position for the clock and the Dial;
    - the volume follows the main knob;
    - the live radio is silent while the window is open;
    - the "heard" marks are kept.
  - After a seek, the noise tracker needs a moment to settle. It must not blast unprocessed hiss or
    swallow the first words after a seek. For example, prime it from a little audio before the seek
    point, or from the whole file. **(builder's call)**
- With the demo source or an IQ file source, NR works the same as with the RSP.

## 4. Skip silence

### 4.1 Behaviour

- **What counts as silence:** stretches of true digital silence in the file. That covers the squelch
  gaps in older recordings and the silenced long gaps in new ones, including the short fades at their
  edges. **(user: skip short and long gaps)** Squelch-open hiss that new recordings keep for gaps up
  to *Keep gaps up to* is real audio and plays through.
- **Minimum length:** gaps shorter than about 0.25 s are not skipped, so speech isn't chopped.
  **(builder's call)**
- **Where it lands:** about 0.2 s before the next audio, so the first syllable isn't clipped.
  **(builder's call)**
- **Only while playing.** Clicking, dragging, ← → or turning the Dial into a silent stretch while
  paused leaves the playhead where it was put. Pressing Play there jumps ahead to the next audio.
  **(builder's call)**
- **While playing,** a jump made by ← → or the Dial that lands in silence is skipped onward like any
  other.
- **Trailing silence:** if the rest of the recording is silent, playback ends at the end of the
  recording, as it does today. It doesn't go on to the next recording. **(builder's call)**
- **The display:** the waveform is unchanged and the clock and Dial simply jump forward, so the skip
  is visible. **(builder's call)**
- The jump is seamless: no click, no audible gap beyond the silence it removes.

### 4.2 The control

- A **Skip silence** toggle on the player's transport row, next to NR, styled like it, green when on.
  **(user)**
- Saved between launches. It starts **on**. **(builder's call; the owner accepted it in the playback)**
- Window-only: the Dial has no control for it this round.

### 4.3 Finding the silence

The player already computes and caches waveform peaks per file. The builder may reuse that work or
scan the file separately. Either way:
- the silence map must be ready before or soon after playback starts;
- it must work on a 1.5 h file without freezing the window;
- it must be precise enough that a skip never lands inside speech.

A silence map coarser than the 0.2 s landing margin is not good enough.

## 5. Edge cases the builder must handle

- NR on while the radio is stopped: the setting is kept and applies when audio flows.
- NR toggled mid-transmission: no click, no gap.
- Very strong signals: NR at any strength must not noticeably colour a clean, strong voice. Little
  noise means little reduction.
- Static crashes and AGC pumping: NR must not "chase" a crash into a long dropout of the voice after
  it.
- Mode change or retune live: reset or re-converge the noise estimate quickly.
- A recording with no silence at all (squelch-open throughout): Skip silence does nothing.
- A recording that is all silence: Play goes straight to the end.

## 6. Testing

- **Unit tests** for the NR processor:
  - bypass at Off is bit-exact;
  - gain never above 1;
  - steady white noise is reduced by roughly the floor at each strength;
  - a clean tone or voice-like signal well above the noise passes nearly unchanged;
  - no NaNs on digital silence (the spike hit this on squelch gaps);
  - toggling produces no step.
- **A reference comparison** against the spike's Medium on the owner's clip
  (`SubFloor_20261028_164538Z_11175000Hz_USB.flac`, 24–56 s), by listening and by the same rough
  voice-above-hiss measure. The spike scored 9.7 dB at Medium against 2.5 dB unprocessed.
  - **The measure, as run:**
    1. Cut the *unprocessed* clip into 0.1 s frames (4800 samples).
    2. For each frame, take the Hann-windowed power spectrum and its spectral flatness over
       300–2500 Hz: the geometric mean over the arithmetic mean of FFT bins 30–250.
    3. Frames with flatness below 0.25 are "voice". Frames above 0.5 are "hiss". The clip gave 37
       voice frames and 206 hiss frames.
    4. For each output, score = mean frame level in dB over the voice frames, minus mean frame level in
       dB over the hiss frames. The frames are the ones chosen from the original.
  - It is a rough guide, not a pass/fail bar **(builder's call)**. A build that sounds at least as
    good as the spike's Medium, and scores within about 1 dB of it, is on target. The owner's ear
    decides.
  - It is insensitive to overall level, so make-up gain doesn't change it.
- **Skip silence tests** on synthetic files:
  - gaps above and below the minimum;
  - the landing margin;
  - paused versus playing;
  - trailing silence;
  - all-silent and never-silent files.
- **Hands-on** by the owner: live on 11.175 and on recordings, every NR strength, Skip silence on and
  off, and the Dial scrubbing alongside both.
- **CPU:** NR live must not cause dropped audio or waterfall stutter at the highest sample rate.

## 7. Left to the builder

- Everything about how the NR maths is done, within §3.1.
- How playback is re-plumbed to allow processing (§3.4).
- How silence is detected (§4.3).
- Exact styling of the button, pop-up and toggle, within §3.3 and the mockup.

## 8. Research summary

The full report is `docs/superpowers/research/2026-10-28-noise-reduction-research.md`.
- **Best fit:** statistical MMSE-LSA/OM-LSA in Swift/Accelerate. This is the family behind
  operators' favourite NRs. AetherSDR's macOS MNR runs it on Accelerate at about 0.3 ms per 10.7 ms
  hop. Strength = gain floor, 0 to −20 dB; benefit plateaus near −18 dB. Mapping strength to a gain
  exponent did worse.
- **An impulse blanker** in front helps with crashes more than a second NR stage would.
- **AI options for later:** DeepFilterNet3 (MIT/Apache, Core ML port, about 30 ms) is the strongest
  licence-clean one; RNNoise (BSD) is the easiest. Both were trained on microphone noise, not HF hiss,
  and show only small gains on weak SSB.
- **Apple's AUSoundIsolation:** tested on this Mac. It gates weak voice, muting about half the speech
  at −3 dB SNR and all of it at −9 dB. Not usable.
- **Ruled out by licence:** WDSP NR2/NNR (GPL) and libspecbleach NR4 (LGPL).
