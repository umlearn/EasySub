import SwiftUI
import AppKit
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

private struct VideoTableComparator: SortComparator {
    var field: VideoSortField
    var order: SortOrder = .forward

    func compare(_ lhs: DownloadItem, _ rhs: DownloadItem) -> ComparisonResult {
        let result: ComparisonResult
        switch field {
        case .added:
            result = compareNames(lhs, rhs)
        case .name:
            result = compareNames(lhs, rhs)
        case .size:
            result = compareValues(lhs.video.size, rhs.video.size, lhs: lhs, rhs: rhs)
        case .status:
            result = compareValues(statusRank(lhs.status), statusRank(rhs.status), lhs: lhs, rhs: rhs)
        }
        return order == .forward ? result : result.reversed
    }

    private func compareValues<T: Comparable>(_ lhsValue: T, _ rhsValue: T,
                                               lhs: DownloadItem, rhs: DownloadItem) -> ComparisonResult {
        if lhsValue < rhsValue { return .orderedAscending }
        if lhsValue > rhsValue { return .orderedDescending }
        return compareNames(lhs, rhs)
    }

    private func compareNames(_ lhs: DownloadItem, _ rhs: DownloadItem) -> ComparisonResult {
        let nameResult = lhs.video.url.lastPathComponent.localizedStandardCompare(rhs.video.url.lastPathComponent)
        guard nameResult == .orderedSame else { return nameResult }
        return lhs.video.url.path.localizedStandardCompare(rhs.video.url.path)
    }

    private func statusRank(_ status: DownloadStatus) -> Int {
        switch status {
        case .ready: 0
        case .queued: 1
        case .downloading: 2
        case .completed: 3
        case .partial: 4
        case .failed: 5
        case .cancelled: 6
        }
    }
}

private extension ComparisonResult {
    var reversed: ComparisonResult {
        switch self {
        case .orderedAscending: .orderedDescending
        case .orderedDescending: .orderedAscending
        case .orderedSame: .orderedSame
        }
    }
}

struct ContentView: View {
    @Bindable var store: DownloadStore
    @Environment(\.openWindow) private var openWindow
    @State private var selection = Set<URL>()
    @State private var filter: QueueFilter? = .all
    @State private var search = ""
    @State private var searchIsExpanded = false
    @State private var showSubtitles = false
    @State private var configurationError: String?
    @State private var isDropTarget = false
    @State private var contentWidth: CGFloat = 820
    @State private var contentHeight: CGFloat = 520
    @FocusState private var contentFocus: ContentFocus?
    @AppStorage("SZSubTypeKey") private var preference = SubtitlePreference.ass.rawValue
    @AppStorage("renameSubtitles") private var renameSubtitles = true
    @AppStorage("overwriteSubtitles") private var overwrite = false
    @AppStorage("subtitleOutputDirectory") private var subtitleOutputDirectory = ""
    @AppStorage("notifyOnCompletion") private var notify = false
    @AppStorage("videoSortField") private var videoSortField = VideoSortField.added.rawValue
    @AppStorage("videoSortDirection") private var videoSortDirection = VideoSortDirection.ascending.rawValue

