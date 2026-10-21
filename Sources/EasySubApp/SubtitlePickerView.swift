import SwiftUI

struct SubtitlePickerView: View {
    private enum FocusTarget: Hashable {
        case search, results, close
    }

    let video: URL
    let overwrite: Bool
    let renameSubtitle: Bool
    let outputDirectory: URL?
    let preferredCandidateIDs: Set<SubtitleCandidate.ID>
    let width: CGFloat
    let height: CGFloat
    var onSaved: (URL, SubtitleCandidate) -> Void = { _, _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [SubtitleCandidate] = []
    @State private var selection: SubtitleCandidate.ID?
    @State private var service: MultiSourceSubtitleService?
    @State private var searchText = ""
    @State private var searchMessage = ""
    @State private var downloadErrors: [SubtitleCandidate.ID: String] = [:]
    @State private var downloaded: [SubtitleCandidate.ID: URL] = [:]
    @State private var busy = true
    @State private var operation: Task<Void, Never>?
    @State private var operationID = UUID()
    @FocusState private var focusedTarget: FocusTarget?

    private var selectedCandidate: SubtitleCandidate? {
        candidates.first { $0.id == selection }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search subtitles", text: $searchText)
                        .textFieldStyle(.plain)
                        .lineLimit(1)
                        .focused($focusedTarget, equals: .search)
                        .onSubmit(beginSearch)
                    if busy {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 0.5)
                        }
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(.bar)

            Divider()

            List(candidates, selection: $selection) { candidate in
                VStack(alignment: .leading, spacing: 4) {
                    Text(candidate.title)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(metadata(for: candidate))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.vertical, 3)
                .contentShape(Rectangle())
                .tag(candidate.id)
            }
            .listStyle(.inset)
            .focused($focusedTarget, equals: .results)

            Divider()

            HStack(alignment: .center, spacing: 12) {
                status
                Spacer(minLength: 20)
                Button("Close") {
                    operation?.cancel()
                    dismiss()
                }
                .focused($focusedTarget, equals: .close)
                .keyboardShortcut(.cancelAction)
                Button("Download selected", action: downloadSelected)
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || selectedCandidate == nil)
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(.bar)
        }
        .frame(width: width, height: height)
        // The list has no rows while the initial search is running, so it cannot accept
        // default focus yet. Use the always-present close button to prevent AppKit from
        // falling back to the text field and selecting its entire value.
        .defaultFocus($focusedTarget, .close)
        .task {
            if searchText.isEmpty { searchText = video.lastPathComponent }
            beginSearch()
        }
        .onDisappear {
            operation?.cancel()
            operationID = UUID()
        }
    }

    @ViewBuilder private var status: some View {
        if let selection, let url = downloaded[selection] {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Downloaded successfully")
                Text(url.lastPathComponent).foregroundStyle(.secondary)
            }
            .font(.caption)
            .lineLimit(1)
        } else if let selection, let error = downloadErrors[selection] {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
                .textSelection(.enabled)
        } else if !searchMessage.isEmpty {
            Text(searchMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }

    private func metadata(for candidate: SubtitleCandidate) -> String {
        var parts = [candidate.source.name, candidate.format.rawValue.uppercased()]
        if !candidate.languageCodes.isEmpty {
            parts.append(candidate.languageCodes.sorted().joined(separator: ", "))
        }
        if candidate.matchKind == .fingerprint {
            parts.append(String(localized: "Fingerprint match"))
        }
        return parts.joined(separator: " · ")
    }

    private func beginSearch() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        operation?.cancel()
        let id = UUID()
        operationID = id
        busy = true
        candidates = []
        selection = nil
        searchMessage = ""
        downloadErrors.removeAll()
        operation = Task {
            defer { if operationID == id { busy = false } }
            do {
                let engine = try SubtitleSourceSettings.service()
                let report = try await engine.searchForSelection(
                    SubtitleSearchRequest(video: video, searchName: query))
                guard operationID == id, !Task.isCancelled else { return }
                service = engine
                candidates = report.candidates
                let initialSelection = candidates.first(where: { preferredCandidateIDs.contains($0.id) })?.id
                    ?? candidates.first?.id
                // Let List install its rows before it becomes first responder. Selecting only
                // after focus lands avoids the transient inactive (gray) selection appearance.
                if initialSelection != nil {
                    await Task.yield()
                    guard operationID == id, !Task.isCancelled else { return }
                    focusedTarget = .results
                    await Task.yield()
                    guard operationID == id, !Task.isCancelled else { return }
                    selection = initialSelection
                }
                searchMessage = report.failures.map(\.description).joined(separator: "\n")
                if candidates.isEmpty {
                    let empty = String(localized: "No subtitles found.")
                    searchMessage = searchMessage.isEmpty ? empty : empty + "\n" + searchMessage
                }
            } catch {
                guard operationID == id, !Task.isCancelled else { return }
                searchMessage = error.localizedDescription
            }
        }
    }

    private func downloadSelected() {
        guard let candidate = selectedCandidate, let service else { return }
        operation?.cancel()
        let id = UUID()
        operationID = id
        busy = true
        downloadErrors[candidate.id] = nil
        operation = Task {
            defer { if operationID == id { busy = false } }
            do {
                let url = try await service.download(candidate: candidate, video: video, overwrite: overwrite,
                                                     renameSubtitle: renameSubtitle,
                                                     outputDirectory: outputDirectory)
                guard operationID == id, !Task.isCancelled else { return }
                downloaded[candidate.id] = url
                onSaved(url, candidate)
            } catch {
                if operationID == id, !Task.isCancelled {
                    downloadErrors[candidate.id] = error.localizedDescription
                }
            }
        }
    }
}
