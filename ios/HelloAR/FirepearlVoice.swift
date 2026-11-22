// Firepearl's voice: a few spoken lines (on-device speech, pitched up) and synthesized purrs, chirps and fire.
import AVFoundation
import QuartzCore

final class FirepearlVoice: NSObject, AVSpeechSynthesizerDelegate {
    enum Moment { case hello, pet, roll, boop, takeoff, land, fire, idle, follow }

    static let friend = "Ava"
    var talks = true
    var sounds = true
    /// While she is listening or thinking she keeps her own chatter to herself.
    var hush = false
    /// Speech goes through a little dragon throat (pitch up, a growly flutter, some grit); off = the plain voice.
    var dragonVoice = true
    var speaking: Bool { synthSpeaking || rendering || fxPlaying }
    private var synthSpeaking = false
    private var rendering = false
    private var fxPlaying = false
    private var utterID = 0
    private let player = AVAudioPlayerNode()
    private let throat = AVAudioUnitTimePitch()
    private var throatRate: Double = 0
    private let fxLock = NSLock()
    private var fxSamples: [Float] = []
    private var fxSampleRate: Double = 0

    private let speech = AVSpeechSynthesizer()
    private var lastSpoke: CFTimeInterval = -100
    private var lastLine: [Moment: String] = [:]

    private static let lines: [Moment: [String]] = {
        let f = friend
        return [
            .hello: ["Hi \(f)! It's me, Firepearl!", "\(f)! I found you!", "Hello \(f)! Ready for an adventure?"],
            .pet: ["Ooh, that tickles!", "More scratches, please!", "Mmm. Right there.", "You're my best friend, \(f).",
                   "I love you, \(f)!", "Purr. Dragons can purr, you know."],
            .roll: ["Belly rubs!", "Hee hee hee! Tummy time!", "Okay, okay, I'm upside down!"],
            .boop: ["Boop!", "Hee hee!", "Hey, that's my nose!", "Boop to you too!"],
            .takeoff: ["Wheee!", "Watch me fly, \(f)!", "Up, up, up!", "I'm flying over your head!"],
            .land: ["Made it!", "Ta-da!", "Back on the ground."],
            .fire: ["Rawr! Did you see my fire?", "Oops. Hot hot hot!", "That was a little fire. I'm still learning."],
            .idle: ["I'm a small dragon, but I'm a brave dragon.", "Where are we going next, \(f)?",
                    "Pearls are my favourite. And you.", "Do you want to see me fly?", "I like it here.",
                    "Pet me! Pet me!", "Is that a squirrel? I'm not scared of squirrels."],
            .follow: ["Wait for me!", "I'm right behind you, \(f)!", "Don't walk too fast, my legs are little!"],
        ]
    }()

    private static let voice: AVSpeechSynthesisVoice? = {
        let english = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        return english.first { $0.quality == .premium } ?? english.first { $0.quality == .enhanced }
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }()

