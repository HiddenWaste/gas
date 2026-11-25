// =====================================================================
// core/state.scd: the ~gas namespace, defaults, logging, and the
// composition loader/validator (the "interpreter" for composition files)
// =====================================================================
//
// WHY ONE NAMESPACE?
// The archive had five namespaces (~stateManager, ~patternEngine, ...),
// each keeping its own copy of data and its own clock. They drifted apart:
// ~setTempo changed one clock while the patterns played on another.
// Here ONE Event, ~gas, holds everything. The core files just add
// functions to it, grouped by topic, so it reads modular without the
// cross-module plumbing.
//
// ---------------------------------------------------------------------
// HOW "METHODS" ON AN EVENT WORK (read this before touching the code)
// ---------------------------------------------------------------------
// `()` makes an Event. Events have `know = true`, so when you write
//
//     ~gas.foo(1, 2)
//
// and Event has no real method called `foo`, SuperCollider looks up the
// key \foo and, if it holds a Function, calls it as  func.(~gas, 1, 2).
// So every function stored on ~gas is written  { |self, a, b| ... }
// and uses `self` instead of `~gas`. That keeps the code working
// even when called from Routines, OSC responders, or a different
// currentEnvironment (ProxySpace etc.).
//
// THREE GOTCHAS this codebase deliberately avoids:
//
//  1. NAME COLLISIONS. If Event already has a real method with that
//     name, the real method wins and your function is never called.
//     SETTERS count too: Event has a real `clock_`, so `~gas.clock = x`
//     silently stores nothing. That's why the system clock is
//     ~gas.beatClock.
//     Colliding names (checked against SC 3.13 in tests/dry-run.scd):
//     play stop reset update free set help at halt group invert loop do
//     parent proto synth every delta order source pause resume isRest
//     size. The archive's "stopTimeline" rename was exactly this problem.
//     That is why voices use `sound:` and `period:` rather than
//     `synth:` and `every:`.
//
//  2. DOT ACCESS CALLS FUNCTIONS. `e.when` on an Event whose \when key
//     holds a Function CALLS the function. Data that might be a Function
//     (reaction conditions, custom commands) is always read with
//     brackets:  r[\when]
//
//  3. NO `^` IN FUNCTIONS. `^` means "return from the enclosing METHOD".
//     Interpreted code has no enclosing method, so the archive's early
//     returns (`^false;`) raised "Out of context return" errors. Here
//     guard clauses are written as if/else (or `case`) expressions;
//     a function's value is its last expression.
// =====================================================================

