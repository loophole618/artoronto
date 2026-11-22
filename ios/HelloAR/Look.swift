// LOOK / LIVE / voice: send the AR view and readings to the studio receiver over Wi-Fi.
import SwiftUI
import Network
import UIKit
import Speech
import AVFoundation

final class LookClient: ObservableObject {
    @Published var state = "looking for the studio on Wi-Fi…"
    private var endpoint: NWEndpoint?
    private let browser = NWBrowser(for: .bonjour(type: "_skyelook._tcp", domain: nil), using: .tcp)

    init() {
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            self.endpoint = results.first?.endpoint
            self.state = self.endpoint == nil ? "studio not found on this Wi-Fi" : "studio found"
        }
        browser.stateUpdateHandler = { [weak self] s in
            if case .failed = s { self?.state = "can't search the Wi-Fi (local network permission?)" }
        }
        browser.start(queue: .main)
    }

    func send(kind: String, app: String, note: String, info: [String: String], image: UIImage?, maxWidth: CGFloat,
              extra: [String: Any] = [:]) {
        guard let endpoint else { state = "studio not found on this Wi-Fi"; return }
        var body: [String: Any] = ["kind": kind, "app": app, "note": note, "info": info,
                                   "time": ISO8601DateFormatter().string(from: Date())]
        for (k, v) in extra { body[k] = v }
        if let image, let jpg = Self.shrink(image, maxWidth: maxWidth).jpegData(compressionQuality: kind == "look" ? 0.8 : 0.6) {
            body["jpeg"] = jpg.base64EncodedString()
        }
        guard let json = try? JSONSerialization.data(withJSONObject: body) else { return }
        var request = Data("POST /look HTTP/1.1\r\nHost: studio\r\nContent-Type: application/json\r\nContent-Length: \(json.count)\r\nConnection: close\r\n\r\n".utf8)
        request.append(json)

        let conn = NWConnection(to: endpoint, using: .tcp)
        conn.stateUpdateHandler = { [weak self] s in
            if case .failed(let e) = s { DispatchQueue.main.async { self?.state = "send failed: \(e)" }; conn.cancel() }
        }
        conn.start(queue: .global(qos: .utility))
        conn.send(content: request, completion: .contentProcessed { [weak self] error in
            if let error { DispatchQueue.main.async { self?.state = "send failed: \(error)" }; conn.cancel(); return }
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1024) { data, _, _, _ in
                let ok = data.flatMap { String(data: $0, encoding: .utf8) }?.contains(" 200 ") ?? false
                let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
                if kind != "live" {
                    DispatchQueue.main.async { self?.state = ok ? "\(kind) sent \(time) ✓" : "studio didn't accept it" }
                }
                conn.cancel()
            }
        })
    }

    private static func shrink(_ image: UIImage, maxWidth: CGFloat) -> UIImage {
        guard image.size.width > maxWidth else { return image }
        let size = CGSize(width: maxWidth, height: image.size.height * maxWidth / image.size.width)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }
}

final class VoiceNote: ObservableObject {
    @Published var text = ""
    @Published var listening = false
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-CA")) ?? SFSpeechRecognizer()

    func start() {
        guard !listening else { return }
        listening = true
        text = ""
        SFSpeechRecognizer.requestAuthorization { status in
            AVAudioApplication.requestRecordPermission { granted in
                DispatchQueue.main.async {
                    guard status == .authorized, granted else { self.text = "(speech or microphone not allowed)"; return }
                    if self.listening { self.begin() }
                }
            }
        }
    }

    private func begin() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker])
        try? session.setActive(true)
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        request = req
        guard let recognizer, recognizer.isAvailable else {
            text = "(speech recognizer not available)"
            appLog.notice("app: voice recognizer unavailable")
            return
        }
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in req.append(buffer) }
        engine.prepare()
        do { try engine.start() } catch {
            text = "(microphone didn't start: \(error.localizedDescription))"
            appLog.notice("app: voice engine failed \(String(describing: error), privacy: .public)")
            return
        }
        appLog.notice("app: voice listening")
        task = recognizer.recognitionTask(with: req) { result, error in
            DispatchQueue.main.async {
                if let result { self.text = result.bestTranscription.formattedString }
                if let error, self.text.isEmpty {
                    self.text = "(speech error: \(error.localizedDescription))"
                    appLog.notice("app: voice error \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    func stop(_ done: @escaping (String) -> Void) {
        listening = false
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            self.task?.cancel()
            self.task = nil
            self.request = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            appLog.notice("app: voice done \(self.text, privacy: .public)")
            done(self.text.isEmpty ? "(no words heard)" : self.text)
        }
    }
}

struct LookBar: View {
    @ObservedObject var look: LookClient
    let app: String
    let fps: Double
    let info: () -> [String: String]
    let snapshot: (@escaping (UIImage?) -> Void) -> Void
    @StateObject private var voice = VoiceNote()
    @State private var note = ""
    @State private var live = false
    @State private var liveSession = ""
    @State private var liveCount = 0
    @State private var lastFrame = Date.distantPast
    private let tick = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: voice.listening ? "mic.fill" : "mic")
                    .font(.system(size: 17, weight: .bold))
                    .frame(width: 44, height: 36)
                    .foregroundStyle(.white)
                    .background(voice.listening ? Color.red : Color.blue, in: RoundedRectangle(cornerRadius: 10))
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { _ in if !voice.listening { voice.start() } }
                        .onEnded { _ in
                            snapshot { image in
                                voice.stop { words in
                                    look.send(kind: "look", app: app, note: words, info: info(), image: image, maxWidth: 1290)
                                }
                            }
                        })
                TextField(voice.listening ? "listening…" : "note (or hold 🎤)", text: voice.listening ? $voice.text : $note)
                    .font(.system(size: 13))
                    .padding(.horizontal, 8)
                    .frame(height: 36)
                    .background(.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(.black)
                Button {
                    let n = note
                    snapshot { image in look.send(kind: "look", app: app, note: n, info: info(), image: image, maxWidth: 1290) }
                    note = ""
                } label: {
                    Image(systemName: "eye.fill")
                        .font(.system(size: 15, weight: .bold))
                        .frame(width: 48, height: 36)
                        .foregroundStyle(.white)
                        .background(Color.orange, in: RoundedRectangle(cornerRadius: 10))
                }
                Button { toggleLive() } label: {
                    Text(live ? "■ \(liveCount)" : "LIVE")
                        .font(.system(size: 12, weight: .heavy, design: .rounded))
                        .frame(width: 58, height: 36)
                        .foregroundStyle(.white)
                        .background(live ? Color.red : Color.gray, in: RoundedRectangle(cornerRadius: 10))
                }
            }
            Text(look.state).font(.system(size: 10, design: .monospaced)).foregroundStyle(.white)
        }
        .onReceive(tick) { now in
            guard live, now.timeIntervalSince(lastFrame) >= 1 / max(fps, 0.1) else { return }
            lastFrame = now
            liveCount += 1
            let seq = liveCount, session = liveSession
            snapshot { image in
                look.send(kind: "live", app: app, note: "", info: info(), image: image, maxWidth: 720,
                          extra: ["session": session, "seq": seq])
            }
        }
    }

    private func toggleLive() {
        if live {
            live = false
            look.send(kind: "liveend", app: app, note: "", info: info(), image: nil, maxWidth: 720,
                      extra: ["session": liveSession, "frames": liveCount])
        } else {
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd-HHmmss"
            liveSession = f.string(from: Date())
            liveCount = 0
            lastFrame = .distantPast
            live = true
        }
    }
}
