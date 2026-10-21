import SwiftUI
import UserNotifications

struct SettingsView: View {
    private let browseOutputDirectoryTag = "__browse_subtitle_output_directory__"
    @State private var language = ApplicationLanguage.current()
    @AppStorage("SZSubTypeKey") private var preference = "ASS"
    @AppStorage("renameSubtitles") private var renameSubtitles = true
    @AppStorage("overwriteSubtitles") private var overwrite = false
    @AppStorage("subtitleOutputDirectory") private var subtitleOutputDirectory = ""
    @AppStorage("notifyOnCompletion") private var notify = false
    @State private var notificationMessage: String?

    @AppStorage("sourceShooter") private var shooter = false
    @AppStorage("sourceXunlei") private var xunlei = true
    @AppStorage("sourceAssrt") private var assrt = false
    @AppStorage("assrtToken") private var token = ""
    @State private var isEditingToken = false
    @FocusState private var tokenIsFocused: Bool

    var body: some View {
        Form {
            Section("Language") {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("App language", selection: $language) {
                        Text("Follow system").tag(ApplicationLanguage.system)
                        Text(verbatim: "简体中文").tag(ApplicationLanguage.simplifiedChinese)
                        Text(verbatim: "English").tag(ApplicationLanguage.english)
                    }
                    .onChange(of: language) { language.save() }
                    Text("Language changes take effect the next time you open EasySub. Finish your downloads before quitting.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Downloads") {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("Preferred format", selection: $preference) {
                        Text("ASS first").tag("ASS")
                        Text("SRT first").tag("SRT")
                        Text("Both").tag("BOTH")
                    }
                    Text("If the preferred format is unavailable, the other format is tried. Both downloads one subtitle of each format when available.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Rename subtitle files", isOn: $renameSubtitles)
                    Text("Rename subtitle files to match the video name. When off, subtitles keep their source names.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Replace existing subtitles", isOn: $overwrite)
                    Text("Only subtitles with the same filename are replaced.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Picker("Subtitle output folder", selection: outputDirectorySelection) {
                        Text("Same as video").tag("")
                        if !subtitleOutputDirectory.isEmpty {
                            Text(subtitleOutputDirectory)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .tag(subtitleOutputDirectory)
                        }
                        Divider()
                        Text("Browse…").tag(browseOutputDirectoryTag)
                    }
                    .help(subtitleOutputDirectory)
                    Text("Subtitles are saved beside each video by default. Choose a folder to save all downloaded subtitles there.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Shooter", isOn: $shooter)
                    Text("Legacy fingerprint service. Off by default because matches are now rare.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Xunlei (filename search)", isOn: $xunlei)
                Toggle("ASSRT (requires token)", isOn: $assrt)
                if assrt {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 20) {
                            Text("ASSRT token")
                            Spacer(minLength: 20)
                            tokenField
                        }
                        HStack(spacing: 4) {
                            Text("Provided by assrt.net")
                                .foregroundStyle(.secondary)
                            Link("Get token", destination: URL(string: "https://assrt.net/usercp.php")!)
                        }
                        .font(.caption)
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("Subtitle sources")
            } footer: {
                Text("Automatic matching compares title, year, season and episode. Use manual search when no candidate is safe to select. Video content stays on your Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Notifications") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Notify when a batch finishes", isOn: $notify)
                        .onChange(of: notify) {
                            guard notify else { return }
                            Task {
                                do {
                                    if try await !UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) {
                                        notify = false
                                        notificationMessage = String(localized: "Allow notifications for EasySub in System Settings.")
                                    }
                                } catch { notify = false; notificationMessage = error.localizedDescription }
                            }
                        }
                    if let notificationMessage { Text(notificationMessage).font(.caption).foregroundStyle(.secondary) }
                }
            }
            Section("About") {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Version", value: appVersion)
                    Text("Shooter · Xunlei · ASSRT")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Link("Source code & credits", destination: URL(string: "https://github.com/umlearn/EasySub")!)
            }
        }.formStyle(.grouped).frame(width: 580, height: 760)
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var outputDirectorySelection: Binding<String> {
        Binding(
            get: { subtitleOutputDirectory },
            set: { selection in
                if selection == browseOutputDirectoryTag {
                    chooseOutputDirectory()
                } else {
                    subtitleOutputDirectory = selection
                }
            }
        )
    }

    private func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose")
        if !subtitleOutputDirectory.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: subtitleOutputDirectory, isDirectory: true)
        }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            subtitleOutputDirectory = url.standardizedFileURL.path
        }
    }

    @ViewBuilder private var tokenField: some View {
        if isEditingToken {
            TextField("", text: $token)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .focused($tokenIsFocused)
                .task {
                    try? await Task.sleep(for: .milliseconds(80))
                    tokenIsFocused = true
                }
                .onSubmit {
                    tokenIsFocused = false
                    isEditingToken = false
                    token = token.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                .onChange(of: tokenIsFocused) {
                    guard !tokenIsFocused else { return }
                    isEditingToken = false
                    token = token.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                .frame(width: 340, alignment: .trailing)
                .overlay(alignment: .trailing) {
                    if token.isEmpty {
                        Text("input your token here")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.trailing, 3)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .accessibilityLabel("ASSRT token")
        } else {
            Button { isEditingToken = true } label: {
                Group {
                    if token.isEmpty {
                        Text("input your token here")
                    } else {
                        Text(verbatim: String(repeating: "•", count: 18))
                    }
                }
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .buttonStyle(.plain)
            .frame(width: 340)
            .accessibilityLabel("ASSRT token")
        }
    }
}
