# Thoughts on the Glassian Autonomous System

*Written after the first analysis and rebuild, November 2026.*

## The project as a whole

The core idea is strong and specific. It isn't "generative music" in general but a **score that is a set of tendencies**, read by a system that performs it, with a human able to lean on it in real time. That puts it in good company (Eno's tape systems, Reich's process pieces, Riley's *In C*, which is the closest cousin structurally), but the Glass angle gives it a sharper identity than most generative systems have.

What makes Glass's music *Glass* rather than generic minimalism is something worth designing around: **change is rare, structural, and audible precisely because everything else holds still.** A figure repeats until you know it. Then one note is added and you hear the whole thing regroup. The archive's engine (and, by default, this one) could easily drift toward *busy*: several voices mutating independently every few cycles. That produces texture, but texture isn't the same as the "aha" of an additive process. The single most important musical setting in this system is probably **the rate of change**, and the most Glassian default is a *low* one. I'd treat `period` and `chance` as the main expressive controls, more than the mutation types.

The rebuild's two biggest representational choices both serve that:

1. **Figures are scale degrees, not MIDI notes.** Harmony becomes a *lens* the figures are seen through. A `\scale` or `\chord` change re-colours every repeating figure at once, without touching the figures. That is how Glass's harmonic motion works (the figure stays the same and the bass moves underneath it), and it deleted most of the archive's snapping code.
2. **Change happens per voice, on its own downbeat.** Voices with different figure lengths therefore drift against each other, and the "phasing" emerges from the structure rather than being simulated by a rotation routine. That's the emergence `project-idea.md` talks about, coming from the mechanism itself.

I think the composition-file idea is right, and the question in `project-idea.md` ("how much pattern definition do I want in this file?") resolves fairly well once figures are one-liners like `figure: [0, 2, 4, 2, 4, 7], start: 3`. The file stays short because **styles** carry the behaviour and **defaults** carry everything else. `template.scd` is a complete, playable piece in 20 lines.

## Answers to the open questions in project-idea.md

**System + timing folded together?** Yes. `system:` holds tempo, meter, volume, reverb, seed and OSC. It reads better, and since `~gas.comp.system` is one place, other code (OSC, status, reactions) knows where to look.

**Instruments vs. patterns: what goes where?** My proposal, as built:
- an **instrument** is *what it sounds like* plus *what it plays* (`sound`, `figure`, `range`, mix);
- a **style** is *how it behaves* (`process`, `period`, `chance`, `strength`, `weights`);
- **evolution** holds the global behavioural defaults.

The one case this doesn't cover is one sound playing several independent lines (two organ hands, say). If that comes up, the next step would be separating `sounds:` from `voices:` (each voice referencing a sound). I didn't do it yet because it adds a level of indirection every composition would pay for.

**Loops in the timeline?** Done: `[beat, \loop, \section, times]`, nested and counted, or `inf`. Loops move the *timeline*, not the voices, so a looped section is never the same twice. The figures have evolved since the last pass. I think that's the right semantics for this project, and it's worth being deliberate about. If you ever want a section to replay its *figures* too, `\snapshot`/`\recall` or `\revert` at the section start does that.

**Object-oriented vs. simpler?** I simplified the plumbing (one namespace, plain Events, no string-path state manager) but kept the modular file layout. Events-as-objects is the right choice while the design is fluid: you can redefine one function and re-evaluate without recompiling the class library. It has sharp edges, though. Real Event methods silently shadow your functions (`clock_`, `synth`, `every` and `group` all bit or nearly bit this rebuild), dot access calls stored functions, and `^` is a trap. When the design settles, **porting the engine to real classes** (a small Quark: `GASystem`, `GAVoice`, `GATimeline`) would remove that whole category of bugs, make it faster, and make it shareable. I'd keep compositions as `.scd` Events even then, because being able to put a function in a reaction is too useful to give up.

## What I'm not sure about (honest limitations)

- **I couldn't listen to it.** Everything here was checked structurally: 1,954 headless checks, an offline render of every SynthDef with level and NaN checks, a live server smoke test, and two 60-second recordings checked for clipping. Whether the weights, styles, and the default rate of change *sound* good is unverified. `recordings/glassian-excerpt.wav` and `recordings/drift-excerpt.wav` are the first thing to listen to. They were recorded at slightly lower master volumes than the current defaults (0.6/0.65, now 0.8/0.75), so they peak around −16 dBFS.
- **The tension metric is a placeholder.** It's a 0.4/0.3/0.3 blend of note density, pitch span and pitch-class count, kept from the archive's instinct and made cheaper. It's useful for reactions (`m.density > 9`), but it doesn't know about consonance or the current chord. Treat it as a hook, not a model.
- **Reactions see the previous bar.** The monitor runs on the bar line, and TempoClock doesn't guarantee whether it runs before or after timeline events scheduled for the same beat. In practice this means a one-bar lag, which is harmless for musical decisions but worth knowing.
- **Seeds make dry runs reproducible, not live ones.** The test proves the same seed gives the identical mutation history. Live, the analysis-driven reactions and real-time jitter break that. A true "replay this performance" feature needs logging rather than seeding (see *offline rendering* below).
- **`\chord` is diatonic.** Diatonic shifts are exactly what Glass-style progressions need, but a major V in minor needs an explicit `\scale, \harmonicMinor` (as in `glassian.scd`). Chord *qualities* (applying a different scale per chord) would be a natural extension.
- **The sounds are sketches.** They follow the contract and are balanced, but `FreeVerb` and a sine-stack organ won't carry a performance. The sampled instruments the roadmap wanted are the obvious upgrade.

