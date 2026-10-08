# Complete Control — App OSC Reference

Complete Control's built-in effects (the **Routing** tab) can be controlled with OSC
messages, so any macro, song command or AI assistant can change any effect setting.

- Any OSC message whose address starts with **`/app/`** is handled **inside the app**.
  It is never sent to the network, and no OSC target needs to be connected.
- The message's **float value** is the new setting.
- Changes apply **instantly** (no glide) and are **saved**, exactly as if the setting
  were changed in the Routing tab.
- Values outside a parameter's range are **clamped**. Whole-number parameters are rounded.
- Every message is written to the **Activity** log: `App: Lead Vox pitch/retuneSpeed → 25`
  on success, or the reason it failed (unknown channel, effect or parameter).

> Source of truth: `Midi Set List/ModelsAppOSC.swift` (`BuiltInFXType.oscParams`).
> The app can also generate this reference with the user's real channel names:
> **Routing tab → ⋯ → Share OSC Reference**.

---

## 1. Address forms

| Address | Value | Effect |
|---|---|---|
| `/app/<channel>/volume` | 0 to 1 | Channel fader |
| `/app/<channel>/mute` | 1 = muted, 0 = unmuted | Channel mute |
| `/app/<channel>/output` | 1 to 32 | First hardware output (1-based): 3 = Out 3 (mono) or Out 3–4 (stereo) |
| `/app/<channel>/stereoOut` | 1 = stereo, 0 = mono | Stereo pair from that output, or mono to that one output |
| `/app/<channel>/<fx>/bypass` | 1 = bypassed, 0 = active | Bypass one effect |
| `/app/<channel>/<fx>/<param>` | see §3 | Set one effect parameter |
| `/app/engine/run` | 1 = start, 0 = stop | Start/stop the routing engine |

### `<channel>` — which routing channel

- The channel's **name** as shown on its strip, e.g. `Lead Vox`.
  Matching ignores case, spaces, `-` and `_`, so `lead-vox`, `LeadVox` and `lead_vox`
  all reach `Lead Vox`.
- **Names are always unique** under that matching, so a name reaches exactly one
  channel. The app enforces it: a taken name gets a number ("Vox" → "Vox 2"), and names
  that look like a position (`ch2`) or are `engine` are not allowed.
- Or its **position**: `ch1` is the first strip, `ch2` the second, and so on.
  Unnamed channels can only be reached this way.
- **Renaming a channel updates macros automatically**: when you finish editing the name
  on its strip, every device macro and song command addressed `/app/<old name>/…` is
  rewritten to `/app/<new name>/…` (the strip briefly shows how many were updated).
  Position-based addresses (`ch1`…) are not rewritten, and they change if strips are
  added or removed in front of the channel — prefer names.

### `<fx>` — which effect on that channel

The effect's short name (table below). If a channel has the **same effect twice**,
the first (lower slot) is `<fx>` and the second is `<fx>2`, e.g. `pitch` and `pitch2`.

| `<fx>` | Effect |
|---|---|
| `gain` | Gain / Pan |
| `eq` | 3-Band EQ |
| `reverb` | Reverb |
| `delay` | Delay |
| `rider` | Level Rider |
| `opto` | Opto Comp (LA-2A style) |
| `fet` | FET Comp (1176 style) |
| `notch` | Feedback Notch |
| `pitch` | Pitch Guide (pitch correction, transpose, formant) |
| `detune` | Micro Detune (micro-pitch stereo widener) |
| `harmony` | Harmony (key-aware harmonizer) |
| `body` | Piezo Body (acoustic pickup enhancer) |

### Value conventions

- **Toggle**: `1` = on, `0` = off (anything ≥ 0.5 counts as on).
- **Choice**: send the option's **number** (listed with each parameter).
- **Action**: the value is ignored; sending the message performs the action.

---

## 2. Two instances of the same effect

Two **channels** with Pitch Guide are told apart by the channel segment:

```
/app/Lead Vox/pitch/retuneSpeed  25
/app/BGV 1/pitch/retuneSpeed     60
```

Two Pitch Guides on the **same** channel are told apart by the number suffix:

```
/app/Lead Vox/pitch/transpose    0     (slot with the first Pitch Guide)
/app/Lead Vox/pitch2/transpose  -12    (slot with the second Pitch Guide)
```

---

## 3. Parameters

### `gain` — Gain / Pan
| Param | Range | Notes |
|---|---|---|
| `volume` | 0 to 2 | Linear gain, 1 = unity |
| `pan` | -1 to 1 | -1 left, 0 centre, 1 right |

### `eq` — 3-Band EQ
| Param | Range | Notes |
|---|---|---|
| `lowGain` | -24 to 24 dB | Low shelf |
| `lowFreq` | 20 to 500 Hz | |
| `midGain` | -24 to 24 dB | Parametric mid |
| `midFreq` | 100 to 8000 Hz | |
| `midWidth` | 0.05 to 5 octaves | |
| `highGain` | -24 to 24 dB | High shelf |
| `highFreq` | 1000 to 20000 Hz | |

