import SwiftUI

@main
struct ArtorontoApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

enum BuildInfo {
    /// Set by CI as "<run number>-<short commit>", so the HUD shows which build is on the phone.
    static var label: String {
        let value = Bundle.main.object(forInfoDictionaryKey: "ARTBuildLabel") as? String ?? ""
        return value.isEmpty ? "local" : value
    }
}
