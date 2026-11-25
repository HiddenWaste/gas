// =====================================================================
// synthdefs.scd: the sound palette for the Glassian Autonomous System
// =====================================================================
//
// This file replaces the old sample manager. Per project-idea.md, it is a
// handful of small, self-contained SynthDefs that are good enough to test
// the system, and nothing more. Swapping in samples later only means adding
// a SynthDef that plays a buffer: the engine doesn't care what makes the sound.
//
// ---------------------------------------------------------------------
// THE CONTRACT every instrument SynthDef follows
// ---------------------------------------------------------------------
//   out      audio bus for the dry signal        (the engine's main bus)
//   send     audio bus for the reverb send       (the engine's reverb bus)
//   sendAmt  how much of the signal goes to `send` (0..1)
//   freq     Hz. The pattern system works it out from \midinote for us
//   amp      linear amplitude
//   pan      -1..1
//   gate     ONLY on sustained sounds. The \note event type looks the
//            SynthDef up in SynthDescLib: if it has a `gate` control, the
//            event sends gate=0 after `sustain` beats. If it has no gate (our
//            percussive defs), no release is sent, so they must free
//            themselves (doneAction: Done.freeSelf).
//
// Any new SynthDef that follows this contract can be named in a
// composition's `sound:` field and will just work.
//
// ---------------------------------------------------------------------
// SuperCollider reminders used throughout
// ---------------------------------------------------------------------
// * `|a=1, b=2|` declares a SynthDef's controls. Defaults must be literals.
// * Every `var` must be declared at the top of a function, before any
//   statement. That's why each def below starts with one `var` block.
// * Multichannel expansion: `SinOsc.ar(freq * [1, 2, 3])` builds THREE
//   oscillators and returns an Array. `.sum` mixes them back to one channel.
// * We keep the SynthDef objects in ~gasSynthDefs (as well as `.add`ing
//   them) so tests/render-synthdefs.scd can render them offline (NRT).
// =====================================================================