    private var visibleItems: [DownloadItem] {
        let filtered = store.items.filter {
            (filter ?? .all).includes($0) && (search.isEmpty || $0.video.url.lastPathComponent.localizedCaseInsensitiveContains(search))
        }
        guard currentSortField != .added else {
            return currentSortDirection == .ascending ? filtered : Array(filtered.reversed())
        }
        return filtered.sorted(using: activeComparator)
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
                Button { openWindow(id: "settings") } label: {
                    Label("Settings", systemImage: "gearshape")
                }
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
                    .contextMenu {
                        Button { selectVideos(store: store) } label: {
                            Label("Add videos", systemImage: "plus")
                        }
                    }
                } else {
                    Table(visibleItems, selection: $selection, sortOrder: tableSortOrder) {
                        TableColumn("Video", sortUsing: VideoTableComparator(field: .name)) { item in
                            HStack(spacing: 10) {
                                Image(systemName: "film").foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.video.url.lastPathComponent).lineLimit(1)
                                    Text(item.video.url.deletingLastPathComponent().path)
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                }.padding(.vertical, 6)
                            }.help(item.video.url.path)
                        }.width(min: 200, ideal: 340)
                        TableColumn("Size", sortUsing: VideoTableComparator(field: .size)) { item in
                            Text(ByteCountFormatter.string(fromByteCount: item.video.size, countStyle: .file))
                                .foregroundStyle(.secondary).monospacedDigit()
                        }.width(85)
                        TableColumn("Status", sortUsing: VideoTableComparator(field: .status)) { item in
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
                    .contextMenu(forSelectionType: URL.self) { contextSelection in
                        Group {
                        if contextSelection.isEmpty {
                            Button { selectVideos(store: store) } label: {
                                Label("Add videos", systemImage: "plus")
                            }
                        } else {
                            Button("Search subtitles manually") {
                                selection = contextSelection
                                showSubtitles = true
                            }
                                .disabled(store.isRunning || contextSelection.count != 1)
                            Divider()
                            if canMarkAsPending(contextSelection) {
                                Button("Mark as Pending") { store.mark(contextSelection, as: .ready) }
                                    .disabled(store.isRunning)
                            }
                            if canMarkAsCompleted(contextSelection) {
                                Button("Mark as Completed") { store.mark(contextSelection, as: .completed) }
                                    .disabled(store.isRunning)
                            }
                            Button("Remove selected", role: .destructive) {
                                store.remove(contextSelection)
                                selection.subtract(contextSelection)
                            }
                                .disabled(store.isRunning)
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting(Array(contextSelection))
                            }
                        }
                        }
                        .onAppear { adoptContextSelection(contextSelection) }
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
                    Button {
                        collapseEmptySearch()
                        selectVideos(store: store)
                    } label: { Label("Add videos", systemImage: "plus") }
                        .help("Add video files or folders")
                    Button {
                        collapseEmptySearch()
                        store.remove(selection)
                        selection.removeAll()
                    } label: { Label("Remove selected", systemImage: "minus") }
                        .disabled(selection.isEmpty || store.isRunning)
                        .help("Remove selected videos from the list")
                    Button {
                        collapseEmptySearch()
                        store.clearAll()
                        selection.removeAll()
                    } label: { Label("Clear all videos", systemImage: "trash") }
                        .disabled(store.items.isEmpty || store.isRunning)
                        .help("Clear all videos from the list")
                }
#if compiler(>=6.2)
                if #available(macOS 26.0, *) {
                    ToolbarSpacer(.fixed, placement: .primaryAction)
                }