(
~gas = ();                                   // the single, fresh namespace
~gas.root = ~gasRoot ?? { "." };             // set by main.scd before loading

// ---------------------------------------------------------------------
// DEFAULTS: every key a composition may set, with a sensible value.
// A composition only writes what it wants to change; the loader
// deep-merges it over these. Short compositions stay short.
// ---------------------------------------------------------------------
~gas.defaults = (

	// SYSTEM: audio + timing folded together (per project-idea.md)
	system: (
		tempo: 120,            // BPM. One beat = one quarter note
		beatsPerBar: 4,        // used for quantising live entries and the monitor
		volume: 0.7,           // master volume, 0..1
		reverb: (room: 0.7, damp: 0.5, level: 1),
		seed: nil,             // an Integer makes a run repeatable (see THOUGHTS.md caveat)
		verbosity: \normal,    // \quiet (warnings only), \normal, \verbose
		oscOut: nil,           // e.g. ["127.0.0.1", 9000] to broadcast state
		analysis: true,        // run the \gasAnalyzer on the master bus
		status: 0              // print a status line every N bars (0 = never)
	),

	// CONSTRAINTS: the harmonic world
	constraints: (
		root: 60,              // MIDI number or a note name like \A3 or "F#2"
		scale: \major,         // any Scale.at name, or an Array of semitones
		range: [36, 96]        // default pitch window for voices (MIDI)
	),

	// EVOLUTION: global defaults for HOW figures change.
	// Every one of these can be overridden by a style or by an instrument.
	evolution: (
		process: \additive,    // \additive \subtractive \breathe \static \free
		period: 4,             // cycles (figure repetitions) between mutation checks
		chance: 0.7,           // probability that a check actually mutates
		strength: 0.5,         // 0..1: how big a change, and how many at once
		unfold: 0.8,           // chance a grow reveals the next note of the seed figure
		weights: (             // relative likelihood of each mutation (0 = never)
			grow: 4, shrink: 4,
			transpose: 1, retrograde: 0.5, invert: 0.5, rotate: 1,
			swap: 1, neighbor: 1, shade: 1,
			rhythm: 0, rest: 0
		)
	),

	// STYLES: named bundles of evolution settings. This is one answer to
	// the "instruments vs patterns" question in project-idea.md:
	// an INSTRUMENT is a sound plus a figure; a STYLE is how it behaves.
	// Compositions can add styles or override these.
	styles: (
		// classic Glass additive/subtractive breathing
		glass:    (process: \breathe, period: 4, chance: 0.9, strength: 0.35, unfold: 0.9,
			weights: (transpose: 0.3, retrograde: 0.2, invert: 0.1, rotate: 0.3, swap: 0.2, neighbor: 0.3, shade: 0.5)),
		// a bass line or drone: changes slowly and rarely
		ostinato: (process: \static, period: 8, chance: 0.4, strength: 0.2,
			weights: (transpose: 0.5, neighbor: 1, rotate: 0.5, retrograde: 0, invert: 0, swap: 0)),
		// melodic, wandering, free to do anything
		wander:   (process: \free, period: 2, chance: 0.6, strength: 0.6,
			weights: (grow: 1, shrink: 1, neighbor: 2, rotate: 1, swap: 1, rhythm: 0.5, rest: 0.3))
	),

	// Defaults for each instrument entry (merged under evolution + style)
	voice: (
		sound: \gasOrgan,      // SynthDef name (see synthdefs.scd)
		amp: 0.2, pan: 0, verb: 0.2,
		octave: 0,             // octave offset from the root
		range: nil,            // nil = constraints.range
		figure: [0],           // scale degrees; \r = rest; [0, 2, 4] = chord
		durs: nil,             // per-step durations (cycled); nil = use pulse
		pulse: 0.5,            // default step length in beats (0.5 = eighth notes)
		start: nil,            // how many steps of the figure to begin with (nil = all)
		minLen: 1, maxLen: 8,
		legato: 0.9,           // fraction of the step a gated note holds
		accent: 0.2,           // how much quieter non-downbeat steps are
		human: 0.04,           // random +/- amplitude jitter per note
		stretch: 1,            // time multiplier: 1.01 = 1% slower = drifts out of phase
		style: nil             // name of an entry in `styles`
	),

	instruments: (),           // name -> voice spec
	timeline: [],              // [beat, \command, args...]
	reactions: [],             // (when: {|gas, m| bool}, then: [\cmd, ...] or {|gas, m|}, cooldown: beats)
	commands: ()               // custom commands: name -> {|gas ...args| }
);

// Keys that may appear in a timeline (built-in). Filled in by control.scd.
~gas.commands = ();

// Runtime state, reset by ~gas.start
~gas.running   = false;
~gas.dry       = false;       // dry run: no server, just the evolving score in the post window
~gas.history   = List.new;    // recent log lines, so you can scroll back during a performance
~gas.snapshots = ();
~gas.ramps     = ();          // running fade/ramp Routines, keyed by what they control
~gas.metrics   = ();
~gas.analysis  = (amp: 0, centroid: 0, flatness: 0, onsets: 0);
~gas.voices    = ();
~gas.verbosity = \normal;

// ---------------------------------------------------------------------
// tree: copy nested Events/Arrays but share Functions and atoms.
// (Object:deepCopy also tries to copy Functions, which is not what we want.)
// ---------------------------------------------------------------------
~gas.tree = { |self, obj|
	case
	{ obj.isKindOf(Event) } {
		var out = ();
		obj.keysValuesDo { |k, v| out[k] = self.tree(v) };
		out
	}
	{ obj.isKindOf(Array) } { obj.collect { |x| self.tree(x) } }
	{ obj }
};

// deepMerge: `over` wins, nested Events merge key by key.
~gas.deepMerge = { |self, base, over|
	var out = self.tree(base ? ());
	(over ? ()).keysValuesDo { |k, v|
		if(v.isKindOf(Event) and: { out[k].isKindOf(Event) }) {
			out[k] = self.deepMerge(out[k], v)
		} {
			out[k] = self.tree(v)
		}
	};
	out
};

// ---------------------------------------------------------------------
// LOGGING
// Levels: \error \warn \event \mutate \info \debug
// Verbosity: \quiet shows errors and warnings only, \normal everything
// but debug, \verbose shows everything.
// Every line is prefixed with the musical position: [bar.beat section]
// ---------------------------------------------------------------------
~gas.where = { |self|
	if(self.beatClock.notNil and: { self.running }) {
		var bpb = self.bpb ? 4, b = self.beatClock.beats;
		var bar = (b / bpb).floor.asInteger + 1, beat = (b % bpb).floor.asInteger + 1;
		"%.% %".format(bar.asString.padLeft(3, "0"), beat, self.section ? "-")
	} { "---.- -" }
};

~gas.log = { |self, msg, level = \info|
	var rank = (error: 0, warn: 0, event: 1, mutate: 1, info: 1, debug: 2);
	var allowed = (quiet: 0, normal: 1, verbose: 2)[self.verbosity] ? 1;
	var line = "[%] %".format(self.where, msg);
	if(level != \debug) {
		self.history.add(line);
		if(self.history.size > 500) { self.history.removeAt(0) };
	};
	if((rank[level] ? 1) <= allowed) {
		case
		{ level == \error } { ("[gas] ERROR " ++ line).postln }
		{ level == \warn }  { ("[gas] WARNING " ++ line).postln }
		{ ("[gas] " ++ line).postln }
	};
	line
};

// Print the last n lines of history (handy after a quiet stretch)
~gas.recent = { |self, n = 20|
	self.history.keep(n.neg).do(_.postln);
	nil
};

// =====================================================================
// COMPOSITION LOADING: the "interpreter" for the unique data structure
// =====================================================================

// Load a composition file. `nameOrPath` may be a bare name
// ("glassian" -> compositions/glassian.scd) or a path to any .scd file
// whose last expression is an Event.
~gas.loadComposition = { |self, nameOrPath|
	var path = nameOrPath.asString, raw;
	if(File.exists(path).not) { path = self.root +/+ "compositions" +/+ path ++ ".scd" };
	if(File.exists(path).not) {
		self.log("composition not found: %".format(nameOrPath), \error);
		false
	} {
		raw = path.load;   // String:load compiles and runs the file, answering its last value
		self.compPath = path;
		self.useComposition(raw)
	}
};

// Use a composition Event that is already in memory (also handy for
// live-building pieces in the IDE, and for the tests).
~gas.useComposition = { |self, raw|
	var comp, problems;
	if(raw.isKindOf(Event).not) {
		self.log("a composition must evaluate to an Event, got %".format(raw.class), \error);
		false
	} {
		comp = self.deepMerge(self.defaults, raw);
		// Instruments are NOT merged with defaults.instruments wholesale:
		// each gets the voice defaults in makeVoice. Keep the raw ones.
		comp.instruments = raw[\instruments] ? ();
		comp.timeline = self.prepareTimeline(raw[\timeline] ? []);
		comp.reactions = raw[\reactions] ? [];
		problems = self.validate(comp);
		if(problems.notEmpty) {
			problems.do { |p| self.log(p, \error) };
			self.log("composition '%' NOT loaded (% problems)".format(comp[\name] ? "?", problems.size), \error);
			false
		} {
			self.comp = comp;
			self.verbosity = comp.system.verbosity;
			self.bpb = comp.system.beatsPerBar;
			self.buildVoices;
			self.resetHarmony;
			self.applySystem;
			self.log("loaded '%': % instruments, % timeline events".format(
				comp[\name] ? "untitled", comp.instruments.size, comp.timeline.size), \event);
			true
		}
	}
};

// Check a merged composition and return a list of human-readable problems.
// Catching mistakes at load time beats discovering them at bar 97 of a
// performance.
~gas.validate = { |self, comp|
	var p = List.new;
	var known = self.commands.keys.union(comp.commands.keys).add(\loop);
	var processes = [\additive, \subtractive, \breathe, \static, \free];
	var voiceCmds = [\in, \out, \process, \evolve, \mutate, \figure, \revert, \mute, \nudge, \stretch, \pan, \verb];
	var sections = comp.timeline.select { |e| e[\cmd] == \section }.collect { |e| e[\args][0] };

	if(comp.instruments.isEmpty) { p.add("no instruments defined") };

	comp.instruments.keysValuesDo { |name, spec|
		var style = spec[\style], fig = spec[\figure];
		if(spec.isKindOf(Event).not) { p.add("instrument % must be an Event".format(name)) } {
			if(fig.isNil or: { fig.isKindOf(Array).not } or: { fig.isEmpty }) {
				p.add("instrument % needs a non-empty `figure:` array".format(name))
			};
			if(style.notNil and: { comp.styles[style].isNil }) {
				p.add("instrument % uses unknown style %".format(name, style))
			};
			if(spec[\process].notNil and: { processes.includes(spec[\process]).not }) {
				p.add("instrument % has unknown process %".format(name, spec[\process]))
			};
			if(self.dry.not and: { spec[\sound].notNil } and: { SynthDescLib.global[spec[\sound]].isNil }) {
				p.add("instrument % uses unknown SynthDef %".format(name, spec[\sound]))
			};
			if(spec[\synth].notNil) { p.add("instrument %: use `sound:` not `synth:`".format(name)) };
			if(spec[\every].notNil) { p.add("instrument %: use `period:` not `every:`".format(name)) };
		}
	};

	comp.timeline.do { |e|
		var where = "timeline beat %".format(e[\beat]);
		case
		{ e[\beat].isNumber.not } { p.add("% : first element must be a beat number".format(e[\raw])) }
		{ known.includes(e[\cmd]).not } { p.add("%: unknown command %".format(where, e[\cmd])) }
		{ voiceCmds.includes(e[\cmd]) } {
			// a target may be \all, one name, or an Array of names
			var target = e[\args][0];
			if(target != \all) {
				target.asArray.do { |t|
					if(comp.instruments[t].isNil) {
						p.add("%: % refers to unknown instrument %".format(where, e[\cmd], t))
					}
				}
			}
		}
		{ (e[\cmd] == \loop) or: { e[\cmd] == \goto } } {
			if(sections.includes(e[\args][0]).not) {
				p.add("%: % to unknown section %".format(where, e[\cmd], e[\args][0]))
			}
		}
	};
	p
};

// Turn `[beat, \cmd, args...]` arrays into Events, sorted by beat.
// Events on the same beat keep their written order (ties broken by index),
// so "section then in" always happens in that order.
~gas.prepareTimeline = { |self, raw|
	var events = raw.collect { |e, i|
		if(e.isKindOf(Array) and: { e.size >= 2 }) {
			(beat: e[0], cmd: e[1], args: e.drop(2), i: i, raw: e)
		} {
			(beat: nil, cmd: nil, args: [], i: i, raw: e)
		}
	};
	events.sort { |a, b|
		var ab = a[\beat] ? inf, bb = b[\beat] ? inf;
		(ab < bb) or: { (ab == bb) and: { a[\i] <= b[\i] } }
	}
};

"[gas] state loaded".postln;
)
