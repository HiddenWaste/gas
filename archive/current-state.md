(
// data-analyst.scd
# = {{{ 
// Audio analysis and OSC communication for the Glass-inspired system
// Handles real-time audio analysis and external communication

/*
  Usage:
  1. Initialize using ~dataAnalyst.init()
  2. Start analysis using ~dataAnalyst.startAnalysis()
  3. Configure OSC using ~dataAnalyst.configureOSC()
  4. Send OSC messages using ~dataAnalyst.sendOSC()
*/

// Create namespace for the data analyst
~dataAnalyst = ();

// Initialize the data analyst
~dataAnalyst.init = { |analysisRate=10|
  // Make sure dependencies are available
  if(~stateManager.isNil) {
    "Error: State Manager must be initialized before Data Analyst".error;
    ^false;
  };

  // Initialize analysis parameters
  ~dataAnalyst.analysisRate = analysisRate;  // Times per second
  ~dataAnalyst.activeAnalysis = false;
  ~dataAnalyst.analysisRoutines = List.new;
  ~dataAnalyst.analysisData = ();

  // Initialize OSC
  ~dataAnalyst.oscEnabled = false;
  ~dataAnalyst.oscTargets = List.new;

  ~stateManager.log.("Data Analyst initialized with analysis rate: % Hz".format(analysisRate));

  // Return for chaining
  ~dataAnalyst;
};

// Create audio analysis buses and synths
~dataAnalyst.setupAnalysis = {
  // Create analysis buses
  ~dataAnalyst.analysisBusses = (
    amplitude: Bus.control(s, 1),
    centroid: Bus.control(s, 1),
    flatness: Bus.control(s, 1),
    zeroCrossings: Bus.control(s, 1)
  );

  // Create analysis synth
  ~dataAnalyst.analysisSynth = SynthDef(\audioAnalyzer, {
    arg in=0, ampBus, centroidBus, flatnessBus, zeroCrossingBus;
    var input = In.ar(in, 2).sum;
    var amp = Amplitude.kr(input);
    var centroid = SpecCentroid.kr(FFT(LocalBuf(2048), input));
    var flatness = SpecFlatness.kr(FFT(LocalBuf(2048), input));
    var zeroCrossing = ZeroCrossing.ar(input);

    Out.kr(ampBus, amp);
    Out.kr(centroidBus, centroid);
    Out.kr(flatnessBus, flatness);
    Out.kr(zeroCrossingBus, zeroCrossing);
  }).play(s, [
    \in, 0,  // Use main output
    \ampBus, ~dataAnalyst.analysisBusses.amplitude,
    \centroidBus, ~dataAnalyst.analysisBusses.centroid,
    \flatnessBus, ~dataAnalyst.analysisBusses.flatness,
    \zeroCrossingBus, ~dataAnalyst.analysisBusses.zeroCrossings
  ]);

  ~stateManager.log.("Audio analysis setup complete");

  ~dataAnalyst.analysisSynth;
};

// Start continuous analysis
~dataAnalyst.startAnalysis = {
  var analysisRoutine;

  // Setup analysis infrastructure if needed
  if(~dataAnalyst.analysisSynth.isNil) {
    ~dataAnalyst.setupAnalysis.();
  };

  // Start the analysis routine
  analysisRoutine = Routine({
    var updateInterval = 1 / ~dataAnalyst.analysisRate;

    ~dataAnalyst.activeAnalysis = true;

    inf.do({
      // Get values from buses
      ~dataAnalyst.analysisBusses.amplitude.get({ |val|
        ~dataAnalyst.analysisData.amplitude = val;
      });

      ~dataAnalyst.analysisBusses.centroid.get({ |val|
        ~dataAnalyst.analysisData.centroid = val;
      });

      ~dataAnalyst.analysisBusses.flatness.get({ |val|
        ~dataAnalyst.analysisData.flatness = val;
      });

      ~dataAnalyst.analysisBusses.zeroCrossings.get({ |val|
        ~dataAnalyst.analysisData.zeroCrossings = val;
      });

      // Calculate additional metrics
      ~dataAnalyst.updateDerivedMetrics.();

      // Send OSC if enabled
      if(~dataAnalyst.oscEnabled) {
        ~dataAnalyst.sendAnalysisOSC.();
      };

      updateInterval.wait;
    });
  });

  // Start the routine
  analysisRoutine.play;

  // Add to analysis routines for cleanup
  ~dataAnalyst.analysisRoutines.add(analysisRoutine);

  ~stateManager.log.("Started continuous audio analysis at % Hz".format(~dataAnalyst.analysisRate));

  analysisRoutine;
};

// Stop analysis
~dataAnalyst.stopAnalysis = {
  // Stop analysis routines
  ~dataAnalyst.analysisRoutines.do { |routine|
    if(routine.isPlaying) {
      routine.stop;
    };
  };

  ~dataAnalyst.analysisRoutines = List.new;
  ~dataAnalyst.activeAnalysis = false;

  // Free synth if exists
  if(~dataAnalyst.analysisSynth.notNil && ~dataAnalyst.analysisSynth.isPlaying) {
    ~dataAnalyst.analysisSynth.free;
    ~dataAnalyst.analysisSynth = nil;
  };

  // Free buses
  if(~dataAnalyst.analysisBusses.notNil) {
    ~dataAnalyst.analysisBusses.do { |bus|
      bus.free;
    };
    ~dataAnalyst.analysisBusses = nil;
  };

  ~stateManager.log.("Stopped audio analysis");

  true;
};

// Calculate derived metrics from raw analysis data
~dataAnalyst.updateDerivedMetrics = {
  var ampSmoothed = ~dataAnalyst.analysisData.amplitude ? 0;
  var centroidNorm = (~dataAnalyst.analysisData.centroid ? 0) / 10000;

  // Calculate dynamic level
  ~dataAnalyst.analysisData.dynamicLevel = ampSmoothed.linlin(0, 0.5, 0, 100);

  // Calculate brightness
  ~dataAnalyst.analysisData.brightness = centroidNorm.linlin(0, 1, 0, 100);

  // Calculate activity level
  ~dataAnalyst.analysisData.activity = (
    (~dataAnalyst.analysisData.dynamicLevel * 0.5) +
    (~dataAnalyst.analysisData.brightness * 0.3) +
    ((~dataAnalyst.analysisData.zeroCrossings ? 0) * 0.2)
  ).clip(0, 100);

  // Add to state for internal use
  ~stateManager.state.runtime.analysisData = ~dataAnalyst.analysisData;
};

// Configure OSC communication
~dataAnalyst.configureOSC = { |enabled=true, targets|
  ~dataAnalyst.oscEnabled = enabled;

  if(enabled) {
    // Add targets if provided
    if(targets.notNil) {
      targets.do { |target|
        ~dataAnalyst.addOSCTarget.(target.address, target.port);
      };
    };

    ~stateManager.log.("OSC communication enabled with % targets".format(~dataAnalyst.oscTargets.size));
  } {
    ~stateManager.log.("OSC communication disabled");
  };

  ~dataAnalyst.oscEnabled;
};

// Add an OSC target
~dataAnalyst.addOSCTarget = { |address, port|
  var newTarget = NetAddr(address, port);
  ~dataAnalyst.oscTargets.add(newTarget);

  ~stateManager.log.("Added OSC target: %:%".format(address, port));

  ~dataAnalyst.oscTargets.size;
};

// Send analysis data via OSC
~dataAnalyst.sendAnalysisOSC = {
  if(~dataAnalyst.oscEnabled.not || ~dataAnalyst.oscTargets.size == 0) {
    ^false;
  };

  ~dataAnalyst.oscTargets.do { |target|
    // Send main analysis data
    target.sendMsg(
      '/glassSystem/analysis',
      ~dataAnalyst.analysisData.amplitude ? 0,
      ~dataAnalyst.analysisData.centroid ? 0,
      ~dataAnalyst.analysisData.flatness ? 0,
      ~dataAnalyst.analysisData.dynamicLevel ? 0,
      ~dataAnalyst.analysisData.brightness ? 0,
      ~dataAnalyst.analysisData.activity ? 0
    );

    // Send musical state data
    target.sendMsg(
      '/glassSystem/musical',
      ~stateManager.getParam.("musical.tension") ? 0,
      ~stateManager.getParam.("musical.root") ? 60,
      ~stateManager.getParam.("musical.scale") ? "naturalMinor",
      ~stateManager.getParam.("runtime.currentBeat") ? 0
    );
  };

  true;
};

// Send a custom OSC message
~dataAnalyst.sendOSCMessage = { |address, args|
  if(~dataAnalyst.oscEnabled.not || ~dataAnalyst.oscTargets.size == 0) {
    ^false;
  };

  ~dataAnalyst.oscTargets.do { |target|
    target.sendMsg(address, *args);
  };

  true;
};

// Setup OSC receiver for incoming messages
~dataAnalyst.setupOSCReceiver = { |port=57120|
  var receiver;

  // Create OSC responders for incoming messages
  OSCdef(\glassSystemCmd, { |msg, time, addr, recvPort|
    var command = msg[1].asSymbol;

    ~stateManager.log.("Received OSC command: % from %".format(command, addr));

    // Process the command
    case
      // Start/stop commands
      { command == \start } {
        ~stateManager.start.();
      }
      { command == \stop } {
        ~stateManager.stop.();
      }

      // Process commands
      { command == \additive } {
        ~stateManager.updateParam.("process.currentProcess", \additive);
      }
      { command == \subtractive } {
        ~stateManager.updateParam.("process.currentProcess", \subtractive);
      }

      // Scale commands
      { command == \changeScale } {
        if(msg.size > 2) {
          ~musicalConstraints.changeScale.(msg[2].asSymbol);
        } {
          ~musicalConstraints.changeScale.();
        };
      }

      // Root commands
      { command == \changeRoot } {
        if(msg.size > 2) {
          ~musicalConstraints.changeRoot.(msg[2].asInteger);
        } {
          ~musicalConstraints.changeRoot.();
        };
      }

      // Instrument commands
      { command == \startInstrument } {
        if(msg.size > 2) {
          ~patternEngine.startPattern.(msg[2].asSymbol);
        };
      }
      { command == \stopInstrument } {
        if(msg.size > 2) {
          ~patternEngine.stopPattern.(msg[2].asSymbol);
        };
      }

      // Tempo commands
      { command == \setTempo } {
        if(msg.size > 2) {
          ~stateManager.updateParam.("timing.tempo", msg[2].asInteger);
        };
      }

      // Pattern transform commands
      { command == \transformPattern } {
        if(msg.size > 3) {
          var instrument = msg[2].asSymbol;
          var transform = msg[3].asSymbol;
          var event = (
            type: \patternTransform,
            instrument: instrument,
            transform: transform
          );

          if(msg.size > 4 && transform == \transpose) {
            event.interval = msg[4].asInteger;
          };

          ~timelineInterpreter.executeEvent.(event);
        };
      };

  }, '/glassSystem/command', recvPort: port);

  ~stateManager.log.("OSC receiver setup on port %".format(port));

  true;
};

// Create a timeline event when analysis detects significant changes
~dataAnalyst.setupAnalysisResponseEvents = { |threshold=15, cooldown=32|
  var lastEventBeat = 0;
  var analysisRoutine;

  // Start analysis if not already running
  if(~dataAnalyst.activeAnalysis.not) {
    ~dataAnalyst.startAnalysis.();
  };

  // Create response routine
  analysisRoutine = Routine({
    inf.do({
      var currentBeat = ~stateManager.getParam.("runtime.currentBeat") ? 0;
      var activity = ~dataAnalyst.analysisData.activity ? 0;
      var tension = ~stateManager.getParam.("musical.tension") ? 0;
      var eventType, event;

      // Check for significant activity and tension changes
      if(activity > threshold && tension > 50 && (currentBeat - lastEventBeat) >= cooldown) {
        eventType = [\patternTransform, \scaleChange, \rootChange].wchoose([0.5, 0.3, 0.2]);

        case
          { eventType == \patternTransform } {
            var instruments = ~stateManager.getParam.("patterns.instruments");
            var instrument = instruments.choose;
            var transform = [\invert, \retrograde, \transpose].choose;

            event = (
              type: \patternTransform,
              instrument: instrument,
              transform: transform
            );

            if(transform == \transpose) {
              event.interval = [-7, -5, -3, 3, 5, 7].choose;
            };
          }
          { eventType == \scaleChange } {
            event = (
              type: \scaleChange,
              scale: ~stateManager.getParam.("scales").keys.asArray.choose
            );
          }
          { eventType == \rootChange } {
            event = (
              type: \rootChange,
              interval: [-5, -3, 3, 4, 5, 7].choose
            );
          };

        // Execute the event
        ~timelineInterpreter.executeEvent.(event);

        // Update last event beat
        lastEventBeat = currentBeat;

        ~stateManager.log.("Analysis triggered event: % (activity: %, tension: %)".format(
          eventType,
          activity.round(0.1),
          tension.round(0.1)
        ));
      };

      1.wait;  // Check once per beat
    });
  });

  // Start the routine
  analysisRoutine.play(~stateManager.clock);

  // Add to routines for cleanup
  ~dataAnalyst.analysisRoutines.add(analysisRoutine);

  ~stateManager.log.("Analysis response events setup with threshold: %, cooldown: % beats".format(
    threshold, cooldown
  ));

  analysisRoutine;
};

"Data Analyst module loaded successfully.".postln;
~dataAnalyst;
)

