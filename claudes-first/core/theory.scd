// =====================================================================
// core/theory.scd: pitch. Scales, scale degrees -> MIDI, ranges, names
// =====================================================================
//
// THE BIG SIMPLIFICATION vs. the archive
// The archive stored patterns as MIDI note numbers, then spent hundreds of
// lines snapping notes back into the scale after every transformation
// (and choosing random notes when it couldn't). Here figures are stored
// as SCALE DEGREES (0 = root, 1 = second, 2 = third, -1 = the note below
// the root ...). Conversion to MIDI happens only when a cycle is about to
// play, using whatever root/scale/chord is current at that moment.
//
// That gets us, for free:
//   * every note is always in the current mode, so no snapping is needed
//   * a \scale change re-colours every figure at its next downbeat
//     (dorian <-> aeolian sounds like a real modal shift)
//   * transposition is diatonic (move by scale steps), like Glass
//   * a \chord command shifts the whole texture to another scale degree,
//     which is how the Glass-style chord progressions are written
//
// SuperCollider already knows the scales: Scale.at(\dorian).degrees gives
// [0, 2, 3, 5, 7, 9, 10], and  degree.degreeToKey(degrees, 12)  maps any
// (even negative, or Array-for-chords) degree to semitones above the root.
// =====================================================================

(
// The current harmonic state. Lives on ~gas.harmony and is reset from
// the composition's `constraints` on every start.
~gas.resetHarmony = { |self|
	var c = self.comp.constraints;
	self.harmony = (
		root: self.toMidi(c.root),
		scaleName: c.scale,
		degrees: self.resolveScale(c.scale),
		chord: 0,                      // diatonic offset applied to every voice
		range: c.range
	);
	self.harmony
};

// Accept a Scale name, a Scale object, or an Array of semitones.
~gas.resolveScale = { |self, scale|
	case
	{ scale.isKindOf(Scale) } { scale.degrees }
	{ scale.isKindOf(Array) } { scale }
	{ Scale.at(scale.asSymbol).notNil } {
		var sc = Scale.at(scale.asSymbol);
		if(sc.pitchesPerOctave != 12) {
			self.log("scale % is not 12-tone; treating its degrees as semitones".format(scale), \warn)
		};
		sc.degrees
	}
	{
		self.log("unknown scale %, using major (see Scale.directory)".format(scale), \warn);
		Scale.major.degrees
	}
};

// Note name or number -> MIDI number. "A3" \C4 "F#2" "Bb-1" 57 all work.
// Convention: C4 = 60 (middle C), matching the archive.
~gas.toMidi = { |self, x|
	if(x.isNumber) { x } {
		var str = x.asString, base, acc = 0, i = 1, rest;
		base = (C: 0, D: 2, E: 4, F: 5, G: 7, A: 9, B: 11)[str[0].toUpper.asSymbol];
		if(base.isNil) {
			self.log("can't read note name %, using 60".format(x), \warn);
			60
		} {
			// walk over accidentals: '#' sharp, 'b' flat (multiple allowed)
			while { (i < str.size) and: { "#b".includes(str[i]) } } {
				acc = acc + if(str[i] == $#) { 1 } { -1 };
				i = i + 1;
			};
			// whatever is left is the octave (default 4). Note "".asInteger
			// is 0, not nil, so test for emptiness explicitly.
			rest = str.copyToEnd(i);
			((if(rest.isEmpty) { 4 } { rest.asInteger }) + 1) * 12 + base + acc
		}
	}
};

// MIDI -> name, for logs. Uses the common spellings.
~gas.noteName = { |self, midi|
	var names = #["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"];
	if(midi.isKindOf(Array)) {
		"[" ++ midi.collect { |m| self.noteName(m) }.join(" ") ++ "]"
	} {
		var m = midi.round.asInteger;
		names[m % 12] ++ ((m div: 12) - 1)
	}
};

// Rests are written as \r (any Symbol, or nil, counts).
// (Named `silent` because `isRest` is a real Event method; see state.scd.)
~gas.silent = { |self, deg| deg.isNil or: { deg.isKindOf(Symbol) } };

// Keep a MIDI note inside [lo, hi] by moving whole OCTAVES, so the pitch
// class (the note's "name") survives. Only if the window is narrower than
// an octave do we fall back to clipping. Works on chords (Arrays).
~gas.fold = { |self, midi, range|
	if(midi.isKindOf(Array)) { midi.collect { |m| self.fold(m, range) } } {
		var lo = range[0], hi = range[1], m = midi;
		if((hi - lo) < 12) { m.clip(lo, hi) } {
			while { m < lo } { m = m + 12 };
			while { m > hi } { m = m - 12 };
			m
		}
	}
};

// Scale degree (or chord of degrees) for a given voice -> MIDI, or Rest().
// This is the ONLY place figures turn into pitches.
~gas.degreeToMidi = { |self, voice, deg|
	if(self.silent(deg)) { Rest() } {
		var h = self.harmony;
		var semis = (deg + h.chord).degreeToKey(h.degrees, 12);
		self.fold(h.root + (voice.octave * 12) + semis, voice.range ? h.range)
	}
};

// The human-readable spelling of one step, e.g. "E4", "[A3 C4 E4]", "-"
~gas.stepName = { |self, voice, step|
	var m = self.degreeToMidi(voice, step[\deg]);
	if(m.isRest) { "-" } { self.noteName(m) }
};

// The whole current figure, e.g. "A3 C4 E4 C4"
~gas.figString = { |self, voice|
	voice.figure.collect { |st| self.stepName(voice, st) }.join(" ")
};

"[gas] theory loaded".postln;
)
