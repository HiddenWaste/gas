// =====================================================================
// tests/dry-run.scd: headless test of the whole engine (no audio server)
// =====================================================================
// Run from a terminal:
//     sclang -i none tests/dry-run.scd
// (On a machine without a display, prefix with QT_QPA_PLATFORM=offscreen.)
// NOTE: if a file has a PARSE error, sclang prints it and then just sits
// there (the final .exit never runs). Run under `timeout`, and if output
// seems missing, wrap in `script -q -c "..." log.txt`: sclang buffers
// stdout when it's not a terminal, so a killed run can lose the error.
//
// It checks:
//   1. no ~gas / voice / metrics key collides with a real Event method
//   2. pitch helpers (note names, folding, degrees -> MIDI)
//   3. the validator rejects broken compositions with useful messages
//   4. every composition in compositions/ runs end to end at ~200 beats
//      per second, while a watchdog checks the invariants: figure lengths
//      within [minLen, maxLen], pitches within range, no zero durations
//   5. a seeded run is reproducible (same seed -> same mutation history)
// Exits with status 0 if everything passed, 1 otherwise.
// =====================================================================
(
var root = File.realpath(thisProcess.nowExecutingPath).dirname.dirname;   // absolute, even if run with a relative path
var failures = List.new, passes = 0, check, runPiece, eventMethods, collisions;

check = { |cond, msg|
	if(cond == true) { passes = passes + 1 } { failures.add(msg); ("  FAIL: " ++ msg).postln };
};

~gasRoot = root;
["state", "theory", "engine", "timeline", "control"].do { |f| (root +/+ "core" +/+ f ++ ".scd").load };
~gas.dry = true;

// ---------------------------------------------------------------------
"\n== 1. Event method collisions ==".postln;
// Keys we call/read with dot syntax must not be real Event methods,
// because the real method would silently win.
collisions = { |event, label|
	event.keys.do { |k|
		check.(().respondsTo(k).not, "% key '%' collides with an Event method".format(label, k));
		// setters too: `e.k = x` calls k_, and a real k_ method would swallow it
		check.(().respondsTo((k ++ "_").asSymbol).not, "% key '%_' collides with an Event setter".format(label, k));
	}
};
collisions.(~gas, "~gas");

// ---------------------------------------------------------------------
"\n== 2. theory ==".postln;
check.(~gas.toMidi("A3") == 57, "A3 = 57");
check.(~gas.toMidi(\C4) == 60, "C4 = 60");
check.(~gas.toMidi("C#4") == 61, "C#4 = 61");
check.(~gas.toMidi("Bb2") == 46, "Bb2 = 46");
check.(~gas.toMidi("A") == 69, "A (no octave) = A4 = 69");
check.(~gas.toMidi("F#-1") == 6, "F#-1 = 6");
check.(~gas.noteName(61) == "C#4", "61 -> C#4");
check.(~gas.fold(30, [48, 72]) == 54, "fold 30 into [48,72] by octaves = 54");
check.(~gas.fold(90, [48, 72]) == 66, "fold 90 into [48,72] = 66");
check.(~gas.fold([30, 90], [48, 72]) == [54, 66], "fold works on chords");
check.(~gas.silent(\r) and: { ~gas.silent(3).not }, "\\r is a rest, 3 is not");

// ---------------------------------------------------------------------
"\n== 3. validator ==".postln;
check.(~gas.useComposition(42) == false, "a non-Event composition is rejected");
check.(~gas.useComposition((instruments: (a: (figure: [])))) == false, "empty figure rejected");
check.(~gas.useComposition((
	instruments: (a: (figure: [0])),
	timeline: [[0, \in, \nobody], [4, \frobnicate], [8, \loop, \nowhere, 1]]
)) == false, "unknown instrument / command / section rejected");
check.(~gas.useComposition((instruments: (a: (figure: [0], style: \nope)))) == false, "unknown style rejected");
check.(~gas.useComposition((instruments: (a: (figure: [0], synth: \gasOrgan)))) == false, "`synth:` key flagged");
check.(~gas.useComposition((instruments: (a: (figure: [0, 2, 4], start: 1)), timeline: [[0, \in, \a]])) == true,
	"a minimal composition loads");
check.(~gas.voices[\a].figure.size == 1, "start: 1 begins with one step");
~gas.harmony.chord = 0;
check.(~gas.degreeToMidi(~gas.voices[\a], 2) == 64, "degree 2 in C major = E4 (64)");
check.(~gas.degreeToMidi(~gas.voices[\a], -1) == 59, "degree -1 = B3 (59)");
check.(~gas.degreeToMidi(~gas.voices[\a], \r).isRest, "\\r -> Rest()");

// every mutation, applied directly, keeps the figure valid
~gas.mutations.keys.asArray.sort.do { |op|
	var v = ~gas.makeVoice(\t, (figure: [0, 2, 4, 2], minLen: 2, maxLen: 6));
	30.do { ~gas.applyMutation(v, op) };
	check.(v.figure.size.inclusivelyBetween(2, 6), "% keeps length in [2, 6] (got %)".format(op, v.figure.size));
	check.(v.figure.every { |st| st[\dur] > 0 }, "% keeps durations positive".format(op));
};

// ---------------------------------------------------------------------
// 4/5. full runs
// ---------------------------------------------------------------------
// Play a composition at `bps` beats per second until it ends (or for
// `maxBeats`), watching the invariants. Answers the mutation history.
runPiece = { |name, maxBeats = 600, seed, bps = 200|
	var t0, watch = 0, bad = List.new, ok, mutations, loops;
	ok = ~gas.loadComposition(name);
	check.(ok, "% loads".format(name));
	if(ok) {
		collisions.(~gas.comp, "% composition".format(name));
		collisions.(~gas.comp.system, "% system".format(name));
		~gas.verbosity = \quiet;
		~gas.comp.system.tempo = bps * 60;
		~gas.comp.system.seed = seed;
		~gas.history = List.new;
		~gas.start;
		~gas.voices.do { |v| collisions.(v, "% voice %".format(name, v.name)) };
		// stop pieces that loop forever
		~gas.beatClock.sched(maxBeats, { if(~gas.running) { ~gas.kill }; nil });
		t0 = Main.elapsedTime;
		while { ~gas.running and: { (Main.elapsedTime - t0) < (maxBeats / bps + 5) } } {
			// watchdog: check every voice's current state
			~gas.voices.do { |v|
				if(v.figure.size.inclusivelyBetween(v.minLen, v.maxLen).not) {
					bad.add("% % length % outside [%, %]".format(name, v.name, v.figure.size, v.minLen, v.maxLen))
				};
				v.figure.do { |st|
					var m = ~gas.degreeToMidi(v, st[\deg]), r = v.range;
					if(m.isRest.not and: { m.asArray.every { |x| x.inclusivelyBetween(r[0], r[1]) }.not }) {
						bad.add("% % pitch % outside %".format(name, v.name, m, r))
					};
					if(st[\dur] <= 0) { bad.add("% % zero duration".format(name, v.name)) };
				};
			};
			watch = watch + 1;
			0.01.wait;
		};
		if(~gas.running) { ~gas.kill };
		mutations = ~gas.history.select { |l| l.contains("->") };
		loops = ~gas.history.select { |l| l.contains("loop ->") };
		check.(bad.isEmpty, "% invariants held over % watchdog checks %".format(name, watch, bad.keep(3)));
		check.(mutations.size > 10, "% produced mutations (%)".format(name, mutations.size));
		check.(~gas.history.any { |l| l.contains("ERROR") }.not, "% logged no errors".format(name));
		"  % : % log lines, % mutations, % loop jumps".format(name, ~gas.history.size, mutations.size, loops.size).postln;
		"  last lines:".postln;
		~gas.history.keep(-6).do { |l| ("    " ++ l).postln };
		~gas.history.copy
	} { [] }
};

Routine {
	var h1, h2, mut;
	"\n== 4. full dry runs ==".postln;
	h1 = runPiece.("glassian", 2000);
	check.(h1.any { |l| l.contains("timeline finished") }, "glassian reaches the end of its timeline");
	check.(h1.select { |l| l.contains("loop -> cadence") }.size == 3, "glassian: cadence looped exactly 3 times");
	check.(h1.select { |l| l.contains("loop -> growth") }.size == 1, "glassian: growth looped exactly once");
	check.(h1.any { |l| l.contains("stopped") }, "glassian: \\end stopped the system");

	h1 = runPiece.("drift", 1200);
	check.(h1.select { |l| l.contains("loop -> tide") }.size >= 5, "drift: infinite loop keeps looping");
	check.(h1.any { |l| l.contains("unison") }, "drift: custom command ran");

	h1 = runPiece.("template", 400);
	check.(h1.any { |l| l.contains("stopped") }, "template runs to its end");

	"\n== 5. seeded reproducibility ==".postln;
	mut = { |h| h.select { |l| l.contains("->") } };
	h1 = mut.(runPiece.("glassian", 2000, 1977));
	h2 = mut.(runPiece.("glassian", 2000, 1977));
	check.((h1 == h2) and: { h1.size > 10 }, "same seed -> identical mutation history (% lines)".format(h1.size));
	h2 = mut.(runPiece.("glassian", 2000, 2024));
	check.(h1 != h2, "different seed -> different history");

	"\n================================".postln;
	"% checks passed, % failed".format(passes, failures.size).postln;
	failures.do { |f| ("  - " ++ f).postln };
	"================================".postln;
	(if(failures.isEmpty) { 0 } { 1 }).exit;
}.play(SystemClock);
)
