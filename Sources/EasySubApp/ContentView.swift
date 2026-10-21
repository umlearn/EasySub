import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

private enum QueueFilter: String, CaseIterable, Identifiable {
    case all, pending, completed, attention
    var id: Self { self }
    var title: LocalizedStringKey {
        switch self {
        case .all: "All videos"
        case .pending: "Pending"
        case .completed: "Completed"
        case .attention: "Needs attention"
        }
    }
    var symbol: String {
        switch self {
        case .all: "film.stack"
        case .pending: "clock"
        case .completed: "checkmark.circle"
        case .attention: "exclamationmark.circle"
        }
    }
    func includes(_ item: DownloadItem) -> Bool {
        switch self {
        case .all: true
        case .pending: [.ready, .queued, .downloading, .cancelled].contains(item.status)
        case .completed: item.status == .completed
        case .attention: [.failed, .partial].contains(item.status)
        }
    }
}

private enum ContentFocus: Hashable {
    case sidebar, videos
}

struct ContentView: View {
    @Bindable var store: DownloadStore
    @State private var selection = Set<URL>()
    @State private var filter: QueueFilter? = .all
    @State private var search = ""
    @State private var searchIsExpanded = false
    @State private var showSubtitles = false
    @State private var configurationError: String?
    @State private var isDropTarget = false
    @State private var contentWidth: CGFloat = 820
    @FocusState private var searchIsFocused: Bool
    @FocusState private var contentFocus: ContentFocus?
    @AppStorage("SZSubTypeKey") private var preference = SubtitlePreference.ass.rawValue
    @AppStorage("renameSubtitles") private var renameSubtitles = true
    @AppStorage("overwriteSubtitles") private var overwrite = false
    @AppStorage("subtitleOutputDirectory") private var subtitleOutputDirectory = ""
    @AppStorage("notifyOnCompletion") private var notify = false

    private var visibleItems: [DownloadItem] {
        store.items.filter {
            (filter ?? .all).includes($0) && (search.isEmpty || $0.video.url.lastPathComponent.localizedCaseInsensitiveContains(search))
        }
    }

    private var selectedItem: DownloadItem? {
        guard selection.count == 1 else { return nil }
        return store.items.first { selection.contains($0.id) }
    }

    private var completedSelectedItem: DownloadItem? {
        guard let item = selectedItem,
              item.status == .completed,
              !item.detail.isEmpty else { return nil }
        return item
    }

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 10) {
                    Image("EasySubMark")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 48, height: 48)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading) {
                        Text(verbatim: "EasySub").font(.headline)
                        Text("Subtitles, simplified.").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.horizontal, 16).padding(.top, 24)
                List(QueueFilter.allCases, selection: $filter) { item in
                    HStack {
                        Label(item.title, systemImage: item.symbol)
                        Spacer()
                        Text("\(store.items.filter { item.includes($0) }.count)")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }.tag(item)
                }
                .listStyle(.sidebar)
                .focused($contentFocus, equals: .sidebar)
                SettingsLink { Label("Settings", systemImage: "gearshape") }
                    .buttonStyle(.borderless)
                    .padding(16)
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 280)
        } detail: {
            VStack(spacing: 0) {
                header
                Divider()
                if store.items.isEmpty {
                    ContentUnavailableView {
                        Label("Drop your videos here", systemImage: "arrow.down.doc")
                    } description: {
                        Text("Add video files or folders. Subtitles are saved beside each video.")
                    } actions: {
                        Button("Add videos") { selectVideos(store: store) }.buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Table(visibleItems, selection: $selection) {
                        TableColumn("Video") { item in
                            HStack(spacing: 10) {
                                Image(systemName: "film").foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.video.url.lastPathComponent).lineLimit(1)
                                    Text(item.video.url.deletingLastPathComponent().path)
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                }.padding(.vertical, 6)
                            }.help(item.video.url.path)
                        }.width(min: 200, ideal: 340)
                        TableColumn("Size") { item in
                            Text(ByteCountFormatter.string(fromByteCount: item.video.size, countStyle: .file))
                                .foregroundStyle(.secondary).monospacedDigit()
                        }.width(85)
                        TableColumn("Status") { item in
                            Label(item.status.title, systemImage: item.status.symbol)
                                .foregroundStyle(item.status.color)
                                .help(statusHelp(for: item))
                        }.width(140)
                    }
                    .focused($contentFocus, equals: .videos)
                    .overlay(alignment: .bottomLeading) {
                        if let item = completedSelectedItem {
                            HStack(spacing: 8) {
                                ViewThatFits(in: .horizontal) {
                                    Text(item.detail)
                                        .fixedSize()
                                    Text(item.detail)
                                        .lineLimit(3)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .frame(maxWidth: 520, alignment: .leading)
                                }
                                .font(.caption)
                                .foregroundStyle(.primary.opacity(0.75))
                                .textSelection(.enabled)
                                .help(item.detail)

                                Divider()
                                    .frame(height: 16)
                                    .padding(.horizontal, 6)

                                HoverIconButton(title: "Show in Finder", systemImage: "folder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([item.video.url])
                                }

                                HoverIconButton(title: "Search subtitles manually", systemImage: "magnifyingglass") {
                                    showSubtitles = true
                                }
                                .disabled(store.isRunning)
                            }
                            .controlSize(.small)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .strokeBorder(.primary.opacity(0.08), lineWidth: 1)
                            }
                            .shadow(color: .black.opacity(0.09), radius: 4, y: 2)
                            .padding(14)
                        }
                    }
                    .contextMenu {
                        Button("Search subtitles manually") { showSubtitles = true }
                            .disabled(store.isRunning || selection.count != 1)
                        if canMarkSelectionAsPending {
                            Button("Mark as Pending") { store.mark(selection, as: .ready) }
                                .disabled(store.isRunning)
                        }
                        if canMarkSelectionAsCompleted {
                            Button("Mark as Completed") { store.mark(selection, as: .completed) }
                                .disabled(store.isRunning)
                        }
                        Button("Remove selected", role: .destructive) { store.remove(selection); selection.removeAll() }
                            .disabled(selection.isEmpty || store.isRunning)
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(Array(selection)) }
                            .disabled(selection.isEmpty)
                    }
                    .onDeleteCommand { store.remove(selection) }
                }
                Divider()
                footer
            }
            .alert("Subtitle sources", isPresented: Binding(get: { configurationError != nil }, set: { if !$0 { configurationError = nil } })) {
                Button("OK") { configurationError = nil }
            } message: { Text(configurationError ?? "") }
            .navigationTitle((filter ?? .all).title)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { selectVideos(store: store) } label: { Label("Add videos", systemImage: "plus") }
                        .help("Add video files or folders")
                    Button { store.remove(selection); selection.removeAll() } label: { Label("Remove selected", systemImage: "minus") }
                        .disabled(selection.isEmpty || store.isRunning)
                        .help("Remove selected videos from the list")
                    Button { store.clearAll(); selection.removeAll() } label: { Label("Clear all videos", systemImage: "trash") }
                        .disabled(store.items.isEmpty || store.isRunning)
                        .help("Clear all videos from the list")
                }