### `reverb` — Reverb
| Param | Range | Notes |
|---|---|---|
| `room` | choice | 0 Small Room, 1 Medium Room, 2 Large Room, 3 Medium Hall, 4 Large Hall, 5 Plate, 6 Medium Chamber, 7 Large Chamber, 8 Cathedral, 9 Large Room 2, 10 Medium Hall 2, 11 Medium Hall 3, 12 Large Hall 2 |
| `mix` | 0 to 100 % | Wet/dry |

### `delay` — Delay
| Param | Range | Notes |
|---|---|---|
| `time` | 0 to 2 s | One beat = 60 ÷ BPM (use a formula: `60 / bpm`) |
| `feedback` | -100 to 100 % | |
| `cutoff` | 10 to 22050 Hz | Low-pass on the repeats |
| `mix` | 0 to 100 % | Wet/dry |

### `rider` — Level Rider (automatic fader)
| Param | Range | Notes |
|---|---|---|
| `inputTrim` | -12 to 12 dB | Before the detector |
| `target` | -30 to -6 dBFS | Level it aims for |
| `maxCut` | -18 to 0 dB | |
| `maxBoost` | 0 to 9 dB | |
| `cutSpeed` | 20 to 300 ms | |
| `boostSpeed` | 200 to 2000 ms | |
| `gate` | -60 to -20 dBFS | Below this it holds still |
| `outputTrim` | -12 to 12 dB | |

### `opto` — Opto Comp (LA-2A style)
| Param | Range | Notes |
|---|---|---|
| `peakReduction` | 0 to 100 | More = more compression |
| `gain` | 0 to 40 dB | Makeup |
| `limit` | toggle | 0 Compress (~3:1), 1 Limit (~10:1) |

### `fet` — FET Comp (1176 style)
| Param | Range | Notes |
|---|---|---|
| `input` | 0 to 48 dB | Drives into the fixed threshold: more = more compression |
| `output` | -24 to 12 dB | |
| `ratio` | choice | 0 = 4:1, 1 = 8:1, 2 = 12:1, 3 = 20:1, 4 = All buttons |
| `attack` | 1 to 7 (whole) | 7 fastest (20 µs), 1 slowest (800 µs) |
| `release` | 1 to 7 (whole) | 7 fastest (50 ms), 1 slowest (1.1 s) |

### `notch` — Feedback Notch
| Param | Range | Notes |
|---|---|---|
| `sensitivity` | 0 to 100 | Ring-out detection sensitivity |
| `maxDepth` | -18 to -6 dB (whole) | Deepest any notch may go |
| `clear` | action | Removes every ring-out notch |

### `pitch` — Pitch Guide
| Param | Range | Notes |
|---|---|---|
| `retuneSpeed` | 0 to 400 ms | Time to land on the note, same scale as Auto-Tune. 0 = instant/robotic, 10–25 tight, 50–150 natural |
| `amount` | 0 to 100 % | How far toward the note. 0 = transpose only |
| `humanize` | 0 to 100 % | Loosens retune on long held notes |
| `tolerance` | 0 to 50 cents | Notes this close are left alone |
| `pickiness` | 0 to 100 % | Higher = only clear, steady notes |
| `gate` | -70 to -20 dBFS | Quieter input (bleed) is ignored |
| `key` | choice | 0 C, 1 C#, 2 D, 3 D#, 4 E, 5 F, 6 F#, 7 G, 8 G#, 9 A, 10 A#, 11 B — key the singer sings in (fallback when following the song key) |
| `scale` | choice | 0 Chromatic, 1 Major, 2 Natural Minor, 3 Harmonic Minor, 4 Melodic Minor, 5 Dorian, 6 Mixolydian, 7 Major Pentatonic, 8 Minor Pentatonic, 9 Blues, 10 Phrygian, 11 Lydian, 12 Locrian |
| `voiceRange` | choice | 0 Low (70–400 Hz), 1 Mid (120–800 Hz), 2 High (180–1200 Hz) |
| `followSongKey` | toggle | Correct in the key of the song loaded in Perform |
| `transpose` | -12 to 12 semitones (whole) | Shifts the corrected voice (sung in D, +2 → heard in E) |
| `autoFormant` | toggle | Keeps the singer's natural tone when shifting |
| `formant` | -6 to 6 semitones | + smaller/brighter, − bigger/darker |
| `shiftOnlyWhileSinging` | toggle | Transpose/Formant switch off between phrases |
| `bleedDuck` | -20 to 0 dB | Turns the mic down between phrases. 0 = off |

### `body` — Piezo Body
| Param | Range | Notes |
|---|---|---|
| `amount` | 0 to 100 % | Body back in, quack and spikiness out. 0 = flat |
| `size` | choice | 0 Parlor, 1 Dreadnought, 2 Jumbo — where the body resonances sit |
| `phase` | toggle | Flip polarity; try it when the low end feeds back |
| `mute` | toggle | Silence the guitar (e.g. to tune) |
| `level` | -12 to 6 dB | Output level |

