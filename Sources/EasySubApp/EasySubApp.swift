import SwiftUI
import UserNotifications

@main
struct EasySubApp: App {
    @State private var store = DownloadStore()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("EasySub", id: "main") {
            ContentView(store: store)
        }
        .defaultSize(width: 1000, height: 680)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add videos") { selectVideos(store: store) }
                    .keyboardShortcut("o")
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { openWindow(id: "settings") }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
        Window("EasySub Settings", id: "settings") {
            SettingsView()
        }
        .defaultSize(width: 580, height: 760)
        .windowResizability(.contentMinSize)
    }
}

@MainActor
func selectVideos(store: DownloadStore) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = true
    panel.prompt = String(localized: "Add videos")
    panel.begin { response in
        if response == .OK {
            let urls = panel.urls
            Task { await store.add(urls) }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { sender.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil) }
        return true
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
