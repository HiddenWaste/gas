# Analysis of the archived system

This is a read-through of everything in `archive/` (≈4,100 lines across `main.scd`, the six `core/` modules, the two presets, and `sample-config.scd`; `current-state.md/.txt` are concatenated copies of the same sources). The goal was to work out what the system was *trying* to be, what actually ran, and what to keep.

Line references are to files under `archive/`. Each claim marked **(verified)** was reproduced in SuperCollider 3.13.0 on this machine, not just inferred from reading.

---

## 1. What the design got right (and the rebuild keeps)

- **One composition file read by an interpreter.** `presets/default.scd` is already close to the idea in `project-idea.md`: system/timing, instruments, musical constraints, a timeline of events. The rebuild keeps this and makes it the only way a piece is defined.
- **Timeline events with sections and jumps.** `sectionMarker` and `sectionJump` are the right primitives. They become `\section` and `\loop`/`\goto`.
- **An additive/subtractive "process" as a global mode.** This is the most Glassian idea in the code, and it's now central to the engine.
- **Pattern transformations** (invert, retrograde, transpose), plus the rotation that `setupPhasePatterns` was reaching for. All are kept as mutations.
- **A tension measure that can trigger changes.** It was over-engineered but the instinct is right. It's now a cheap `metrics` block plus composition-defined `reactions`.
- **OSC command surface and audio analysis.** The archive had the right list of interaction points. They now all go through one dispatcher.

---

## 2. Why it didn't run as written

These would stop or silently break the system before any music evolved.

### 2.1 `^` early returns abort the whole program (verified)
There are **28** guard clauses like `if(x.isNil) { ...; ^false; };` across `core/*.scd` and `config/`. `^` means "return from the enclosing *method*", and interpreted code has no method. In SC 3.13, when such a guard fires, the **entire top-level interpreted block exits silently**: no error, and nothing after it runs. So a single failed guard inside the big `s.waitForBoot { ... }` block in `main.scd` would quietly skip the rest of startup.

### 2.2 `~stateManager.init(~tempo)` passes the Event, not the tempo (verified)
`main.scd:44`. Calling a function stored on an Event *with method syntax* (`e.init(x)`) passes the Event itself as the first argument. `init = { |clockTempo=120| ... TempoClock.new(clockTempo/60) }` therefore receives the Event as `clockTempo` and fails on `Event / 60`. Every other call site uses `.init.()` or `.foo.(args)`, so the two calling conventions are mixed. The rebuild uses method syntax everywhere, with `|self, ...|` as the first argument.

### 2.3 Module paths can't resolve
`main.scd:43-63` builds paths with `thisProcess.nowExecutingPath` **inside** the `s.waitForBoot` callback, by which time it is `nil`. The paths also use Windows-only backslashes (`"core\\state-manager.scd"`). The rebuild captures the root directory before booting and joins paths with `+/+`.

### 2.4 Sample names never matched for accidentals
Both `noteToName` functions (`musical-constraints.scd:323`, `state-manager.scd:406`) spell notes with sharps (`C#4`, `F#4`). The University of Iowa sample files name them with flats (`Db4`, `Gb4`), and the fallback converter in `main.scd:615` uses flats too. Every pattern note on a black key would have hit "Note ... not loaded" and played nothing. (Check your sample folder to confirm the spelling. The mismatch between the two converters is in the code either way.)

### 2.5 Two clocks
`main.scd:34` creates `~clock`, and `state-manager.scd:22` creates `~stateManager.clock`. Every routine plays on the second one (`pattern-engine.scd:388`, `timeline-interpreter.scd:134`, ...), but `~setTempo` (`main.scd:595`) changes the first. Tempo changes did nothing.

### 2.6 Instruments started twice
`~startSystem` starts **both** `startBeatCounter` (`main.scd:515`), which starts instruments from `entryTimes`, **and** the timeline (`main.scd:530`), which starts the same instruments from its `instrumentStart` events. `executeEvent` doesn't check whether a voice is already playing, so piano got two routines at beat 0. The second overwrote the first in `activePatterns`, leaving an orphan that `stopPattern` could never stop.

### 2.7 Section jumps replay everything before them
On `sectionJump`, `prepareQueue` (`timeline-interpreter.scd:187`) re-queues **all** events, and the runner pops everything with `beat <= currentBeat`. Jumping to "intro" therefore re-fired every intro event, including `instrumentStart`, which compounds 2.6.

