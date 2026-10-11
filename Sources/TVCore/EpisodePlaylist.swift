import Foundation

/// Follow the source's ordering within the current line; never jump to another
/// line or wrap the final episode back to the beginning.
public struct EpisodePlaylist: Sendable {
    public let episodes: [Episode]
    public init(_ episodes: [Episode]) { self.episodes = episodes }
    public var flags: [String] {
        var seen = Set<String>()
        return episodes.map(\.flag).filter { seen.insert($0).inserted }
    }
    public func episodes(for flag: String) -> [Episode] { episodes.filter { $0.flag == flag } }
    public func next(after context: PlaybackHistoryContext) -> Episode? {
        let line = episodes(for: context.episodeFlag)
        guard let current = context.episode(in: line), let index = line.firstIndex(of: current),
              line.indices.contains(index + 1) else { return nil }
        return line[index + 1]
    }
}