# }}}
(
// musical-constraints.scd
# = {{{
// Module for handling scales, modes, and tension/resolution
// Provides functions for working with musical theory in the generative system

/*
  Usage:
  1. Initialize using ~musicalConstraints.init()
  2. Generate notes using ~musicalConstraints.getScaleNotes() or ~musicalConstraints.getNextNotes()
  3. Check notes using ~musicalConstraints.isValidNote()
  4. Update musical state using ~musicalConstraints.updateState()
*/

// Create namespace for musical constraints
~musicalConstraints = ();

// Initialize the module
~musicalConstraints.init = {
  // Make sure state manager is available
  if(~stateManager.isNil) {
    "Error: State Manager must be initialized before Musical Constraints".error;
    ^false;
  };

  // Initialize the last note for note sequence generation
  ~musicalConstraints.lastNote = nil;

  ~stateManager.log.("Musical Constraints module initialized");

  // Return for chaining
  ~musicalConstraints;
};

// Get the current root note
~musicalConstraints.getRoot = {
  ~stateManager.getParam.("musical.root");
};

// Get the current scale
~musicalConstraints.getScale = {
  var scaleName = ~stateManager.getParam.("musical.scale");
  ~stateManager.getParam.("scales." ++ scaleName);
};

// Get the current scale name
~musicalConstraints.getScaleName = {
  ~stateManager.getParam.("musical.scale");
};

// Generate notes in current scale
~musicalConstraints.getScaleNotes = { |numOctaves = 2, startOctave = 0|
  var root = ~musicalConstraints.getRoot.();
  var scale = ~musicalConstraints.getScale.();
  var notes = [];

  if(root.isNil || scale.isNil) {
    // Handle missing parameters
    ~stateManager.log.("Warning: Missing root or scale parameters", \warn);
    ^[60, 62, 64, 65, 67, 69, 71, 72];  // Fall back to C major
  };

  numOctaves.do({ |octave|
    scale.do({ |offset|
      notes = notes.add(root + offset + ((startOctave + octave) * 12));
    });
  });

  notes;
};

// Check if a note fits current scale
~musicalConstraints.isValidNote = { |note|
  var root = ~musicalConstraints.getRoot.();
  var scale = ~musicalConstraints.getScale.();
  var normalizedNote, inScale;

  if(root.isNil || scale.isNil) {
    // Handle missing parameters
    ~stateManager.log.("Warning: Missing root or scale parameters", \warn);
    ^true;  // Default to allowing any note
  };

  normalizedNote = (note - root) % 12;
  inScale = scale.includes(normalizedNote);

  inScale;
};

// Get weighted note probabilities based on musical state
~musicalConstraints.getNoteWeights = { |availableNotes|
  var weights = Array.fill(availableNotes.size, 1);
  var tensionPhase = ~stateManager.getParam.("musical.tension") > 50;
  var lastNote = ~musicalConstraints.lastNote;

  // Adjust weights based on tension
  weights = weights.collect({ |w, i|
    var note = availableNotes[i];
    var weight = w;

    // Favor higher notes in high tension
    if(tensionPhase) {
      weight = weight * (1 + (note - ~musicalConstraints.getRoot.())/24);
    };

    // Favor stepwise motion
    if(lastNote.notNil) {
      var interval = (note - lastNote).abs;
      weight = weight * (1 / (1 + (interval/2)));
    };

    weight;
  });

  weights;
};

// Get next suggested notes based on current state
~musicalConstraints.getNextNotes = { |numNotes = 1|
  var availableNotes = ~musicalConstraints.getScaleNotes.();
  var weights = ~musicalConstraints.getNoteWeights.(availableNotes);
  var selected = Array.new(numNotes);

  // Handle case where no notes are available
  if(availableNotes.size == 0) {
    ~stateManager.log.("Warning: No scale notes available", \warn);
    ^[60, 64, 67];  // Fall back to C major triad
  };

  numNotes.do({
    var note = availableNotes.wchoose(weights.normalizeSum);
    selected = selected.add(note);
    ~musicalConstraints.lastNote = note;
  });

  selected;
};

// Update tension based on current pattern data
~musicalConstraints.updateTension = { |patterns|
  var harmonicDensity = 0;
  var rhythmicDensity = 0;
  var verticalSpread = 0;
  var tension = 0;
  var activeNotes, totalNotes = 0, activeDurs = 0;

  // Handle empty patterns or nil input
  if(patterns.isNil || patterns.size == 0) {
    ~stateManager.updateParam.("musical.tension", 0);
    ~stateManager.updateParam.("musical.harmonicDensity", 0);
    ~stateManager.updateParam.("musical.rhythmicDensity", 0);
    ~stateManager.updateParam.("musical.verticalSpread", 0);
    ^0;
  };

  // Extract all currently playing notes from patterns
  activeNotes = patterns.collect({ |pat|
    pat.collect({ |event| event.note });
  }).flatten;

  // Update harmonic density
  harmonicDensity = (activeNotes.size / 12 * 100).clip(0, 100);

  // Update vertical spread
  if(activeNotes.size > 0) {
    var spread = activeNotes.maxItem - activeNotes.minItem;
    verticalSpread = (spread / 36 * 100).clip(0, 100);
  };

  // Update rhythmic density
  patterns.do({ |pat|
    if(pat.notNil && pat.size > 0) {
      totalNotes = totalNotes + pat.size;
      activeDurs = activeDurs + pat.sum({ |event| event.dur ? 0.25 });
    };
  });

  if(activeDurs > 0) {
    rhythmicDensity = (totalNotes / activeDurs * 25).clip(0, 100);  // Adjust factor to normalize
  };

  // Calculate overall tension
  tension = (
    (harmonicDensity * 0.4) +
    (rhythmicDensity * 0.3) +
    (verticalSpread * 0.3)
  ).clip(0, 100);

  // Update state
  ~stateManager.updateParam.("musical.harmonicDensity", harmonicDensity);
  ~stateManager.updateParam.("musical.rhythmicDensity", rhythmicDensity);
  ~stateManager.updateParam.("musical.verticalSpread", verticalSpread);
  ~stateManager.updateParam.("musical.tension", tension);

  ~stateManager.log.("Updated musical tension: %".format(tension.round(0.1)));

  tension;
};

// Change root note but maintain scale
~musicalConstraints.changeRoot = { |interval=nil|
  var currentRoot = ~musicalConstraints.getRoot.();
  var newRoot;
  var minPitch = ~stateManager.getParam.("musical.minPitch") ? 48;
  var maxPitch = ~stateManager.getParam.("musical.maxPitch") ? 84;

  if(currentRoot.isNil) {
    currentRoot = 60;  // Default to middle C
  };


  // Use provided interval or choose a pleasing interval
  if(interval.isNil) {
    interval = [3, 4, 5, 7, -2, -3].choose;
  };

  newRoot = currentRoot + interval;

  // Keep within reasonable range
  newRoot = newRoot.clip(minPitch, maxPitch - 12);

  // Update state
  ~stateManager.updateParam.("musical.root", newRoot);

  ~stateManager.log.("Root changed to %".format(~stateManager.noteToName.(newRoot)));

  newRoot;
};

// Change scale/mode but maintain root
~musicalConstraints.changeScale = { |newScale=nil|
  var scaleNames = ~stateManager.getParam.("scales").keys.asArray;
  var currentScale = ~musicalConstraints.getScaleName.();

  if(currentScale.isNil) {
    currentScale = \major;  // Default to major scale
  };

  // Use provided scale or choose one different from current
  if(newScale.isNil) {
    // Remove current scale from choices if we have more than one scale
    if(scaleNames.size > 1) {
      scaleNames = scaleNames.reject({ |sc| sc == currentScale });
    };
    newScale = scaleNames.choose;
  };

  // Make sure the scale exists
  if(~stateManager.getParam.("scales." ++ newScale).isNil) {
    ~stateManager.log.("Warning: Scale % not found".format(newScale), \warn);
    ^currentScale;  // Keep current scale
  };

  // Update state
  ~stateManager.updateParam.("musical.scale", newScale);

  ~stateManager.log.("Scale changed to %".format(newScale));

  newScale;
};

// Invert a pattern (upside down)
~musicalConstraints.invertPattern = { |pattern|
  var center = ~musicalConstraints.getRoot.(); // Use root as center
  var result = pattern.collect({ |event|
    var invertedNote = center + (center - event.note);
    var minPitch = ~stateManager.getParam.("musical.minPitch") ? 48;
    var maxPitch = ~stateManager.getParam.("musical.maxPitch") ? 84;

    // Keep in reasonable range
    invertedNote = invertedNote.clip(minPitch, maxPitch);

    // Ensure the note is in the current scale
    if(~musicalConstraints.isValidNote.(invertedNote).not) {
      invertedNote = ~musicalConstraints.getNextNotes.(1)[0];
    };

    event.copy.put(\note, invertedNote);
  });

  result;
};

// Retrograde a pattern (backwards)
~musicalConstraints.retrogradePattern = { |pattern|
  pattern.reverse;
};

// Transpose a pattern
~musicalConstraints.transposePattern = { |pattern, interval|
  var result = pattern.collect({ |event|
    var newNote = event.note + interval;
    var minPitch = ~stateManager.getParam.("musical.minPitch") ? 48;
    var maxPitch = ~stateManager.getParam.("musical.maxPitch") ? 84;

    // Keep in reasonable range
    newNote = newNote.clip(minPitch, maxPitch);

    // Ensure the note is in the current scale
    if(~musicalConstraints.isValidNote.(newNote).not) {
      // Find nearest scale note
      var scale = ~musicalConstraints.getScale.();
      var root = ~musicalConstraints.getRoot.();
      var normalized = (newNote - root) % 12;
      var distances = scale.collect({ |sc| (sc - normalized).abs });
      var idx = distances.minIndex;

      if(idx.notNil && scale[idx].notNil) {
        newNote = newNote + (scale[idx] - normalized);
      } {
        // Fall back to a note from the scale
        newNote = ~musicalConstraints.getNextNotes.(1)[0];
      };
    };

    event.copy.put(\note, newNote);
  });

  result;
};

// Convert MIDI note to note name
~musicalConstraints.noteToName = { |note|
  var noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"];
  var octave = (note / 12).floor - 1;
  var noteName = noteNames[note % 12];
  noteName ++ octave.asString;
};

// Convert note name to MIDI note
~musicalConstraints.nameToNote = { |noteName|
  var noteMap, octave, note;

  // Handle different note name formats
  if(noteName.isString || noteName.isSymbol) {
    var nameStr = noteName.asString;
    var lastChar = nameStr.last;
    var nameWithoutOctave, octaveChar;

    // Check if the last character is a digit
    if(lastChar.isDecDigit) {
      octaveChar = lastChar;
      nameWithoutOctave = nameStr.drop(-1);
    } {
      // Default to octave 4 if not specified
      octaveChar = "4";
      nameWithoutOctave = nameStr;
    };

    // Set up note name mapping
    noteMap = Dictionary[
      'C' -> 0, 'C#' -> 1, 'Db' -> 1,
      'D' -> 2, 'D#' -> 3, 'Eb' -> 3,
      'E' -> 4, 'F' -> 5, 'F#' -> 6,
      'Gb' -> 6, 'G' -> 7, 'G#' -> 8,
      'Ab' -> 8, 'A' -> 9, 'A#' -> 10,
      'Bb' -> 10, 'B' -> 11
    ];

    // Calculate the MIDI note number
    note = noteMap[nameWithoutOctave.asSymbol];
    if(note.isNil) {
      ~stateManager.log.("Warning: Invalid note name: %".format(nameWithoutOctave), \warn);
      ^60;  // Default to middle C if invalid
    };

    octave = octaveChar.asString.asInteger;
    note = note + ((octave + 1) * 12);
  } {
    // Assume it's already a MIDI note number
    note = noteName.asInteger;
  };

  note;
};

"Musical Constraints module loaded successfully.".postln;
~musicalConstraints;
# }}}
)

