// =====================================================================
// compositions/template.scd: the smallest useful composition.
// Copy this file, rename it, and load it with
//     ~gas.loadComposition("my-piece"); ~gas.start;
// Everything not written here comes from `~gas.defaults` (core/state.scd).
// =====================================================================
(
name: "Template",

system: (tempo: 112, volume: 0.6),

constraints: (root: \C4, scale: \lydian),

instruments: (
	// sound + figure is all an instrument needs
	keys: (sound: \gasPiano, figure: [0, 4, 2, 4], style: \glass),
	low:  (sound: \gasBass,  figure: [0, \r], octave: -2, pulse: 1, style: \ostinato)
),

timeline: [
	[0,  \section, \A],
	[0,  \in, \keys],
	[16, \in, \low],
	[48, \scale, \mixolydian],
	[64, \loop, \A, 1],
	[64, \end, 8]
]

// Optional sections (see glassian.scd and drift.scd for examples):
//   evolution: (process:, period:, chance:, strength:, unfold:, weights: (...))
//   styles:    (myStyle: (process: \breathe, ...))
//   reactions: [(when: {|gas, m| ... }, then: [\cmd, ...], cooldown: 16)]
//   commands:  (myCmd: {|gas, a, b| ... })
)
