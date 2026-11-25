// =====================================================================
// tests/live-smoke.scd: boot the real server and play for a few seconds
// =====================================================================
// Run from a terminal:
//     sclang -i none tests/live-smoke.scd            (silent: master volume 0)
//     sclang -i none tests/live-smoke.scd 0.5        (audible, master volume 0.5)
//
// Exercises the parts the dry run can't: SynthDefs on the server, the
// group/bus graph, note events, the analyzer's SendReply -> OSCdef path,
// and a clean shutdown. With volume 0 nothing reaches the speakers, but
// the analyzer still hears the music because it listens BEFORE the master
// volume.
// =====================================================================
(
var root = File.realpath(thisProcess.nowExecutingPath).dirname.dirname;
var vol = (thisProcess.argv[0] ? "0").asFloat, seconds = 10;
~gasRoot = root;
["state", "theory", "engine", "timeline", "control"].do { |f| (root +/+ "core" +/+ f ++ ".scd").load };

~gas.boot((composition: "glassian"), { |gas|
	var peakAmp = 0, maxNodes = 0, ok;
	gas.comp.system.volume = vol;
	gas.verbosity = \normal;
	gas.start;
	// sample analysis + node count while it plays
	(seconds * 4).do {
		0.25.wait;
		peakAmp = peakAmp.max(gas.analysis.amp ? 0);
		maxNodes = maxNodes.max(gas.srv.numSynths);
	};
	gas.status;
	gas.kill;
	1.wait;
	ok = (peakAmp > 0.005) and: { maxNodes > 3 };
	"\nLIVE SMOKE: peak analyzer amp % | max synths % | %".format(
		peakAmp.round(0.0001), maxNodes, if(ok) { "PASS" } { "FAIL" }).postln;
	gas.srv.quit;
	2.wait;
	(if(ok) { 0 } { 1 }).exit;
});
)
