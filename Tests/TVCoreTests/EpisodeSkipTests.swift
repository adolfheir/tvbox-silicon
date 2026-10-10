import Foundation
import Testing
@testable import TVCore

@Test func episodeSkipRejectsInvalidAndExcessivePositions() {
    for text in ["-1", "nan", "1:60", "1::20", "1.5", "9999999999999999999999", "24:00:01"] {
        #expect(EpisodeSkipSettings.parseTime(text) == nil)
    }
    #expect(EpisodeSkipSettings.parseTime(" 01:30 ") == 90)
    #expect(EpisodeSkipSettings.parseTime("1:02:03") == 3723)
    let valid = EpisodeSkipSettings(enabled: true, introEnd: 90, outroLength: 120)
    #expect(valid.validationError(duration: 2700) == nil)
    for length in [0.0, .infinity, .nan, 119] {
        #expect(valid.validationError(duration: length) != nil)
    }
    #expect(EpisodeSkipSettings(enabled: true, introEnd: 301).validationError(duration: 2700) != nil)
    #expect(EpisodeSkipSettings(enabled: true, outroLength: 601).validationError(duration: 2700) != nil)
    #expect(EpisodeSkipSettings(enabled: true, introEnd: 120, outroLength: 120).validationError(duration: 480) != nil)
    #expect(EpisodeSkipSettings(enabled: true, introEnd: .nan).validationError(duration: 2700) != nil)
}

@Test func episodeSkipRunsOnceAndAllowsManualRewind() {
    let settings = EpisodeSkipSettings(enabled: true, introEnd: 90, outroLength: 120)
    var pass = EpisodeSkipPass()
    #expect(pass.target(time: 0, duration: 2700, playing: false, settings: settings) == nil)
    #expect(pass.target(time: 0, duration: 2700, playing: true, settings: settings) == 90)
    #expect(pass.target(time: 10, duration: 2700, playing: true, settings: settings) == nil)
    #expect(pass.target(time: 2579, duration: 2700, playing: true, settings: settings) == nil)
    #expect(pass.target(time: 2580, duration: 2700, playing: true, settings: settings) == 2699.95)
    #expect(pass.target(time: 2600, duration: 2700, playing: true, settings: settings) == nil)
    var disabled = EpisodeSkipPass()
    #expect(disabled.target(time: 0, duration: 2700, playing: true, settings: EpisodeSkipSettings()) == nil)
}

@Test func episodeSkipPersistsPerTitleAndPreservesOldChannelData() throws {
    let suite = "episode-skip-tests." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let origin = URL(string: "https://example.com/config.json")!
    let scope = EpisodeSkipSettings.scope(origin: origin, source: "source", video: "series-1")
    let settings = EpisodeSkipSettings(enabled: true, introEnd: 90, outroLength: 120)
    settings.save(scope: scope, defaults: defaults)
    #expect(EpisodeSkipSettings.load(scope: scope, defaults: defaults) == settings)
    #expect(EpisodeSkipSettings.load(scope: EpisodeSkipSettings.scope(origin: origin, source: "source", video: "series-2"), defaults: defaults) == EpisodeSkipSettings())
    // The ending follows each episode's duration instead of retaining the first episode's absolute timestamp.
    var pass = EpisodeSkipPass()
    #expect(pass.target(time: 2880, duration: 3000, playing: true, settings: settings) == 2999.95)
    let legacy = Data(#"{"name":"Live","group":"TV","url":"https://example.com/live.m3u8","headers":{}}"#.utf8)
    #expect(try JSONDecoder().decode(Channel.self, from: legacy).skipScope == nil)
}
