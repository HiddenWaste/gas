# The Glassian Autonomous System: first rebuild

A SuperCollider system that reads a **composition file** (a small data structure describing instruments, harmonic constraints, how things should evolve, and a timeline) and **performs** it. Figures repeat, grow, shrink, transpose, and drift against each other, so no two runs are the same. You can talk to it while it plays.

See [`ANALYSIS.md`](ANALYSIS.md) for what was wrong with the archived version and [`THOUGHTS.md`](THOUGHTS.md) for where this could go next.

```
claudes-first/
├── main.scd               entry point: evaluate it, then ~gas.start
├── synthdefs.scd          7 instruments + reverb / master / analyzer
├── core/
│   ├── state.scd          ~gas namespace, defaults, logging, composition loader + validator
│   ├── theory.scd         scale degrees -> MIDI, note names, range folding
│   ├── engine.scd         voices, the mutation model, playback   <- the heart
│   ├── timeline.scd       timeline runner (sections, nested loops, goto), queue
│   └── control.scd        commands, start/end, monitor + reactions, OSC, analysis, status
├── compositions/
│   ├── glassian.scd       "Organ Study No. 1": additive organs over a looping i-VI-iv-V
│   ├── drift.scd          "Tide Tables": Reich-style phasing mallets, loops forever
│   └── template.scd       the smallest useful composition
├── tests/
│   ├── dry-run.scd        headless: 1,954 checks incl. full high-speed runs of every piece
│   ├── render-synthdefs.scd   offline (NRT) render of every SynthDef -> tests/out/synthdefs.wav
│   └── live-smoke.scd     boots the real server, plays 10 s (silently by default)
└── recordings/            60 s excerpts of both pieces, seed 1977 (made with the test setup)
```

## Running it

1. Open `main.scd` in the SuperCollider IDE (3.13 is what this was tested on).
2. Evaluate the big `( ... )` block (cursor inside, **Ctrl/Cmd+Enter**).
3. When `System ready` prints, evaluate `~gas.start;`.
4. Evaluate lines from the cheat sheet at the bottom of `main.scd` while it plays. `~gas.end(16)` fades out and stops.

To pick a different piece, change `composition:` at the top of `main.scd`, or call `~gas.loadComposition("drift"); ~gas.start;`.

**No soundcard?** Set `dryRun: true`. The whole engine still runs on the clock, but notes are logged rather than played.

### Tests (from a terminal)

```sh
sclang -i none tests/dry-run.scd            # exits 0 when all checks pass
sclang -i none tests/render-synthdefs.scd   # writes tests/out/synthdefs.wav
sclang -i none tests/live-smoke.scd         # needs a working audio server; silent unless you pass a volume
```

Prefix with `QT_QPA_PLATFORM=offscreen` on a machine without a display. If a script has a **parse error**, sclang prints it and then waits forever, so use `timeout`. sclang also buffers output when it isn't writing to a terminal, so wrap a run in `script -q -c "..." log.txt` to keep the error text if you have to kill it.

On this machine scsynth uses JACK, and PipeWire owns the soundcard without the `pipewire-jack` shim installed. The live test and the recordings were made against a dummy JACK server: `jackd -n gasdummy -d dummy -r 48000 &` and `JACK_DEFAULT_SERVER=gasdummy sclang ...`. To hear it for real, either install `pipewire-jack` (then scsynth talks to PipeWire directly) or stop PipeWire and run jackd on the card.

---

## How it thinks

Each **instrument** is a voice looping a short **figure**: scale degrees, `\r` for rests, arrays for chords. One pass through the figure is a **cycle**.

