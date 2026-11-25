// =====================================================================
// tests/render-synthdefs.scd: render every SynthDef offline (NRT)
// =====================================================================
// Run from a terminal (no soundcard or running server needed):
//     sclang -i none tests/render-synthdefs.scd
//
// Builds a Score that plays a short arpeggio on each instrument, plus
// one segment through the reverb + master chain, renders it with scsynth
// in non-real-time mode to tests/out/synthdefs.wav, then reads the file
// back and checks each segment: not silent, not clipping, no NaNs.
// Listen to the WAV to audition the palette.
// =====================================================================
(
var root = File.realpath(thisProcess.nowExecutingPath).dirname.dirname;   // absolute, even if run with a relative path
var outDir = root +/+ "tests" +/+ "out", wav, osc;
var instruments = [\gasOrgan, \gasPiano, \gasMallet, \gasFlute, \gasChoir, \gasBass, \gasPad];
var seg = 3.0, sr = 44100, score = Score.new, id = 1000, t, total, notes;

(root +/+ "synthdefs.scd").load;
File.mkdir(outDir);
wav = outDir +/+ "synthdefs.wav";
osc = outDir +/+ "synthdefs.osc";

// 1. every SynthDef goes into the score at time 0
~gasSynthDefs.do { |d| score.add([0, [\d_recv, d.asBytes]]) };

// a three-note arpeggio, A minor; bass an octave and a half lower
notes = { |name| if(name == \gasBass) { [33, 40, 45] } { [57, 60, 64] } };

// 2. one segment per instrument, straight to the outputs
instruments.do { |name, i|
	var gated = SynthDescLib.global[name].hasGate;
	t = (i * seg) + 0.1;
	notes.(name).do { |m, j|
		var start = t + (j * 0.5), node = id = id + 1;
		score.add([start, [\s_new, name, node, 0, 0, \freq, m.midicps, \amp, 0.3, \out, 0, \send, 0, \sendAmt, 0]]);
		if(gated) { score.add([start + 0.45, [\n_set, node, \gate, 0]]) };   // release, like a \note event would
	};
};

// 3. the effects chain: organ -> send bus 8 -> reverb -> main bus 10 -> master -> out 0
t = instruments.size * seg;
score.add([t, [\s_new, \gasMaster, 900, 1, 0, \in, 10, \out, 0, \vol, 0.8]]);     // tail
score.add([t, [\s_new, \gasReverb, 901, 0, 0, \in, 8, \out, 10]]);                // head (runs first)
[57, 60, 64, 69].do { |m, j|
	var start = t + 0.1 + (j * 0.4), node = id = id + 1;
	score.add([start, [\s_new, \gasOrgan, node, 0, 0, \freq, m.midicps, \amp, 0.3, \out, 10, \send, 8, \sendAmt, 0.6]]);
	score.add([start + 0.35, [\n_set, node, \gate, 0]]);
};
total = t + 4;
score.add([total, [\c_set, 0, 0]]);   // end-of-score marker
score.sort;

"rendering % s of audio to %".format(total, wav).postln;
score.recordNRT(osc, wav, nil, sr, "WAV", "float",
	ServerOptions.new.numOutputBusChannels_(2).numInputBusChannels_(0).memSize_(65536),
	duration: total,
	action: {
		var sf = SoundFile.openRead(wav), data, failures = 0, labels;
		data = FloatArray.newClear(sf.numFrames * sf.numChannels);
		sf.readData(data);
		sf.close;
		labels = instruments ++ [\reverbChain];
		"\n  segment        peak     rms     verdict".postln;
		labels.do { |name, i|
			var a = (i * seg * sr).asInteger * 2;
			var b = (((i + 1) * seg).min(total) * sr).asInteger * 2;
			var chunk = data.copyRange(a, (b - 1).min(data.size - 1));
			var peak = chunk.abs.maxItem, rms = (chunk.squared.mean).sqrt;
			var nan = chunk.any { |x| x.isNaN };
			var verdict = case
				{ nan } { "FAIL (NaN)" }
				{ peak < 0.01 } { "FAIL (silent)" }
				{ peak >= 1.0 } { "FAIL (clips)" }
				{ "ok" };
			if(verdict != "ok") { failures = failures + 1 };
			"  % % % %".format(name.asString.padRight(14), peak.round(0.001).asString.padRight(8),
				rms.round(0.0001).asString.padRight(8), verdict).postln;
		};
		"\n% of % segments failed. Listen: %".format(failures, labels.size, wav).postln;
		(if(failures == 0) { 0 } { 1 }).exit;
	}
);
)
