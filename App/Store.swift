import SwiftUI
import TVCore

@MainActor @Observable final class Store {
    static let defaultURL = "https://cdn.jsdelivr.net/gh/adolfheir/tvbox@master/fty.json"
    let searchModel = SearchModel()
    let recommendationModel = RecommendationModel()
    let playbackHistory: PlaybackHistory
    let playbackDefaults: UserDefaults
    let pinnedSources: PinnedSources
    var resumingHistoryID: String?
    var subscription: Subscription?
    var subscriptionAddress: String
    var favorites: [Channel] = []
    var importing = false
    var error: String?
    var notice: String?
    var playing: Channel?
    var playbackCatalog: PlaybackCatalog?
    var resolvingEpisode: Episode?
    var episodeError: String?
    var autoPlayNext: Bool {
        didSet { if persistsChanges { defaults.set(autoPlayNext, forKey: "autoPlayNextEpisode") } }
    }
    private var episodeRequest = UUID()
    private var episodeTask: Task<Void, Never>?
    var section: AppSection = .home
    private let defaults: UserDefaults
    private let http = HTTPClient()
    private var persistsChanges: Bool {
        #if DEBUG
        return !defaults.bool(forKey: "qaIsolatedData")
        #else
        return true
        #endif
    }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        #if DEBUG
        playbackDefaults = defaults.bool(forKey: "qaIsolatedData")
            ? UserDefaults(suiteName: "com.tvbox.yingxia.qa.player") ?? defaults : defaults
        playbackHistory = defaults.bool(forKey: "qaIsolatedData")
            ? PlaybackHistory(file: URL.cachesDirectory.appending(path: "qa-player-history.json"), defaults: playbackDefaults) : .shared
        #else
        playbackDefaults = defaults
        playbackHistory = .shared
        #endif
        pinnedSources = PinnedSources(defaults: playbackDefaults)
        autoPlayNext = defaults.object(forKey: "autoPlayNextEpisode") == nil || defaults.bool(forKey: "autoPlayNextEpisode")
        subscriptionAddress = defaults.string(forKey: "subscriptionAddress") ?? Self.defaultURL
        let cached = (try? Data(contentsOf: Self.subscriptionFile)) ?? defaults.data(forKey: "subscription")
        if let cached { subscription = try? JSONDecoder().decode(Subscription.self, from: cached) }
        if let subscription { Self.registerPlugins(subscription) }
        // Older builds kept the whole subscription in defaults; move it to the file and drop the key.
        if persistsChanges, let legacy = defaults.data(forKey: "subscription") {
            try? Self.saveSubscription(legacy)
            defaults.removeObject(forKey: "subscription")
        }
        if let data = defaults.data(forKey: "favorites") { favorites = (try? JSONDecoder().decode([Channel].self, from: data)) ?? [] }
    }
    /// Large subscriptions run to megabytes, past the defaults size limit that aborts tvOS apps,
    /// so the parsed subscription lives in a file. tvOS only offers Caches, which the system may purge;
    /// `restoreSubscription()` refetches it from the saved address when that happens.
    private static var subscriptionFile: URL {
        #if os(tvOS)
        let directory = URL.cachesDirectory
        #else
        let directory = URL.applicationSupportDirectory
        #endif
        return directory.appending(path: "subscription.json")
    }
    private static func saveSubscription(_ data: Data) throws {
        try FileManager.default.createDirectory(at: subscriptionFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: subscriptionFile, options: .atomic)
    }
    /// Lets sources on a shared spider borrow classes from the subscription's other plugin archives.
    private static func registerPlugins(_ subscription: Subscription) {
        let archives = subscription.pluginArchives
        Task { await PluginLocator.shared.use(archives) }
    }
    /// Refetches a previously imported subscription whose cached copy is gone.
    func restoreSubscription() async {
        guard subscription == nil, defaults.string(forKey: "subscriptionAddress") != nil else { return }
        await importSubscription()
    }
    func importSubscription(address: String? = nil) async {
        guard !importing else { return }
        importing = true; error = nil; notice = nil
        defer { importing = false }
        do {
            let url = try WebAddress.resolve(address ?? subscriptionAddress)
            let value = try await http.subscription(url)
            if persistsChanges {
                try Self.saveSubscription(JSONEncoder().encode(value))
                defaults.set(url.absoluteString, forKey: "subscriptionAddress")
            }
            subscriptionAddress = url.absoluteString
            searchModel.reset()
            recommendationModel.reset()
            subscription = value
            Self.registerPlugins(value)
            notice = L10n.text("Imported sources: %lld · Live playlists: %lld", value.sites.count, value.lives.count)
        } catch { self.error = L10n.text("Import failed: %@", error.localizedDescription) }
    }
    func searchVideos(_ title: String) {
        guard let config = subscription else { return }
        let keyword = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return }
        let old = defaults.data(forKey: "videoSearchHistory").flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        defaults.set(try? JSONEncoder().encode(Array(([keyword] + old.filter { $0 != keyword }).prefix(20))), forKey: "videoSearchHistory")
        searchModel.search(keyword, config: config)
        section = .search
    }
    func toggleFavorite(_ channel: Channel) {
        if let index = favorites.firstIndex(where: { $0.id == channel.id }) { favorites.remove(at: index) }
        else { favorites.append(channel) }
        defaults.set(try? JSONEncoder().encode(favorites), forKey: "favorites")
    }
    func isFavorite(_ channel: Channel) -> Bool { favorites.contains { $0.id == channel.id } }

    func orderedSites(_ config: Subscription) -> [Site] {
        pinnedSources.arrange(SourceStrategy.arrange(config.sites) { !$0.hidden && $0.canBrowse(jarURL: config.spiderURL) }, origin: config.origin)
    }

    func catalogChannel(_ resolved: Channel, video: Video, episode: Episode, client: CatalogClient,
                        resumePosition: Double? = nil) -> Channel {
        let context = PlaybackHistoryContext(origin: client.origin, site: client.site, video: video, episode: episode)
        if let data = try? JSONEncoder().encode(video) {
            MediaCache.shared.store(data, for: "detail", kind: .catalog, scope: context.id, ttl: 6 * 3600, ticket: MediaCache.shared.ticket())
        }
        playbackCatalog = PlaybackCatalog(video: video, client: client.with(parses: subscription?.parseServices ?? client.parses), scope: context.id)
        return Channel(name: "\(video.name) · \(episode.name)", group: resolved.group, url: resolved.url,
                       logo: resolved.logo, headers: resolved.headers, skipScope: context.id,
                       historyContext: context, resumePosition: resumePosition)
    }

    func catalog(for channel: Channel) -> PlaybackCatalog? {
        guard let catalog = playbackCatalog, catalog.scope == channel.historyContext?.id else { return nil }
        return catalog
    }

    func nextEpisode(after channel: Channel) -> Episode? {
        guard let context = channel.historyContext else { return nil }
        return catalog(for: channel)?.playlist.next(after: context)
    }

    func selectEpisode(_ episode: Episode, from channel: Channel) {
        guard playing == channel, let catalog = catalog(for: channel),
              catalog.video.episodes.contains(episode) else { return }
        cancelEpisodeSelection()
        let request = episodeRequest
        resolvingEpisode = episode; episodeError = nil
        episodeTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.episodeRequest == request { self.resolvingEpisode = nil; self.episodeTask = nil } }
            do {
                let resolved = try await catalog.client.playback(episode)
                guard !Task.isCancelled, self.episodeRequest == request, self.playing == channel else { return }
                self.playing = self.catalogChannel(resolved, video: catalog.video, episode: episode, client: catalog.client)
            } catch {
                guard !Task.isCancelled, self.episodeRequest == request, self.playing == channel else { return }
                self.episodeError = error.localizedDescription
            }
        }
    }

    func cancelEpisodeSelection() {
        episodeRequest = UUID()
        episodeTask?.cancel(); episodeTask = nil; resolvingEpisode = nil
    }

    func resumeHistory(_ entry: PlaybackHistoryEntry) async {
        guard resumingHistoryID == nil else { return }
        guard let config = subscription, config.origin == entry.context.origin,
              let site = config.sites.first(where: { $0.key == entry.context.sourceKey }) else {
            error = L10n.text("This history source is no longer in the current subscription. Restore that subscription to continue.")
            return
        }
        resumingHistoryID = entry.id
        let previousPlayback = playing
        defer { resumingHistoryID = nil }
        do {
            let client = CatalogClient(site: site, origin: config.origin, jarURL: config.spiderURL).with(parses: config.parseServices)
            // Plugin/API sources resolve an episode again. Direct-file APIs must refresh
            // their detail first so an expiring media address never becomes a resume shortcut.
            var video = try await client.detail(entry.context.videoID, cached: site.type == 3 || site.type == 4)
            guard var episode = entry.context.episode(in: video.episodes) else {
                throw TVError.unsupported(L10n.text("The saved episode is no longer available from this source. Choose an episode again."))
            }
            let channel: Channel
            do { channel = try await client.playback(episode) }
            catch {
                try Task.checkCancellation()
                video = try await client.detail(entry.context.videoID)
                guard let refreshed = entry.context.episode(in: video.episodes) else { throw error }
                episode = refreshed
                channel = try await client.playback(refreshed)
            }
            guard !Task.isCancelled, playing == previousPlayback, subscription?.origin == config.origin else { return }
            playing = catalogChannel(channel, video: video, episode: episode, client: client, resumePosition: entry.resumePosition)
        } catch {
            guard !(error is CancellationError) else { return }
            self.error = L10n.text("Unable to resume playback: %@", error.localizedDescription)
        }
    }
}

struct PlaybackCatalog {
    let video: Video
    let client: CatalogClient
    let scope: String
    var playlist: EpisodePlaylist { EpisodePlaylist(video.episodes) }
}