- **When** a figure changes: every `period` cycles the voice rolls `chance`. Mutations only land on the voice's own downbeat.
- **Direction**: the `process` decides what kinds of change are allowed right now.
  - `\additive` grows (and doesn't shrink); `\subtractive` is the reverse.
  - `\breathe` grows to `maxLen`, shrinks to `minLen`, and repeats.
  - `\static` keeps the length fixed; `\free` allows anything.
- **Strength** (0..1) sets the size of transpositions and leaps, and whether two mutations stack.
- **Weights** pick the kind of mutation: `grow shrink transpose retrograde invert rotate swap neighbor shade rhythm rest`.

**Glass's additive process** is built in. Give an instrument a long `figure:` and a short `start:`, and *grow* reveals the next written note (1 2 → 1 2 3 → 1 2 3 4…) before it starts inventing new ones.

**Phasing** happens naturally whenever voices have different figure lengths. Reich-style drift is also available: `\stretch` slows a voice slightly, and `\nudge` shifts it by a fraction of a beat.

Because figures are **scale degrees**, `\scale` changes the mode of everything at each voice's next downbeat. `\chord` moves the whole texture diatonically, which is how the chord progressions in `glassian.scd` are written.

## The composition file

One Event literal; everything is optional except `instruments`. Full defaults are in `core/state.scd` (`~gas.defaults`).

```supercollider
(
name: "My Piece",
system: (tempo: 132, beatsPerBar: 4, volume: 0.7, reverb: (room: 0.7, damp: 0.5, level: 1),
         seed: nil, status: 8, oscOut: nil, analysis: true, verbosity: \normal),
constraints: (root: \A3, scale: \minor, range: [40, 88]),
evolution: (process: \additive, period: 4, chance: 0.7, strength: 0.5, unfold: 0.8,
            weights: (grow: 4, shrink: 4, transpose: 1, rotate: 1 /* ... */)),
styles: (myStyle: (process: \breathe, period: 2)),       // adds to built-ins: glass, ostinato, wander
instruments: (
    organ: (sound: \gasOrgan, figure: [0, 2, 4, 2, 4, 7], start: 3, style: \glass,
            pulse: 0.5, minLen: 2, maxLen: 8, amp: 0.2, pan: -0.3, verb: 0.25,
            octave: 0, range: [52, 81], legato: 0.9, accent: 0.2, human: 0.04, stretch: 1)
),
timeline: [
    [0,  \section, \A],
    [0,  \in, \organ],
    [32, \chord, 5],
    [64, \loop, \A, 2],        // two more passes; nested loops and inf are fine
    [64, \end, 16]
],
reactions: [ (name: \busy, when: { |gas, m| m.density > 8 }, then: [\process, \all, \subtractive], cooldown: 32) ],
commands: ( myCommand: { |gas, arg1| /* usable in the timeline, live, and over OSC */ } )
)
```

An instrument's settings resolve in this order, later winning: `defaults.voice` < `evolution` < `styles[style]` < the instrument entry. The loader **validates** before accepting a file: unknown instruments, commands, sections, styles, SynthDefs, and the old `synth:`/`every:` key names are all reported at once.

## Commands

The same vocabulary works in the timeline (`[beat, \cmd, ...]`), live (`~gas.cmd(\cmd, ...)`), queued (`~gas.queue(when, \cmd, ...)`, where `when` is beats, `\bar` or `\bars4`), in reactions, and over OSC (`/gas/cmd cmd args...` to port 57120). A `target` is an instrument name, `\all`, or an array of names.

| command | args | |
|---|---|---|
| `section` | name | marks a section (and the jump target for `loop`/`goto`) |
| `loop` | section, times | timeline only. Jump back `times` more times (`inf` = forever) |
| `goto` | section | jump. Live use waits for the next bar |
| `in` / `out` | instrument, [figure] / [\now] | enter (live: on the next bar) / leave at the end of the cycle |
| `scale` / `root` / `shift` / `chord` | name / note / semitones / degree | harmony |
| `process` | target, process | direction of evolution |
| `evolve` | target, (params) | set any evolution keys, e.g. `(strength: 0.8, period: 2, weights: (rotate: 3))` |
| `mutate` | target, op | force one mutation now |
| `figure` / `revert` | target, [degrees] / target | replace the figure / back to the written one |
| `snapshot` / `recall` | name | save/restore every voice's figure |
| `vol` | target or `\master`, amp, [beats] | set or fade |
| `pan` / `verb` / `mute` | target, value | mix |
| `tempo` | bpm, [beats] | set or ramp |
| `stretch` / `nudge` | target, factor / beats | phasing |
| `post` / `func` / `end` | words / fn / [beats] | log, run code, fade out and stop |

Reading the system: `~gas.status`, `~gas.metrics` (density, span, pitch classes, tension), `~gas.analysis` (amp, centroid, flatness, onsets from the server), `~gas.recent(n)`, and, with `system.oscOut: ["127.0.0.1", 9000]`, a `/gas/metrics` message every bar plus `/gas/section`, `/gas/mutation`, `/gas/voice`… as they happen.

## Adding things

- **A sound:** a SynthDef in `synthdefs.scd` following the contract at the top of that file (`out send sendAmt freq amp pan`, plus `gate` if it sustains). Then use `sound: \yourDef`.
- **A mutation:** a function in `~gas.mutations` (`core/engine.scd`) returning a description or `nil`. Then give it a weight.
- **A command:** in a composition's `commands:`, or globally in `~gas.commands` (`core/control.scd`).

### SuperCollider gotchas this code avoids (worth knowing when editing)

1. Functions stored on an Event run as methods: `~gas.foo(1)` calls `foo.(~gas, 1)`. **A real Event method with the same name wins silently**, setters included. That's why the clock is `beatClock` (Event has `clock_`) and instruments use `sound:`/`period:` (Event has `synth`/`every`). `tests/dry-run.scd` checks every key for this.
2. Dot access *calls* a stored function, so read function-valued data with brackets: `r[\when]`.
3. No `^` in interpreted functions. It silently aborts the whole block.
4. Every `var` goes at the top of its function.
