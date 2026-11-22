// Firepearl's mind: hold to talk, the words go to the chat server, the reply comes back to be spoken.
// The server address and PIN are typed on the phone once; neither lives in this repo.
import Foundation
import Speech
import AVFoundation

final class SkyLink: ObservableObject {
    @Published var status = ""
    @Published var listening = false
    @Published var busy = false

    /// Filled in at build time from a repository secret (empty in a local build).
    static let builtInServer = (Bundle.main.object(forInfoDictionaryKey: "ARTSkyServer") as? String ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)

    var server: String {
        get { UserDefaults.standard.string(forKey: "skyServer") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "skyServer") }
    }
    var connected: Bool {
        get { UserDefaults.standard.bool(forKey: "skyConnected") && !server.isEmpty }
        set { UserDefaults.standard.set(newValue, forKey: "skyConnected") }
    }

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var heard = ""
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-CA")) ?? SFSpeechRecognizer()

    // MARK: - connecting

    func connect(server raw: String, pin: String, done: @escaping (Bool) -> Void) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.isEmpty && !s.lowercased().hasPrefix("http") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s + "/api/login") else { status = "that address doesn't look right"; done(false); return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["pin": pin])
        status = "connecting…"
        URLSession.shared.dataTask(with: req) { _, response, error in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            DispatchQueue.main.async {
                if ok {
                    self.server = s
                    self.connected = true
                    self.status = "connected"
                } else {
                    self.status = error != nil ? "couldn't reach it" : "wrong PIN or address"
                }
                appLog.notice("app: sky connect ok=\(ok)")
                done(ok)
            }
        }.resume()
    }

    func disconnect() {
        connected = false
        for c in HTTPCookieStorage.shared.cookies ?? [] where server.contains(c.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))) {
            HTTPCookieStorage.shared.deleteCookie(c)
        }
        status = "not connected"
    }

    // MARK: - talking

    /// Sends what Ava said; the reply (spoken text) and the action tag come back on the main queue.
    func send(_ text: String, done: @escaping (_ reply: String?, _ action: String?) -> Void) {
        guard connected, let url = URL(string: server + "/api/chat") else { done(nil, nil); return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 45
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["message": text, "form": "firepearl"])
        busy = true
        status = "thinking…"
        URLSession.shared.dataTask(with: req) { data, response, _ in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            DispatchQueue.main.async {
                self.busy = false
                if code == 401 {
                    self.connected = false
                    self.status = "the PIN expired: connect again"
                    done(nil, nil)
                } else if let reply = json?["reply"] as? String {
                    self.status = "said: \(reply)"
                    done(reply, json?["action"] as? String)
                } else {
                    self.status = "couldn't reach Sky (\(code))"
                    done(nil, nil)
                }
                appLog.notice("app: sky reply code=\(code)")
            }
        }.resume()
    }

    // MARK: - listening (same recipe as the LOOK voice note)

    func startListening() {
        guard !listening else { return }
        listening = true
        heard = ""
        status = "listening…"
        SFSpeechRecognizer.requestAuthorization { auth in
            AVAudioApplication.requestRecordPermission { granted in
                DispatchQueue.main.async {
                    guard auth == .authorized, granted else { self.status = "speech or microphone not allowed"; return }
                    if self.listening { self.beginListening() }
                }
            }
        }
    }

    private func beginListening() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker])
        try? session.setActive(true)
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        request = req
        guard let recognizer, recognizer.isAvailable else { status = "speech recognizer not available"; return }
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in req.append(buffer) }
        engine.prepare()
        do { try engine.start() } catch { status = "microphone didn't start"; return }
        task = recognizer.recognitionTask(with: req) { result, _ in
            DispatchQueue.main.async {
                if let result {
                    self.heard = result.bestTranscription.formattedString
                    self.status = "heard: \(self.heard)"
                }
            }
        }
    }

    /// Stops listening; hands back what was heard (empty if nothing).
    func stopListening(_ done: @escaping (String) -> Void) {
        guard listening else { done(""); return }
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
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
            done(self.heard.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