#endif
                ToolbarItem(placement: .primaryAction) {
                    CollapsibleSearchControl(
                        text: $search,
                        isPresented: $searchIsExpanded,
                        prompt: String(localized: "Find videos")
                    )
                }
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
        .contextMenu {
            Button { selectVideos(store: store) } label: {
                Label("Add videos", systemImage: "plus")
            }
        }
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear {
                        contentWidth = geometry.size.width
                        contentHeight = geometry.size.height
                    }
                    .onChange(of: geometry.size) { _, newSize in
                        contentWidth = newSize.width
                        contentHeight = newSize.height
                    }
            }
        }
        .defaultFocus($contentFocus, .videos)
        .focusedSceneValue(\.mainWindowCommands, mainWindowCommandActions)
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
            if !selected.isEmpty, !showSubtitles {
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
                    downloadedCandidates: item.downloadedCandidates,
                    width: min(880, max(520, contentWidth - 40)),
                    // Keep the search sheet aligned with the main window instead of
                    // freezing at the former 620 pt cap. GeometryReader updates
                    // contentHeight continuously while the window is being resized.
                    height: max(420, contentHeight - 40)
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
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                Text("Format")
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Picker(selection: $preference) {
                    Text("ASS first").tag("ASS")
                    Text("SRT first").tag("SRT")
                    Text("Both").tag("BOTH")
                } label: {
                    EmptyView()
                }
                .pickerStyle(.segmented)
                .frame(width: 310, alignment: .leading)
                .disabled(store.isRunning)
            }
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
            if store.activeImports > 0 { ProgressView().controlSize(.small).help("Scanning folders…") }
            Spacer(minLength: 8)
            ViewThatFits(in: .horizontal) {
                Label(overwrite ? LocalizedStringKey("Replace existing") : LocalizedStringKey("Keep existing"),
                      systemImage: overwrite ? "arrow.triangle.2.circlepath" : "lock.shield")
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Image(systemName: overwrite ? "arrow.triangle.2.circlepath" : "lock.shield")
                    .help(overwrite ? "Replace existing" : "Keep existing")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }.padding(18)
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
                    startDownloads()
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

    private var mainWindowCommandActions: MainWindowCommandActions {
        MainWindowCommandActions(
            hasSelection: !selection.isEmpty,
            hasSingleSelection: selection.count == 1,
            hasCompletedItems: store.items.contains { $0.status == .completed },
            hasItems: !store.items.isEmpty,
            hasPendingItems: store.pendingCount > 0 && store.activeImports == 0,
            canMarkPending: canMarkAsPending(selection),
            canMarkCompleted: canMarkAsCompleted(selection),
            isRunning: store.isRunning,
            isSearchExpanded: searchIsExpanded,
            sortField: currentSortField,
            sortDirection: currentSortDirection,
            removeSelected: removeSelected,
            clearCompleted: clearCompleted,
            clearAll: clearAll,
            showInFinder: showSelectionInFinder,
            downloadPending: startDownloads,
            cancelDownload: { store.cancel() },
            searchSubtitlesManually: searchSelectedItemManually,
            markPending: { store.mark(selection, as: .ready) },
            markCompleted: { store.mark(selection, as: .completed) },
            findVideos: expandSearch,
            closeSearch: closeSearch,
            showAll: { filter = .all },
            showPending: { filter = .pending },
            showCompleted: { filter = .completed },
            showNeedsAttention: { filter = .attention },
            setSortField: setSortField,
            setSortDirection: setSortDirection
        )
    }

    private var currentSortField: VideoSortField {
        VideoSortField(rawValue: videoSortField) ?? .added
    }

    private var currentSortDirection: VideoSortDirection {
        VideoSortDirection(rawValue: videoSortDirection) ?? .ascending
    }

    private var activeComparator: VideoTableComparator {
        VideoTableComparator(
            field: currentSortField,
            order: currentSortDirection == .ascending ? .forward : .reverse
        )
    }

    private var tableSortOrder: Binding<[VideoTableComparator]> {
        Binding(
            get: { [activeComparator] },
            set: { comparators in
                guard let comparator = comparators.first else { return }
                videoSortField = comparator.field.rawValue
                videoSortDirection = comparator.order == .forward
                    ? VideoSortDirection.ascending.rawValue
                    : VideoSortDirection.descending.rawValue
            }
        )
    }

    private func setSortField(_ field: VideoSortField) {
        videoSortField = field.rawValue
    }

    private func setSortDirection(_ direction: VideoSortDirection) {
        videoSortDirection = direction.rawValue
    }

    private func removeSelected() {
        store.remove(selection)
        selection.removeAll()
    }

    private func clearCompleted() {
        let completed = Set(store.items.filter { $0.status == .completed }.map(\.id))
        store.clearCompleted()
        selection.subtract(completed)
    }

    private func clearAll() {
        store.clearAll()
        selection.removeAll()
    }

    private func showSelectionInFinder() {
        guard !selection.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(Array(selection))
    }

    private func searchSelectedItemManually() {
        guard selection.count == 1, !store.isRunning else { return }
        showSubtitles = true
    }

    private func startDownloads() {
        do {
            store.start(preference: SubtitlePreference(rawValue: preference) ?? .ass, overwrite: overwrite,
                        renameSubtitle: renameSubtitles,
                        outputDirectory: configuredOutputDirectory,
                        service: try SubtitleSourceSettings.service())
        } catch {
            configurationError = error.localizedDescription
        }
    }

    private func expandSearch() {
        searchIsExpanded = true
    }

    private func closeSearch() {
        search = ""
        searchIsExpanded = false
        contentFocus = .videos
    }

    private func collapseEmptySearch() {
        guard searchIsExpanded,
              search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        search = ""
        searchIsExpanded = false
    }

    private func statusHelp(for item: DownloadItem) -> String {
        guard !item.detail.isEmpty else { return item.status.helpText }
        return item.status.helpText + "\n\n" + item.detail
    }

    private func adoptContextSelection(_ contextSelection: Set<URL>) {
        guard !contextSelection.isEmpty else { return }
        if contextSelection.count == 1, let clicked = contextSelection.first, selection.contains(clicked) {
            return
        }
        selection = contextSelection
        contentFocus = .videos
    }

    private func canMarkAsPending(_ ids: Set<URL>) -> Bool {
        store.items.contains { item in
            guard ids.contains(item.id) else { return false }
            return item.status == .completed || item.status == .failed || item.status == .partial
        }
    }

    private func canMarkAsCompleted(_ ids: Set<URL>) -> Bool {
        store.items.contains { item in
            guard ids.contains(item.id) else { return false }
            return item.status == .ready || item.status == .cancelled
                || item.status == .failed || item.status == .partial
        }
    }
}

