import SwiftUI
import TVCore

struct PlaybackHistoryView: View {
    @Environment(Store.self) private var store
    @State private var query = ""
    @State private var managing = false
    @State private var selected = Set<String>()
    @State private var confirmsDelete = false
    @State private var deletionIDs = Set<String>()
    private var entries: [PlaybackHistoryEntry] {
        store.playbackHistory.entries.filter { query.isEmpty || $0.context.videoName.localizedCaseInsensitiveContains(query) || $0.context.sourceName.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        Group {
            if store.playbackHistory.entries.isEmpty {
                ContentUnavailableView(L10n.text("No Playback History Yet"), systemImage: "clock.arrow.circlepath",
                    description: Text(L10n.text("Videos you watch appear here. Tap a record to continue from your saved position.")))
            } else {
                List {
                    if let error = store.playbackHistory.persistenceError {
                        Text(L10n.text("Unable to save playback history: %@", error)).foregroundStyle(.orange)
                    }
                    HStack {
                        Text(L10n.text("%lld titles", store.playbackHistory.entries.count)).font(.headline)
                        Spacer()
                        Button(L10n.text(managing ? "Done" : "Manage history")) { managing.toggle(); selected.removeAll() }
                            .accessibilityIdentifier("history.manage")
                        if !managing {
                            Menu {
                                Button(L10n.text("Clear history"), role: .destructive) {
                                    deletionIDs = Set(store.playbackHistory.entries.map(\.id)); confirmsDelete = true
                                }
                            } label: { Image(systemName: "ellipsis.circle").frame(minWidth: 44, minHeight: 44) }
                            .accessibilityLabel(L10n.text("More"))
                        }
                    }.buttonStyle(.borderless)
                    if managing {
                        HStack {
                            Button(L10n.text("Select all")) { selected = Set(entries.map(\.id)) }.accessibilityIdentifier("history.selectAll")
                            Spacer()
                            Button(L10n.text("Delete selected (%lld)", selected.count), role: .destructive) { deletionIDs = selected; confirmsDelete = true }
                                .disabled(selected.isEmpty).accessibilityIdentifier("history.deleteSelected")
                        }.buttonStyle(.borderless)
                    }
                    Text(L10n.text("Removing a title also clears its cached content and skip times."))
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(entries) { entry in
                        HStack {
                            if managing {
                                Button {
                                    if selected.contains(entry.id) { selected.remove(entry.id) } else { selected.insert(entry.id) }
                                } label: {
                                    Image(systemName: selected.contains(entry.id) ? "checkmark.circle.fill" : "circle").font(.title2)
                                        .frame(width: 44, height: 44).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain).accessibilityIdentifier("history.select." + entry.context.videoID)
                                .accessibilityLabel(entry.context.videoName).accessibilityValue(selected.contains(entry.id) ? "1" : "0")
                            }
                            PlaybackHistoryButton(entry: entry)
                        }
                            .listRowBackground(Color.clear)
                            .contextMenu {
                                Button(L10n.text("Remove from history"), role: .destructive) { store.playbackHistory.remove(entry.id) }
                            }
                    }
                    .onDelete { indices in
                        store.playbackHistory.remove(Set(indices.map { entries[$0].id }))
                    }
                }
                #if !os(tvOS)
                .scrollContentBackground(.hidden)
                #endif
            }
        }
        .screenBackdrop().screenTitle(L10n.text("Playback History"))
        .catalogSearchable(text: $query, prompt: L10n.text("Search history"))
        .alert(L10n.text("Remove selected history and its cached content?"), isPresented: $confirmsDelete) {
            Button(L10n.text("Remove from history"), role: .destructive) { store.playbackHistory.remove(deletionIDs); selected.removeAll() }
                .accessibilityIdentifier("history.confirmDelete")
            Button(L10n.text("Cancel"), role: .cancel) {}
        }
    }
}

struct PlaybackHistoryButton: View {
    @Environment(Store.self) private var store
    let entry: PlaybackHistoryEntry

    var body: some View {
        Button { Task { await store.resumeHistory(entry) } } label: {
            HStack(spacing: 14) {
                if let poster = entry.context.poster {
                    PosterImage(url: poster, headers: entry.context.posterHeaders ?? [:]).frame(width: 52, height: 74).clipShape(RoundedRectangle(cornerRadius: 6))
                } else { IconTile(symbol: "play.circle.fill", tint: Brand.terracotta, size: 46) }
                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.context.videoName).font(.headline).lineLimit(1)
                    Text("\(entry.context.episodeName) · \(SourceLabel(entry.context.sourceName).text)")
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    Text(entry.completed ? L10n.text("Finished · Watch again")
                         : L10n.text("Continue from %@", EpisodeSkipSettings.formatTime(entry.position)))
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    if entry.duration > 0 { ProgressView(value: entry.progress).tint(Brand.accent) }
                    Text(entry.updatedAt, style: .relative).font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                if store.resumingHistoryID == entry.id { ProgressView() }
                else { Image(systemName: "play.fill").foregroundStyle(Brand.accent) }
            }
            .padding(.vertical, 8).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(store.resumingHistoryID != nil)
        .accessibilityIdentifier("history.resume.\(entry.context.videoID)")
    }
}
