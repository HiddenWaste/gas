// =====================================================================
// compositions/drift.scd: "Tide Tables"
// =====================================================================
// The second prototype piece, deliberately different from glassian.scd:
//   * slow, pentatonic, mallets + piano + pad
//   * PHASING in the Steve Reich sense: two mallets play the same figure,
//     one is `stretch`ed slightly slower so they drift apart, then it
//     locks back to tempo at a new offset
//   * a custom command (`unison`) defined right here in the composition
//   * reactions that use live AUDIO ANALYSIS (gas.analysis)
//   * an infinite loop: it never ends by itself. Stop it with ~gas.end(16)
// =====================================================================
(
name: "Tide Tables",
about: "Phasing mallets and a wandering piano; loops forever",

system: (
	tempo: 84,
	volume: 0.75,
	reverb: (room: 0.9, damp: 0.3, level: 1),
	status: 16
),

constraints: (
	root: \D4,
	scale: \majorPentatonic,          // D E F# A B
	range: [45, 93]
),

evolution: (
	process: \free,
	period: 4,
	chance: 0.5,
	strength: 0.4
),

instruments: (
	// The phasing pair. Same figure, opposite sides. A doesn't mutate on its
	// own (chance 0); the timeline and the \unison command decide when the
	// figure changes, so the pair stays recognisably "the same".
	malletA: (
		sound: \gasMallet, process: \static, chance: 0,
		figure: [0, 2, 4, 3, 1, 4, 2, 3],
		pulse: 0.25, amp: 0.28, pan: -0.6, verb: 0.25, accent: 0.3,
		range: [62, 86]
	),
	malletB: (
		sound: \gasMallet, process: \static, chance: 0,
		figure: [0, 2, 4, 3, 1, 4, 2, 3],
		pulse: 0.25, amp: 0.25, pan: 0.6, verb: 0.25, accent: 0.3,
		range: [62, 86]
	),

	// Sustained pad: one chord per figure step, eight beats each
	pad: (
		sound: \gasPad, style: \ostinato,
		figure: [[0, 2, 4], [-1, 1, 3]],
		pulse: 8, legato: 1.0, octave: -1,
		amp: 0.09, verb: 0.6,
		range: [45, 72]
	),

	// The wandering voice: rests, rhythm changes, neighbor tones
	piano: (
		sound: \gasPiano, style: \wander,
		figure: [4, \r, 2, \r, 5, 4],
		pulse: 0.5, minLen: 3, maxLen: 10,
		amp: 0.2, pan: 0.15, verb: 0.45,
		range: [62, 93]
	)
),

timeline: [
	[0,   \section, \still],
	[0,   \in, \malletA],
	[16,  \in, \pad],

	// B enters in unison, then drifts: at stretch 1.01 a 2-beat cycle
	// slips about 1/50 of a beat per pass, so it takes roughly 25 beats to
	// fall one sixteenth behind A.
	[32,  \section, \phase],
	[32,  \in, \malletB],
	[40,  \stretch, \malletB, 1.01],
	[64,  \stretch, \malletB, 1],       // lock at the new offset
	[80,  \stretch, \malletB, 0.99],    // and drift the other way
	[96,  \stretch, \malletB, 1],

	// The repeating middle: piano wanders, harmony slowly rotates, and the
	// mallet figure is rotated and re-unisoned. Loops forever.
	[96,  \section, \tide],
	[96,  \in, \piano],
	[96,  \chord, 0],
	[128, \chord, 3],
	[128, \mutate, \malletA, \rotate],
	[132, \unison, \malletA, \malletB],
	[160, \chord, -2],
	[160, \nudge, \malletB, 0.25],      // an instant one-sixteenth phase step
	[176, \chord, 1],
	[192, \mutate, \malletA, \neighbor],
	[196, \unison, \malletA, \malletB],
	[224, \loop, \tide, inf]
],

// Custom commands: usable in the timeline, live, and over OSC
//   ~gas.cmd(\unison, \malletA, \malletB)
//   /gas/cmd unison malletA malletB
commands: (
	unison: { |gas, from, to|
		var a = gas.voices[from], b = gas.voices[to];
		b.figure = a.figure.collect(_.copy);
		gas.log("unison % -> %   %".format(from, to, gas.figString(b)), \event);
	}
),

reactions: [
	// If the room gets loud (actual output level), the piano backs off.
	(
		name: \loud,
		when: { |gas, m| gas.analysis.amp > 0.25 },
		then: [\process, \piano, \subtractive],
		cooldown: 32
	),
	(
		name: \quiet,
		when: { |gas, m| gas.analysis.amp < 0.08 and: { m.voices > 2 } },
		then: [\process, \piano, \free],
		cooldown: 32
	),
	// Now and then the piano gets bolder for a while
	(
		name: \flare,
		when: { |gas, m| m.section == \tide },
		then: { |gas, m|
			gas.cmd(\evolve, \piano, (strength: 0.8, period: 2));
			gas.queue(32, \evolve, \piano, (strength: 0.4, period: 4));
		},
		cooldown: 96, chance: 0.25
	)
]
)
