// =====================================================================
// core/control.scd: the "system" layer. Commands, start/stop, the
// monitor (metrics + reactions), OSC in/out, audio analysis, the server
// graph, and status printing.
// =====================================================================
//
// INTERACTION SURFACES (all lead to the same ~gas.cmd):
//   live code     ~gas.cmd(\scale, \lydian)
//   queued        ~gas.queue(\bar, \in, \flute)
//   timeline      [96, \scale, \lydian]
//   reactions     (when: {|gas, m| m.tension > 0.7}, then: [\process, \all, \subtractive])
//   OSC           /gas/cmd scale lydian          (port 57120, sclang's default)
//                 /gas/queue 8 in flute
//   reading       ~gas.status, ~gas.metrics, ~gas.analysis, ~gas.recent
//                 and, with system.oscOut set, a /gas/metrics message every bar
// =====================================================================

(
// ---------------------------------------------------------------------
// QUANTISATION RULE
// When a command runs INSIDE the system's own clock (timeline, queue,
// reactions), it already happens at a musically chosen moment, so it
// acts immediately (quant 0). When a human types it, there's no telling
// where in the bar they are, so entries wait for the next bar line.
// `thisThread.clock` tells us which situation we're in.
// ---------------------------------------------------------------------
~gas.liveQuant = { |self|
	if(thisThread.clock === self.beatClock) { 0 } { self.bpb ? 4 }
};

// Run a command: ~gas.cmd(\name, args...)
~gas.cmd = { |self, name ... args| self.cmdArray([name] ++ args) };

// The dispatcher. Errors inside a command are caught and logged, so a
// typo in bar 97 doesn't kill the performance.
~gas.cmdArray = { |self, list|
	var name = list[0], args = list.drop(1);
	var fn = self.commands[name] ?? { self.comp !? { self.comp.commands[name] } };
	if(fn.isNil) { self.log("unknown command %".format(name), \warn); nil } {
		try { fn.valueArray([self] ++ args) } { |err|
			self.log("command % failed: %".format(name, err.errorString), \error); nil
		}
	}
};

// Resolve a target to a list of voices: \all, a name, or an Array of names
~gas.targets = { |self, t|
	case
	{ t == \all } { self.voices.values.asArray }
	{ t.isKindOf(Array) } { t.collect { |n| self.voices[n] }.reject(_.isNil) }
	{ self.voices[t].notNil } { [self.voices[t]] }
	{ self.log("no instrument called %".format(t), \warn); [] }
};

// Generic ramp over `beats` on the system clock. `key` names what's being
// ramped, so a new ramp on the same thing replaces the old one.
~gas.ramp = { |self, key, from, to, beats, setter|
	self.ramps[key] !? { self.ramps[key].stop };
	if((beats ? 0) <= 0 or: { self.beatClock.isNil }) { setter.value(to) } {
		self.ramps[key] = Routine {
			var steps = (beats * 8).ceil.asInteger.max(1);
			steps.do { |i|
				setter.value(from.blend(to, (i + 1) / steps));
				(beats / steps).wait;
			};
			self.ramps[key] = nil;
		}.play(self.beatClock);
	};
	nil
};

// ---------------------------------------------------------------------
// HARMONY HELPERS (used by commands)
// ---------------------------------------------------------------------
~gas.setScale = { |self, scale|
	self.harmony.degrees = self.resolveScale(scale);
	self.harmony.scaleName = scale;
	self.log("scale  %".format(scale), \event);
	self.emit('/gas/scale', scale);
};

~gas.setRoot = { |self, root|
	self.harmony.root = self.toMidi(root);
	self.log("root   %".format(self.noteName(self.harmony.root)), \event);
	self.emit('/gas/root', self.harmony.root);
};

// Master volume. In seconds for the synth's lag, so convert from beats.
~gas.setMaster = { |self, vol, beats = 0|
	var secs = if(self.beatClock.notNil) { beats / self.beatClock.tempo } { 0 };
	self.volume = vol;
	self.masterSynth !? { self.masterSynth.set(\vol, vol, \lagTime, secs.max(0.05)) };
};

// =====================================================================
// THE COMMAND VOCABULARY
// Each is { |self, args...| }. `target` is an instrument name, \all, or
// an Array of names. Compositions can add their own in `commands: (...)`.
// =====================================================================
~gas.commands = (
	// ---- structure ----
	section: { |self, name|
		self.section = name;
		self.log("== section % ==".format(name), \event);
		self.emit('/gas/section', name);
	},
	goto:  { |self, name| self.gotoSection(name) },   // in a timeline, the runner handles this
	end:   { |self, beats = 8| self.end(beats) },
	post:  { |self ... words| self.log(words.join(" "), \event) },
	func:  { |self, fn ... args| fn.valueArray([self] ++ args) },   // escape hatch: run any code

	// ---- instruments in/out ----
	in:  { |self, name, figure|
		var v = self.voices[name];
		if(v.notNil and: { figure.notNil }) { self.setFigure(v, figure) };
		self.voiceIn(name)
	},
	out: { |self, name, how| self.voiceOut(name, how == \now) },

	// ---- harmony ----
	scale: { |self, scale| self.setScale(scale) },
	root:  { |self, root| self.setRoot(root) },
	shift: { |self, semitones| self.setRoot(self.harmony.root + semitones) },
	// diatonic shift of the whole texture: [t, \chord, 5] in A minor = F major area
	chord: { |self, degree|
		self.harmony.chord = degree;
		self.log("chord  % (degree %)".format(
			self.noteName(self.harmony.root + degree.degreeToKey(self.harmony.degrees, 12)), degree), \event);
		self.emit('/gas/chord', degree);
	},

	// ---- time ----
	tempo: { |self, bpm, beats = 0|
		var from = self.tempo;
		self.ramp(\tempo, from, bpm, beats, { |b| self.tempo = b; self.beatClock !? { self.beatClock.tempo = b / 60 } });
		self.log("tempo  % -> % over % beats".format(from, bpm, beats), \event);
	},
	nudge:   { |self, target, beats = 0.25| self.targets(target).do { |v| v.nudge = beats } },
	stretch: { |self, target, x| self.targets(target).do { |v| v.stretch = x } },

	// ---- evolution ----
	process: { |self, target, process|
		self.targets(target).do { |v| v.process = process };
		self.log("process % -> %".format(target, process), \event);
	},
	// [t, \evolve, \organ, (strength: 0.8, period: 2, weights: (rotate: 3))]
	evolve: { |self, target, params|
		self.targets(target).do { |v|
			params.keysValuesDo { |k, x|
				if(k == \weights) { v.weights = self.deepMerge(v.weights, x) } { v[k] = x }
			}
		};
		self.log("evolve % %".format(target, params), \event);
	},
	// force one mutation now (it is heard at the voice's next cycle)
	mutate: { |self, target, op|
		self.targets(target).do { |v|
			var r = self.applyMutation(v, op);
			self.log("% % (forced)  ->  %".format(v.name, r ? "no change", self.figString(v)), \mutate);
		}
	},
	figure: { |self, target, fig| self.targets(target).do { |v| self.setFigure(v, fig) } },
	revert: { |self, target| self.targets(target).do { |v| self.revertVoice(v) } },
	snapshot: { |self, name| self.snapshot(name) },
	recall:   { |self, name| self.recall(name) },

	// ---- mix ----
	// [t, \vol, \organ, 0.1, 8]  or  [t, \vol, \master, 0, 16]
	vol: { |self, target, amp, beats = 0|
		if(target == \master) {
			self.setMaster(amp, beats)
		} {
			self.targets(target).do { |v|
				self.ramp(("vol_" ++ v.name).asSymbol, v.amp, amp, beats, { |a| v.amp = a })
			}
		}
	},
	pan:  { |self, target, p| self.targets(target).do { |v| v.pan = p } },
	verb: { |self, target, amt| self.targets(target).do { |v| v.verb = amt } },
	mute: { |self, target, flag = true| self.targets(target).do { |v| v.muted = flag } }
);

// =====================================================================
// LIFECYCLE
// =====================================================================

// Begin a performance of the loaded composition. Every start is fresh:
// new clock at beat 0, figures and harmony back to what's written.
~gas.start = { |self|
	case
	{ self.comp.isNil } { self.log("no composition loaded", \warn) }
	{ self.running } { self.log("already running (~gas.end or ~gas.kill first)", \warn) }
	{
		var sys = self.comp.system;
		if(sys.seed.notNil) { thisThread.randSeed = sys.seed };
		self.buildVoices;
		self.resetHarmony;
		self.section = nil;
		self.reactionTimes = ();
		self.tempo = sys.tempo;
		self.beatClock = TempoClock(sys.tempo / 60);
		self.running = true;
		self.setMaster(sys.volume, 0);
		self.runTimeline(0, 0);
		self.startMonitor;
		self.log("started '%' at % BPM".format(self.comp[\name] ? "untitled", sys.tempo), \event);
	};
	self
};

// Musical ending: fade the master over `beats`, then stop everything.
~gas.end = { |self, beats = 8|
	if(self.running.not) { self.log("not running", \warn) } {
		self.log("ending over % beats".format(beats), \event);
		self.setMaster(0, beats);
		self.beatClock.sched(beats + 0.5, { self.kill; nil });
	};
	self
};

// Stop immediately.
~gas.kill = { |self|
	self.voices.do { |v| v.player !? { v.player.stop }; v.player = nil };
	self.tlTask !? { self.tlTask.stop }; self.tlTask = nil;
	self.monitorTask !? { self.monitorTask.stop }; self.monitorTask = nil;
	self.ramps.do { |r| r.stop }; self.ramps = ();
	if(self.running) { self.log("stopped", \event) };
	self.running = false;
	self.beatClock !? { self.beatClock.stop }; self.beatClock = nil;
	// restore the composition's volume so the next start isn't silent
	self.comp !? { self.setMaster(self.comp.system.volume, 0) };
	self
};

// =====================================================================
// MONITOR: once per bar, measure the texture, check reactions, report
// =====================================================================
~gas.startMonitor = { |self|
	self.monitorTask = Routine {
		var bars = 0, every = self.comp.system.status;
		loop {
			self.updateMetrics;
			self.checkReactions;
			self.emitMetrics;
			if((every > 0) and: { (bars % every) == 0 } and: { bars > 0 } and: { self.verbosity != \quiet }) {
				self.statusLine.postln
			};
			bars = bars + 1;
			self.bpb.wait;
		}
	}.play(self.beatClock, quant: 0);
};

// METRICS: a small, cheap description of the current texture. This
// replaces the archive's harmonicDensity/rhythmicDensity/verticalSpread/
// tension block, which counted notes rather than pitch classes and was
// recomputed inside every single mutation.
//   density  notes per beat, summed over sounding voices
//   span     semitones from lowest to highest sounding note
//   pcs      number of distinct pitch classes (harmonic richness)
//   steps    total figure length across voices
//   tension  0..1 blend of the three (a starting point; tune to taste)
~gas.updateMetrics = { |self|
	var midis = List.new, density = 0, steps = 0, m, active = self.activeVoices;
	active.do { |v|
		var len = v.figure.sum { |st| st[\dur] } * v.stretch;
		var notes = v.figure.reject { |st| self.silent(st[\deg]) }
		.collect { |st| self.degreeToMidi(v, st[\deg]) }.flat;
		midis.addAll(notes);
		steps = steps + v.figure.size;
		if(len > 0) { density = density + (notes.size / len) };
	};
	m = (
		beat: self.beatClock !? { self.beatClock.beats.round(0.01) } ? 0,
		section: self.section,
		voices: active.size,
		steps: steps,
		density: density.round(0.01),
		span: if(midis.isEmpty) { 0 } { midis.maxItem - midis.minItem },
		pcs: midis.collect { |x| x % 12 }.asSet.size
	);
	m.tension = (((m.density / 8).clip(0, 1) * 0.4)
		+ ((m.span / 36).clip(0, 1) * 0.3)
		+ ((m.pcs / 7).clip(0, 1) * 0.3)).round(0.001);
	self.metrics = m;
	m
};

// REACTIONS: composition-defined rules, checked every bar.
//   (name: \thin,
//    when: { |gas, m| m.density > 6 },            // condition (gets ~gas and metrics)
//    then: [\process, \all, \subtractive],         // a command, or { |gas, m| ... }
//    cooldown: 32,                                 // beats before it may fire again
//    chance: 0.5,                                  // probability when the condition holds
//    once: false)                                  // fire only once per performance
~gas.checkReactions = { |self|
	self.comp.reactions.do { |r, i|
		var last = self.reactionTimes[i], now = self.beatClock.beats, ok;
		var ready = (last.isNil or: { (now - last) >= (r[\cooldown] ? 16) })
		and: { (r[\once] != true) or: { last.isNil } };
		if(ready) {
			ok = try { r[\when].value(self, self.metrics) == true } { |err|
				self.log("reaction % condition failed: %".format(r[\name] ? i, err.errorString), \error); false
			};
			if(ok and: { (r[\chance] ? 1).coin }) {
				self.reactionTimes[i] = now;
				self.log("reaction % fired".format(r[\name] ? i), \event);
				if(r[\then].isKindOf(Array)) { self.cmdArray(r[\then]) } {
					try { r[\then].value(self, self.metrics) } { |err|
						self.log("reaction % failed: %".format(r[\name] ? i, err.errorString), \error)
					}
				};
			};
		};
	};
};

// =====================================================================
// OSC
// =====================================================================

// Outgoing: only if system.oscOut = [host, port]
~gas.emit = { |self, path ... args|
	self.oscOut !? { self.oscOut.sendMsg(path, *args) };
};

~gas.emitMetrics = { |self|
	var m = self.metrics, a = self.analysis;
	self.oscOut !? {
		self.oscOut.sendMsg('/gas/metrics', m.beat, (m.section ? \none), m.voices, m.steps,
			m.density, m.span, m.pcs, m.tension, a.amp, a.centroid, a.flatness)
	};
};

// Incoming: commands and queue requests, plus analysis replies from the server.
~gas.setupOSC = { |self|
	// /gas/cmd scale lydian      (OSC strings arrive in sclang as Symbols)
	OSCdef(\gas_cmd, { |msg| self.cmdArray(msg.drop(1)) }, '/gas/cmd');
	// /gas/queue 8 in flute      or  /gas/queue bar out organ
	OSCdef(\gas_queue, { |msg| self.queue(*msg.drop(1)) }, '/gas/queue');
	// /gas/status  -> replies to the sender with /gas/metrics
	OSCdef(\gas_status, { |msg, time, addr|
		var m = self.metrics;
		addr.sendMsg('/gas/metrics', m.beat ? 0, (m.section ? \none), m.voices ? 0, m.steps ? 0,
			m.density ? 0, m.span ? 0, m.pcs ? 0, m.tension ? 0)
	}, '/gas/status');
	// replies from \gasAnalyzer: [path, nodeID, replyID, amp, centroid, flatness, onsets]
	OSCdef(\gas_analysis, { |msg|
		var a = self.analysis;
		a.amp = msg[3]; a.centroid = msg[4]; a.flatness = msg[5]; a.onsets = msg[6];
	}, '/gas/analysis');
	self.log("OSC: listening on port % for /gas/cmd, /gas/queue, /gas/status".format(NetAddr.langPort), \info);
};

// =====================================================================
// SERVER GRAPH
//   [src group: voices] -> [fx group: reverb] -> [master group: analyzer, master]
// Voices write dry to `main` and their send to `verb`; the reverb adds
// into `main`; the master reads `main` and writes to the speakers.
// Rebuilt automatically after Cmd-. (via ServerTree), so pressing Cmd-.
// during a performance never leaves the system without its master/reverb.
// =====================================================================
~gas.allocBuses = { |self|
	self.buses = (main: Bus.audio(self.srv, 2), verb: Bus.audio(self.srv, 2));
};

~gas.buildGraph = { |self|
	var s = self.srv, sys = (self.comp ? self.defaults).system;
	self.groups = ();
	self.groups.src    = Group.head(s);
	self.groups.fx     = Group.after(self.groups.src);
	self.groups.master = Group.after(self.groups.fx);
	self.verbSynth = Synth(\gasReverb, [\in, self.buses.verb.index, \out, self.buses.main.index,
		\room, sys.reverb.room, \damp, sys.reverb.damp, \level, sys.reverb.level], self.groups.fx);
	if(sys.analysis) {
		self.analyzer = Synth(\gasAnalyzer, [\in, self.buses.main.index], self.groups.master, \addToHead);
	};
	self.masterSynth = Synth(\gasMaster, [\in, self.buses.main.index, \out, 0, \vol, self.volume ? sys.volume],
		self.groups.master, \addToTail);
};

// Push the composition's system settings to the running server graph
~gas.applySystem = { |self|
	var sys = self.comp.system;
	self.volume = sys.volume;
	self.oscOut = sys.oscOut !? { NetAddr(sys.oscOut[0], sys.oscOut[1]) };
	self.verbSynth !? { self.verbSynth.set(\room, sys.reverb.room, \damp, sys.reverb.damp, \level, sys.reverb.level) };
	self.masterSynth !? { self.masterSynth.set(\vol, sys.volume) };
};

// Boot (or not, in a dry run), load SynthDefs and a composition, then call onReady.
~gas.boot = { |self, config, onReady|
	config = config ? ();
	self.dry = config[\dryRun] == true;
	if(self.dry) {
		self.log("dry run: no server, the score is printed instead of played", \info);
		self.loadComposition(config[\composition] ? "glassian");
		onReady.value(self);
	} {
		self.srv = Server.default;
		self.srv.options.memSize = 65536;        // room for FFT buffers etc. (must be an Integer)
		self.srv.latency = 0.1;                  // patterns are scheduled this far ahead: tight timing
		self.srv.waitForBoot {
			(self.root +/+ "synthdefs.scd").load;
			self.srv.sync;
			self.allocBuses;
			self.buildGraph;
			// rebuild the graph after Cmd-. (which frees every node)
			ServerTree.remove(self[\treeFunc], self.srv);   // brackets: dot access would CALL it
			self.treeFunc = { self.kill; self.buildGraph; self.log("graph rebuilt after Cmd-.", \info) };
			ServerTree.add(self[\treeFunc], self.srv);
			self.srv.sync;
			self.setupOSC;
			self.loadComposition(config[\composition] ? "glassian");
			onReady.value(self);
		};
	};
	self
};

// Record the master output to a file (stops when you call it again or at ~gas.kill)
~gas.rec = { |self, path|
	if(self.dry) { self.log("can't record a dry run", \warn) } {
		if(self.srv.isRecording) { self.srv.stopRecording } {
			path = path ?? { self.root +/+ "recordings" +/+ "gas_%.wav".format(Date.getDate.stamp) };
			File.mkdir(path.dirname);
			self.srv.recHeaderFormat = "wav";
			self.srv.record(path);
		}
	}
};

// =====================================================================
// READING THE SYSTEM
// =====================================================================

// One line, good for the post window during a performance
~gas.statusLine = { |self|
	var m = self.metrics, h = self.harmony;
	"[%] % | % % chord % | voices % steps % | dens % span % pcs % | tension %".format(
		self.where, self.tempo.round(0.1), self.noteName(h.root), h.scaleName, h.chord,
		m.voices, m.steps, m.density, m.span, m.pcs, m.tension)
};

// The full picture
~gas.status = { |self|
	var h = self.harmony;
	"".postln;
	"=== % ===  %".format(self.comp !? { self.comp[\name] } ? "no composition",
		if(self.running) { "RUNNING " ++ self.where } { "stopped" }).postln;
	if(h.notNil) {
		"harmony: root % | scale % | chord % | tempo %".format(
			self.noteName(h.root), h.scaleName, h.chord, self.tempo ? "-").postln;
	};
	(self.voiceOrder ? []).do { |n|
		var v = self.voices[n];
		"  % % %  len %/%-% cyc %  % | %".format(
			if(self.playing(v)) { if(v.muted) { "M" } { ">" } } { " " },
			n.asString.padRight(8), v.process.asString.padRight(11),
			v.figure.size, v.minLen, v.maxLen, v.cycles.asString.padLeft(3),
			v.sound, self.figString(v)).postln;
	};
	if(self.metrics.notEmpty) {
		"metrics: %".format(self.metrics).postln;
		"audio:   amp % | centroid % Hz | flatness %".format(
			self.analysis.amp.round(0.001), self.analysis.centroid.round(1), self.analysis.flatness.round(0.001)).postln;
	};
	"".postln;
	self
};

~gas.guide = { |self|
	[
		"",
		"=== Glassian Autonomous System ===",
		"  ~gas.start                      begin the loaded composition",
		"  ~gas.end(16)                    fade out over 16 beats, then stop",
		"  ~gas.kill                       stop now",
		"  ~gas.status                     everything, now",
		"  ~gas.recent(20)                 last 20 log lines",
		"  ~gas.loadComposition(\"drift\")   load compositions/drift.scd",
		"  ~gas.rec                        start/stop recording to recordings/",
		"",
		"  ~gas.cmd(\\scale, \\lydian)        any timeline command, right now",
		"  ~gas.queue(\\bar, \\in, \\flute)    ...or later: beats, \\bar, \\bars4",
		"  commands: " ++ self.commands.keys.asArray.sort.join(" ") ++ " loop",
		"  ~gas.cmd(\\evolve, \\organ, (strength: 0.9, period: 2))",
		"  ~gas.cmd(\\mutate, \\all, \\retrograde)",
		"  ~gas.cmd(\\vol, \\master, 0.3, 8)",
		""
	].do(_.postln);
	self
};

"[gas] control loaded".postln;
)
