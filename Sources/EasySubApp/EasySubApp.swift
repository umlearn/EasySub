import SwiftUI
import UserNotifications

enum VideoSortField: String, Sendable {
    case added, name, size, status
}

enum VideoSortDirection: String, Sendable {
    case ascending, descending
}

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
            MainWindowCommands()
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
                Button("Report an Issue") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/umlearn/EasySub/issues")!)
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

struct MainWindowCommandActions {
    var hasSelection = false
    var hasSingleSelection = false
    var hasCompletedItems = false
    var hasItems = false
    var hasPendingItems = false
    var canMarkPending = false
    var canMarkCompleted = false
    var isRunning = false
    var isSearchExpanded = false
    var sortField: VideoSortField = .added
    var sortDirection: VideoSortDirection = .ascending

    var removeSelected: () -> Void = {}
    var clearCompleted: () -> Void = {}
    var clearAll: () -> Void = {}
    var showInFinder: () -> Void = {}
    var downloadPending: () -> Void = {}
    var cancelDownload: () -> Void = {}
    var searchSubtitlesManually: () -> Void = {}
    var markPending: () -> Void = {}
    var markCompleted: () -> Void = {}
    var findVideos: () -> Void = {}
    var closeSearch: () -> Void = {}
    var showAll: () -> Void = {}
    var showPending: () -> Void = {}
    var showCompleted: () -> Void = {}
    var showNeedsAttention: () -> Void = {}
    var setSortField: (VideoSortField) -> Void = { _ in }
    var setSortDirection: (VideoSortDirection) -> Void = { _ in }
}

extension FocusedValues {
    @Entry var mainWindowCommands: MainWindowCommandActions?
}

private struct MainWindowCommands: Commands {
    @FocusedValue(\.mainWindowCommands) private var actions

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Remove selected") { actions?.removeSelected() }
                .disabled(actions?.hasSelection != true || actions?.isRunning == true)

            Divider()

            Button("Clear completed") { actions?.clearCompleted() }
                .disabled(actions?.hasCompletedItems != true || actions?.isRunning == true)
            Button("Clear all videos") { actions?.clearAll() }
                .disabled(actions?.hasItems != true || actions?.isRunning == true)

            Divider()

            Button("Show in Finder") { actions?.showInFinder() }
                .disabled(actions?.hasSelection != true)
        }

        CommandMenu("Subtitles") {
            Button("Download pending") { actions?.downloadPending() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(actions?.hasPendingItems != true || actions?.isRunning == true)
            Button("Cancel") { actions?.cancelDownload() }
                .disabled(actions?.isRunning != true)

            Divider()

            Button("Search subtitles manually") { actions?.searchSubtitlesManually() }
                .disabled(actions?.hasSingleSelection != true || actions?.isRunning == true)

            Divider()

            Button("Mark as Pending") { actions?.markPending() }
                .disabled(actions?.canMarkPending != true || actions?.isRunning == true)
            Button("Mark as Completed") { actions?.markCompleted() }
                .disabled(actions?.canMarkCompleted != true || actions?.isRunning == true)
        }

        CommandGroup(after: .sidebar) {
            Button("Find videos") { actions?.findVideos() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(actions == nil)
            Button("Close search") { actions?.closeSearch() }
                .disabled(actions?.isSearchExpanded != true)

            Divider()

            Button("All videos") { actions?.showAll() }
                .keyboardShortcut("1", modifiers: .command)
                .disabled(actions == nil)
            Button("Pending") { actions?.showPending() }
                .keyboardShortcut("2", modifiers: .command)
                .disabled(actions == nil)
            Button("Completed") { actions?.showCompleted() }
                .keyboardShortcut("3", modifiers: .command)
                .disabled(actions == nil)
            Button("Needs attention") { actions?.showNeedsAttention() }
                .keyboardShortcut("4", modifiers: .command)
                .disabled(actions == nil)

            Divider()

            Menu("Sort By") {
                sortFieldToggle("Added Order", field: .added)
                sortFieldToggle("Name", field: .name)
                sortFieldToggle("Size", field: .size)
                sortFieldToggle("Status", field: .status)
            }
            .disabled(actions == nil)

            Menu("Sort Order") {
                if actions?.sortField == .added {
                    sortDirectionToggle("Earliest Added First", direction: .ascending)
                    sortDirectionToggle("Recently Added First", direction: .descending)
                } else {
                    sortDirectionToggle("Ascending", direction: .ascending)
                    sortDirectionToggle("Descending", direction: .descending)
                }
            }
            .disabled(actions == nil)
        }
    }

    private func sortFieldToggle(_ title: LocalizedStringKey, field: VideoSortField) -> some View {
        Toggle(title, isOn: Binding(
            get: { actions?.sortField == field },
            set: { if $0 { actions?.setSortField(field) } }
        ))
    }

    private func sortDirectionToggle(_ title: LocalizedStringKey, direction: VideoSortDirection) -> some View {
        Toggle(title, isOn: Binding(
            get: { actions?.sortDirection == direction },
            set: { if $0 { actions?.setSortDirection(direction) } }
        ))
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
