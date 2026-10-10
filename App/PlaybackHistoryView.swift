import SwiftUI
import TVCore

struct PlaybackHistoryView: View {
    @Environment(Store.self) private var store
    @State private var confirmsClear = false

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
                    ForEach(store.playbackHistory.entries) { entry in
                        PlaybackHistoryButton(entry: entry)
                            .listRowBackground(Color.clear)
                            .contextMenu {
                                Button(L10n.text("Remove from history"), role: .destructive) { store.playbackHistory.remove(entry.id) }
                            }
                    }
                    .onDelete { indices in
                        let ids = indices.map { store.playbackHistory.entries[$0].id }
                        for id in ids { store.playbackHistory.remove(id) }
                    }
                }
                #if !os(tvOS)
                .scrollContentBackground(.hidden)
                #endif
            }
        }
        .screenBackdrop().screenTitle(L10n.text("Playback History"))
        .toolbar {
            if !store.playbackHistory.entries.isEmpty {
                Button(L10n.text("Clear history"), role: .destructive) { confirmsClear = true }
            }
        }
        .confirmationDialog(L10n.text("Clear all playback history?"), isPresented: $confirmsClear, titleVisibility: .visible) {
            Button(L10n.text("Clear history"), role: .destructive) { store.playbackHistory.clear() }
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
                IconTile(symbol: "play.circle.fill", tint: Brand.terracotta, size: 46)
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