private struct CollapsibleSearchControl: View {
    @Binding var text: String
    @Binding var isPresented: Bool
    let prompt: String
    @State private var widthProgress: CGFloat = 0
    @State private var widthAnimationTask: Task<Void, Never>?

    private let collapsedWidth: CGFloat = 38
    private let expandedWidth: CGFloat = 220
    private let animationDuration: TimeInterval = 0.2

    var body: some View {
        ZStack {
            NativeCollapsibleSearchField(
                text: $text,
                isPresented: $isPresented,
                prompt: prompt
            )
            .opacity(expandedContentOpacity)
            .allowsHitTesting(isPresented)

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isPresented = true
                }
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 38, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(prompt)
            .accessibilityLabel(Text("Find videos"))
            .opacity(collapsedContentOpacity)
            .allowsHitTesting(!isPresented && widthProgress < 0.001)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        }
        .frame(width: collapsedWidth + (expandedWidth - collapsedWidth) * widthProgress,
               height: 30)
        .clipped()
        .onAppear {
            widthProgress = isPresented ? 1 : 0
        }
        .onChange(of: isPresented) { _, expanded in
            animateWidth(expanded: expanded)
        }
        .onDisappear {
            widthAnimationTask?.cancel()
        }
    }

    private var collapsedContentOpacity: Double {
        Double(max(0, min(1, 1 - widthProgress / 0.35)))
    }

    private var expandedContentOpacity: Double {
        Double(max(0, min(1, (widthProgress - 0.05) / 0.3)))
    }

    private func animateWidth(expanded: Bool) {
        widthAnimationTask?.cancel()
        let start = widthProgress
        let target: CGFloat = expanded ? 1 : 0
        guard abs(target - start) > 0.001 else { return }

        widthAnimationTask = Task { @MainActor in
            let startedAt = Date()
            while !Task.isCancelled {
                let elapsed = Date().timeIntervalSince(startedAt)
                let linearProgress = min(max(elapsed / animationDuration, 0), 1)
                let easedProgress = linearProgress * linearProgress * (3 - 2 * linearProgress)
                widthProgress = start + (target - start) * CGFloat(easedProgress)

                guard linearProgress < 1 else { break }
                do {
                    try await Task.sleep(for: .milliseconds(16))
                } catch {
                    return
                }
            }

        }
    }
}