### 2.8 The analyzer SynthDef can't build
`data-analyst.scd:58-63` writes `ZeroCrossing.ar` (audio rate) to `Out.kr` (control rate). The OSC commands `start`/`stop` call `~stateManager.start/stop`, which don't exist.

---

## 3. Logic that ran but didn't do what it said

| Where | Intent | What actually happened |
|---|---|---|
| `pattern-engine.scd:335,383` | evolve every `additionRate` **beats** | `beatCount` counts **pattern loops**, so evolution happened every 16 *cycles*, and the interval varied with pattern length |
| `pattern-engine.scd:314` | per-instrument process type | `startPattern(processType)` overwrites the **global** process for everyone |
| `pattern-engine.scd:254,229,90` | velocities between `velocityMin`/`velocityMax` | hard-coded `rrand(0.15, 0.25)`; `velocityMin/Max/StepSize`, `rhythmStepSizes`, `resetThreshold` were never read |
| `pattern-engine.scd:256,277` | modify a copy | `currentPattern.copy` is shallow, so `newPattern[idx].vel = ...` mutated the stored events in place. Snapshots had the same problem |
| `pattern-engine.scd:483,492` | phase shifting | `rotate(size * i/8)`: instrument 0 never shifts, and short patterns round to 0 |
| `pattern-engine.scd:520` | additive/subtractive cycling | `setupProcessCycling` is a stub, so `additiveDuration`/`subtractiveDuration` were unused |
| `state-manager.scd:191` | instrument relationships | defined in detail but never applied (`createInfluencedPattern` is never called) |
| `musical-constraints.scd:161` | harmonic density | counts **notes**, not distinct pitch classes, and was recomputed (and logged) inside every single mutation |
| `main.scd:270,288` | reverb send | a reverb synth reads a bus that nothing ever writes to |
| `presets/default.scd` | a preset | never loaded. `main.scd` hard-codes a duplicate, and the preset uses different key names (`pattern` vs `process`, `instruments` vs `audio`) and capitalised instrument names (`Piano`) that the engine (`\piano`) wouldn't match |
| `pattern-engine.scd:590` | skip nil patterns | `{ nil }` is a no-op, and the values were computed before the check |

---

## 4. Structural observations

- **State in triplicate.** Instrument lists, volumes, pans, and limits exist in `state-manager.scd`, `main.scd`, and the preset, with drifting key names. A 400-line state manager mostly wraps `Event` get/put behind `"dotted.string.paths"`.
- **Hard-coded instruments.** `piano/marimba/flute` appear in `case` statements in the engine (`pattern-engine.scd`'s articulation switch, `state-manager.scd`'s beat counter, `main.scd`'s `playNoteDirect`). You couldn't add an instrument without editing core code.
- **MIDI-number patterns plus scale snapping.** Storing notes as MIDI numbers meant every transformation had to snap back into the scale, and when it couldn't, it picked a random note (`invertPattern`, `transposePattern`). Most of `musical-constraints.scd` exists to fix that.
- **Logging as the main output.** Every evolution posts the full pattern twice plus a tension update. That's great for development but drowns the post window in performance.

---

## 5. What the rebuild changes, in one table

| Archive | Rebuild (`claudes-first/`) |
|---|---|
| 5 namespaces, 2 clocks | one `~gas` Event, one `~gas.beatClock` |
| `"a.b.c"` string-path state manager | plain Events. Defaults are deep-merged under the composition |
| MIDI notes + snapping | **scale degrees**, converted only at play time. Mode changes, diatonic transposition and chord shifts come for free |
| per-loop counters, ad-hoc phase routine | per-voice **cycle** model: `period` × `chance` = when, `process` = direction, `strength` = size |
| timeline + beat counter + OSC + analysis each executing events their own way | one command vocabulary, one dispatcher (`~gas.cmd`) |
| timeline re-queue on jump | index-based runner, with nested, counted, or infinite `\loop`s |
| samples + sample manager | 7 small SynthDefs following one contract |
| no tests | headless dry-run suite (1,954 checks), offline SynthDef render, live smoke test |

Size: the system itself (`main.scd`, `synthdefs.scd`, `core/`) is ≈1,200 lines of code with comments and blank lines stripped, compared with ≈2,300 for the archive's `main.scd` + `core/`. With its (deliberately heavy) comments it is ≈1,870 lines, and ≈2,500 including the three compositions and the tests.
