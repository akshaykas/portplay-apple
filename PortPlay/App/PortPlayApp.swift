import SwiftUI

@main
struct PortPlayApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    @StateObject private var model = AppModel()

    var body: some Scene {
        #if os(macOS)
        // A single window, since every window would show the same feed
        Window("PortPlay", id: "main") {
            root
        }
        .defaultSize(width: 1280, height: 720)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
        #else
        WindowGroup {
            root
        }
        #endif
    }

    private var root: some View {
        ContentView()
            .environmentObject(model)
    }
}

#if os(macOS)
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Closing the window quits the app, like the Windows version.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
#endif
