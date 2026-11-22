// ARToronto app entry and build label.
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
    static var label: String {
        let value = Bundle.main.object(forInfoDictionaryKey: "ARTBuildLabel") as? String ?? ""
        return value.isEmpty ? "local" : value
    }
}
