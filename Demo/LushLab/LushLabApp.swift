import SwiftUI

/// LushLab — the harness app for LushKit. Logs into mvServer (real JWT via
/// MvAuth), then hosts the kit exactly the way a production host does: engine
/// built inert with an injected token provider, running only while its screen
/// is up and the app is in front, wiped on sign-out.
/// All lush UI development happens here, not inside a production host.
@main
struct LushLabApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .tint(.pink)
        }
    }
}
