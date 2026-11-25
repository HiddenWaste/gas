// =====================================================================
// core/engine.scd: the pattern engine. Voices, figures, mutation, playback.
// =====================================================================
//
// THE MODEL (one paragraph)
// Each instrument is a VOICE that loops a short FIGURE (a list of steps:
// scale degree + duration + dynamic). The voice plays its figure over and
// over; one full pass is a CYCLE. Every `period` cycles, the voice rolls
// `chance` to see whether it MUTATES. If it does, the PROCESS decides the
// DIRECTION of change (grow? shrink? neither?) and STRENGTH decides how big
// the change is and how many changes happen. WEIGHTS pick which kind.
// Mutations only ever land on a cycle boundary, so each voice changes on
// its own downbeat. Voices whose figures have different lengths drift in
// and out of alignment with each other: that's the "phasing" of the piece,
// and it comes from the structure itself, not from a separate routine.
//
// This answers the "when / direction / strength" requirement in
// project-idea.md:
//     WHEN      = period x chance          (+ timeline, reactions, live commands)
//     DIRECTION = process                  (\additive \subtractive \breathe ...)
//     STRENGTH  = strength                 (size of leaps/transpositions, 1-2 ops)
//
// A STEP is a tiny Event:  (deg: 2, dur: 0.5, vel: 1)
//   deg  scale degree (Integer), chord (Array of degrees) or \r for a rest
//   dur  length in beats
//   vel  0..1 dynamic shading; the downbeat accent is added at play time
//
// GLASS'S ADDITIVE PROCESS, specifically
// An instrument can be given a long figure and a short `start:`. The voice
// then begins with only the first `start` notes, and each "grow" mutation
// usually (with probability `unfold`) REVEALS the next note of the
// original figure:
//      1 2  ->  1 2 3  ->  1 2 3 4  ->  ...
// That is the additive process from Einstein on the Beach and Music in
// Twelve Parts. When a voice is past the end of its seed figure, grow
// invents a new note: stepwise motion, chord tones preferred.
//
// All step fields are read with brackets (st[\dur]), never st.dur. See the
// collision note in state.scd. Voice fields are safe to dot-access because
// their names were chosen not to collide.
// =====================================================================

