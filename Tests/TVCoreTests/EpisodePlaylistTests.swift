import Foundation
import Testing
@testable import TVCore

private func episodeContext(id: String = "old-index", name: String = "第 1 集", flag: String = "line") -> PlaybackHistoryContext {
    PlaybackHistoryContext(origin: URL(string: "https://example.com/config.json")!, sourceKey: "s", sourceName: "Source",
        videoID: "v", videoName: "Series", episodeID: id, episodeName: name, episodeFlag: flag)
}

@Test func playlistFollowsSourceOrderingWithoutCrossingLinesOrWrapping() {
    let first = Episode(id: "0", name: "第 1 集", address: "one", flag: "line")
    let second = Episode(id: "1", name: "第 2 集", address: "two", flag: "line")
    let alternative = Episode(id: "2", name: "第 1 集", address: "alternate", flag: "backup")
    let playlist = EpisodePlaylist([first, alternative, second])
    #expect(playlist.flags == ["line", "backup"])
    #expect(playlist.next(after: episodeContext()) == second)
    #expect(playlist.next(after: episodeContext(id: "1", name: "第 2 集")) == nil)
    #expect(playlist.next(after: episodeContext(id: "2", flag: "backup")) == nil)
}

@Test func playlistRejectsMissingOrAmbiguousCurrentEpisodes() {
    let playlist = EpisodePlaylist([
        Episode(id: "1", name: "第 1 集", address: "a", flag: "line"),
        Episode(id: "2", name: "第 1 集", address: "b", flag: "line"),
        Episode(id: "3", name: "第 2 集", address: "c", flag: "line")])
    #expect(playlist.next(after: episodeContext()) == nil)
    #expect(playlist.next(after: episodeContext(name: "missing")) == nil)
    #expect(playlist.next(after: episodeContext(flag: "deleted")) == nil)
    #expect(EpisodePlaylist([]).next(after: episodeContext()) == nil)
}