    override init() {
        super.init()
        speech.delegate = self
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        sampleRate = Float(format.sampleRate)
        node = AVAudioSourceNode(format: format) { [unowned self] _, _, frameCount, list -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            let n = Int(frameCount)
            guard let first = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            self.render(first, n)
            for b in buffers.dropFirst() {
                b.mData?.assumingMemoryBound(to: Float.self).update(from: first, count: n)
            }
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.attach(player)
        engine.attach(throat)
        throat.pitch = 500
        engine.prepare()
    }

    // MARK: - speaking

    /// Says a line for the moment, unless she spoke very recently. Returns true if she spoke.
    @discardableResult
    func say(_ m: Moment) -> Bool {
        guard talks, !hush, var options = Self.lines[m] else { return false }
        let now = CACurrentMediaTime()
        let gap: CFTimeInterval
        switch m {
        case .hello, .boop, .pet, .roll: gap = 2.5
        default: gap = 6
        }
        guard now - lastSpoke > gap, !speaking || m == .hello else { return false }
        if options.count > 1, let last = lastLine[m] { options.removeAll { $0 == last } }
        let line = options.randomElement()!
        lastLine[m] = line
        utter(line)
        return true
    }

    /// Speaks a reply from her mind (Sky): always, interrupting any chatter.
    func speak(_ text: String) { utter(text) }

    private func plainUtterance(_ text: String) -> AVSpeechUtterance {
        let u = AVSpeechUtterance(string: text)
        u.voice = Self.voice
        u.volume = 1
        u.pitchMultiplier = 1.65
        u.rate = min(AVSpeechUtteranceMaximumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * 1.05)
        return u
    }

    private func utter(_ text: String) {
        lastSpoke = CACurrentMediaTime()
        prepareSession()
        utterID += 1
        let id = utterID
        player.stop()
        fxPlaying = false
        if speech.isSpeaking { speech.stopSpeaking(at: .immediate) }
        guard dragonVoice else {
            synthSpeaking = true
            speech.speak(plainUtterance(text))
            return
        }
        // render the words to samples, then play them through the dragon throat
        let u = AVSpeechUtterance(string: text)
        u.voice = Self.voice
        u.volume = 1
        u.pitchMultiplier = 1.15
        u.rate = min(AVSpeechUtteranceMaximumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * 1.08)
        fxLock.lock(); fxSamples = []; fxSampleRate = 0; fxLock.unlock()
        rendering = true
        speech.write(u) { [weak self] buffer in
            guard let self, let pcm = buffer as? AVAudioPCMBuffer else { return }
            let n = Int(pcm.frameLength)
            if n == 0 {
                DispatchQueue.main.async { self.playThroughThroat(id: id, text: text) }
                return
            }
            var chunk = [Float](repeating: 0, count: n)
            if let fl = pcm.floatChannelData {
                for k in 0..<n { chunk[k] = fl[0][k] }
            } else if let i16 = pcm.int16ChannelData {
                for k in 0..<n { chunk[k] = Float(i16[0][k]) / 32768 }
            } else if let i32 = pcm.int32ChannelData {
                for k in 0..<n { chunk[k] = Float(i32[0][k]) / 2147483648 }
            }
            self.fxLock.lock()
            self.fxSamples += chunk
            self.fxSampleRate = pcm.format.sampleRate
            self.fxLock.unlock()
        }
        // if the end-of-speech buffer never comes, play what arrived
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.playThroughThroat(id: id, text: text) }
    }

