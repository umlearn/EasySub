import SwiftUI
import UserNotifications

@main
struct EasySubApp: App {
    @State private var store = DownloadStore()
#if DEBUG
    @State private var updateChecker = UpdateChecker(
        currentVersion: ProcessInfo.processInfo.arguments.contains("--simulate-update-available")
            ? "0.0.0"
            : nil
    )
#else
    @State private var updateChecker = UpdateChecker()
#endif
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("EasySub", id: "main") {
            ContentView(store: store)
                .environment(updateChecker)
                .task { await updateChecker.performAutomaticCheckIfNeeded() }
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
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    Task { await updateChecker.checkForUpdates(from: .menu) }
                }
                .disabled(updateChecker.isChecking)
            }
            CommandGroup(replacing: .help) {
                Button("EasySub Help") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/umlearn/EasySub")!)
                }
            }
        }
        Window("EasySub Settings", id: "settings") {
            SettingsView()
                .environment(updateChecker)
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
