import SwiftUI
import Network
import UIKit

// LOOK: send what the app sees to the studio computer on the same Wi-Fi.
//
// The studio receiver (a small script on the studio computer) announces itself over
// Bonjour as "_skyelook._tcp", so no address lives in the app. A LOOK sends the
// AR picture, the HUD readings and a note (type it, or dictate with the
// keyboard's mic); LIVE sends a smaller frame every few seconds instead of
// screen mirroring.

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

    func send(kind: String, app: String, note: String, info: [String: String], image: UIImage?, maxWidth: CGFloat) {
        guard let endpoint else { state = "studio not found on this Wi-Fi"; return }
        var body: [String: Any] = ["kind": kind, "app": app, "note": note, "info": info,
                                   "time": ISO8601DateFormatter().string(from: Date())]
        if let image, let jpg = Self.shrink(image, maxWidth: maxWidth).jpegData(compressionQuality: kind == "look" ? 0.8 : 0.5) {
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
                DispatchQueue.main.async { self?.state = ok ? "\(kind) sent \(time) ✓" : "studio didn't accept it" }
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

/// The LOOK row: a note field, LOOK, and LIVE.
struct LookBar: View {
    @ObservedObject var look: LookClient
    let app: String
    /// The HUD readings to send along.
    let info: () -> [String: String]
    /// Grab the AR picture (ARView.snapshot), then call back.
    let snapshot: (@escaping (UIImage?) -> Void) -> Void
    @State private var note = ""
    @State private var live = false
    private let tick = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                TextField("note for Skye (🎤 to dictate)", text: $note)
                    .font(.system(size: 13))
                    .padding(.horizontal, 8)
                    .frame(height: 36)
                    .background(.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(.black)
                Button {
                    let n = note
                    snapshot { image in
                        look.send(kind: "look", app: app, note: n, info: info(), image: image, maxWidth: 1290)
                    }
                    note = ""
                } label: {
                    Label("LOOK", systemImage: "eye.fill")
                        .font(.system(size: 13, weight: .heavy, design: .rounded))
                        .frame(width: 84, height: 36)
                        .foregroundStyle(.white)
                        .background(Color.orange, in: RoundedRectangle(cornerRadius: 10))
                }
                Button { live.toggle() } label: {
                    Text(live ? "LIVE ●" : "LIVE")
                        .font(.system(size: 12, weight: .heavy, design: .rounded))
                        .frame(width: 58, height: 36)
                        .foregroundStyle(.white)
                        .background(live ? Color.red : Color.gray, in: RoundedRectangle(cornerRadius: 10))
                }
            }
            Text(look.state).font(.system(size: 10, design: .monospaced)).foregroundStyle(.white)
        }
        .onReceive(tick) { _ in
            guard live else { return }
            snapshot { image in look.send(kind: "live", app: app, note: "", info: info(), image: image, maxWidth: 540) }
        }
    }
}