### `harmony` — Harmony
| Param | Range | Notes |
|---|---|---|
| `voice1` / `voice2` / `voice3` | toggle | 1 = on, 0 = muted (settings kept) |
| `interval1` / `2` / `3` | choice | 0 Octave Below, 1 6th Below, 2 5th Below, 3 4th Below, 4 3rd Below, 5 3rd Above, 6 4th Above, 7 5th Above, 8 6th Above, 9 Octave Above — in the song's key |
| `level1` / `2` / `3` | -24 to 6 dB | |
| `pan1` / `2` / `3` | -100 to 100 | -100 = left, 100 = right |
| `gender1` / `2` / `3` | -6 to 6 semitones | + smaller/brighter, − bigger/deeper; pitch stays |
| `leadLevel` | -60 to 6 dB | The singer's own voice. -60 = off (harmonies only) |
| `humanize` | 0 to 100 % | Small detune, drift and delay so the voices sound like singers |
| `followSongKey` | toggle | Harmonize in the key of the song loaded in Perform |
| `key` | choice | Same as `pitch` — fallback when following the song key |
| `scale` | choice | Same as `pitch` |
| `pickiness` | 0 to 100 % | Higher = only clear, steady notes get harmonies |
| `gate` | -70 to -20 dBFS | Quieter input (bleed) gets no harmonies |

### `detune` — Micro Detune
| Param | Range | Notes |
|---|---|---|
| `pitchA` | 0 to 50 cents | Voice A (left) shifted up. 9 = classic |
| `pitchB` | -50 to 0 cents | Voice B (right) shifted down. -9 = classic |
| `delayA` | 0 to 2000 ms | Voice A delay (when not tempo-synced). The shifter adds ~25 ms on top |
| `delayB` | 0 to 2000 ms | Voice B delay (when not tempo-synced). The shifter adds ~25 ms on top |
| `tempoSync` | toggle | Delays follow the loaded song's tempo as note values |
| `noteA` | choice | 0 1/32, 1 1/16T, 2 1/16, 3 1/8T, 4 1/16., 5 1/8, 6 1/4T, 7 1/8., 8 1/4, 9 1/4., 10 1/2 |
| `noteB` | choice | Same as `noteA` |
| `pitchMix` | 0 to 100 % | 0 = only A, 50 = both, 100 = only B |
| `mix` | 0 to 100 % | 50 = dry and wet both full; above that the dry fades |
| `feedback` | 0 to 95 % | Repeats shift further each time: rising/falling repeats |
| `tone` | -100 to 100 | − darker, 0 flat, + brighter (voices only) |
| `lowCut` | 20 to 600 Hz | Keeps the low end out of the voices. 20 = off |
| `modDepth` | 0 to 100 % | Chorus: at 100 each voice swings from 0 to 2× its shift |
| `modRate` | 0.1 to 10 Hz | Speed of the chorus |

---

## 4. Examples

| Goal | Address | Value |
|---|---|---|
| Tight tuning on the lead vocal | `/app/Lead Vox/pitch/retuneSpeed` | 15 |
| Natural tuning on the lead vocal | `/app/Lead Vox/pitch/retuneSpeed` | 120 |
| Transpose BGV up a whole step | `/app/BGV/pitch/transpose` | 2 |
| Octave-down doubler on the 2nd Pitch Guide | `/app/Lead Vox/pitch2/transpose` | -12 |
| Correct in A minor | `/app/Lead Vox/pitch/key` + `/app/Lead Vox/pitch/scale` | 9, then 2 |
| Slam the 1176 for a chorus | `/app/Lead Vox/fet/ratio` | 4 |
| Bypass the FET comp on channel 1 | `/app/ch1/fet/bypass` | 1 |
| Delay of one beat at the song's tempo | `/app/Lead Vox/delay/time` | formula `60 / bpm` |
| Mute a channel | `/app/Keys/mute` | 1 |
| Send the lead vocal to Out 5 only (mono) | `/app/Lead Vox/output` + `/app/Lead Vox/stereoOut` | 5, then 0 |
| Clear ring-out notches | `/app/Lead Vox/notch/clear` | 0 |

A macro that changes several settings at once is a **group macro** of single-message
OSC macros, the same as for any other OSC device.

---

## 5. Notes for AI integrations

- Build each macro as **one OSC message**: `oscAddress` = an `/app/` address, `oscFloatArg` = the value.
- Use **only** channel names that exist (ask the user, or read the "Channels right now"
  list in the in-app generated reference). If unsure, `ch1`… by position also works.
- Use **only** parameter keys from §3 (they are case-insensitive) and stay inside the ranges.
- For choices send the **number**, not the label.
- An effect type can't be changed over OSC (that needs an engine restart); only its settings.
- In-app assistant: name a device **"Complete Control"** (or "App") in the device library
  and its AI macro chat will build `/app/` macros using the live channel list.