    private func playThroughThroat(id: Int, text: String) {
        guard id == utterID, rendering else { return }
        rendering = false
        fxLock.lock(); var s = fxSamples; let rate = fxSampleRate; fxSamples = []; fxLock.unlock()
        ensureRunning()
        guard !s.isEmpty, rate > 0, engine.isRunning,
              let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(s.count)) else {
            synthSpeaking = true
            speech.speak(plainUtterance(text))
            return
        }
        // the throat: a 32 Hz flutter (a purring growl) and a little grit
        let w = 2 * Float.pi * 32 / Float(rate)
        let grit: Float = 1.8, norm = tanhf(1.8)
        for k in s.indices { s[k] = tanhf(grit * s[k] * (0.7 + 0.3 * sinf(w * Float(k)))) / norm }
        buf.frameLength = AVAudioFrameCount(s.count)
        if let out = buf.floatChannelData?[0] { s.withUnsafeBufferPointer { out.update(from: $0.baseAddress!, count: s.count) } }
        if rate != throatRate {
            engine.disconnectNodeOutput(player)
            engine.disconnectNodeOutput(throat)
            engine.connect(player, to: throat, format: fmt)
            engine.connect(throat, to: engine.mainMixerNode, format: fmt)
            throatRate = rate
        }
        fxPlaying = true
        player.scheduleBuffer(buf, at: nil, options: .interrupts) { [weak self] in
            DispatchQueue.main.async { if self?.utterID == id { self?.fxPlaying = false } }
        }
        player.play()
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didStart u: AVSpeechUtterance) { if !rendering { synthSpeaking = true } }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) { synthSpeaking = false }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) { synthSpeaking = false }

    // MARK: - sounds

    func chirp() { play(Sound(kind: .chirp, dur: 0.16, f0: Float.random(in: 1100...1400), f1: Float.random(in: 1700...2200), trill: 0, amp: 0.22)) }
    func trill() { play(Sound(kind: .chirp, dur: 0.32, f0: 900, f1: 1500, trill: 28, amp: 0.25)) }
    func giggle() {
        for k in 0..<3 {
            play(Sound(kind: .chirp, dur: 0.09, f0: 1500 + 150 * Float(k), f1: 1900 + 150 * Float(k), trill: 0, amp: 0.2,
                       delay: 0.11 * Float(k)))
        }
    }
    func whoosh() {
        play(Sound(kind: .whoosh, dur: 0.85, f0: 0, f1: 0, trill: 0, amp: 0.55))
        play(Sound(kind: .growl, dur: 0.45, f0: 140, f1: 85, trill: 32, amp: 0.3))
    }
    /// Continuous purr level 0…1; call every frame.
    func purr(_ level: Float) {
        purrTarget = sounds ? level : 0
        if purrTarget > 0.01 { ensureRunning() }
    }

    private func play(_ s: Sound) {
        guard sounds else { return }
        ensureRunning()
        lock.lock(); pending.append(s); lock.unlock()
    }

    private func prepareSession() {
        let session = AVAudioSession.sharedInstance()
        if session.category != .playAndRecord {
            try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        }
        try? session.setActive(true)
    }

    private func ensureRunning() {
        guard !engine.isRunning else { return }
        prepareSession()
        try? engine.start()
    }

    // MARK: - synth (audio thread)

    private enum Kind { case chirp, whoosh, growl }
    private struct Sound {
        var kind: Kind
        var dur: Float
        var f0: Float
        var f1: Float
        var trill: Float
        var amp: Float
        var delay: Float = 0
        var age: Float = 0
        var phase: Float = 0
        var filt: Float = 0
    }

    private let engine = AVAudioEngine()
    private var node: AVAudioSourceNode!
    private var sampleRate: Float = 44100
    private let lock = NSLock()
    private var pending: [Sound] = []
    private var active: [Sound] = []
    private var purrTarget: Float = 0
    private var purrLevel: Float = 0
    private var purrPhase: Float = 0
    private var breathPhase: Float = 0
    private var purrFilt: Float = 0
    private var seed: UInt32 = 0x9E3779B9

    private func noise() -> Float {
        seed = seed &* 1664525 &+ 1013904223
        return Float(seed >> 8) / Float(1 << 24) * 2 - 1
    }

    private func render(_ out: UnsafeMutablePointer<Float>, _ n: Int) {
        if lock.try() {
            if !pending.isEmpty { active += pending; pending.removeAll(keepingCapacity: true) }
            lock.unlock()
        }
        let dt = 1 / sampleRate
        let twoPi = 2 * Float.pi
        let target = purrTarget
        for i in 0..<n {
            var s: Float = 0
            purrLevel += (target - purrLevel) * 0.0004
            if purrLevel > 0.002 {
                purrPhase += 25 * dt; if purrPhase >= 1 { purrPhase -= 1 }
                breathPhase += 0.7 * dt; if breathPhase >= 1 { breathPhase -= 1 }
                purrFilt += (noise() - purrFilt) * 0.06
                let pulse = powf(max(0, sinf(twoPi * purrPhase)), 3)
                let breathe = 0.55 + 0.45 * sinf(twoPi * breathPhase)
                s += purrLevel * breathe * pulse * (purrFilt * 2.4 + 0.18 * sinf(twoPi * purrPhase * 2))
            }
            for k in active.indices {
                if active[k].delay > 0 { active[k].delay -= dt; continue }
                let u = active[k].age / active[k].dur
                guard u < 1 else { continue }
                active[k].age += dt
                switch active[k].kind {
                case .chirp:
                    let f = active[k].f0 + (active[k].f1 - active[k].f0) * u * u
                    active[k].phase += f * dt; if active[k].phase >= 1 { active[k].phase -= 1 }
                    let env = powf(sinf(Float.pi * u), 1.5)
                    let tr = active[k].trill > 0 ? 0.55 + 0.45 * sinf(twoPi * active[k].trill * active[k].age) : 1
                    let ph = twoPi * active[k].phase
                    s += active[k].amp * env * tr * (sinf(ph) + 0.25 * sinf(2 * ph))
                case .whoosh:
                    let cut = 0.35 * (1 - u) + 0.02
                    active[k].filt += (noise() - active[k].filt) * cut
                    let env = min(1, u / 0.06) * powf(1 - u, 1.4)
                    s += active[k].amp * env * active[k].filt
                case .growl:
                    let f = active[k].f0 + (active[k].f1 - active[k].f0) * u
                    active[k].phase += f * dt; if active[k].phase >= 1 { active[k].phase -= 1 }
                    let env = min(1, u / 0.1) * (1 - u)
                    let tr = 0.6 + 0.4 * sinf(twoPi * active[k].trill * active[k].age)
                    let saw = 2 * active[k].phase - 1
                    s += active[k].amp * env * tr * saw
                }
            }
            out[i] = tanhf(s * 1.2)
        }
        active.removeAll { $0.age >= $0.dur }
    }
}
