// =====================================================================
// core/timeline.scd: running the composition's timeline, and queuing
// =====================================================================
//
// A timeline is a list of  [beat, \command, args...]  entries, e.g.
//
//     [0,   \section, \A],
//     [0,   \in, \organ],
//     [64,  \scale, \dorian],
//     [128, \loop, \A, 2],      // go back to section A two more times
//     [192, \end, 16]
//
// Every entry is just a COMMAND with a time. The same commands can be
// typed live (~gas.cmd(\scale, \dorian)), queued (~gas.queue(8, \scale,
// \dorian)), sent over OSC, or fired by a reaction. One vocabulary
// everywhere. (The archive had separate code paths for each, which is
// where several of its bugs lived.)
//
// HOW THE RUNNER WORKS
// It walks the sorted entries with an index `i` and a timeline position
// `pos` (in beats). For each entry it waits (beat - pos), runs it, and moves
// on. \loop and \goto are handled by the runner itself because they move
// `i` and `pos` backwards. Each \loop keeps its own counter, which resets
// once the loop is done. That makes NESTED loops work: an inner loop plays
// its full count again on every pass of an outer loop.
//
// The runner owns only the timeline position. Absolute time is
// ~gas.beatClock.beats, which keeps counting through loops, so voices are
// never restarted or re-synchronised by a loop: they keep evolving.
// (The archive re-queued every event on a jump, which started the
// piano a second time on every loop.)
// =====================================================================

(
// Index and beat of each section marker (first occurrence wins)
~gas.sectionTable = { |self|
	var table = ();
	self.comp.timeline.do { |e, i|
		if((e[\cmd] == \section) and: { table[e[\args][0]].isNil }) {
			table[e[\args][0]] = (i: i, beat: e[\beat])
		}
	};
	table
};

// Start the timeline runner at entry `fromIndex`, timeline position `fromPos`.
~gas.runTimeline = { |self, fromIndex = 0, fromPos = 0, quant = 0|
	var events = self.comp.timeline, sections = self.sectionTable, counts = ();
	self.tlTask !? { self.tlTask.stop };
	self.tlPos = fromPos;
	self.tlTask = Routine {
		var i = fromIndex, pos = fromPos, e, target, times, n;
		while { i < events.size } {
			e = events[i];
			(e[\beat] - pos).max(0).wait;       // 0.wait is fine: same-beat events run back to back
			pos = e[\beat];
			self.tlPos = pos;
			case
			// [beat, \loop, \section, times]: jump back `times` more times (inf = forever)
			{ e[\cmd] == \loop } {
				target = sections[e[\args][0]];
				times = e[\args][1] ? 1;
				n = counts[i] ? 0;
				if(n < times) {
					counts[i] = n + 1;
					self.log("loop -> % (%/%)".format(e[\args][0], n + 1, times), \event);
					self.emit('/gas/loop', e[\args][0], n + 1);
					i = target[\i]; pos = target[\beat];
				} {
					counts[i] = 0;     // reset, so an enclosing loop can replay this one fully
					i = i + 1;
				}
			}
			// [beat, \goto, \section]: unconditional jump
			{ e[\cmd] == \goto } {
				target = sections[e[\args][0]];
				self.log("goto %".format(e[\args][0]), \event);
				i = target[\i]; pos = target[\beat];
			}
			// anything else is an ordinary command
			{
				self.cmdArray([e[\cmd]] ++ e[\args]);
				i = i + 1;
			};
		};
		self.log("timeline finished (voices keep evolving until \\end)", \event);
		self.tlTask = nil;
	}.play(self.beatClock, quant: quant);
	self.tlTask
};

// Live jump to a section, on the next bar line.
~gas.gotoSection = { |self, name|
	var target = self.sectionTable[name];
	if(target.isNil) { self.log("no section %".format(name), \warn) } {
		self.runTimeline(target[\i], target[\beat], self.bpb);
		self.log("jumping to % at the next bar".format(name), \event);
	};
	name
};

// ---------------------------------------------------------------------
// QUEUE: schedule a command for later, relative to now.
//     ~gas.queue(8, \scale, \lydian)       // in 8 beats
//     ~gas.queue(\bar, \in, \flute)        // on the next bar line
//     ~gas.queue(\bars4, \out, \organ)     // in 4 bars (on a bar line)
// ---------------------------------------------------------------------
~gas.queue = { |self, when ... cmdAndArgs|
	var delta;
	if(self.running.not) { self.log("not running; can't queue", \warn) } {
		delta = case
		{ when.isNumber } { when }
		{ when == \bar }  { self.beatClock.timeToNextBeat(self.bpb) }
		{ when.asString.beginsWith("bars") } {
			self.beatClock.timeToNextBeat(self.bpb) + ((when.asString.drop(4).asInteger - 1).max(0) * self.bpb)
		}
		{ self.log("queue: don't understand %".format(when), \warn); nil };
		if(delta.notNil) {
			self.beatClock.sched(delta, { self.cmdArray(cmdAndArgs); nil });  // answer nil = don't repeat
			self.log("queued % in % beats".format(cmdAndArgs, delta.round(0.01)), \event);
		};
	};
	nil
};

"[gas] timeline loaded".postln;
)