## Where it could go

Roughly in the order I'd do them:

1. **Listen, then tune the defaults.** Run each piece several times with different seeds, record (`~gas.rec`), and adjust `period`/`chance`/`weights` until changes feel like events. One concrete feature I'd add first: **a global change throttle** (e.g. `system.maxChangesPerBar: 1`), so only one voice changes at a time across the ensemble. That one rule probably does more for the "Glass sound" than any new mutation type.

2. **Bring samples back without a sample manager.** Write a `\gasSampler` SynthDef that follows the same contract, plus a tiny loader that maps a folder of files to MIDI numbers (choosing the nearest sample and repitching by `rate`). Instruments then say `sound: \gasSampler, bank: \marimba`. Normalise the note spelling when loading (Iowa files use flats; see ANALYSIS §2.4).

3. **Voice relationships.** The archive specified these in detail but never implemented them (piano influencing marimba rhythm, and so on). The clean way in this architecture is **couplings**: when voice A mutates, voice B follows with probability *p*, applying the same op or a mirrored one:
   ```supercollider
   couplings: [ (from: \organ, to: \organ2, follow: \transpose, chance: 0.5) ]
   ```
   `evolveVoice` already emits an event on every mutation, so this would be about 20 lines.

4. **Continuous shapes, not just steps.** Allow `curves: (strength: Env([0.2, 0.8, 0.3], [128, 128]))` or `[t, \ramp, \all, \strength, 0.8, 64]`, so a composition can describe arcs (gradually more volatile, then calming) rather than stair-steps.

5. **A "composed" mode alongside the evolving one.** Glass scores are literally figures with repeat counts. A per-voice `sequence: [[figA, 8], [figB, 4], ...]` would let a piece mix fixed passages with autonomous ones, which is a good way to give pieces landmarks.

6. **Performance surface.** OSC in/out is already there. A small SC Qt window (or Open Stage Control/TouchOSC) with per-voice process, strength and mute would make it playable without typing. A visual display of each voice's figure as it changes (a scrolling piano roll fed by `/gas/mutation`) would be beautiful and would also make the system legible to an audience.

7. **Sync with other musicians: `LinkClock`.** SuperCollider ships an Ableton Link clock. Swapping `TempoClock` for `LinkClock` in `~gas.start` would let the system play in time with a DAW or other performers. It's nearly free and fits the "system as performer" idea.

8. **MIDI out.** Allow `sound: \midi, chan: 2` (the Event `\midi` type) so the engine can drive hardware synths or a DAW instrument. The engine wouldn't change at all.

9. **Offline rendering and replay.** Run the engine in dry mode on a virtual clock, collect every note event into a `Score`, and render it with NRT. That gives faster-than-real-time renders, A/B comparisons between seeds, and true replay of a logged live performance.

10. **Freeze a moment into a new piece.** `~gas.export("name")` writes the current figures, harmony and settings out as a new composition file. Combined with snapshots, that turns improvising with the system into a way of composing *for* it.

## Smaller improvements I noticed along the way

- Per-voice mutation history, so you can ask `~gas.why(\organ)` what happened to a voice during a performance.
- Command argument checking in the validator (currently it checks names, not types).
- Non-12-TET scales: `resolveScale` warns and treats degrees as semitones. SC's `Tuning` support would make microtonal pieces straightforward.
- Velocity → timbre in the SynthDefs (brighter when louder), plus a slow auto-pan, would add life cheaply.
- Better space: `JPverb`/`Greyhole` from sc3-plugins, or a convolution reverb.
- Optional Pdef wrapping of each voice, for live coders who want to override a voice's pattern directly.
- Put `tests/dry-run.scd` in CI if this becomes a git repo. It runs in about a minute and has already caught real bugs.

## Closing

The archive had nearly all the right ideas: composition file, process, timeline, analysis, OSC. It had too many ways of doing each one, and a few SuperCollider traps that stopped it running. The rebuild is mostly an act of choosing one way for each: one namespace, one clock, one command vocabulary, one representation of pitch, one model of change. What's left is small enough to hold in your head, which matters for a system you want to *play*. The next real step isn't more code. It's listening to it and deciding what it should sound like when it's at its best.