(
// ---------------------------------------------------------------------
// VOICE CONSTRUCTION
// Resolution order (later wins):
//   defaults.voice  <  composition.evolution  <  styles[style]  <  the instrument entry
// The result is ONE flat Event per voice holding sound + figure +
// evolution settings. Live commands change these keys directly.
// ---------------------------------------------------------------------
~gas.makeVoice = { |self, name, spec|
	var c = self.comp, v, style;
	style = if(spec[\style].notNil) { c.styles[spec[\style]] ? () } { () };
	v = self.deepMerge(c.voice, c.evolution);
	v = self.deepMerge(v, style);
	v = self.deepMerge(v, spec);

	v.name   = name;
	v.range  = v.range ? c.constraints.range;
	v.period = v.period.asInteger.max(1);
	v.minLen = v.minLen.max(1);
	v.seed   = self.parseFigure(v, v.figure);           // the full, original figure
	v.start  = (v.start ? v.seed.size).clip(1, v.seed.size);
	v.maxLen = v.maxLen.max(v.start);                    // never forbid the starting length
	self.revertVoice(v);
	v.player = nil;
	v.muted  = false;
	v.leaving = false;
	v.nudge  = 0;
	v
};

// (Re)build every voice from the composition. Called on load and on start,
// so each performance begins from the written figures.
~gas.buildVoices = { |self|
	self.voices = ();
	self.comp.instruments.keysValuesDo { |name, spec| self.voices[name] = self.makeVoice(name, spec) };
	self.voiceOrder = self.orderVoices;
	self.voices
};

// Events have no key order, so for display we order voices by their first
// appearance in the timeline (entry order), then alphabetically.
~gas.orderVoices = { |self|
	var order = List.new;
	self.comp.timeline.do { |e|
		var n = e[\args][0];
		if((e[\cmd] == \in) and: { self.voices[n].notNil } and: { order.includes(n).not }) { order.add(n) }
	};
	self.voices.keys.asArray.sort.do { |n| if(order.includes(n).not) { order.add(n) } };
	order.asArray
};

// Back to the start of the written figure
~gas.revertVoice = { |self, v|
	v.figure = v.seed.keep(v.start).collect(_.copy);
	v.cycles = 0;
	v.dir = \grow;           // used by the \breathe process
	v
};

// Composition figure -> steps.  `durs` (if given) is cycled over the steps.
~gas.parseFigure = { |self, v, fig|
	fig.collect { |deg, i|
		(deg: deg, dur: (v.durs !? { v.durs.wrapAt(i) } ? v.pulse).max(1/64), vel: 1)
	}
};

// Replace a voice's figure (new seed, starts from the full figure)
~gas.setFigure = { |self, v, fig|
	v.seed  = self.parseFigure(v, fig);
	v.start = v.seed.size;
	v.maxLen = v.maxLen.max(v.start);
	self.revertVoice(v)
};

// ---------------------------------------------------------------------
// PLAYBACK
// Each voice is a Prout (a Routine-as-pattern) that keeps asking
// nextCycle for "the next pass of the figure" and embeds it. Because the
// Pbind for a cycle is built when the cycle starts, any change (mutation,
// scale, chord, figure) is picked up exactly at the voice's next downbeat.
//
// Why a Prout loop and not Pn(Plazy(...))? With Pn, a voice that wants to
// leave would have to return an empty pattern, and Pn would immediately ask
// again, forever, freezing sclang. The Prout simply ends its loop, and
// the player stops cleanly at the end of the cycle.
// ---------------------------------------------------------------------
~gas.voiceIn = { |self, name, quant|
	var v = self.voices[name];
	case
	{ v.isNil } { self.log("no instrument called %".format(name), \warn) }
	{ v.player.notNil and: { v.player.isPlaying } and: { v.leaving.not } } {
		// quiet: a looped section re-running its \in entries is normal
		self.log("% is already playing".format(name), \debug)
	}
	{
		var pat;
		if(v.player.notNil) { v.player.stop };          // it was on its way out: cut it
		v.leaving = false;
		v.cycles = 0;
		pat = Prout { |inval|
			var ev = inval;
			while { v.leaving.not } { ev = self.nextCycle(v).embedInStream(ev) };
			ev
		};
		v.player = pat.play(self.beatClock, quant: quant ? self.liveQuant);
		self.log("% in   %".format(name.asString.padRight(8), self.figString(v)), \event);
		self.emit('/gas/voice', name, \in);
	};
	v
};

// Leave at the end of the current cycle (musical), or `now`.
~gas.voiceOut = { |self, name, now = false|
	var v = self.voices[name];
	if(v.isNil) { self.log("no instrument called %".format(name), \warn) } {
		if(now == true) {
			v.player !? { v.player.stop };
			v.player = nil;
		} {
			v.leaving = true;
		};
		self.log("% out%".format(name, if(now == true) { " (now)" } { "" }), \event);
		self.emit('/gas/voice', name, \out);
	};
	v
};

// Is a voice currently sounding?
~gas.playing = { |self, v| v.player.notNil and: { v.player.isPlaying } and: { v.leaving.not } };

~gas.activeVoices = { |self|
	self.voiceOrder.collect { |n| self.voices[n] }.select { |v| self.playing(v) and: { v.muted.not } }
};

// Called at the top of each cycle: count, maybe mutate, then build the cycle.
~gas.nextCycle = { |self, v|
	v.cycles = v.cycles + 1;
	if((v.cycles > 1) and: { ((v.cycles - 1) % v.period) == 0 }) { self.evolveVoice(v) };
	self.cyclePattern(v)
};

// One pass of the figure as a finite Pbind.
// Static values are computed now; values a performer may change mid-cycle
// (amp, pan, reverb send, stretch, legato) are read live with Pfunc.
~gas.cyclePattern = { |self, v|
	var fig = v.figure, midis, durs, vels;
	if(fig.isEmpty) { fig = [(deg: \r, dur: v.pulse, vel: 0)] };   // safety: never a zero-length cycle
	midis = fig.collect { |st| self.degreeToMidi(v, st[\deg]) };
	durs  = fig.collect { |st| st[\dur] };
	// the downbeat of each cycle is accented; that's what makes the
	// figure's length audible, so the listener hears the grouping change
	vels  = fig.collect { |st, i| st[\vel] * if(i == 0) { 1 } { 1 - v.accent } };

	// A pending \nudge: delay this cycle by a fraction of a beat (Reich-style
	// phase shift). It is consumed once.
	if(v.nudge != 0) {
		midis = [Rest()] ++ midis;
		durs  = [v.nudge.abs] ++ durs;
		vels  = [0] ++ vels;
		v.nudge = 0;
	};

	Pbind(
		\type,       if(self.dry) { \rest } { \note },
		\instrument, v.sound,
		\midinote,   Pseq(midis),
		\dur,        Pseq(durs),
		\stretch,    Pfunc { v.stretch },
		\legato,     Pfunc { v.legato },
		\amp,        Pseq(vels) * Pfunc { if(v.muted) { 0 } { v.amp } } * Pwhite(1 - v.human, 1 + v.human),
		\pan,        Pfunc { v.pan },
		\sendAmt,    Pfunc { v.verb },
		\out,        self.buses !? { self.buses.main.index } ? 0,
		\send,       self.buses !? { self.buses.verb.index } ? 0,
		\group,      self.groups !? { self.groups.src.nodeID } ? 1
	)
};

// =====================================================================
// EVOLUTION
// =====================================================================

// A mutation check: roll `chance`; strong voices may stack two mutations.
~gas.evolveVoice = { |self, v|
	if(v.chance.coin) {
		var count = if((v.strength > 0.66) and: { v.strength.coin }) { 2 } { 1 };
		var done = count.collect { self.applyMutation(v) }.reject(_.isNil);
		if(done.notEmpty) {
			self.log("% %  ->  %".format(
				v.name.asString.padRight(8), done.join(" + "), self.figString(v)), \mutate);
			self.emit('/gas/mutation', v.name, done.join(" + "));
		};
	};
	v
};

// The process turns the voice's weights into "what is allowed right now".
~gas.effectiveWeights = { |self, v|
	var w = v.weights.copy, n = v.figure.size;
	switch(v.process)
	{ \additive }    { w[\shrink] = 0 }
	{ \subtractive } { w[\grow] = 0 }
	{ \static }      { w[\grow] = 0; w[\shrink] = 0 }
	{ \breathe }     {
		// grow to maxLen, then shrink to minLen, then grow again...
		if(n >= v.maxLen) { v.dir = \shrink };
		if(n <= v.minLen) { v.dir = \grow };
		if(v.dir == \grow) { w[\shrink] = 0 } { w[\grow] = 0 };
	}
	{ \free } { };
	w
};

// Pick and apply one mutation; answer its description, or nil if nothing
// could be done. Inapplicable choices (e.g. grow at maxLen) are discarded
// and another is drawn, so a check is never silently wasted.
// Pass `forced` (a Symbol) to apply that specific mutation.
~gas.applyMutation = { |self, v, forced|
	var w = self.effectiveWeights(v), ops, op, result;
	ops = if(forced.notNil) { [forced] } {
		// sorted so a seeded run makes the same choices every time
		w.keys.asArray.sort.select { |k| (w[k] > 0) and: { self.mutations[k].notNil } }
	};
	while { result.isNil and: { ops.notEmpty } } {
		op = if(forced.notNil) { forced } { ops.wchoose(ops.collect { |k| w[k] }.normalizeSum) };
		if(self.mutations[op].isNil) {
			self.log("unknown mutation %".format(op), \warn);
			ops = [];
		} {
			result = self.mutations[op].value(self, v, v.strength);
			ops.remove(op);
		}
	};
	result
};

// Apply `fn` to a step's degree unless it's a rest. Answers a NEW step.
~gas.mapDeg = { |self, st, fn|
	var n = st.copy;
	if(self.silent(n[\deg]).not) { n[\deg] = fn.value(n[\deg]) };
	n
};

// Index of a random non-rest step, or nil
~gas.pickNote = { |self, v|
	var idx = v.figure.collect { |st, i| if(self.silent(st[\deg])) { nil } { i } }.reject(_.isNil);
	idx.choose
};

// Invent a new step that continues the line: stepwise motion is most
// likely, chord tones (0, 2, 4 in the scale) get a bonus, and very high or
// low degrees are discouraged so lines don't wander off. Strength widens the
// allowed leap from 1 to 4 scale steps.
~gas.inventStep = { |self, v, s|
	var last = v.figure.reverse.detect { |st| self.silent(st[\deg]).not };
	var base = if(last.notNil) { last[\deg].asArray.first } { 0 };
	var maxLeap = 1 + (s * 3).round.asInteger;
	var steps = self.harmony.degrees.size;
	var cands = ((base - maxLeap) .. (base + maxLeap)).reject { |d| d == base };
	var weights = cands.collect { |d|
		var dist = (d - base).abs;
		var chord = if([0, 2, 4].includes(d % steps)) { 2 } { 1 };
		chord / dist / (1 + (d.abs / steps))
	};
	(deg: cands.wchoose(weights.normalizeSum), dur: v.pulse, vel: 1)
};

// ---------------------------------------------------------------------
// THE MUTATIONS
// Each is  { |self, voice, strength| ... }  and answers a short description
// String if it changed the figure, or nil if it couldn't apply.
// To add a new kind of mutation: add a function here and give it a weight
// in a composition. Nothing else needs to change.
// ---------------------------------------------------------------------
~gas.mutations = (

	// ADD a note at the end (reveal the seed, or invent)
	grow: { |self, v, s|
		var fig = v.figure, step, how;
		if(fig.size >= v.maxLen) { nil } {
			if((fig.size < v.seed.size) and: { v.unfold.coin }) {
				step = v.seed[fig.size].copy; how = "unfold";
			} {
				step = self.inventStep(v, s); how = "grow";
			};
			v.figure = fig ++ [step];
			"% %".format(how, self.stepName(v, step))
		}
	},

	// REMOVE a note: usually the last (Glass's subtractive process); a
	// strong voice sometimes drops the first instead, which also shifts
	// where the accent falls.
	shrink: { |self, v, s|
		var fig = v.figure, front, gone;
		if(fig.size <= v.minLen) { nil } {
			front = (s > 0.7) and: { 0.3.coin };
			gone = if(front) { fig.first } { fig.last };
			v.figure = if(front) { fig.drop(1) } { fig.drop(-1) };
			"shrink %%".format(if(front) { "^" } { "" }, self.stepName(v, gone))
		}
	},

	// Move the whole figure by scale steps. Pulls back toward the centre if
	// the figure has wandered far from the root.
	transpose: { |self, v, s|
		var notes = v.figure.reject { |st| self.silent(st[\deg]) }, centre, amt, sign;
		if(notes.isEmpty) { nil } {
			centre = notes.collect { |st| st[\deg].asArray.mean }.mean;
			sign = case { centre > 5 } { -1 } { centre < -5 } { 1 } { [-1, 1].choose };
			amt = rrand(1, 1 + (s * 3).round.asInteger) * sign;
			v.figure = v.figure.collect { |st| self.mapDeg(st, { |d| d + amt }) };
			"transpose %%".format(if(amt > 0) { "+" } { "" }, amt)
		}
	},

	// Play it backwards. The accent stays on the downbeat (it is applied by
	// position at play time), so the reversed figure is re-grouped.
	retrograde: { |self, v, s|
		if(v.figure.size < 2) { nil } { v.figure = v.figure.reverse; "retrograde" }
	},

	// Mirror the figure around its first note, diatonically
	invert: { |self, v, s|
		var first = v.figure.detect { |st| self.silent(st[\deg]).not }, pivot;
		if(first.isNil or: { v.figure.size < 2 }) { nil } {
			pivot = first[\deg].asArray.first;
			v.figure = v.figure.collect { |st| self.mapDeg(st, { |d| (2 * pivot) - d }) };
			"invert"
		}
	},

	// Move the first step to the end: the same notes, but the downbeat
	// (and so the perceived pattern) shifts by one
	rotate: { |self, v, s|
		if(v.figure.size < 2) { nil } { v.figure = v.figure.rotate(-1); "rotate" }
	},

	// Exchange two neighbouring steps
	swap: { |self, v, s|
		var i;
		if(v.figure.size < 2) { nil } {
			i = rrand(0, v.figure.size - 2);
			v.figure = v.figure.copy.swap(i, i + 1);
			"swap %<>%".format(i, i + 1)
		}
	},

	// Nudge one note up or down a scale step: the subtlest change
	neighbor: { |self, v, s|
		var i = self.pickNote(v), old, new;
		if(i.isNil) { nil } {
			old = v.figure[i];
			new = self.mapDeg(old, { |d| d + [-1, 1].choose });
			v.figure = v.figure.copy.put(i, new);
			"neighbor % -> %".format(self.stepName(v, old), self.stepName(v, new))
		}
	},

	// Re-shade the dynamic of one step
	shade: { |self, v, s|
		var i = rrand(0, v.figure.size - 1), st = v.figure[i].copy;
		st[\vel] = rrand(1 - (0.5 * s) - 0.1, 1.0).clip(0.3, 1);
		v.figure = v.figure.copy.put(i, st);
		"shade %".format(i)
	},

	// Change one step's duration (off by default: Glass keeps a steady pulse)
	rhythm: { |self, v, s|
		var i = rrand(0, v.figure.size - 1), st = v.figure[i].copy, choices, new;
		choices = if(s < 0.5) { [0.5, 1, 2] } { [0.5, 1, 1.5, 2, 3] } * v.pulse;
		new = choices.reject { |d| d == st[\dur] }.choose;
		st[\dur] = new;
		v.figure = v.figure.copy.put(i, st);
		"rhythm % -> %".format(i, new)
	},

	// Turn a note into a rest, or bring a rest back to life
	rest: { |self, v, s|
		var i = rrand(0, v.figure.size - 1), st = v.figure[i].copy;
		var sounding = v.figure.count { |x| self.silent(x[\deg]).not };
		case
		{ self.silent(st[\deg]) } {
			st[\deg] = st[\was] ?? { self.inventStep(v, s)[\deg] };
			v.figure = v.figure.copy.put(i, st);
			"unrest %".format(i)
		}
		{ sounding > 1 } {
			st[\was] = st[\deg]; st[\deg] = \r;
			v.figure = v.figure.copy.put(i, st);
			"rest %".format(i)
		}
		{ nil }
	}
);

// ---------------------------------------------------------------------
// SNAPSHOTS: save and recall every voice's current figure by name
// ---------------------------------------------------------------------
~gas.snapshot = { |self, name = \snap|
	var snap = ();
	self.voices.keysValuesDo { |k, v| snap[k] = v.figure.collect(_.copy) };
	self.snapshots[name] = snap;
	self.log("snapshot '%' saved".format(name), \event);
	name
};

~gas.recall = { |self, name = \snap|
	var snap = self.snapshots[name];
	if(snap.isNil) { self.log("no snapshot '%'".format(name), \warn) } {
		snap.keysValuesDo { |k, fig| self.voices[k] !? { |v| v.figure = fig.collect(_.copy) } };
		self.log("snapshot '%' recalled (takes effect at each voice's next cycle)".format(name), \event);
	};
	name
};

"[gas] engine loaded".postln;
)
