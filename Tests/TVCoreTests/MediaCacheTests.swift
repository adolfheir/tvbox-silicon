import Foundation
import Testing
@testable import TVCore

@Test func diskCachePersistsExpiresAndRejectsDownloadsFromBeforeDeletion() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = MediaCache(root: root, budget: 100)
    let now = Date()
    let old = cache.ticket()
    #expect(cache.store(Data([1,2,3]), for: "episode1", kind: .danmaku, scope: "series", ttl: 60, ticket: old, now: now))
    #expect(MediaCache(root: root, budget: 100).data(for: "episode1", kind: .danmaku, scope: "series", now: now) == Data([1,2,3]))
    cache.remove(scope: "series")
    #expect(cache.data(for: "episode1", kind: .danmaku, scope: "series") == nil)
    #expect(!cache.store(Data([4]), for: "late", kind: .danmaku, scope: "series", ttl: 60, ticket: old))
    cache.store(Data([5]), for: "short", kind: .artwork, ttl: 1, ticket: cache.ticket(), now: now)
    #expect(cache.data(for: "short", kind: .artwork, now: now.addingTimeInterval(2)) == nil)
    let beforeClear = cache.ticket()
    cache.clear()
    #expect(!cache.store(Data([6]), for: "late", kind: .artwork, ttl: 60, ticket: beforeClear))
    #expect(cache.summary().bytes == 0)
}

@Test func cacheRetainsOnlyTwentyWorkMappingsAndProtectsHistoryUnderPressure() {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = MediaCache(root: root, budget: 100)
    let now = Date()
    for index in 0..<22 {
        cache.store(Data([UInt8(index)]), for: String(index), kind: .lookup, ttl: 100, ticket: cache.ticket(), now: now.addingTimeInterval(Double(index)))
    }
    #expect(cache.summary(now: now).lookups == 20)
    #expect(cache.data(for: "0", kind: .lookup, now: now) == nil)
    #expect(cache.data(for: "21", kind: .lookup, now: now) != nil)
    cache.clear(); cache.prioritize(["history"])
    cache.store(Data(repeating: 1, count: 60), for: "saved", kind: .danmaku, scope: "history", ttl: 100, ticket: cache.ticket(), now: now)
    cache.store(Data(repeating: 2, count: 60), for: "browsing", kind: .artwork, ttl: 100, ticket: cache.ticket(), now: now.addingTimeInterval(1))
    #expect(cache.data(for: "saved", kind: .danmaku, scope: "history", now: now) != nil)
    #expect(cache.data(for: "browsing", kind: .artwork, now: now) == nil)
    #expect(cache.summary(now: now).bytes == 60)
}

@Test @MainActor func deletingHistoryCleansSeriesContentAndTimesButKeepsAddressMappings() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let suite = "history-cache." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
    let cache = MediaCache(root: root.appending(path: "cache"))
    let history = PlaybackHistory(file: root.appending(path: "history.json"), cache: cache, defaults: defaults)
    let context = PlaybackHistoryContext(origin: URL(string: "https://example.com/sub")!, sourceKey: "a", sourceName: "Source", videoID: "v", videoName: "Series",
        poster: URL(string: "https://example.com/poster.jpg"), episodeID: "e", episodeName: "第1集", episodeFlag: "line")
    history.record(context, position: 10, duration: 2000)
    EpisodeSkipSettings(enabled: true, introEnd: 90).save(scope: context.id, defaults: defaults)
    let ticket = cache.ticket()
    for kind in [MediaCache.Kind.danmaku, .catalog] { cache.store(Data([1]), for: "content", kind: kind, scope: context.id, ttl: 100, ticket: ticket) }
    cache.store(Data([2]), for: "cover", kind: .artwork, scope: PosterResource.artworkScope(context.poster!), ttl: 100, ticket: ticket)
    cache.store(Data([3]), for: "address", kind: .lookup, ttl: 100, ticket: ticket)
    history.remove([context.id])
    #expect(history.entries.isEmpty)
    #expect(cache.summary().danmaku == 0)
    #expect(cache.summary().catalogs == 0)
    #expect(cache.summary().artwork == 0)
    #expect(cache.summary().lookups == 1)
    #expect(EpisodeSkipSettings.load(scope: context.id, defaults: defaults).introEnd == 0)
    #expect(!cache.store(Data([4]), for: "late", kind: .danmaku, scope: context.id, ttl: 100, ticket: ticket))
    history.record(context, position: 12, duration: 2000)
    EpisodeSkipSettings(enabled: true, introEnd: 45).save(scope: context.id, defaults: defaults)
    cache.clear()
    #expect(history.entries.count == 1)
    #expect(EpisodeSkipSettings.load(scope: context.id, defaults: defaults).introEnd == 45)
}

@Test @MainActor func sourcePinsPersistAreSubscriptionQualifiedAndKeepOtherOrdering() throws {
    let suite = "pins." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let config = try Subscription.parse(Data(#"{"sites":[{"key":"a","name":"A","type":1,"api":"https://example.com/a"},{"key":"b","name":"B","type":1,"api":"https://example.com/b"},{"key":"c","name":"C","type":1,"api":"https://example.com/c"}]}"#.utf8), origin: URL(string: "https://example.com/sub")!)
    let pins = PinnedSources(defaults: defaults)
    pins.toggle(config.sites[2], origin: config.origin); pins.toggle(config.sites[0], origin: config.origin)
    #expect(pins.arrange(config.sites, origin: config.origin).map(\.key) == ["c","a","b"])
    #expect(PinnedSources(defaults: defaults).contains(config.sites[2], origin: config.origin))
    #expect(!pins.contains(config.sites[2], origin: URL(string: "https://other.example/sub")!))
    pins.toggle(config.sites[2], origin: config.origin)
    #expect(pins.arrange(config.sites, origin: config.origin).map(\.key) == ["a","b","c"])
}
