import Foundation
import Observation

/// Catalog identity only: an expiring stream URL or its authorization headers must
/// never become the address used to resume a saved episode.
public struct PlaybackHistoryContext: Codable, Hashable, Sendable {
    public let origin: URL
    public let sourceKey: String
    public let sourceName: String
    public let videoID: String
    public let videoName: String
    public let poster: URL?
    public let episodeID: String
    public let episodeName: String
    public let episodeFlag: String
    public var id: String { EpisodeSkipSettings.scope(origin: origin, source: sourceKey, video: videoID) }

    public init(origin: URL, sourceKey: String, sourceName: String, videoID: String, videoName: String,
                poster: URL? = nil, episodeID: String, episodeName: String, episodeFlag: String) {
        self.origin = origin; self.sourceKey = sourceKey; self.sourceName = sourceName
        self.videoID = videoID; self.videoName = videoName; self.poster = poster
        self.episodeID = episodeID; self.episodeName = episodeName; self.episodeFlag = episodeFlag
    }

    public init(origin: URL, site: Site, video: Video, episode: Episode) {
        self.init(origin: origin, sourceKey: site.key, sourceName: site.name, videoID: video.id,
                  videoName: video.name, poster: video.poster, episodeID: episode.id,
                  episodeName: episode.name, episodeFlag: episode.flag)
    }

    /// Names survive list reordering. Never silently resume a different episode
    /// just because a source now gives it the saved numeric index.
    public func episode(in episodes: [Episode]) -> Episode? {
        let matches = episodes.filter { $0.flag == episodeFlag && $0.name == episodeName }
        if let exact = matches.first(where: { $0.id == episodeID }) { return exact }
        return matches.count == 1 ? matches.first : nil
    }
}

public struct PlaybackHistoryEntry: Identifiable, Codable, Hashable, Sendable {
    public let context: PlaybackHistoryContext
    public let position: Double
    public let duration: Double
    public let updatedAt: Date
    public var id: String { context.id }
    public var completed: Bool { duration > 0 && position >= duration - 1 }
    public var resumePosition: Double { completed ? 0 : position }
    public var progress: Double { duration > 0 ? min(1, max(0, position / duration)) : 0 }

    public static func resumeTarget(_ position: Double, duration: Double) -> Double? {
        guard position.isFinite, position >= 0, duration.isFinite, duration > 0 else { return nil }
        return min(position, max(0, duration - 0.25))
    }
}

/// Shared by the library and player, bounded and atomically persisted outside
/// UserDefaults so a growing history does not hit its size limit.
@MainActor @Observable public final class PlaybackHistory {
    public static let shared = PlaybackHistory()
    public static let limit = 200
    public private(set) var entries: [PlaybackHistoryEntry] = []
    public private(set) var persistenceError: String?
    private let file: URL

    public init(file: URL? = nil) {
        #if os(tvOS)
        let directory = URL.cachesDirectory
        #else
        let directory = URL.applicationSupportDirectory
        #endif
        self.file = file ?? directory.appending(path: "playback-history-v1.json")
        if let data = try? Data(contentsOf: self.file), data.count <= 2 * 1024 * 1024,
           let decoded = try? JSONDecoder().decode([PlaybackHistoryEntry].self, from: data) {
            var seen = Set<String>()
            entries = Array(decoded.filter { Self.valid($0) }.sorted { $0.updatedAt > $1.updatedAt }
                .filter { seen.insert($0.id).inserted }.prefix(Self.limit))
        }
    }

    public func record(_ context: PlaybackHistoryContext, position: Double, duration: Double, now: Date = Date()) {
        guard position.isFinite, position >= 1, duration.isFinite, duration >= 0 else { return }
        let entry = PlaybackHistoryEntry(context: context, position: duration > 0 ? min(position, duration) : position,
                                         duration: duration, updatedAt: now)
        guard Self.valid(entry) else { return }
        if let old = entries.first(where: { $0.id == entry.id }), old.context == context,
           abs(old.position - entry.position) < 0.25, old.duration == duration { return }
        entries.removeAll { $0.id == entry.id }
        entries.insert(entry, at: 0)
        entries = Array(entries.prefix(Self.limit))
        persist()
    }

    public func remove(_ id: String) { entries.removeAll { $0.id == id }; persist() }
    public func clear() { entries.removeAll(); persist() }

    private static func valid(_ entry: PlaybackHistoryEntry) -> Bool {
        !entry.context.sourceKey.isEmpty && !entry.context.videoID.isEmpty &&
        entry.position.isFinite && entry.position >= 0 && entry.duration.isFinite && entry.duration >= 0 &&
        entry.updatedAt.timeIntervalSince1970.isFinite
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(entries)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            persistenceError = nil
        } catch { persistenceError = error.localizedDescription }
    }
}
