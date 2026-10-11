import Foundation

public struct DanmakuResolver: Sendable {
    public let cache: MediaCache
    public let http: DanmakuHTTP
    public let dandanServer: String
    public let dmkuServer: URL
    public let officialLookup: Bool
    public init(cache: MediaCache = .shared, http: DanmakuHTTP = .init(),
                dandanServer: String = DanmakuClient.defaultServer, dmkuServer: URL = URL(string: "https://dmku.hls.one/")!,
                officialLookup: Bool = true) {
        self.cache = cache; self.http = http; self.dandanServer = (try? DanmakuClient(address: dandanServer).server.absoluteString) ?? dandanServer
        self.dmkuServer = dmkuServer; self.officialLookup = officialLookup
    }
    public static func episodeKey(_ context: PlaybackHistoryContext) -> String {
        DanmakuMatcher.episodeNumber(context.episodeName).map { "episode:\($0)" } ?? context.episodeName
    }
    private func lookupKey(_ context: PlaybackHistoryContext) -> String {
        String(data: try! JSONEncoder().encode([DanmakuMatcher.normalized(context.videoName), context.year ?? "", dandanServer, dmkuServer.absoluteString]), encoding: .utf8)!
    }
    private struct Outcome: Sendable {
        var result: AutomaticDanmakuResult?
        var mapping: DanmakuMapping?
        var responded = false
    }
    public func remember(_ mapping: DanmakuMapping, for context: PlaybackHistoryContext, ticket: MediaCache.Ticket) {
        let key = lookupKey(context)
        var mappings = cache.data(for: key, kind: .lookup).flatMap { try? JSONDecoder().decode([DanmakuMapping].self, from: $0) } ?? []
        mappings.removeAll { $0.provider == mapping.provider }; mappings.append(mapping)
        if let data = try? JSONEncoder().encode(mappings) {
            cache.store(data, for: key, kind: .lookup, ttl: 30 * 86400, ticket: ticket)
        }
    }
    public func resolve(_ context: PlaybackHistoryContext, ticket: MediaCache.Ticket? = nil) async throws -> AutomaticDanmakuResult {
        let ticket = ticket ?? cache.ticket()
        let key = Self.episodeKey(context)
        if let data = cache.data(for: key, kind: .danmaku, scope: context.id),
           var result = try? JSONDecoder().decode(AutomaticDanmakuResult.self, from: data),
           ["loaded", "unmatched", "unavailable"].contains(result.state) {
            result.cached = true; return result
        }
        let lookupKey = lookupKey(context)
        var mappings = cache.data(for: lookupKey, kind: .lookup).flatMap { try? JSONDecoder().decode([DanmakuMapping].self, from: $0) } ?? []
        let saved = mappings
        return try await withThrowingTaskGroup(of: Outcome.self) { group in
            group.addTask { await self.dandan(context, cached: saved.first { $0.provider == "dandan" }) }
            if let page = context.officialPage.flatMap({ OfficialVideoPage.validated($0.absoluteString) }) {
                group.addTask {
                    let mapping = DanmakuMapping(provider: "direct", title: context.videoName, year: context.year,
                        tracks: [DanmakuTrack(number: DanmakuMatcher.episodeNumber(context.episodeName), title: context.episodeName, page: page)])
                    return await self.official(context, provider: "direct", cached: mapping)
                }
            } else if officialLookup {
                for provider in ["iqiyi", "tencent"] {
                    group.addTask { await self.official(context, provider: provider, cached: saved.first { $0.provider == provider }) }
                }
            }
            var responded = false
            for try await outcome in group {
                try Task.checkCancellation()
                responded = responded || outcome.responded
                if let mapping = outcome.mapping, !mapping.tracks.isEmpty {
                    mappings.removeAll { $0.provider == mapping.provider }
                    mappings.append(mapping)
                    if let data = try? JSONEncoder().encode(mappings) {
                        cache.store(data, for: lookupKey, kind: .lookup, ttl: 30 * 86400, ticket: ticket)
                    }
                }
                if let result = outcome.result, !result.comments.isEmpty {
                    group.cancelAll()
                    if let data = try? JSONEncoder().encode(result) {
                        cache.store(data, for: key, kind: .danmaku, scope: context.id, ttl: 7 * 86400, ticket: ticket)
                    }
                    return result
                }
            }
            let result = AutomaticDanmakuResult(comments: [], track: "", source: "", state: responded ? "unmatched" : "unavailable")
            // Short negative caching prevents repeated searches during rapid revisits.
            // An explicit retry bypasses it, and failures expire much sooner than real tracks.
            if let data = try? JSONEncoder().encode(result) {
                cache.store(data, for: key, kind: .danmaku, scope: context.id, ttl: responded ? 300 : 30, ticket: ticket)
            }
            return result
        }
    }
    private func official(_ context: PlaybackHistoryContext, provider: String, cached: DanmakuMapping?) async -> Outcome {
        let started = Date()
        var stage = "lookup"
        do {
            var mapping = cached
            if mapping?.track(for: context) == nil {
                let catalog = OfficialDanmakuCatalog(http: http)
                mapping = try await provider == "iqiyi" ? catalog.iqiyi(context) : catalog.tencent(context)
            }
            guard let mapping, let track = mapping.track(for: context), let page = track.page,
                  let safe = OfficialVideoPage.validated(page.absoluteString) else { return Outcome(mapping: mapping, responded: true) }
            stage = "comments"
            var url = URLComponents(url: dmkuServer, resolvingAgainstBaseURL: false)!
            url.queryItems = [.init(name: "ac", value: "dm"), .init(name: "url", value: safe.absoluteString)]
            let request = URLRequest(url: url.url!, timeoutInterval: 35)
            let comments = try DanmakuParser.parse(await http.send(request))
            try Task.checkCancellation()
            Diagnostics.shared.record(.debug, "danmaku", "provider=\(provider) comments=\(comments.count) seconds=\(Int(Date().timeIntervalSince(started)))")
            return Outcome(result: AutomaticDanmakuResult(comments: comments, track: mapping.title + " · " + track.title,
                source: "dmku · " + provider, state: comments.isEmpty ? "unmatched" : "loaded"), mapping: mapping, responded: true)
        } catch {
            if !(error is CancellationError) {
                let failure = error as NSError
                Diagnostics.shared.record(.debug, "danmaku", "provider=\(provider) stage=\(stage) failed=\(failure.domain):\(failure.code) seconds=\(Int(Date().timeIntervalSince(started)))")
            }
            return Outcome()
        }
    }
    private func dandan(_ context: PlaybackHistoryContext, cached: DanmakuMapping?) async -> Outcome {
        do {
            let client = try DanmakuClient(address: dandanServer, transport: http)
            var mapping = cached
            if mapping?.track(for: context) == nil {
                guard let anime = DanmakuMatcher.anime(title: context.videoName, in: try await client.search(context.videoName)) else { return Outcome(responded: true) }
                let episodes = try await client.episodes(anime)
                mapping = DanmakuMapping(provider: "dandan", title: anime.title, year: nil,
                    tracks: episodes.map { DanmakuTrack(number: DanmakuMatcher.episodeNumber($0.title), title: $0.title, id: $0.id) })
            }
            guard let mapping, let track = mapping.track(for: context), let id = track.id else { return Outcome(mapping: mapping, responded: true) }
            let comments = try await client.comments(DanmakuEpisode(id: id, title: track.title))
            try Task.checkCancellation()
            return Outcome(result: AutomaticDanmakuResult(comments: comments, track: mapping.title + " · " + track.title,
                source: "Dandanplay", state: comments.isEmpty ? "unmatched" : "loaded"), mapping: mapping, responded: true)
        } catch { return Outcome() }
    }
}