(
// pattern-engine.scd
# = {{{
// Pattern generation and evolution for the Glass-inspired system
// Handles creating, transforming, and playing musical patterns

/*
  Usage:
  1. Initialize using ~patternEngine.init()
  2. Generate patterns using ~patternEngine.generatePattern()
  3. Evolve patterns using ~patternEngine.evolvePattern()
  4. Start pattern playback using ~patternEngine.startPattern()
*/

(
// Create namespace for the pattern engine
~patternEngine = ();

// Initialize the pattern engine
~patternEngine.init = {
  // Make sure dependencies are available
  if(~stateManager.isNil) {
    "Error: State Manager must be initialized before Pattern Engine".error;
    ^false;
  };

  if(~musicalConstraints.isNil) {
    "Error: Musical Constraints must be initialized before Pattern Engine".error;
    ^false;
  };

  // Initialize storage for active patterns
  ~patternEngine.activePatterns = Dictionary.new;
  ~patternEngine.patternData = Dictionary.new;
  ~patternEngine.phaseRoutine = nil;
  ~patternEngine.processCycleRoutine = nil;

  ~stateManager.log.("Pattern Engine initialized");

  // Return for chaining
  ~patternEngine;
};

// Format pattern for display
~patternEngine.formatPattern = { |pattern, label="Pattern"|
  var result = "";
  result = result ++ "=== % ===\n".format(label);

  pattern.do { |evt, i|
    result = result ++ "  [%] % (vel: %, dur: %)\n".format(
      i,
      ~musicalConstraints.noteToName.(evt.note),
      evt.vel.round(0.01),
      evt.dur
    );
  };

  result = result ++ "==============";
  ~stateManager.log.(result);

  result;
};

// Generate a new pattern for an instrument
~patternEngine.generatePattern = { |instrument, length=nil, style=\basic|
  var pattern = List.new;
  var instrumentKey = instrument.asSymbol;
  var constraints = ~stateManager.getParam.("instrumentConstraints.patternLimits." ++ instrumentKey);
  var minLength, maxLength;

  // Use instrument-specific constraints or defaults
  if(constraints.notNil) {
    minLength = constraints.min;
    maxLength = constraints.max;
  } {
    minLength = ~stateManager.getParam.("process.minPatternLength");
    maxLength = ~stateManager.getParam.("process.maxPatternLength");
  };

  // Use specified length or pick between min/max
  if(length.isNil) {
    length = rrand(minLength, maxLength);
  } {
    // Ensure length is within constraints
    length = length.clip(minLength, maxLength);
  };

  // Create a pattern of proper length
  length.do({ |i|
    var noteChoices = ~musicalConstraints.getNextNotes.(1);
    var note = noteChoices[0];
    var velocity = rrand(0.15, 0.25);
    var duration, noteEvent;

    // Duration based on style
    duration = case
      { style == \minimal } { 0.25 }
      { style == \melodic } { 0.5 }
      { 0.25 };

    noteEvent = (
      note: note,
      vel: velocity,
      dur: duration
    );
    // Create the note event

    pattern.add(noteEvent);
  });

  // Log the new pattern
  ~patternEngine.formatPattern.(pattern.asArray, "Generated % Pattern".format(instrumentKey));
  ~stateManager.log.("Generated % pattern with % notes (limits: % to %)".format(
    instrumentKey, pattern.size, minLength, maxLength
  ));

  // Return the array version of the pattern
  pattern.asArray;
};

// Display pattern information
~patternEngine.logPattern = { |instrument, pattern, operation="No change", beatPosition=nil|
  var noteInfo = pattern.collect({ |n, i|
    "    [%] % (vel: %, dur: %)".format(
      i,
      ~musicalConstraints.noteToName.(n.note),
      n.vel.round(0.01),
      n.dur
    )
  });

  // Format beat position if provided
  var beatInfo = if(beatPosition.notNil) {
    " at beat %".format(beatPosition.round(0.1))
  } {
    ""
  };

  "=== Pattern Change% ===".format(beatInfo).postln;
  ("Instrument: " ++ instrument).postln;
  ("Operation: " ++ operation).postln;
  "Notes:".postln;
  noteInfo.do({ |info| info.postln });
  "".postln;

  // Also log to state manager
  ~stateManager.log.("Pattern change for %: %".format(instrument, operation));
};

// Enhanced evolve pattern function with detailed output
~patternEngine.evolvePattern = { |currentPattern, instrument|
  var newPattern = currentPattern.copy;
  var instrumentKey = instrument.asSymbol;
  var constraints = ~stateManager.getParam.("instrumentConstraints.patternLimits." ++ instrumentKey);
  var isAdditive = ~stateManager.getParam.("process.currentProcess") == \additive;
  var minLength, maxLength;
  var operation = "No change";
  var changesMade = false;

  // Get musical tension level
  var tension = ~stateManager.getParam.("musical.tension");
  var tensionThreshold = ~stateManager.getParam.("musical.tensionThreshold");
  var modeChangeThreshold = ~stateManager.getParam.("musical.modeChangeThreshold");

  var velocityChangeChance, rhythmChangeChance;

  // Use instrument-specific constraints or defaults
  if(constraints.notNil) {
    minLength = constraints.min;
    maxLength = constraints.max;
  } {
    minLength = ~stateManager.getParam.("process.minPatternLength");
    maxLength = ~stateManager.getParam.("process.maxPatternLength");
  };

  // Display original pattern
  "=== Pattern Evolution (%) ===".format(instrumentKey).postln;
  "Current process: % (limits: % to %)".format(
    ~stateManager.getParam.("process.currentProcess"),
    minLength,
    maxLength
  ).postln;
  ~patternEngine.formatPattern.(currentPattern, "Original Pattern");

  // Update musical state based on all current patterns
  ~musicalConstraints.updateTension.(~patternEngine.patternData.values.asArray);


  // Handle tension-based transformations
  if(tension > tensionThreshold) {
    // Increase chance of transformation
    var transformChance = ~stateManager.getParam.("process.transformChance") * 1.5;

    // Consider mode change if tension is very high
    if(tension > modeChangeThreshold && 0.3.coin) {
      ~musicalConstraints.changeScale.();
      operation = "Scale changed due to high tension";
      changesMade = true;
    } {
      if(transformChance.coin) {
        // Apply a random transformation
        var transform = [\invert, \retrograde, \transpose].choose;

        case
          { transform == \invert } {
            newPattern = ~musicalConstraints.invertPattern.(newPattern);
            operation = "Pattern inverted";
            changesMade = true;
          }
          { transform == \retrograde } {
            newPattern = ~musicalConstraints.retrogradePattern.(newPattern);
            operation = "Pattern retrograded";
            changesMade = true;
          }
          { transform == \transpose } {
            var interval = [-7, -5, -3, 3, 5, 7].choose;
            newPattern = ~musicalConstraints.transposePattern.(newPattern, interval);
            operation = "Pattern transposed by %".format(interval);
            changesMade = true;
          };
      };
    };
  };

  // Handle additive/subtractive processes
  if(isAdditive) {
    if(currentPattern.size < maxLength) {
      var nextNotes = ~musicalConstraints.getNextNotes.(1);
      var nextNote = (
        note: nextNotes[0],
        vel: rrand(0.15, 0.25),
        dur: [0.25, 0.5].choose
      );

      newPattern = newPattern ++ [nextNote];
      operation = operation ++ (if(changesMade) { " + " } { "" }) ++
                  "Added note %".format(~musicalConstraints.noteToName.(nextNotes[0]));
      changesMade = true;
    };
  } {
    if(currentPattern.size > minLength) {
      var removedNote = newPattern.last.note;
      newPattern = newPattern.drop(-1);
      operation = operation ++ (if(changesMade) { " + " } { "" }) ++
                  "Removed note %".format(~musicalConstraints.noteToName.(removedNote));
      changesMade = true;
    };
  };

  // Velocity evolution
  velocityChangeChance = ~stateManager.getParam.("musical.velocityChangeChance");

  if(velocityChangeChance.coin) {
    var idx = rrand(0, newPattern.size - 1);
    var oldVel = newPattern[idx].vel;
    var newVel = rrand(0.15, 0.25);

    newPattern[idx].vel = newVel;
    operation = operation ++ (if(changesMade) { " + " } { "" }) ++
                "Changed velocity of note % [%] from % to %".format(
                  idx,
                  ~musicalConstraints.noteToName.(newPattern[idx].note),
                  oldVel.round(0.01),
                  newVel.round(0.01)
                );
    changesMade = true;
  };

  // Rhythm evolution
  rhythmChangeChance = ~stateManager.getParam.("musical.rhythmChangeChance");

  if(rhythmChangeChance.coin) {
    var idx = rrand(0, newPattern.size - 1);
    var oldDur = newPattern[idx].dur;
    var newDur = [0.25, 0.5].choose;

    // Only change if the new duration is different
    if(oldDur != newDur) {
      newPattern[idx].dur = newDur;
      operation = operation ++ (if(changesMade) { " + " } { "" }) ++
                  "Changed duration of note % [%] from % to %".format(
                    idx,
                    ~musicalConstraints.noteToName.(newPattern[idx].note),
                    oldDur,
                    newDur
                  );
      changesMade = true;
    };
  };

  // If no changes were made, keep the operation as "No change"
  if(changesMade.not) {
    operation = "No change";
  };

  // Display results
  "Operation: %".format(operation).postln;
  ~patternEngine.formatPattern.(newPattern, "Updated Pattern");
  "==============================".postln;

  [newPattern, operation, changesMade];
};

// Start playing a pattern for an instrument
~patternEngine.startPattern = { |instrument, pattern, processType=nil|
  var instrumentKey = instrument.asSymbol;
  var routine, player;

  // Use provided pattern or generate a new one
  pattern = pattern ?? { ~patternEngine.generatePattern.(instrumentKey) };

  // Store pattern data
  ~patternEngine.patternData[instrumentKey] = pattern;

  // Set current process type if provided
  if(processType.notNil) {
    ~stateManager.updateParam.("process.currentProcess", processType);
  };

  // Create a routine to play the pattern
  routine = Routine({
    var currentProcess, evolveRate, transformChance;
    var beatCount = 0;

    inf.do {
      // Get current state values
      currentProcess = ~stateManager.getParam.("process.currentProcess");

      // Determine evolution rate based on process
      evolveRate = if(currentProcess == \additive) {
        ~stateManager.getParam.("process.additionRate") ? 16
      } {
        ~stateManager.getParam.("process.subtractionRate") ? 24
      };

      // Check if it's time to evolve the pattern
      if(beatCount % evolveRate == 0 && beatCount > 0) {
        var currentPattern = ~patternEngine.patternData[instrumentKey];
        var result = ~patternEngine.evolvePattern.(currentPattern, instrumentKey);
        var newPattern = result[0];
        var operation = result[1];
        var changed = result[2];

        // Update pattern if it changed
        if(changed) {
          ~patternEngine.patternData[instrumentKey] = newPattern;
          ~patternEngine.updatePattern.(instrumentKey, newPattern);

          // Log the evolution
          ~stateManager.log.("Evolved % pattern: %".format(instrumentKey, operation));
        };
      };

      // Get the current pattern (which might have been updated)
      pattern = ~patternEngine.patternData[instrumentKey];

      // Play each note in the pattern
      pattern.do { |evt|
        var note = evt.note;
        var velocity = evt.vel;
        var duration = evt.dur;
        var articulation, amp, pan;

        // Determine articulation based on instrument
        articulation = case
          { instrumentKey == \piano } { \ff }
          { instrumentKey == \marimba } { \cord }
          { instrumentKey == \flute } { \vib }
          { nil };

        // Calculate amplitude based on velocity
        amp = velocity * (~stateManager.getParam.("audio.instrumentVolumes." ++ instrumentKey) ? 0.7);

        // Calculate pan based on instrument
        pan = ~stateManager.getParam.("audio.instrumentPans." ++ instrumentKey) ? 0;

        // Play the note
        ~playNoteDirect.(instrumentKey, ~musicalConstraints.noteToName.(note), articulation, amp, pan);

        // Wait for the note duration
        duration.wait;
      };

      // Increment beat counter
      beatCount = beatCount + 1;
    };
  });

  // Start the routine
  player = routine.play(~stateManager.clock);

  // Store active pattern for later reference
  ~patternEngine.activePatterns[instrumentKey] = player;

  // Add to active routines for cleanup
  ~stateManager.state.runtime.activeRoutines.add(player);

  ~stateManager.log.("Started pattern for %".format(instrumentKey));

  player;
};

// Stop a pattern for an instrument
~patternEngine.stopPattern = { |instrument|
  var instrumentKey = instrument.asSymbol;
  var player = ~patternEngine.activePatterns[instrumentKey];

  if(player.notNil && player.isPlaying) {
    player.stop;
    ~patternEngine.activePatterns.removeAt(instrumentKey);
    ~stateManager.log.("Stopped pattern for %".format(instrumentKey));
  } {
    ~stateManager.log.("No active pattern for %".format(instrumentKey));
  };

  true;
};

// Stop all active patterns
~patternEngine.stopAllPatterns = {
  ~patternEngine.activePatterns.keysValuesDo { |instrument, player|
    if(player.isPlaying) {
      player.stop;
      ~stateManager.log.("Stopped pattern for %".format(instrument));
    };
  };

  ~patternEngine.activePatterns = Dictionary.new;
  ~stateManager.log.("All patterns stopped");

  true;
};

// Update a pattern while it's playing (for transitions)
~patternEngine.updatePattern = { |instrument, newPattern|
  var instrumentKey = instrument.asSymbol;

  // Update the stored pattern data
  ~patternEngine.patternData[instrumentKey] = newPattern;

  // Log the update
  ~patternEngine.logPattern.(instrumentKey, newPattern, "Pattern updated",
    ~stateManager.getParam.("runtime.currentBeat"));

  true;
};

// Setup phase relationships between patterns
~patternEngine.setupPhasePatterns = { |force=false|
  var phaseSettings = ~stateManager.getParam.("patterns.phasing.primary");

  // Skip if already defined and not forced to redefine
  if(~patternEngine.phaseRoutine.notNil && ~patternEngine.phaseRoutine.isPlaying && force.not) {
    ~stateManager.log.("Phase patterns already running");
    ^~patternEngine.phaseRoutine;
  };

  if(phaseSettings.isNil || phaseSettings.active.not) {
    ~stateManager.log.("No phase settings found or phases inactive");
    ^false;
  };

  // Create a routine to apply phase shifts
  ~patternEngine.phaseRoutine = Routine({
    var shiftEvery = phaseSettings.shiftEvery ? 32;
    var instruments = phaseSettings.instruments ? [\piano, \marimba, \flute];
    var phaseShift = phaseSettings.phaseShift ? (1/8);
    var staggered = phaseSettings.staggered ? true;
    var beatCount = 0;

    ~stateManager.log.("Starting phase shifting routine");

    inf.do {
      // Check if it's time to apply phase shifts
      if(beatCount % shiftEvery == 0 && beatCount > 0) {
        ~stateManager.log.("Applying phase shifts at beat %".format(beatCount));

        // Apply phase shifts to each instrument
        instruments.do { |instrumentKey, i|
          var currentPattern = ~patternEngine.patternData[instrumentKey];

          if(currentPattern.notNil && currentPattern.size > 1) {
            // Apply phase shift based on instrument index
            var shift = if(staggered) {
              i * phaseShift
            } {
              phaseShift
            };

            // Phase shifting is implemented by reordering the pattern
            if(shift > 0) {
              var shiftItems = (currentPattern.size * shift).asInteger;
              if(shiftItems > 0) {
                var newPattern = currentPattern.rotate(shiftItems);

                // Update the pattern
                ~patternEngine.patternData[instrumentKey] = newPattern;
                ~patternEngine.logPattern.(instrumentKey, newPattern,
                  "Phase shifted by %".format(shift), beatCount);
              };
            };
          };
        };
      };

      // Wait one beat
      1.wait;
      beatCount = beatCount + 1;
    };
  });

  // Start the phase routine
  ~patternEngine.phaseRoutine.play(~stateManager.clock);
  ~stateManager.state.runtime.activeRoutines.add(~patternEngine.phaseRoutine);

  ~stateManager.log.("Phase relationships setup");

  ~patternEngine.phaseRoutine;
};

// Setup process cycling (additive/subtractive)
~patternEngine.setupProcessCycling = { |force=false|
  var additiveDuration = ~stateManager.getParam.("process.additiveDuration") ? 128;
  var subtractiveDuration = ~stateManager.getParam.("process.subtractiveDuration") ? 96;

  // Skip if already defined and not forced to redefine
  if(~patternEngine.processCycleRoutine.notNil && ~patternEngine.processCycleRoutine.isPlaying && force.not) {
    ~stateManager.log.("Process cycling already running");
    ^~patternEngine.processCycleRoutine;
  }
};

// Initialize patterns for multiple instruments
~patternEngine.initializePatterns = { |instruments=nil|
  var instrumentList = instruments ?? { [\piano, \marimba, \flute] };

  instrumentList.do { |instrument|
    var initialPattern = ~patternEngine.generatePattern.(instrument);
    ~patternEngine.patternData[instrument] = initialPattern;
  };

  ~stateManager.log.("Initialized patterns for % instruments".format(instrumentList.size));

  ~patternEngine.patternData;
};

// Generate pattern variations based on existing patterns
~patternEngine.generateVariation = { |sourcePattern, variationAmount=0.3|
  var newPattern = sourcePattern.copy;
  var numChanges = (sourcePattern.size * variationAmount).asInteger.max(1);

  numChanges.do {
    var changeType = [\changeNote, \changeVelocity, \changeDuration].choose;
    var idx = rrand(0, newPattern.size-1);

    case
      { changeType == \changeNote } {
        var noteChoices = ~musicalConstraints.getNextNotes.(1);
        newPattern[idx].note = noteChoices[0];
      }
      { changeType == \changeVelocity } {
        var minVel = ~stateManager.getParam.("musical.velocityMin") ? 0.1;
        var maxVel = ~stateManager.getParam.("musical.velocityMax") ? 0.7;
        newPattern[idx].vel = rrand(minVel, maxVel);
      }
      { changeType == \changeDuration } {
        var durations = [0.125, 0.25, 0.375, 0.5, 0.75, 1.0];
        newPattern[idx].dur = durations.choose;
      };
  };

  newPattern;
};

// Find relationships between patterns
~patternEngine.findPatternRelationships = {
  var instruments = ~patternEngine.patternData.keys.asArray;
  var relationships = List.new;

  // Check each pair of instruments
  instruments.do { |instrument1, i|
    instruments[(i+1)..].do { |instrument2|
      var pattern1 = ~patternEngine.patternData[instrument1];
      var pattern2 = ~patternEngine.patternData[instrument2];
      var relationship = ();
      var rhythmSimilarity = pattern1.collect(_.dur).normalizeSum - pattern2.collect(_.dur).normalizeSum;
      var noteDifferences = pattern1.collect(_.note).differentiate.abs -pattern2.collect(_.note).differentiate.abs;
      var pitchRelationship = noteDifferences.mean;

      // Skip if any pattern is missing
			if(pattern1.isNil || pattern2.isNil) { nil };

      // Calculate rhythmic similarity
      rhythmSimilarity = 1 - rhythmSimilarity.abs.sum;

      // Calculate pitch relationship


      // Store relationship data
      relationship = (
        source: instrument1,
        target: instrument2,
        rhythmicSimilarity: rhythmSimilarity,
        pitchRelationship: pitchRelationship
      );

      relationships.add(relationship);
    };
  };

  relationships.asArray;
};

// Create a new pattern with influences from another pattern
~patternEngine.createInfluencedPattern = { |targetInstrument, sourceInstrument, influenceAmount=0.5|
  var targetPattern = ~patternEngine.patternData[targetInstrument];
  var sourcePattern = ~patternEngine.patternData[sourceInstrument];
  var newPattern;

  // Return original pattern if source or target missing
  if(targetPattern.isNil || sourcePattern.isNil) {
    ~stateManager.log.("Warning: Missing pattern for influence operation", \warn);
    ^targetPattern;
  };

  // Create new pattern by combining elements
  newPattern = targetPattern.collect { |event, i|
    var sourceIdx = i % sourcePattern.size;
    var sourceEvent = sourcePattern[sourceIdx];
    var resultEvent = event.copy;

    // Apply rhythmic influence
    if(influenceAmount.coin) {
      resultEvent.dur = sourceEvent.dur;
    };

    // Apply velocity influence (with partial influence)
    resultEvent.vel = (event.vel * (1-influenceAmount)) + (sourceEvent.vel * influenceAmount);

    // Occasionally apply melodic influence
    if((influenceAmount * 0.5).coin) {
      var interval = sourceEvent.note - sourcePattern[0].note;
      resultEvent.note = targetPattern[0].note + interval;

      // Ensure the note is in scale
      if(~musicalConstraints.isValidNote.(resultEvent.note).not) {
        var noteChoices = ~musicalConstraints.getNextNotes.(1);
        resultEvent.note = noteChoices[0];
      };
    };

    resultEvent;
  };

  ~stateManager.log.("Created pattern for % influenced by % (amount: %)".format(
    targetInstrument, sourceInstrument, influenceAmount
  ));

  newPattern;
};

// Reset all patterns to simpler versions
~patternEngine.resetPatterns = {
  var instruments = ~patternEngine.patternData.keys.asArray;

  instruments.do { |instrument|
    var newPattern = ~patternEngine.generatePattern.(instrument, nil, \minimal);
    ~patternEngine.patternData[instrument] = newPattern;
    ~patternEngine.updatePattern.(instrument, newPattern);
  };

  ~stateManager.log.("Reset all patterns to minimal versions");

  true;
};

// Save current pattern state
~patternEngine.savePatternState = { |name="snapshot"|
  var snapshot = ();
  var instruments = ~patternEngine.patternData.keys.asArray;

  instruments.do { |instrument|
    snapshot[instrument] = ~patternEngine.patternData[instrument].copy;
  };

  ~patternEngine.patternSnapshots = ~patternEngine.patternSnapshots ?? {Dictionary.new};
  ~patternEngine.patternSnapshots[name] = snapshot;

  ~stateManager.log.("Saved pattern snapshot '%'".format(name));

  name;
};

// Restore pattern state from saved snapshot
~patternEngine.restorePatternState = { |name="snapshot"|
  var snapshot = ~patternEngine.patternSnapshots[name];

  if(snapshot.isNil) {
    ~stateManager.log.("Warning: Pattern snapshot '%' not found".format(name), \warn);
    ^false;
  };

  snapshot.keysValuesDo { |instrument, pattern|
    ~patternEngine.patternData[instrument] = pattern.copy;
    ~patternEngine.updatePattern.(instrument, pattern);
  };

  ~stateManager.log.("Restored pattern snapshot '%'".format(name));

  true;
};
# }}}
)

(
// sample-loader.scd
# = {{{
// Sample loading module for the Glass-inspired system
// This module handles loading multi-articulation instrument samples

(
// Create namespace for the sample loader
~sampleLoader = ();

// Initialize the sample loader
~sampleLoader.init = { |basePath|
  var sampleDict, instrumentDict;

  // Just store the path and print a message
  ~sampleLoader.basePath = basePath.asString;

  // Create empty dictionaries
  ~sampleLoader.samples = Dictionary.new;
  ~sampleLoader.instruments = Dictionary.new;

  // Add basic sample player SynthDef if not already defined
  SynthDef(\samplePlayer, {
    |buf=0, amp=0.5, pan=0, attack=0.01, release=0.3, out=0, gate=1|
    var sig, env;

    env = EnvGen.kr(Env.asr(attack, 1, release), gate, doneAction: 2);
    sig = PlayBuf.ar(
      numChannels: 2,
      bufnum: buf,
      rate: BufRateScale.kr(buf),
      doneAction: 0  // Let the envelope handle completion
    );
    sig = sig * env * amp;
    sig = Pan2.ar(sig, pan);
    Out.ar(out, sig);
  }).add;

  // Add reverb SynthDef for effects if not already defined
  SynthDef(\simpleReverb, {
    |in=0, out=0, mix=0.3, room=0.5, damp=0.5|
    var dry, wet;

    dry = In.ar(in, 2);
    wet = FreeVerb.ar(dry, mix, room, damp);
    Out.ar(out, wet);
  }).add;

  "Sample Loader initialized with base path: %".format(basePath).postln;

  // Return the initialized sample loader for chaining
  ~sampleLoader;
};

// Load samples from a folder with proper note naming
~sampleLoader.loadSampleFolder = { |folderPath, instrument, articulation, notePosition=3|
  var folder = PathName(folderPath);
  var count = 0;

  // Create instrument/articulation dictionaries if needed
  if(~sampleLoader.samples[instrument].isNil) {
    ~sampleLoader.samples[instrument] = Dictionary.new;
  };

  if(~sampleLoader.samples[instrument][articulation].isNil) {
    ~sampleLoader.samples[instrument][articulation] = Dictionary.new;
  };

  // Check if folder exists
  if(folder.isFolder.not) {
    "Warning: Folder % does not exist".format(folderPath).warn;
    ^0;
  };

  "Loading % % samples from %".format(instrument, articulation, folderPath).postln;

  folder.files.do { |file|
    if((file.extension == "aif") || (file.extension == "aiff") || (file.extension == "wav")) {
      var fileName = file.fileName;
      var parts = fileName.split($\.);

      if(parts.size > notePosition) {
        var noteName = parts[notePosition];

        // Only show first 10 loading messages to avoid console spam
        if(count < 10) {
          "Loading % % %".format(instrument, articulation, noteName).postln;
        };
        if(count == 10) { "... (more samples) ...".postln; };

        ~sampleLoader.samples[instrument][articulation][noteName.asSymbol] =
          Buffer.read(s, file.fullPath);

        count = count + 1;
      };
    };
  };

  "Loaded % % % samples".format(count, instrument, articulation).postln;
  count;
};

// Play a note with specified parameters
~sampleLoader.playNote = { |instrument, note, articulation=nil, amp=nil, pan=0, attack=nil, release=nil, out=0, callback=nil|
  var instrumentSettings, articulationToUse, noteSymbol, buffer, synth;
  var attackTime, releaseTime, ampValue, synthID;

  // Validate instrument
  instrumentSettings = ~sampleLoader.instruments[instrument];
  if(instrumentSettings.isNil) {
    "Instrument % not loaded".format(instrument).warn;
    ^nil;
  };

  // Use default articulation if none specified
  articulationToUse = articulation ? instrumentSettings.defaultArticulation;

  // Convert note to symbol
  noteSymbol = note.asSymbol;

  // Get the buffer
  buffer = ~sampleLoader.samples[instrument][articulationToUse][noteSymbol];
  if(buffer.isNil) {
    "Note % for % % not loaded".format(noteSymbol, instrument, articulationToUse).warn;
    ^nil;
  };

  // Set parameters based on instrument or use provided values
  attackTime = attack ? instrumentSettings.defaultAttack;
  releaseTime = release ? instrumentSettings.defaultRelease;
  ampValue = amp ? instrumentSettings.defaultAmp;

  // Create a unique synth ID for tracking
  synthID = "%.%-%-%".format(instrument, articulationToUse, noteSymbol, UniqueID.next).asSymbol;

  // Create the synth
  synth = Synth(\samplePlayer, [
    \buf, buffer,
    \amp, ampValue,
    \pan, pan,
    \attack, attackTime,
    \release, releaseTime,
    \out, out
  ]);

  // Execute callback if provided
  if(callback.notNil) {
    callback.value(synth);
  };

  // Return the synth for reference
  synth;
};

// Play a direct note (simplified version without tracking)
~sampleLoader.playNoteDirect = { |instrument, note, articulation=nil, amp=0.7, pan=0|
  var noteSymbol = note.asSymbol;
  var buffer, attackTime, releaseTime;

  // Get correct buffer based on instrument and articulation
  if(articulation.isNil && (~sampleLoader.instruments[instrument].notNil)) {
    articulation = ~sampleLoader.instruments[instrument].defaultArticulation;
  };

  buffer = ~sampleLoader.samples[instrument][articulation][noteSymbol];

  // Set parameters based on instrument
  case
    { instrument == \flute } {
      attackTime = 0.01;
      releaseTime = 0.3;
    }
    { instrument == \marimba } {
      attackTime = 0.005;
      releaseTime = 0.5;
    }
    { instrument == \piano } {
      attackTime = 0.001;
      releaseTime = 0.3;
      amp = amp * 1.5; // Piano often needs higher amplitude
    }
    {
      attackTime = 0.01;
      releaseTime = 0.3;
    };

  if(buffer.notNil) {
    "Playing % % %".format(instrument, articulation, noteSymbol).postln;

    Synth(\samplePlayer, [
      \buf, buffer,
      \amp, amp,
      \pan, pan,
      \attack, attackTime,
      \release, releaseTime
    ]);
  } {
    "Note % for % % not loaded".format(noteSymbol, instrument, articulation).warn;
  };
};

// Setup a reverb effect bus and synth
~sampleLoader.setupReverb = { |out=0, mix=0.3, room=0.5, damp=0.5|
  // Create a stereo bus for the reverb
  ~sampleLoader.reverbBus = Bus.audio(s, 2);

  // Create the reverb synth
  ~sampleLoader.reverbSynth = Synth(\simpleReverb, [
    \in, ~sampleLoader.reverbBus,
    \out, out,
    \mix, mix,
    \room, room,
    \damp, damp
  ], addAction: \addToTail);

  "Reverb setup complete on bus %".format(~sampleLoader.reverbBus).postln;

  // Return the reverb bus
  ~sampleLoader.reverbBus;
};

// Play a note with reverb
~sampleLoader.playNoteWithReverb = { |instrument, note, articulation=nil, dryAmp=0.7, wetAmp=0.3, pan=0|
  var directSynth;
  var reverbSend;

  // Check if reverb is set up
  if(~sampleLoader.reverbBus.isNil) {
    ~sampleLoader.setupReverb.();
  };

  // Play the direct sound
  directSynth = ~sampleLoader.playNoteDirect.(instrument, note, articulation, dryAmp, pan);

  // Send a copy to the reverb bus
  if(directSynth.notNil && ~sampleLoader.reverbBus.notNil) {
    reverbSend = Synth(\samplePlayer, [
      \buf, ~sampleLoader.samples[instrument][articulation][note.asSymbol],
      \amp, wetAmp,
      \pan, pan,
      \attack, 0.005,
      \release, 0.5,
      \out, ~sampleLoader.reverbBus
    ]);
  };

  // Return the direct synth
  directSynth;
};

// Free all samples for an instrument
~sampleLoader.freeInstrument = { |instrument|
  if(~sampleLoader.samples[instrument].notNil) {
    ~sampleLoader.samples[instrument].keysValuesDo { |articulation, sampleDict|
      sampleDict.keysValuesDo { |noteName, buffer|
        if(buffer.notNil) {
          buffer.free;
        };
      };
    };

    ~sampleLoader.samples[instrument] = Dictionary.new;
    ~sampleLoader.instruments.removeAt(instrument);

    "Freed all samples for instrument %".format(instrument).postln;
  } {
    "Instrument % not loaded".format(instrument).warn;
  };
};

// Free all loaded samples
~sampleLoader.freeAllSamples = {
  ~sampleLoader.samples.keysValuesDo { |instrument, articulationDict|
    articulationDict.keysValuesDo { |articulation, sampleDict|
      sampleDict.keysValuesDo { |noteName, buffer|
        if(buffer.notNil) {
          buffer.free;
        };
      };
    };
  };

  ~sampleLoader.samples = Dictionary.new;
  ~sampleLoader.instruments = Dictionary.new;

  "All samples freed.".postln;
};

// Print a summary of loaded samples
~sampleLoader.printSummary = {
  "=== Sample Loader Summary ===".postln;

  if(~sampleLoader.samples.isNil || (~sampleLoader.samples.size == 0)) {
    "No samples loaded.".postln;
    ^nil;
  };

  ~sampleLoader.samples.keysValuesDo { |instrument, articulationDict|
    "Instrument: %".format(instrument).postln;

    articulationDict.keysValuesDo { |articulation, sampleDict|
      "  %: % samples".format(articulation, sampleDict.size).postln;

      if(sampleDict.size > 0) {
        var noteList = sampleDict.keys.asArray.sort;
        var displayNotes = if(noteList.size <= 10) {
          noteList;
        } {
          noteList[0..9] ++ ["... (% more)".format(noteList.size - 10)];
        };

        "    Notes: %".format(displayNotes).postln;
      };
    };
  };

  "===========================".postln;
};

// Get a list of available notes for an instrument/articulation
~sampleLoader.getAvailableNotes = { |instrument, articulation=nil|
  var instrumentSettings, articulationToUse, sampleDict;

  // Validate instrument
  instrumentSettings = ~sampleLoader.instruments[instrument];
  if(instrumentSettings.isNil) {
    "Instrument % not loaded".format(instrument).warn;
    ^nil;
  };

  // Use default articulation if none specified
  articulationToUse = articulation ? instrumentSettings.defaultArticulation;

  // Get the sample dictionary
  sampleDict = ~sampleLoader.samples[instrument][articulationToUse];
  if(sampleDict.isNil || sampleDict.size == 0) {
    "No samples loaded for % %".format(instrument, articulationToUse).warn;
    ^nil;
  };

  // Return sorted array of available notes
  sampleDict.keys.asArray.sort;
};

"Sample Loader module loaded successfully.".postln;
~sampleLoader;
# }}}
)

(
// state-manager.scd
# = {{{
// Central system state and parameter management for the Glass-inspired system
// Handles system parameters, musical state, and runtime operations

/*
  Usage:
  1. Initialize using ~stateManager.init()
  2. Load a preset using ~stateManager.loadPreset(presetName)
  3. Start/stop the system using ~stateManager.start() and ~stateManager.stop()
  4. Update parameters using ~stateManager.updateParam(path, value)
*/

(
// Create namespace for the state manager
~stateManager = ();

// Initialize the state manager
~stateManager.init = { |clockTempo=120|
  var initialState;
  
  // Initialize system clock
  ~stateManager.clock = TempoClock.new(clockTempo/60);
  
  // Initialize global message function
  ~stateManager.log = { |message, type=\info|
    var timestamp = Date.getDate.format("%H:%M:%S");
    var formattedMessage = "[%] [%] %".format(timestamp, type, message);
    
    formattedMessage.postln;
    
    // Store the message in the runtime log
    if(~stateManager.state.notNil) {
      if(~stateManager.state.runtime.notNil && ~stateManager.state.runtime.messages.notNil) {
        ~stateManager.state.runtime.messages.add((
          time: timestamp,
          type: type,
          message: message
        ));
        
        // Keep only the last 100 messages
        if(~stateManager.state.runtime.messages.size > 100) {
          ~stateManager.state.runtime.messages.removeAt(0);
        };
      };
    };
    
    // Return the formatted message
    formattedMessage;
  };
  
  // Initialize system state
  initialState = (
    // Global timing and clock settings
    timing: (
      tempo: clockTempo,        // BPM
      clockDiv: 4,              // Clock division
      swingAmount: 0,           // 0-1 range for swing
      globalReset: 512          // Number of beats before considering a global reset
    ),

    // Process settings
    process: (
      // Current process state
      currentProcess: \additive,  // Current process type (\additive or \subtractive)
      
      // Additive/Subtractive mode timings
      additiveDuration: 128,     // Duration of additive phase in beats
      subtractiveDuration: 96,   // Duration of subtractive phase in beats

      // Evolution rate controls
      additionRate: 16,          // How often to add elements
      subtractionRate: 24,       // How often to remove elements

      // Basic constraints
      maxPatternLength: 8,
      minPatternLength: 2,

      // Transformation controls
      transformChance: 0.15,      // Base chance for transformations
      systemTransformChance: 0.01
    ),

    // Audio settings
    audio: (
      // Master volume and mix controls
      masterVolume: 0.8,  // 0-1 range

      // Default instrument volumes
      instrumentVolumes: (
        piano: 0.7,
        marimba: 0.8,
        flute: 0.6
      ),
      
      // Default instrument panning
      instrumentPans: (
        piano: 0,
        marimba: 0.3,
        flute: -0.3
      ),
      
      // Reverb settings
      reverb: (
        roomSize: 0.6,
        dampening: 0.5,
        mix: 0.45,
        
        // Per-instrument reverb amounts (0.0 - 1.0)
        amounts: (
          piano: 0.3,      // Medium reverb
          marimba: 0.2,    // Less reverb for clarity
          flute: 0.4       // More reverb for air
        )
      )
    ),
    
    // Timeline for the system
    timeline: (),
    
    // Runtime state
    runtime: (
      isPlaying: false,         // Whether the system is currently playing
      currentBeat: 0,           // Current beat position
      currentSection: nil,      // Current section name
      activePatterns: (),       // Currently active patterns
      activeRoutines: List.new, // Active routines for cleanup
      activeSynths: List.new,   // Active synths for cleanup
      messages: List.new        // System messages for logging
    ),

    // Musical controls
    musical: (
      root: 60,                 // Starting root note (Middle C)
      scale: \major,            // Starting scale
      tension: 0,               // Current tension level (0-100)
      harmonicDensity: 0,       // Current harmonic density (0-100)
      rhythmicDensity: 0,       // Current rhythmic density (0-100)
      verticalSpread: 0,        // Current vertical spread (0-100)

      tensionThreshold: 75,     // Point at which we might trigger changes
      modeChangeThreshold: 85,  // Point at which we might change modes

      // Velocity controls
      velocityMin: 0.1,
      velocityMax: 0.7,
      velocityStepSize: 0.08,
      velocityChangeChance: 0.2,

      // Rhythm controls
      rhythmChangeChance: 0.1,
      rhythmStepSizes: [0.125, 0.25, 0.5, 1.0],
      rhythmMin: 0.125,
      rhythmMax: 1.0,

      // Pitch boundaries
      maxPitch: 87,
      minPitch: 48,
      resetThreshold: 83
    ),

    // Pattern settings
    patterns: (
      bankChangeChance: 0.05,
      initialBank: 'basic',
      styles: ['basic', 'melodic', 'minimal'],
      instruments: ['piano', 'marimba', 'flute'],
      
      instrumentEnabled: ( // Keeps track of which instruments are currently enabled
        piano: false,      // Start inactive, enabled via timeline events
        marimba: false,
        flute: false
      ),

      // Default starting patterns for instruments
      initialPatterns: (
        piano: [
          (note: 60, vel: 0.2, dur: 0.25),
          (note: 62, vel: 0.2, dur: 0.25)
        ],
        marimba: [
          (note: 60, vel: 0.2, dur: 0.5),
          (note: 64, vel: 0.2, dur: 0.25)
        ],
        flute: [
          (note: 72, vel: 0.2, dur: 1.0),
          (note: 67, vel: 0.2, dur: 0.5)
        ]
      ),

      // Pattern relationships - how instruments influence each other
      relationships: (
        // Piano influences marimba rhythms
        piano_marimba: (
          source: \piano,
          target: \marimba,
          property: \rhythm,      // Affects rhythm
          strength: 0.4,          // Probability of influence
          mode: \adopt,           // How influence works (adopt, reflect, counter)
          active: true            // Can be toggled on/off
        ),

        // Marimba influences flute pitch
        marimba_flute: (
          source: \marimba,
          target: \flute,
          property: \pitch,
          strength: 0.35,
          intervals: [3, 4, 7],   // Preferred intervals for pitch relationships
          mode: \follow,
          active: true
        ),

        // Flute influence on piano dynamics
        flute_piano: (
          source: \flute,
          target: \piano,
          property: \velocity,
          strength: 0.25,
          mode: \contrast,        // Create contrast rather than similarity
          variance: 0.2,          // How much variance in the influence
          active: true
        )
      ),
      
      // Phase relationships
      phasing: (
        // Basic phase relationship
        primary: (
          instruments: [\piano, \marimba, \flute],
          phaseShift: 1/8,       // Amount to shift each pattern
          shiftEvery: 32,        // Apply shifts every 32 beats
          staggered: true,       // Apply shifts in staggered manner
          active: true           // Enable this relationship
        )
      ),
      
      // Global influence settings
      influenceStrength: 0.3     // Global scaling for pattern influences
    ),
    
    // Instrument specific constraints
    instrumentConstraints: (
      // Pattern length limits for each instrument
      patternLimits: (
        piano: (min: 2, max: 8),    // Piano can have longer patterns
        marimba: (min: 2, max: 6),  // Medium length for marimba
        flute: (min: 1, max: 4)     // Shorter patterns for flute
      ),
      
      // When instruments enter in the sequence (in beats)
      entryTimes: (
        piano: 0,      // Start immediately
        marimba: 32,   // Enter after 32 beats
        flute: 64      // Enter after 64 beats
      )
    ),
    
    // Set up musical scales
    scales: (
      major: [0, 2, 4, 5, 7, 9, 11],
      naturalMinor: [0, 2, 3, 5, 7, 8, 10],
      harmonicMinor: [0, 2, 3, 5, 7, 8, 11],
      melodicMinor: [0, 2, 3, 5, 7, 9, 11],
      dorian: [0, 2, 3, 5, 7, 9, 10],
      phrygian: [0, 1, 3, 5, 7, 8, 10],
      lydian: [0, 2, 4, 6, 7, 9, 11],
      mixolydian: [0, 2, 4, 5, 7, 9, 10],
      locrian: [0, 1, 3, 5, 6, 8, 10],
      minorPent: [0, 3, 5, 7, 10],
      majorPent: [0, 2, 4, 7, 9]
    )
  );
  
  // Assign the initial state
  ~stateManager.state = initialState;
  
  ~stateManager.log.("State Manager initialized with tempo: %".format(clockTempo));
  
  // Return for chaining
  ~stateManager;
};

// Update a parameter in the state
~stateManager.updateParam = { |path, value|
  var parts = path.split($.);
  var current = ~stateManager.state;
  
  // Navigate to the correct nested object
  if(parts.size > 1) {
    parts[0..(parts.size-2)].do { |part|
      var partSym = part.asSymbol;
      if(current[partSym].isNil) {
        current[partSym] = ();
      };
      current = current[partSym];
    };
    
    // Set the value
    current[parts.last.asSymbol] = value;
  } {
    // Set directly on state
    ~stateManager.state[path.asSymbol] = value;
  };
  
  value;
};

// Get a parameter from the state
~stateManager.getParam = { |path|
  var parts = path.split($.);
  var current = ~stateManager.state;
  
  // Navigate to the correct nested object
  parts.do { |part|
    var partSym = part.asSymbol;
    if(current.isNil) { ^nil };
    current = current[partSym];
  };
  
  current;
};

// Load a preset into the state
~stateManager.loadPreset = { |preset|
  if(preset.isNil) {
    ~stateManager.log.("Cannot load nil preset", \error);
    ^false;
  };
  
  // Update the state with the preset values
  preset.keysValuesDo { |key, value|
    if(key != \name && key != \description && key != \author && key != \created) {
      ~stateManager.updateParam.(key, value);
    };
  };
  
  ~stateManager.log.("Loaded preset: %".format(preset[\name] ? "Unnamed"));
  
  true;
};

// Start the beat counter with instrument entries
~stateManager.startBeatCounter = {
  var beatCounter = Routine({
    inf.do {
      var beat = ~stateManager.state.runtime.currentBeat;
      var entryTimes = ~stateManager.state.instrumentConstraints.entryTimes;
      
      // Check if we need to start any instruments at this beat
      if(entryTimes.notNil) {
        if(beat == entryTimes.piano && ~stateManager.getParam.("patterns.instrumentEnabled.piano").not) {
          ~stateManager.log.("Starting piano at beat %".format(beat));
          
          // Create a timeline event for starting piano
          ~timelineInterpreter.executeEvent.((
            beat: beat,
            type: \instrumentStart,
            instrument: \piano
          ));
        };
        
        if(beat == entryTimes.marimba && ~stateManager.getParam.("patterns.instrumentEnabled.marimba").not) {
          ~stateManager.log.("Starting marimba at beat %".format(beat));
          
          // Create a timeline event for starting marimba
          ~timelineInterpreter.executeEvent.((
            beat: beat,
            type: \instrumentStart,
            instrument: \marimba
          ));
        };
        
        if(beat == entryTimes.flute && ~stateManager.getParam.("patterns.instrumentEnabled.flute").not) {
          ~stateManager.log.("Starting flute at beat %".format(beat));
          
          // Create a timeline event for starting flute
          ~timelineInterpreter.executeEvent.((
            beat: beat,
            type: \instrumentStart,
            instrument: \flute
          ));
        };
      };
      
      // Occasionally log the current beat
      if(beat % 32 == 0) {
        ~stateManager.log.("Beat: %".format(beat));
      };
      
      // Increment beat counter
      ~stateManager.state.runtime.currentBeat = beat + 1;
      
      1.wait;  // Wait one beat
    };
  });
  
  beatCounter.play(~stateManager.clock);
  ~stateManager.state.runtime.activeRoutines.add(beatCounter);
  ~stateManager.log.("Beat counter started");
  
  beatCounter;
};

// Convert MIDI note to note name
~stateManager.noteToName = { |note|
  var names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"];
  var octave = (note / 12).floor - 1;
  var noteName = names[note % 12];
  noteName ++ octave.asString;
};

// Print current state
~stateManager.printState = {
  ~stateManager.log.("=== System State ===");
  ~stateManager.log.("Status: %".format(
    if(~stateManager.state.runtime.isPlaying) { "Running" } { "Stopped" }
  ));
  ~stateManager.log.("Current Beat: %".format(~stateManager.state.runtime.currentBeat));
  ~stateManager.log.("Tempo: % BPM".format(~stateManager.state.timing.tempo));
  ~stateManager.log.("Process: %".format(~stateManager.state.process.currentProcess));
  ~stateManager.log.("Musical Root: % (%)"
    .format(~stateManager.state.musical.root, ~stateManager.noteToName.(~stateManager.state.musical.root)));
  ~stateManager.log.("====================");
};

"State Manager module loaded successfully.".postln;
~stateManager;
# }}}
)

(
// timeline-interpreter.scd
# = {{{ 
// Timeline event interpreter for the Glass-inspired system
// Handles loading, parsing, and executing timeline events

/*
  Usage:
  1. Initialize using ~timelineInterpreter.init()
  2. Load a timeline using ~timelineInterpreter.loadTimeline(events)
  3. Start the system with timeline using ~timelineInterpreter.start()
*/

(
// Create namespace for the timeline interpreter
~timelineInterpreter = ();

// Initialize the timeline interpreter
~timelineInterpreter.init = {
  // Make sure dependencies are available
  if(~stateManager.isNil) {
    "Error: State Manager must be initialized before Timeline Interpreter".error;
    ^false;
  };

  if(~patternEngine.isNil) {
    "Error: Pattern Engine must be initialized before Timeline Interpreter".error;
    ^false;
  };

  // Initialize event queue and timeline data
  ~timelineInterpreter.eventQueue = PriorityQueue.new;
  ~timelineInterpreter.timelineData = List.new;
  ~timelineInterpreter.sectionMarkers = Dictionary.new;
  ~timelineInterpreter.repeatSections = Dictionary.new;
  ~timelineInterpreter.activeRoutines = List.new;

  ~stateManager.log.("Timeline Interpreter initialized");

  // Return for chaining
  ~timelineInterpreter;
};

// Load a timeline from a collection of events
~timelineInterpreter.loadTimeline = { |events|
  // Check if events is an array or list
  if(events.isArray.not && events.isKindOf(List).not) {
    ~stateManager.log.("Error: Events must be an array or list, not %".format(events.class), \error);
    ^false;
  };

  // Clear existing timeline
  ~timelineInterpreter.timelineData = List.new;
  ~timelineInterpreter.sectionMarkers = Dictionary.new;

  // Add each event to the timeline
  events.do { |event|
    // Skip if event is not an event (e.g., if it's a function)
    if(event.isKindOf(Event).not && event.isKindOf(IdentityDictionary).not) {
      ~stateManager.log.("Warning: Skipping non-event item: %".format(event), \warn);
    };

    ~timelineInterpreter.timelineData.add(event);

    // Register section markers
    if(event[\type] == \sectionMarker && event[\name].notNil) {
      ~timelineInterpreter.sectionMarkers[event[\name].asSymbol] = event[\beat];
    };
  };

  // Sort events by beat
  ~timelineInterpreter.timelineData = ~timelineInterpreter.timelineData.sort({ |a, b|
    a[\beat] < b[\beat]
  });

  ~stateManager.log.("Loaded timeline with % events".format(events.size));

  // Return the sorted timeline data
  ~timelineInterpreter.timelineData;
};

// Prepare the event queue for playback
~timelineInterpreter.prepareQueue = {
  // Clear the existing queue
  ~timelineInterpreter.eventQueue.clear;

  // Add all events to the queue
  ~timelineInterpreter.timelineData.do { |event|
    // Use bracket notation instead of dot notation
    ~timelineInterpreter.eventQueue.put(event[\beat], event);
  };

  ~stateManager.log.("Prepared event queue with % events".format(~timelineInterpreter.eventQueue.size));

  // Return the queue size
  ~timelineInterpreter.eventQueue.size;
};

// Start timeline execution
~timelineInterpreter.start = {
  // Make sure system is prepared
  if(~stateManager.state.runtime.isPlaying.not) {
    "Error: System must be running before starting timeline".error;
    ^false;
  };

  // Reset beat counter
  ~stateManager.updateParam.("runtime.currentBeat", 0);

  // Prepare event queue
  ~timelineInterpreter.prepareQueue.();

  // Start the execution routine
  ~timelineInterpreter.executeRoutine = Routine({
    var currentBeat, nextEventBeat, nextEvent;

    inf.do {
      currentBeat = ~stateManager.getParam.("runtime.currentBeat");

      // Check for events at this beat
      while({
        nextEventBeat = ~timelineInterpreter.eventQueue.topPriority;
        nextEventBeat.notNil && (nextEventBeat <= currentBeat);
      }, {
        nextEvent = ~timelineInterpreter.eventQueue.pop;

        // Execute the event
        ~timelineInterpreter.executeEvent.(nextEvent);
      });

      1.wait;  // Wait one beat
    };
  });

  // Start the routine
  ~timelineInterpreter.executeRoutine.play(~stateManager.clock);
  ~stateManager.state.runtime.activeRoutines.add(~timelineInterpreter.executeRoutine);

  ~stateManager.log.("Timeline execution started");

  true;
};

// Stop timeline execution (renamed to avoid conflict with built-in method)
~timelineInterpreter.stopTimeline = {
  // Stop execution routine
  if(~timelineInterpreter.executeRoutine.notNil && ~timelineInterpreter.executeRoutine.isPlaying) {
    ~timelineInterpreter.executeRoutine.stop;
    ~timelineInterpreter.executeRoutine = nil;
  };

  // Stop all active routines
  ~timelineInterpreter.activeRoutines.do { |routine|
    if(routine.isPlaying) {
      routine.stop;
    };
  };
  ~timelineInterpreter.activeRoutines = List.new;

  ~stateManager.log.("Timeline execution stopped");

  true;
};

// Execute a timeline event
~timelineInterpreter.executeEvent = { |event|
  var eventType = event[\type];  // Use array syntax instead of dot syntax

  // Log event execution
  ~stateManager.log.("Executing timeline event: % at beat %"
    .format(eventType, ~stateManager.getParam.("runtime.currentBeat")));

  // Process event based on type
  case
    // Section markers
    { eventType == \sectionMarker } {
      ~stateManager.updateParam.("runtime.currentSection", event[\name]);
      ~stateManager.log.("Entered section: %".format(event[\name]));
    }

    // Section jumps
    { eventType == \sectionJump } {
      var targetBeat = ~timelineInterpreter.sectionMarkers[event[\section].asSymbol];
      if(targetBeat.notNil) {
        ~stateManager.updateParam.("runtime.currentBeat", targetBeat);
        ~stateManager.log.("Jumped to section: % (beat %)".format(event[\section], targetBeat));

        // Reprepare the queue for events after this point
        ~timelineInterpreter.prepareQueue.();
      } {
        ~stateManager.log.("Error: Unknown section: %".format(event[\section]), \error);
      };
    }

    // Process changes
    { eventType == \processChange } {
      ~stateManager.updateParam.("process.currentProcess", event[\process]);
      ~stateManager.log.("Process changed to: %".format(event[\process]));
    }

    // Instrument start
    { eventType == \instrumentStart } {
      var instrument = event[\instrument];
      var processType = event[\processType] ? ~stateManager.getParam.("process.currentProcess");

      // Generate initial pattern
      var pattern = ~patternEngine.generatePattern.(instrument);

      // Start pattern playback
      ~patternEngine.startPattern.(instrument, pattern, processType);

      // Mark instrument as enabled
      ~stateManager.updateParam.("patterns.instrumentEnabled." ++ instrument, true);

      ~stateManager.log.("Started instrument: %".format(instrument));
    }

    // Instrument stop
    { eventType == \instrumentStop } {
      var instrument = event[\instrument];

      // Stop pattern playback
      ~patternEngine.stopPattern.(instrument);

      // Mark instrument as disabled
      ~stateManager.updateParam.("patterns.instrumentEnabled." ++ instrument, false);

      ~stateManager.log.("Stopped instrument: %".format(instrument));
    }

    // Scale changes
    { eventType == \scaleChange } {
      ~musicalConstraints.changeScale.(event[\scale]);
      ~stateManager.log.("Scale changed to: %".format(event[\scale]));
    }

    // Root changes
    { eventType == \rootChange } {
      var interval = event[\interval] ? 0;
      ~musicalConstraints.changeRoot.(interval);
      ~stateManager.log.("Root changed by interval: %".format(interval));
    }

    // Pattern transformations
    { eventType == \patternTransform } {
      var instrument = event[\instrument];
      var transform = event[\transform];
      var currentPattern, newPattern;

      // Get current pattern
      currentPattern = ~patternEngine.patternData[instrument.asSymbol];

      if(currentPattern.notNil) {
        case
          { transform == \invert } {
            newPattern = ~musicalConstraints.invertPattern.(currentPattern);
            ~stateManager.log.("Inverted pattern for %".format(instrument));
          }
          { transform == \retrograde } {
            newPattern = ~musicalConstraints.retrogradePattern.(currentPattern);
            ~stateManager.log.("Retrograded pattern for %".format(instrument));
          }
          { transform == \transpose } {
            var interval = event[\interval] ? 0;
            newPattern = ~musicalConstraints.transposePattern.(currentPattern, interval);
            ~stateManager.log.("Transposed pattern for % by %".format(instrument, interval));
          };

        // Update pattern
        if(newPattern.notNil) {
          ~patternEngine.patternData[instrument.asSymbol] = newPattern;
          ~patternEngine.updatePattern.(instrument, newPattern);
        };
      };
    }

    // Unknown event type
    {
      ~stateManager.log.("Warning: Unknown event type: %".format(eventType), \warn);
    };

  true;
};

// Add a single event to the timeline
~timelineInterpreter.addEvent = { |event|
  // Add to timeline data
  ~timelineInterpreter.timelineData.add(event);

  // Resort timeline
  ~timelineInterpreter.timelineData = ~timelineInterpreter.timelineData.sort({ |a, b|
    a[\beat] < b[\beat]
  });

  // Register section marker if applicable
  if(event[\type] == \sectionMarker && event[\name].notNil) {
    ~timelineInterpreter.sectionMarkers[event[\name].asSymbol] = event[\beat];
  };

  // Add to event queue if timeline is active
  if(~timelineInterpreter.executeRoutine.notNil && ~timelineInterpreter.executeRoutine.isPlaying) {
    ~timelineInterpreter.eventQueue.put(event[\beat], event);
  };

  ~stateManager.log.("Added event to timeline: % at beat %".format(event[\type], event[\beat]));

  true;
};


"Timeline interpreter module loaded successfully.".postln;
~timelineInterpreter;
# }}}
)