#if compiler(>=6.2)
                if #available(macOS 26.0, *) {
                    ToolbarSpacer(.fixed, placement: .primaryAction)
                }
#endif
                ToolbarItem(placement: .primaryAction) { searchControl }
            }
            .overlay {
                if isDropTarget {
                    RoundedRectangle(cornerRadius: 12).strokeBorder(.tint, style: StrokeStyle(lineWidth: 3, dash: [8]))
                        .padding(8).allowsHitTesting(false)
                }
            }
            .onDrop(of: [UTType.fileURL], isTargeted: $isDropTarget) { providers in
                for provider in providers {
                    _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                        guard let data, let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL else { return }
                        Task { @MainActor in await store.add([url]) }
                    }
                }
                return !providers.isEmpty
            }
        }
        .frame(minWidth: 820, minHeight: 520)
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { contentWidth = geometry.size.width }
                    .onChange(of: geometry.size.width) { _, newWidth in
                        contentWidth = newWidth
                    }
            }
        }
        .defaultFocus($contentFocus, .videos)
        .onChange(of: store.items.isEmpty) { wasEmpty, isEmpty in
            guard wasEmpty, !isEmpty else { return }
            // The table does not exist while the empty-state view is visible. Once the first
            // import creates it, wait for layout and establish the same primary focus used
            // after dismissing the subtitle picker.
            Task { @MainActor in
                await Task.yield()
                contentFocus = .videos
            }
        }
        .onChange(of: selection) { _, selected in
            // A row selection is an interaction with the primary table. Keep its native active
            // selection color instead of leaving focus on the import or toolbar button.
            if !selected.isEmpty, !showSubtitles, !searchIsFocused {
                contentFocus = .videos
            }
        }
        .sheet(isPresented: $showSubtitles, onDismiss: {
            // A modal sheet restores focus to its invoking button by default, leaving every
            // selection control inactive (gray). The video table is the primary content area.
            contentFocus = .videos
        }) {
            if let item = selectedItem {
                SubtitlePickerView(
                    video: item.video.url,
                    overwrite: overwrite,
                    renameSubtitle: renameSubtitles,
                    outputDirectory: configuredOutputDirectory,
                    preferredCandidateIDs: Set(item.selectedCandidates.map(\.id)),
                    width: min(880, max(520, contentWidth - 40))
                ) { output, candidate in
                    store.recordManualDownload(video: item.video.url, output: output, candidate: candidate)
                }
            } else {
                Color.clear.frame(width: 1, height: 1)
                    .onAppear { showSubtitles = false }
            }
        }
        .alert("Import notice", isPresented: Binding(get: { store.importMessage != nil }, set: { if !$0 { store.importMessage = nil } })) {
            Button("OK") { store.importMessage = nil }
        } message: { Text(store.importMessage ?? "") }
        .onChange(of: store.completionCount) {
            guard notify else { return }
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Subtitle batch finished")
            content.body = String(localized: "Open EasySub to review download results.")
            content.sound = .default
            Task { try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) }
        }
    }

    private var header: some View {
        HStack {
            Picker("Format", selection: $preference) {
                Text("ASS first").tag("ASS")
                Text("SRT first").tag("SRT")
                Text("Both").tag("BOTH")
            }.pickerStyle(.segmented).frame(maxWidth: 310).disabled(store.isRunning)
            if store.activeImports > 0 { ProgressView().controlSize(.small).help("Scanning folders…") }
            Spacer()
            Label(overwrite ? LocalizedStringKey("Replace existing") : LocalizedStringKey("Keep existing"), systemImage: overwrite ? "arrow.triangle.2.circlepath" : "lock.shield")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(18)
    }

    @ViewBuilder private var searchControl: some View {
        if searchIsExpanded {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find videos", text: $search)
                    .textFieldStyle(.plain)
                    .focused($searchIsFocused)
                    .frame(width: 220)
                Button {
                    search = ""
                    searchIsExpanded = false
                    searchIsFocused = false
                    contentFocus = .videos
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close search")
            }
            .padding(.horizontal, 10)
        } else {
            Button {
                searchIsExpanded = true
                Task { @MainActor in searchIsFocused = true }
            } label: {
                Label("Find videos", systemImage: "magnifyingglass").labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .help("Find videos")
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                if store.isRunning {
                    Text(store.isCancelling ? LocalizedStringKey("Cancelling…") : LocalizedStringKey("Downloading subtitles…")).font(.callout)
                    ProgressView(value: Double(store.batchFinished), total: Double(max(1, store.batchTotal)))
                        .frame(width: 200)
                } else {
                    Text("\(store.items.count) videos · \(store.successCount) completed · \(store.failureCount) need attention")
                        .font(.callout).foregroundStyle(.secondary)
                    Text(subtitleOutputDirectory.isEmpty
                         ? LocalizedStringKey("Saved beside your videos")
                         : LocalizedStringKey("Saved to the selected folder"))
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if store.isRunning {
                Text("\(store.batchFinished)/\(store.batchTotal)").monospacedDigit().foregroundStyle(.secondary)
                Button("Cancel", role: .cancel) { store.cancel() }.disabled(store.isCancelling)
            } else {
                Button {
                    do {
                        store.start(preference: SubtitlePreference(rawValue: preference) ?? .ass, overwrite: overwrite,
                                    renameSubtitle: renameSubtitles,
                                    outputDirectory: configuredOutputDirectory,
                                    service: try SubtitleSourceSettings.service())
                    } catch { configurationError = error.localizedDescription }
                } label: { Label("Download pending", systemImage: "arrow.down.circle.fill") }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(store.pendingCount == 0 || store.activeImports > 0)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }.padding(18)
    }

    private var configuredOutputDirectory: URL? {
        subtitleOutputDirectory.isEmpty ? nil : URL(fileURLWithPath: subtitleOutputDirectory, isDirectory: true)
    }

    private func statusHelp(for item: DownloadItem) -> String {
        guard !item.detail.isEmpty else { return item.status.helpText }
        return item.status.helpText + "\n\n" + item.detail
    }

    private var canMarkSelectionAsPending: Bool {
        store.items.contains { item in
            guard selection.contains(item.id) else { return false }
            return item.status == .completed || item.status == .failed || item.status == .partial
        }
    }

    private var canMarkSelectionAsCompleted: Bool {
        store.items.contains { item in
            guard selection.contains(item.id) else { return false }
            return item.status == .ready || item.status == .cancelled
                || item.status == .failed || item.status == .partial
        }
    }
}

private struct HoverIconButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 22, height: 22)
                .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .background {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isHovering && isEnabled ? Color.primary.opacity(0.09) : .clear)
                }
        }
        .buttonStyle(.plain)
        .foregroundStyle(isEnabled ? .secondary : .tertiary)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .help(Text(title))
    }
}

