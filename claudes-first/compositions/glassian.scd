// =====================================================================
// compositions/glassian.scd: "Organ Study No. 1"
// =====================================================================
// A Glass-inspired study: organ arpeggios unfold additively over a
// looping i - VI - iv - V progression in A minor, a bass ostinato
// anchors it, a choir and a second organ thicken it, then the music
// shifts mode (dorian), thins out subtractively, and the opening
// figures return for the coda.
//
// A composition file is ONE Event literal. Its last value is what the
// loader receives. Anything you leave out comes from core/state.scd's
// `defaults`. It's still SuperCollider code, so comments, arithmetic and
// functions (see `reactions`) are allowed.
//
// Figures are SCALE DEGREES in the current scale: 0 = root, 2 = third,
// 4 = fifth, 7 = root an octave up, -3 = the fifth below. \r is a rest,
// [0, 2, 4] is a chord.
// =====================================================================
(
name: "Organ Study No. 1",
about: "Additive organ arpeggios over a looping minor progression",

// ---------------------------------------------------------------------
// SYSTEM: timing and audio together
// ---------------------------------------------------------------------
system: (
	tempo: 138,
	beatsPerBar: 4,
	volume: 0.8,
	reverb: (room: 0.75, damp: 0.45, level: 0.9),
	seed: nil,              // e.g. 1977 for a repeatable performance
	status: 8               // print a one-line status every 8 bars
),

// ---------------------------------------------------------------------
// CONSTRAINTS: the harmonic world everything is folded into
// ---------------------------------------------------------------------
constraints: (
	root: \A3,              // = MIDI 57
	scale: \minor,
	range: [40, 88]
),

// ---------------------------------------------------------------------
// EVOLUTION: global defaults. Styles and instruments override these.
// ---------------------------------------------------------------------
evolution: (
	period: 4,              // check for mutation every 4 cycles
	chance: 0.8,
	strength: 0.35
),

// ---------------------------------------------------------------------
// INSTRUMENTS: a sound + a figure + (optionally) a style and overrides
// ---------------------------------------------------------------------
instruments: (

	// The main voice. A long seed figure that starts with only 3 notes and
	// unfolds 1-2-3 -> 1-2-3-4 -> ...; then \breathe shrinks it back.
	organ: (
		sound: \gasOrgan, style: \glass,
		figure: [0, 2, 4, 2, 4, 7, 4, 2],
		start: 3, minLen: 2, maxLen: 8,
		pulse: 0.5,
		amp: 0.22, pan: -0.35, verb: 0.25,
		range: [52, 81]
	),

	// A second organ an octave up, in a different length, so the two
	// drift against each other: 6 against the first organ's 3..8.
	organ2: (
		sound: \gasOrgan, style: \glass,
		figure: [4, 7, 9, 7, 4, 2],
		start: 2, minLen: 2, maxLen: 6,
		octave: 1, pulse: 0.5,
		amp: 0.14, pan: 0.4, verb: 0.3,
		range: [64, 88],
		process: \additive
	),

	// Bass ostinato in quarter notes. The ostinato style barely changes it.
	bass: (
		sound: \gasBass, style: \ostinato,
		figure: [0, \r, 0, -3],
		octave: -2, pulse: 1, legato: 0.7,
		amp: 0.3, pan: 0, verb: 0.05,
		range: [28, 52]
	),

	// Choir: slow chord tones, two beats each
	choir: (
		sound: \gasChoir, style: \ostinato,
		figure: [4, 2, 0, 2],
		pulse: 2, legato: 0.98,
		amp: 0.12, pan: 0.1, verb: 0.5,
		range: [57, 76],
		weights: (neighbor: 2)
	),

	// Flute: enters in the dorian section and wanders
	flute: (
		sound: \gasFlute, style: \wander,
		figure: [7, 9, 11, 9, 7, \r],
		pulse: 0.5, minLen: 3, maxLen: 9,
		amp: 0.13, pan: 0.2, verb: 0.4,
		range: [69, 93]
	)
),

// ---------------------------------------------------------------------
// TIMELINE: [beat, \command, args...]. Beats are TIMELINE beats: a
// \loop jumps the timeline back, while the voices keep evolving
// through it.
// ---------------------------------------------------------------------
timeline: [
	[0,   \section, \opening],
	[0,   \in, \organ],
	[16,  \in, \bass],

	// i - VI - iv - V, eight beats per chord, played four times
	[32,  \section, \cadence],
	[32,  \scale, \minor],
	[32,  \chord, 0],                   // A minor
	[40,  \chord, 5],                   // F
	[48,  \chord, 3],                   // D minor
	[56,  \scale, \harmonicMinor],      // raise G to G# ...
	[56,  \chord, 4],                   // ... so this is E major: the dominant
	[64,  \loop, \cadence, 3],

	// thicken: second organ and choir, the progression at half speed, twice
	[64,  \section, \growth],
	[64,  \scale, \minor],
	[64,  \chord, 0],
	[64,  \in, \organ2],
	[80,  \in, \choir],
	[96,  \chord, 5],
	[112, \chord, 3],
	[120, \scale, \harmonicMinor],
	[120, \chord, 4],
	[128, \loop, \growth, 1],

	// modal shift: same root, dorian colour (F# instead of F); flute enters
	[128, \section, \bright],
	[128, \scale, \dorian],
	[128, \chord, 0],
	[128, \in, \flute],
	[128, \evolve, \all, (strength: 0.55)],
	[160, \chord, 3],                   // D major in A dorian
	[176, \chord, 0],

	// subtractive: everything shrinks, voices leave one by one
	[192, \section, \thinning],
	[192, \scale, \minor],
	[192, \process, \all, \subtractive],
	[192, \evolve, \all, (period: 2)],
	[208, \out, \flute],
	[216, \out, \choir],
	[224, \out, \organ2],

	// recapitulation: the written figures return, progression once more
	[240, \section, \coda],
	[240, \revert, \all],
	[240, \process, [\organ], \breathe],
	[240, \evolve, \all, (period: 4, strength: 0.3)],
	[240, \chord, 0],
	[256, \chord, 5],
	[264, \scale, \harmonicMinor],
	[264, \chord, 4],
	[272, \scale, \minor],
	[272, \chord, 0],
	[272, \end, 16]
],

// ---------------------------------------------------------------------
// REACTIONS: the system listening to itself (checked once per bar)
// ---------------------------------------------------------------------
reactions: [
	// If the texture gets crowded, thin everything for 8 bars, then go
	// back to breathing. A function `then:` can do several things at once.
	(
		name: \crowded,
		when: { |gas, m| m.density > 9 },
		then: { |gas, m|
			gas.cmd(\process, \all, \subtractive);
			gas.queue(32, \process, \all, \breathe);
		},
		cooldown: 64
	)
]
)
