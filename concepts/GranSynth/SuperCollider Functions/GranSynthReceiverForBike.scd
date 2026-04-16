(
s.waitForBoot({
    // --- 1. Dynamic Identity Assignment ---
    var path, rootNote, filename, user;
    var currentDens = 200;
    var currentDur = 0.07;
    var currentPos = 0.1;

    user = "whoami".unixCmdGetStdOut;


    if(user.contains("bikes2")) {
        ~host = "2";
        filename = "BassSoundC1.wav";
        rootNote = 26;
    } {
        if(user.contains("bikes3")) {
            ~host = "3";
            filename = "StringSound1.wav";
            rootNote = 60;
        } {
            if(user.contains("bikes4")) {
                ~host = "4";
                filename = "PadSoundC4.wav";
                rootNote = 60;
            } {
                // FALLBACK FIX: Use the actual computer's network name
                ~host = "hostname".unixCmdGetStdOut.replace("\n", "");
                if(~host.isEmpty) { ~host = "127.0.0.1" }; // Safe localhost fallback

                filename = "PadSoundC4.wav";
                rootNote = 60;
            }
        }
    };

    // --- 2. Load Buffer ---
    ~absolutePrefix = thisProcess.nowExecutingPath.dirname.dirname;
    path = ~absolutePrefix +/+ "Audio Files" +/+ filename;
    b = Buffer.readChannel(s, path, channels: [0]);

    // --- 3. SynthDef ---
    SynthDef.new(\gs, {
        arg sync=0, dens=60, dur=0.4, durRand=0.5, durHz=0.3, buf=0,
        rate=1, pos=0.1, posSpeed=0.1, posRand=0.05,
        grainEnv=(-1), pan=0, panHz=0.1, panRand=0,
        atk=0.5, rel=2, gate=1, amp=0.3, out=0;

        var sig, env, trigger, durCtrl, posCtrl, panCtrl;

        env = EnvGen.ar(Env.asr(atk, 1, rel), gate, doneAction: 2);
        trigger = Select.ar(sync, [Dust.ar(dens ! 2), Impulse.ar(dens ! 2)]);
        durCtrl = dur * LFNoise1.kr(durHz ! 2).exprange(1 - durRand, 1 + durRand);
        posCtrl = Phasor.ar(0, posSpeed * BufRateScale.ir(buf), 0, BufSamples.ir(buf) - 1);
        posCtrl = posCtrl + LFNoise1.ar(100 ! 2).bipolar(posRand * SampleRate.ir);
        posCtrl = (posCtrl / BufSamples.ir(buf) + pos).wrap(0, 1);
        panCtrl = pan + LFNoise1.kr(panHz ! 2).bipolar(panRand);

        sig = GrainBuf.ar(2, trigger, durCtrl, buf, rate, posCtrl, 2, panCtrl, grainEnv);
        Out.ar(out, sig * env * amp);
    }).add;

    s.sync;

    // --- 4. Logic & Context ---
    ~noteMap = ( 'C': 0, 'C#': 1, 'D': 2, 'D#': 3, 'E': 4, 'F': 5, 'F#': 6, 'G': 7, 'G#': 8, 'A': 9, 'A#': 10, 'B': 11 );
    ~scales  = (
        'Major':      [0, 2, 4, 5, 7, 9, 11],
        'Minor':      [0, 2, 3, 5, 7, 8, 10],
        'Dorian':     [0, 2, 3, 5, 7, 9, 10],
        'Mixolydian': [0, 2, 4, 5, 7, 9, 10]
    );

    ~activeSynth = nil;
    ~localSynth = nil;

    ~currentRoot = 'C';
    ~currentScale = 'Major';
    ~currentDegree = 1;

    ~playNote = { |rootName, scaleName, degree|
        var rootMidi, noteMidi, ratio;
        ~currentRoot = rootName.asSymbol;
        ~currentScale = scaleName.asSymbol;
        ~currentDegree = degree.asInteger;

        rootMidi = rootNote + ~noteMap[~currentRoot];
        noteMidi = rootMidi + ~scales[~currentScale][~currentDegree - 1];
        ratio = (noteMidi - rootNote).midiratio;

        if (~activeSynth.notNil && { ~activeSynth.isPlaying }) {
            ~activeSynth.set(\rate, ratio);
        } {
            ~activeSynth = Synth(\gs, [
                \buf, b, \rate, ratio, \dens, currentDens,
                \dur, currentDur, \pos, currentPos, \amp, 0.2, \gate, 1
            ]).register;
        };
    };

    ~playChordTone = { |buttonIdx|
        var voicing = [0, 2, 4, 6];
        var scaleDegrees = ~scales[~currentScale];
        var rootOffset = ~noteMap[~currentRoot];
        var rootMidi, degreeInScale, octaveShift, semitone, noteMidi, ratio;

        if(rootOffset.isNil) { rootOffset = 0 };
        if(scaleDegrees.isNil) { scaleDegrees = ~scales['Major'] };

        rootMidi = rootNote + rootOffset;
        degreeInScale = (~currentDegree.asInteger - 1) + voicing[buttonIdx];
        octaveShift = (degreeInScale / 7).floor * 12;
        semitone = scaleDegrees[degreeInScale % 7] + octaveShift;
        noteMidi = rootMidi + semitone;
        ratio = (noteMidi - rootNote).midiratio;

        ~localSynth = Synth(\gs, [
            \buf, b, \rate, ratio, \dens, currentDens,
            \dur, currentDur, \pos, currentPos, \amp, 0.2, \gate, 1
        ]).register;
    };


// --- 5. Network Discovery ---
    // We leave P2PSC running purely so the Host can discover this node's name
    fork {
        p = P2PSC();
        p.sync;
        p.setName(~host);
        p.sync;
        0.2.wait;
        p.sync;
        "? P2PSC Receiver Ready! Node assigned as: %".format(~host).postln;
    };

    // --- 6. OSC Listeners ---

    // A. Listen for the Host's remote chord updates over raw UDP
    OSCdef(\remoteChordListener, { |msg|
        var root = msg[1];
        var scale = msg[2];
        var deg = msg[3].asInteger;

        if(deg > 0) {
            // Silently update the musical context, DO NOT trigger a synth
            ~currentRoot = root.asSymbol;
            ~currentScale = scale.asSymbol;
            ~currentDegree = deg;
        } {
            // deg == 0: The Host turned off the chord.
            // Kill the local harmony if it is currently playing so it doesn't drone on alone.
            {
                if(~localSynth.notNil) { ~localSynth.set(\gate, 0); ~localSynth = nil; };
            }.defer;
        };
    }, "/remoteChord");

    // B. Listen for Pygame's local harmony buttons
    OSCdef(\localRelay, { |msg|
        var btnIdx = msg[1].asInteger;
        var isOn   = msg[2].asInteger;

        if(isOn == 1) {
            { ~playChordTone.value(btnIdx) }.defer;
        } {
            {
                if(~localSynth.notNil) { ~localSynth.set(\gate, 0); ~localSynth = nil; };
            }.defer;
        };
    }, "/localChord");
}))