extension DownloadStatus {
    var title: LocalizedStringKey {
        switch self {
        case .ready: "Pending"
        case .queued: "Queued"
        case .downloading: "Downloading"
        case .completed: "Completed"
        case .partial: "Partial result"
        case .failed: "Needs attention"
        case .cancelled: "Cancelled"
        }
    }
    var symbol: String {
        switch self {
        case .ready: "circle"
        case .queued: "clock"
        case .downloading: "arrow.down.circle"
        case .completed: "checkmark.circle.fill"
        case .partial, .failed: "exclamationmark.circle.fill"
        case .cancelled: "stop.circle"
        }
    }
    var color: Color {
        switch self {
        case .completed: .green
        case .failed: .red
        case .partial: .orange
        case .downloading: .accentColor
        default: .secondary
        }
    }

    var helpText: String {
        switch self {
        case .ready:
            String(localized: "Waiting to download or ready to retry.")
        case .queued:
            String(localized: "Waiting for the download to start.")
        case .downloading:
            String(localized: "The subtitle download is in progress.")
        case .completed:
            String(localized: "The subtitle download completed successfully.")
        case .partial, .failed:
            String(localized: "Needs attention includes failed downloads and partially successful downloads.")
        case .cancelled:
            String(localized: "The download was cancelled and can be retried.")
        }
    }
}