(
~gasSynthDefs = [

	// -----------------------------------------------------------------
	// \gasOrgan: drawbar-ish organ. The Philip Glass Ensemble sound is
	// electric organs, so this is the default voice.
	// Sustained (has gate).
	// -----------------------------------------------------------------
	SynthDef(\gasOrgan, { |out=0, send=0, sendAmt=0.2, freq=440, amp=0.1, pan=0,
		gate=1, attack=0.006, release=0.06|
		var env, vib, partials, levels, sig;
		env = EnvGen.kr(Env.asr(attack, 1, release), gate, doneAction: Done.freeSelf);
		vib = SinOsc.kr(5.6, 0, 0.0012, 1);           // gentle vibrato (rate multiplier ~1)
		partials = [1, 2, 3, 4, 6];                    // "drawbar" harmonics
		levels   = [1, 0.55, 0.3, 0.18, 0.08];
		sig = (SinOsc.ar(freq * vib * partials) * levels).sum;
		sig = sig + (Pulse.ar(freq * vib, 0.3) * 0.06); // a little reedy combo-organ buzz
		sig = LPF.ar(sig, (freq * 10).min(14000));
		sig = Pan2.ar(sig * env * amp * 0.35, pan);
		Out.ar(out, sig);
		Out.ar(send, sig * sendAmt);
	}),

	// -----------------------------------------------------------------
	// \gasPiano: FM electric-piano-ish pluck. Percussive (no gate),
	// frees itself when the amplitude envelope ends.
	// -----------------------------------------------------------------
	SynthDef(\gasPiano, { |out=0, send=0, sendAmt=0.2, freq=440, amp=0.1, pan=0, decay=2.2|
		var env, modEnv, mod, sig;
		env    = EnvGen.ar(Env.perc(0.002, decay, 1, -5), doneAction: Done.freeSelf);
		modEnv = EnvGen.ar(Env.perc(0.001, 0.35, 1, -4));     // bright attack that fades fast
		mod    = SinOsc.ar(freq * 2) * freq * 1.4 * modEnv;     // FM: modulator in Hz of deviation
		sig    = SinOsc.ar(freq + mod) + (SinOsc.ar(freq * 3.001) * 0.08 * modEnv);
		sig    = Pan2.ar(sig * env * amp * 0.5, pan);
		Out.ar(out, sig);
		Out.ar(send, sig * sendAmt);
	}),

	// -----------------------------------------------------------------
	// \gasMallet: marimba-like modal synthesis. Three sine "modes" at
	// the inharmonic ratios of a struck bar, each with its own decay,
	// plus a tiny noise click for the mallet. Percussive.
	// -----------------------------------------------------------------
	SynthDef(\gasMallet, { |out=0, send=0, sendAmt=0.2, freq=440, amp=0.1, pan=0, decay=1.0|
		var ratios, decays, levels, modes, click, sig;
		ratios = [1, 3.93, 9.2];
		decays = [1, 0.22, 0.06] * decay;
		levels = [1, 0.3, 0.1];
		// .collect builds one EnvGen per mode, so each decays at its own speed
		modes = ratios.collect { |r, i|
			SinOsc.ar(freq * r) * levels[i] * EnvGen.ar(Env.perc(0.001, decays[i], 1, -6))
		}.sum;
		click = BPF.ar(WhiteNoise.ar, (freq * 4).min(16000), 0.6) * EnvGen.ar(Env.perc(0.0005, 0.012)) * 0.25;
		sig = modes + click;
		// The longest mode sets the lifetime: free the synth once it's done.
		EnvGen.kr(Env([0, 0], [decay + 0.05]), doneAction: Done.freeSelf);
		sig = Pan2.ar(sig * amp * 0.6, pan);
		Out.ar(out, sig);
		Out.ar(send, sig * sendAmt);
	}),

	// -----------------------------------------------------------------
	// \gasFlute: breathy sine/triangle with vibrato that fades in.
	// Sustained.
	// -----------------------------------------------------------------
	SynthDef(\gasFlute, { |out=0, send=0, sendAmt=0.3, freq=440, amp=0.1, pan=0,
		gate=1, attack=0.05, release=0.12, breath=0.12|
		var env, vibDepth, vib, tone, noise, sig;
		env      = EnvGen.kr(Env.asr(attack, 1, release), gate, doneAction: Done.freeSelf);
		vibDepth = EnvGen.kr(Env([0, 0, 0.004], [0.25, 0.4]));  // vibrato arrives late, like a player
		vib      = SinOsc.kr(4.8, 0, vibDepth, 1);
		tone     = SinOsc.ar(freq * vib) + (LFTri.ar(freq * vib) * 0.25) + (SinOsc.ar(freq * 2 * vib) * 0.1);
		noise    = BPF.ar(PinkNoise.ar, freq * 2, 1.2) * breath;
		sig      = Pan2.ar((tone + noise) * env * amp * 0.45, pan);
		Out.ar(out, sig);
		Out.ar(send, sig * sendAmt);
	}),

	// -----------------------------------------------------------------
	// \gasChoir: an "ah" from three detuned saws through three
	// formant band-passes (roughly the vowel /a/). Stands in for the
	// chorus in roadmap.md. Sustained, slow attack.
	// -----------------------------------------------------------------
	SynthDef(\gasChoir, { |out=0, send=0, sendAmt=0.4, freq=440, amp=0.1, pan=0,
		gate=1, attack=0.18, release=0.5|
		var env, drift, src, formants, bws, levels, sig;
		env      = EnvGen.kr(Env.asr(attack, 1, release), gate, doneAction: Done.freeSelf);
		drift    = LFNoise1.kr([2.1, 2.7, 3.3]).range(0.996, 1.004);   // each "singer" wavers
		src      = Saw.ar(freq * [0.997, 1, 1.0035] * drift).sum / 3;
		formants = [800, 1150, 2900];
		bws      = [80, 90, 120];
		levels   = [1, 0.5, 0.2];
		// BPF's third arg is rq = bandwidth / centre frequency
		sig = (BPF.ar(src, formants, bws / formants) * levels).sum * 4;
		sig = sig + (LPF.ar(src, freq * 2) * 0.15);                      // body under the formants
		sig = Pan2.ar(sig * env * amp * 1.0, pan);                       // formant filtering loses level: gain back
		Out.ar(out, sig);
		Out.ar(send, sig * sendAmt);
	}),

	// -----------------------------------------------------------------
	// \gasBass: round sine bass with a touch of filtered saw.
	// Sustained.
	// -----------------------------------------------------------------
	SynthDef(\gasBass, { |out=0, send=0, sendAmt=0.05, freq=110, amp=0.1, pan=0,
		gate=1, attack=0.008, release=0.1|
		var env, sig;
		env = EnvGen.kr(Env.asr(attack, 1, release), gate, doneAction: Done.freeSelf);
		sig = SinOsc.ar(freq) + (LFTri.ar(freq * 2) * 0.12) + (LPF.ar(Saw.ar(freq), freq * 3) * 0.15);
		sig = Pan2.ar(sig * env * amp * 0.6, pan);
		Out.ar(out, sig);
		Out.ar(send, sig * sendAmt);
	}),

	// -----------------------------------------------------------------
	// \gasPad: slow detuned triangle pad for ambient pieces.
	// Sustained.
	// -----------------------------------------------------------------
	SynthDef(\gasPad, { |out=0, send=0, sendAmt=0.5, freq=440, amp=0.1, pan=0,
		gate=1, attack=0.8, release=1.5|
		var env, sig;
		env = EnvGen.kr(Env.asr(attack, 1, release, [2, -3]), gate, doneAction: Done.freeSelf);
		sig = LFTri.ar(freq * [0.995, 1, 1.006]).sum / 3;
		sig = LPF.ar(sig, freq * LFNoise1.kr(0.3).range(2, 5));      // slow timbral breathing
		sig = Pan2.ar(sig * env * amp * 0.5, pan);
		Out.ar(out, sig);
		Out.ar(send, sig * sendAmt);
	}),

	// =================================================================
	// Infrastructure SynthDefs (not instruments). The engine creates
	// these once and keeps them running in their own groups.
	// =================================================================

	// Reverb: reads the send bus, 100% wet, and writes into the main bus.
	SynthDef(\gasReverb, { |in=0, out=0, room=0.7, damp=0.5, level=1|
		var sig = In.ar(in, 2);
		sig = FreeVerb2.ar(sig[0], sig[1], 1, room, damp);
		Out.ar(out, sig * level);
	}),

	// Master: the single volume control for the whole system, plus safety.
	// VarLag gives linear fades: `set(\vol, 0, \lagTime, 8)` fades over 8 s.
	SynthDef(\gasMaster, { |in=0, out=0, vol=0.7, lagTime=0.05|
		var sig = In.ar(in, 2);
		sig = sig * VarLag.kr(vol, lagTime);
		sig = LeakDC.ar(sig);
		sig = Limiter.ar(sig, 0.95, 0.01);   // never let the system blow up the speakers
		Out.ar(out, sig);
	}),

	// Analyzer: listens to the main bus (pre master-volume, so fades don't
	// fool it) and reports features back to the language `rate` times per
	// second. This also fixes the archive's version, which wrote an
	// audio-rate ZeroCrossing into a control bus.
	//   reply: ['/gas/analysis', nodeID, replyID, amp, centroid, flatness, onsets]
	SynthDef(\gasAnalyzer, { |in=0, rate=8|
		var sig, chain, amp, centroid, flatness, onsets, trig, count;
		sig      = In.ar(in, 2).sum;
		chain    = FFT(LocalBuf(1024), sig);
		amp      = Amplitude.kr(sig, 0.01, 0.25);
		centroid = SpecCentroid.kr(chain);      // "brightness" in Hz
		flatness = SpecFlatness.kr(chain);      // 0 = tonal, 1 = noisy
		onsets   = Onsets.kr(chain, 0.3);
		trig     = Impulse.kr(rate);
		count    = PulseCount.kr(onsets, Delay1.kr(trig));  // onsets since the last report
		SendReply.kr(trig, '/gas/analysis', [amp, centroid, flatness, count]);
	})
];

~gasSynthDefs.do(_.add);   // register with SynthDescLib (and send to the server if booted)
"[gas] % SynthDefs loaded".format(~gasSynthDefs.size).postln;
)
