// =====================================================================
// main.scd: entry point for the Glassian Autonomous System
// =====================================================================
//
// HOW TO RUN
//   1. Open this file in the SuperCollider IDE.
//   2. Put the cursor inside the big ( ... ) block below and press
//      Ctrl+Enter (Cmd+Enter on macOS) to evaluate it.
//   3. When "System ready" prints, evaluate  ~gas.start;
//      (or set autoStart: true below).
//
// Commands you can evaluate line by line while it plays are at the bottom
// of this file, and `~gas.guide` prints them in the post window.
//
// HEADLESS: with no server or soundcard, set dryRun: true. The engine
// runs on the clock exactly as it would live, mutating, looping and reacting,
// but the notes are logged rather than played. tests/dry-run.scd does this
// automatically, at very high speed.
// =====================================================================

(
// ---- configuration --------------------------------------------------
~gasConfig = (
	composition: "glassian",   // a name in compositions/ (no .scd), or a full path
	autoStart:   false,        // start playing as soon as everything is loaded
	dryRun:      false         // true = no audio server; print the score instead
);

// ---- load -----------------------------------------------------------
// Capture this file's folder NOW. `thisProcess.nowExecutingPath` only
// works while the file is being evaluated. Inside s.waitForBoot's
// callback it's already nil, which is one reason the archive's loader
// failed. Paths are joined with +/+ so they work on any OS (the archive
// used Windows-only backslashes).
~gasRoot = thisProcess.nowExecutingPath.dirname;

// If a previous run is still going, stop it before replacing ~gas.
if(~gas.notNil and: { ~gas[\kill].notNil }) { ~gas.kill };

// Order matters only in that state.scd creates ~gas; the rest add to it.
["state", "theory", "engine", "timeline", "control"].do { |f|
	(~gasRoot +/+ "core" +/+ f ++ ".scd").load;
};

~gas.boot(~gasConfig, { |gas|
	"\n[gas] System ready".postln;
	gas.guide;
	if(~gasConfig[\autoStart]) { gas.start };
});
)


// =====================================================================
// PERFORMANCE CHEAT SHEET: evaluate lines one at a time (Shift+Enter)
// =====================================================================

~gas.start;
~gas.status;
~gas.recent(30);

// harmony
~gas.cmd(\scale, \lydian);
~gas.cmd(\chord, 5);
~gas.cmd(\root, \C4);
~gas.cmd(\shift, -2);

// voices
~gas.cmd(\in, \flute);                       // enters on the next bar
~gas.queue(\bars2, \out, \organ2);           // leaves in two bars
~gas.cmd(\mute, \bass, true);
~gas.cmd(\vol, \organ, 0.05, 16);            // fade over 16 beats

// evolution: direction and strength, live
~gas.cmd(\process, \all, \subtractive);
~gas.cmd(\evolve, \organ, (strength: 0.9, period: 1, weights: (rotate: 4)));
~gas.cmd(\mutate, \all, \retrograde);
~gas.cmd(\revert, \all);
~gas.snapshot(\nice);
~gas.recall(\nice);

// time
~gas.cmd(\tempo, 100, 32);                   // ramp to 100 BPM over 32 beats
~gas.cmd(\stretch, \organ2, 1.01);           // let organ2 drift out of phase
~gas.cmd(\goto, \cadence);

// recording, switching pieces, stopping
~gas.rec;                                    // start (and later stop) recording
~gas.end(16);
~gas.kill;
~gas.loadComposition("drift"); ~gas.start;
