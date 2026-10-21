import SwiftUI
import UserNotifications

struct SettingsView: View {
    private let browseOutputDirectoryTag = "__browse_subtitle_output_directory__"
    @Environment(\.locale) private var locale
    @State private var language = ApplicationLanguage.current()
    @AppStorage("SZSubTypeKey") private var preference = "ASS"
    @AppStorage("renameSubtitles") private var renameSubtitles = true
    @AppStorage("overwriteSubtitles") private var overwrite = false
    @AppStorage("subtitleOutputDirectory") private var subtitleOutputDirectory = ""
    @AppStorage("notifyOnCompletion") private var notify = false
    @AppStorage("subtitleLanguagePrimary") private var primaryLanguage = SubtitleLanguageCatalog.defaultCodes[0]
    @AppStorage("subtitleLanguageSecondary") private var secondaryLanguage = SubtitleLanguageCatalog.defaultCodes[1]
    @AppStorage("subtitleLanguageTertiary") private var tertiaryLanguage = SubtitleLanguageCatalog.defaultCodes[2]
    @State private var notificationMessage: String?
    @State private var editingLanguageCode: String?
    @State private var draggingLanguageCode: String?
    @State private var dragOffset: CGFloat = 0

    @AppStorage("sourceShooter") private var shooter = false
    @AppStorage("sourceXunlei") private var xunlei = true
    @AppStorage("sourceAssrt") private var assrt = true
    @AppStorage("assrtToken") private var token = ""
    @AppStorage("sourceOpenSubtitles") private var openSubtitles = false
    @AppStorage("openSubtitlesAPIKey") private var openSubtitlesAPIKey = ""
    @State private var isEditingToken = false
    @State private var isEditingOpenSubtitlesKey = false
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
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        Text("Subtitle languages")
                        Spacer(minLength: 12)
                        HStack(spacing: 8) {
                            ForEach(Array(selectedLanguageCodes.enumerated()), id: \.element) { index, code in
                                languageTag(code: code, index: index)
                            }
                            if selectedLanguageCodes.count < 3 {
                                addLanguageTag
                            }
                        }
                    }
                    Text("Drag tags to reorder. Automatic downloads try languages in this order; manual search still shows all languages.")
                        .font(.caption).foregroundStyle(.secondary)
                }
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
                    if token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Enter an ASSRT token to enable this source.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Shooter", isOn: $shooter)
                    Text("Legacy fingerprint service. Off by default because matches are now rare.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("OpenSubtitles (requires API key)", isOn: $openSubtitles)
                if openSubtitles {
                    credentialRow(label: "OpenSubtitles API key", value: $openSubtitlesAPIKey,
                                  editing: $isEditingOpenSubtitlesKey,
                                  linkTitle: "Get API key", link: "https://www.opensubtitles.com/consumers")
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
                    Text("Xunlei · ASSRT · Shooter · OpenSubtitles")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Link("Source code & credits", destination: URL(string: "https://github.com/umlearn/EasySub")!)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 580, idealWidth: 580, maxWidth: .infinity,
               minHeight: 480, idealHeight: 760, maxHeight: .infinity)
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var selectedLanguageCodes: [String] {
        SubtitleLanguageCatalog.normalizedPreferences(
            [primaryLanguage, secondaryLanguage, tertiaryLanguage]
        )
    }

    private var unselectedLanguages: [SubtitleLanguage] {
        SubtitleLanguageCatalog.all.filter { !selectedLanguageCodes.contains($0.code) }
    }

    @ViewBuilder private func languageTag(code: String, index: Int) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "line.3.horizontal")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.vertical, 3)
                .padding(.horizontal, 2)
                .contentShape(Rectangle())
            Text(verbatim: SubtitleLanguageCatalog.displayName(for: code, in: locale))
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .contentShape(Rectangle())
                .onTapGesture { editingLanguageCode = code }
        }
        .padding(.leading, 5)
        .padding(.trailing, 9)
        .padding(.vertical, 5)
        .fixedSize()
        .background {
            Capsule().fill(index == 0 ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.06))
        }
        .overlay {
            Capsule().stroke(
                index == 0 ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.12),
                lineWidth: 1
            )
        }
        .offset(x: draggingLanguageCode == code ? dragOffset : 0)
        .scaleEffect(draggingLanguageCode == code ? 1.04 : 1)
        .shadow(color: .black.opacity(draggingLanguageCode == code ? 0.24 : 0),
                radius: draggingLanguageCode == code ? 8 : 0, y: 4)
        .zIndex(draggingLanguageCode == code ? 1 : 0)
        .contentShape(Capsule())
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    editingLanguageCode = nil
                    draggingLanguageCode = code
                    dragOffset = value.translation.width
                }
                .onEnded { value in
                    let horizontal = value.translation.width
                    withAnimation(.easeOut(duration: 0.15)) {
                        dragOffset = 0
                        draggingLanguageCode = nil
                    }
                    guard abs(horizontal) >= 16 else { return }
                    moveLanguage(at: index, by: horizontal > 0 ? 1 : -1)
                }
        )
        .popover(isPresented: languageEditorPresented(for: code), arrowEdge: .bottom) {
            languageEditor(for: code, index: index)
        }
        .help("Drag to change order. Click to choose another language.")
        .accessibilityLabel(languageName(for: code))
    }

    private var addLanguageTag: some View {
        Menu {
            ForEach(unselectedLanguages) { language in
                Button {
                    var languages = selectedLanguageCodes
                    languages.append(language.code)
                    saveLanguageCodes(languages)
                } label: {
                    Text(verbatim: language.displayName(in: locale))
                }
            }
        } label: {
            Label("Add", systemImage: "plus")
                .font(.caption.weight(.medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background { Capsule().fill(Color.primary.opacity(0.06)) }
        .overlay { Capsule().stroke(Color.primary.opacity(0.12), lineWidth: 1) }
        .contentShape(Capsule())
        .help("Add another subtitle language.")
    }

    private func languageEditorPresented(for code: String) -> Binding<Bool> {
        Binding(
            get: { editingLanguageCode == code },
            set: { if !$0 { editingLanguageCode = nil } }
        )
    }

    @ViewBuilder private func languageEditor(for code: String, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.tertiary)
                Text(verbatim: languageName(for: code))
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            HStack(spacing: 12) {
                if index > 0 {
                    Button {
                        editingLanguageCode = nil
                        moveLanguage(at: index, by: -1)
                    } label: {
                        Label("Move left", systemImage: "arrow.left")
                    }
                }
                if index < selectedLanguageCodes.count - 1 {
                    Button {
                        editingLanguageCode = nil
                        moveLanguage(at: index, by: 1)
                    } label: {
                        Label("Move right", systemImage: "arrow.right")
                    }
                }
                Spacer()
                if index > 0 {
                    Button("Remove", role: .destructive) {
                        editingLanguageCode = nil
                        var languages = selectedLanguageCodes
                        languages.remove(at: index)
                        saveLanguageCodes(languages)
                    }
                }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(SubtitleLanguageCatalog.all.filter {
                        $0.code == code || !selectedLanguageCodes.contains($0.code)
                    }) { language in
                        Button {
                            editingLanguageCode = nil
                            var languages = selectedLanguageCodes
                            languages[index] = language.code
                            saveLanguageCodes(languages)
                        } label: {
                            HStack {
                                Text(verbatim: language.displayName(in: locale))
                                Spacer()
                                if language.code == code {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 280)
        }
        .frame(width: 230)
    }

    private func languageName(for code: String) -> String {
        guard !code.isEmpty else { return String(localized: "None") }
        return SubtitleLanguageCatalog.displayName(for: code, in: locale)
    }

    private func moveLanguage(at index: Int, by offset: Int) {
        var languages = selectedLanguageCodes
        let destination = index + offset
        guard languages.indices.contains(index), languages.indices.contains(destination) else { return }
        languages.swapAt(index, destination)
        saveLanguageCodes(languages)
    }

    private func saveLanguageCodes(_ languages: [String]) {
        let normalized = SubtitleLanguageCatalog.normalizedPreferences(languages)
        primaryLanguage = normalized.first ?? SubtitleLanguageCatalog.defaultCodes[0]
        secondaryLanguage = normalized.indices.contains(1) ? normalized[1] : ""
        tertiaryLanguage = normalized.indices.contains(2) ? normalized[2] : ""
    }

    @ViewBuilder private func credentialRow(label: LocalizedStringKey, value: Binding<String>,
                                             editing: Binding<Bool>, linkTitle: LocalizedStringKey,
                                             link: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 20) {
                Text(label)
                Spacer(minLength: 20)
                if editing.wrappedValue {
                    TextField("", text: value)
                        .textFieldStyle(.plain).multilineTextAlignment(.trailing)
                        .font(.system(.body, design: .monospaced)).lineLimit(1)
                        .onSubmit {
                            value.wrappedValue = value.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
                            editing.wrappedValue = false
                        }
                        .frame(width: 300)
                } else {
                    Button { editing.wrappedValue = true } label: {
                        Text(value.wrappedValue.isEmpty ? "input your API key here" : String(repeating: "•", count: 18))
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .buttonStyle(.plain).frame(width: 300)
                }
            }
            HStack(spacing: 4) {
                Text("Provided by opensubtitles.com").foregroundStyle(.secondary)
                Link(linkTitle, destination: URL(string: link)!)
            }.font(.caption)
        }.padding(.vertical, 4)
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