private struct NativeCollapsibleSearchField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isPresented: Bool
    let prompt: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isPresented: $isPresented)
    }

    func makeNSView(context: Context) -> CollapsibleSearchField {
        let field = CollapsibleSearchField()
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.searchChanged(_:))
        field.onCollapsedClick = { [weak coordinator = context.coordinator, weak field] in
            guard let coordinator, let field else { return }
            coordinator.activate(field)
        }
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.focusRingType = .none
        field.setContentCompressionResistancePriority(.required, for: .horizontal)
        context.coordinator.installOutsideClickMonitor(for: field)
        return field
    }

    static func dismantleNSView(_ field: CollapsibleSearchField, coordinator: Coordinator) {
        coordinator.removeOutsideClickMonitor()
    }

    func updateNSView(_ field: CollapsibleSearchField, context: Context) {
        context.coordinator.update(text: $text, isPresented: $isPresented)
        field.isCollapsed = !isPresented
        field.placeholderString = isPresented ? prompt : ""
        field.toolTip = prompt
        if field.stringValue != text {
            field.stringValue = text
        }

        if isPresented, !context.coordinator.wasPresented {
            context.coordinator.scheduleFocus(for: field)
        } else if !isPresented,
                  context.coordinator.wasPresented {
            context.coordinator.cancelFocus()
            if field.currentEditor() != nil {
                field.window?.makeFirstResponder(nil)
            }
        }
        context.coordinator.wasPresented = isPresented
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        private var text: Binding<String>
        private var isPresented: Binding<Bool>
        var wasPresented = false
        private var focusTask: Task<Void, Never>?
        private var isActivating = false
        private var outsideClickMonitor: Any?

        init(text: Binding<String>, isPresented: Binding<Bool>) {
            self.text = text
            self.isPresented = isPresented
        }

        func update(text: Binding<String>, isPresented: Binding<Bool>) {
            self.text = text
            self.isPresented = isPresented
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            if !isPresented.wrappedValue {
                isActivating = true
                withAnimation(.easeInOut(duration: 0.2)) {
                    isPresented.wrappedValue = true
                }
            }
            if focusTask == nil {
                isActivating = false
            }
        }

        func activate(_ field: NSSearchField) {
            guard !isPresented.wrappedValue else { return }
            isActivating = true
            withAnimation(.easeInOut(duration: 0.2)) {
                isPresented.wrappedValue = true
            }
        }

        func controlTextDidChange(_ obj: Notification) {
            syncText(from: obj.object as? NSSearchField)
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let field = obj.object as? NSSearchField else { return }
            guard !isActivating else { return }
            if field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                collapse()
            }
        }

        @objc func searchChanged(_ sender: NSSearchField) {
            if !isPresented.wrappedValue {
                activate(sender)
                return
            }
            syncText(from: sender)
        }

        func scheduleFocus(for field: NSSearchField) {
            focusTask?.cancel()
            isActivating = true
            focusTask = Task { @MainActor [weak self, weak field] in
                await Task.yield()
                guard let self, let field, self.isPresented.wrappedValue else { return }
                field.window?.makeFirstResponder(field)

                // AppKit can briefly resign the field while the toolbar item resizes. Ignore
                // that transient end-editing event, then collapse only if focus never landed.
                do {
                    try await Task.sleep(for: .milliseconds(220))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self.isActivating = false
                self.focusTask = nil
                if field.currentEditor() == nil,
                   field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.collapse()
                }
            }
        }

        func cancelFocus() {
            focusTask?.cancel()
            focusTask = nil
            isActivating = false
        }

        func installOutsideClickMonitor(for field: CollapsibleSearchField) {
            removeOutsideClickMonitor()
            outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) {
                [weak self, weak field] event in
                guard let self, let field,
                      event.window === field.window,
                      self.isPresented.wrappedValue,
                      field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { return event }

                let point = field.convert(event.locationInWindow, from: nil)
                if !field.bounds.contains(point) {
                    self.collapse()
                }
                return event
            }
        }

        func removeOutsideClickMonitor() {
            guard let outsideClickMonitor else { return }
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }

        private func collapse() {
            withAnimation(.easeInOut(duration: 0.2)) {
                isPresented.wrappedValue = false
            }
        }

        private func syncText(from field: NSSearchField?) {
            guard let field, text.wrappedValue != field.stringValue else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

private final class CollapsibleSearchField: NSSearchField {
    var isCollapsed = true
    var onCollapsedClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        guard isCollapsed else {
            super.mouseDown(with: event)
            return
        }
        onCollapsedClick?()
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
