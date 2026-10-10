import SwiftUI
import AVKit
import TVCore
import UniformTypeIdentifiers

@MainActor @Observable final class DanmakuModel {
    private(set) var comments: [DanmakuComment] = []
    private(set) var track = ""
    private(set) var revision = UUID()
    var time = 0.0
    var videoSize = CGSize.zero
    var offset = 0.0
    var enabled = UserDefaults.standard.object(forKey: "danmakuEnabled") == nil ? true : UserDefaults.standard.bool(forKey: "danmakuEnabled") {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "danmakuEnabled")
            if !enabled { cancelAutomatic() }
            else if comments.isEmpty { startAutomatic(automaticContext) }
        }
    }
    var automatic = UserDefaults.standard.object(forKey: "danmakuAutoMatch") == nil ? true : UserDefaults.standard.bool(forKey: "danmakuAutoMatch") {
        didSet {
            UserDefaults.standard.set(automatic, forKey: "danmakuAutoMatch")
            if automatic { startAutomatic(automaticContext) } else { cancelAutomatic() }
        }
    }
    var opacity = UserDefaults.standard.object(forKey: "danmakuOpacity") as? Double ?? 0.85 {
        didSet { UserDefaults.standard.set(opacity, forKey: "danmakuOpacity") }
    }
    var fontSize = UserDefaults.standard.object(forKey: "danmakuFontSize") as? Double ?? 22 {
        didSet { UserDefaults.standard.set(fontSize, forKey: "danmakuFontSize") }
    }
    private var generation = UUID()
    private var automaticTask: Task<Void, Never>?
    private var automaticContext: PlaybackHistoryContext?
    private(set) var automaticState = "idle"

    func startAutomatic(_ context: PlaybackHistoryContext?) {
        cancelAutomatic()
        automaticContext = context
        guard let context, automatic, enabled, comments.isEmpty else { return }
        let active = generation
        automaticState = "searching"
        automaticTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == active { self.automaticTask = nil } }
            do {
                let client = try DanmakuClient(address: UserDefaults.standard.string(forKey: "danmakuServer") ?? DanmakuClient.defaultServer)
                let results = try await client.search(context.videoName)
                try Task.checkCancellation()
                guard self.generation == active else { return }
                guard let anime = DanmakuMatcher.anime(title: context.videoName, in: results) else {
                    self.automaticState = "unmatched"; return
                }
                let episodes = try await client.episodes(anime)
                try Task.checkCancellation()
                guard self.generation == active else { return }
                guard let episode = DanmakuMatcher.episode(name: context.episodeName, in: episodes) else {
                    self.automaticState = "unmatched"; return
                }
                let comments = try await client.comments(episode)
                try Task.checkCancellation()
                guard self.generation == active, self.enabled, self.automatic else { return }
                self.comments = comments
                self.track = comments.isEmpty ? "" : anime.title + " · " + episode.title
                self.offset = 0; self.revision = UUID()
                self.automaticState = comments.isEmpty ? "unmatched" : "loaded"
            } catch {
                guard self.generation == active else { return }
                // Optional overlay failures never interrupt video playback or show alerts.
                self.automaticState = error is CancellationError ? "idle" : "unavailable"
            }
        }
    }

    private func cancelAutomatic() {
        generation = UUID(); automaticTask?.cancel(); automaticTask = nil; automaticState = "idle"
    }

    func load(_ episode: DanmakuEpisode, anime: DanmakuAnime, client: DanmakuClient) async throws {
        cancelAutomatic(); automaticContext = nil
        let active = UUID(); generation = active
        let comments = try await client.comments(episode)
        try Task.checkCancellation()
        guard generation == active else { throw CancellationError() }
        self.comments = comments; track = anime.title + " · " + episode.title
        offset = 0; revision = UUID(); enabled = true
    }

    func clear() {
        cancelAutomatic(); automaticContext = nil
        comments = []; track = ""; offset = 0; time = 0; revision = UUID()
    }

    func importFile(_ url: URL) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= DanmakuParser.maximumBytes else { throw TVError.unsupported(L10n.text("The danmaku file is too large.")) }
        let parsed = try DanmakuParser.parse(Data(contentsOf: url, options: .mappedIfSafe))
        cancelAutomatic(); automaticContext = nil
        comments = parsed; track = url.deletingPathExtension().lastPathComponent
        offset = 0; revision = UUID(); enabled = true
    }
}

/// Draw only the comments visible at the player's current media time. No view or
/// animation is allocated per comment, and pause/seek/rate changes stay in sync.
struct DanmakuOverlay: View {
    let model: DanmakuModel
    var fitVideo = true
    @State private var timeline: DanmakuTimeline?
    private struct LayoutKey: Hashable { let revision: UUID; let width: Double; let height: Double; let font: Double }

    var body: some View {
        GeometryReader { geometry in
            let bounds = CGRect(origin: .zero, size: geometry.size)
            let area = fitVideo && model.videoSize.width > 0 && model.videoSize.height > 0
                ? AVMakeRect(aspectRatio: model.videoSize, insideRect: bounds) : bounds
            let key = LayoutKey(revision: model.revision, width: area.width, height: area.height, font: model.fontSize)
            let mediaTime = model.time - model.offset
            let enabled = model.enabled
            let opacity = model.opacity
            Canvas { context, size in
                guard enabled, let timeline else { return }
                let time = mediaTime
                let font = min(36, max(16, model.fontSize))
                let rowHeight = font + 8
                for item in timeline.visible(at: time) {
                    let comment = item.comment
                    let age = time - comment.time
                    let color = Color(red: Double((comment.color >> 16) & 255) / 255,
                                      green: Double((comment.color >> 8) & 255) / 255,
                                      blue: Double(comment.color & 255) / 255)
                    let text = Text(comment.text).font(.system(size: font, weight: .semibold)).foregroundColor(color)
                    let x = comment.mode == .scroll ? size.width - age * timeline.speed + item.width / 2 : size.width / 2
                    let y: Double
                    switch comment.mode {
                    case .scroll: y = max(40, size.height * 0.08) + Double(item.lane + 2) * rowHeight
                    case .top: y = max(40, size.height * 0.08) + Double(item.lane) * rowHeight
                    case .bottom: y = size.height * 0.74 - Double(item.lane) * rowHeight
                    }
                    var drawing = context
                    drawing.opacity = min(1, max(0.2, opacity))
                    drawing.addFilter(.shadow(color: .black, radius: 2))
                    drawing.draw(text, at: CGPoint(x: x, y: y))
                }
            }
            .frame(width: area.width, height: area.height)
            .position(x: area.midX, y: area.midY)
            .task(id: key) {
                timeline = DanmakuTimeline(comments: model.comments, width: max(1, key.width),
                    lanes: max(1, min(6, Int((key.height * 0.6 - max(40, key.height * 0.08)) / (key.font + 8)) - 2)), fontSize: key.font)
            }
        }
        .clipped().allowsHitTesting(false).accessibilityHidden(true)
    }
}

#if !os(tvOS)
struct DanmakuSettingsView: View {
    let model: DanmakuModel
    let channelName: String
    @Environment(\.dismiss) private var dismiss
    @AppStorage("danmakuServer") private var server = DanmakuClient.defaultServer
    @State private var keyword = ""
    @State private var animes: [DanmakuAnime] = []
    @State private var episodes: [DanmakuEpisode] = []
    @State private var selectedAnime: DanmakuAnime?
    @State private var busy = false
    @State private var searched = false
    @State private var error: String?
    @State private var work: Task<Void, Never>?
    @State private var showsImporter = false

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    Toggle(L10n.text("Show Danmaku"), isOn: $model.enabled).accessibilityIdentifier("danmaku.enabled")
                    Toggle(L10n.text("Automatically match the current episode"), isOn: $model.automatic)
                        .accessibilityIdentifier("danmaku.automatic")
                    Text(L10n.text("Matching comments appear automatically. If none match or the service is unavailable, the video stays clear."))
                        .font(.caption).foregroundStyle(.secondary)
                    if !model.track.isEmpty {
                        Text(model.track).font(.subheadline)
                        Text(L10n.text("Loaded %lld comments", model.comments.count)).foregroundStyle(.secondary)
                        HStack {
                            Text(L10n.text("Opacity"))
                            Slider(value: $model.opacity, in: 0.2...1)
                        }
                        HStack {
                            Text(L10n.text("Text Size"))
                            Slider(value: $model.fontSize, in: 16...36, step: 2)
                        }
                        Stepper(value: $model.offset, in: -300...300, step: 0.5) {
                            Text(L10n.text("Time Offset: %@ s", String(format: "%+.1f", model.offset)))
                        }
                        Text(L10n.text("A positive offset shows comments later. Playback controls stay available."))
                            .font(.caption).foregroundStyle(.secondary)
                        Button(L10n.text("Clear Danmaku"), role: .destructive) { work?.cancel(); busy = false; model.clear() }
                    }
                }
                Section {
                    HStack {
                        TextField(L10n.text("Video title"), text: $keyword).onSubmit { search() }.accessibilityIdentifier("danmaku.keyword")
                        Button(L10n.text("Search")) { search() }.disabled(busy || keyword.trimmingCharacters(in: .whitespaces).isEmpty).accessibilityIdentifier("danmaku.search")
                    }
                    if busy { ProgressView(L10n.text("Loading…")) }
                    if let error { Text(error).foregroundStyle(.red).font(.callout) }
                    if let anime = selectedAnime {
                        Button(L10n.text("Back to search results")) { work?.cancel(); busy = false; selectedAnime = nil; episodes = []; error = nil }
                        Text(anime.title).font(.headline)
                        ForEach(episodes) { episode in
                            Button(episode.title) { load(episode, anime: anime) }.disabled(busy).accessibilityIdentifier("danmaku.episode." + episode.id)
                        }
                    } else {
                        ForEach(animes) { anime in
                            Button { select(anime) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(anime.title)
                                    if !anime.type.isEmpty { Text(anime.type).font(.caption).foregroundStyle(.secondary) }
                                }
                            }.disabled(busy).accessibilityIdentifier("danmaku.anime." + anime.id)
                        }
                        if searched && animes.isEmpty && !busy && error == nil {
                            Text(L10n.text("No danmaku found. Try another title or server.")).foregroundStyle(.secondary)
                        }
                    }
                } header: { Text(L10n.text("Find Danmaku")) }
                  footer: { Text(L10n.text("Search sends only the title to the selected danmaku service. Choose the correct season and episode; some videos have no comments.")) }
                Section {
                    Button(L10n.text("Import Danmaku File")) { showsImporter = true }.disabled(busy)
                } footer: { Text(L10n.text("Import Bilibili XML or Dandanplay JSON from Files. Imported comments do not require a network connection.")) }
                Section {
                    TextField(L10n.text("Danmaku server URL"), text: $server)
                        #if os(iOS)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        #endif
                        .onChange(of: server) { _, _ in
                            work?.cancel(); busy = false; animes = []; episodes = []; selectedAnime = nil; searched = false; error = nil
                        }
                    Button(L10n.text("Use Default URL")) { server = DanmakuClient.defaultServer }
                } header: { Text(L10n.text("Danmaku Service")) }
                  footer: { Text(L10n.text("Uses a public Dandanplay-compatible service. You can enter your own danmu_api server. Availability depends on the service.")) }
            }
            .navigationTitle(L10n.text("Danmaku"))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("Done")) { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 500)
        #endif
        .onAppear { keyword = channelName.components(separatedBy: " · ").first ?? channelName }
        .onDisappear { work?.cancel() }
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.xml, .json]) { result in
            do { try model.importFile(result.get()); dismiss() }
            catch { self.error = error.localizedDescription }
        }
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        work?.cancel(); busy = true; error = nil
        work = Task { @MainActor in
            do { try await operation() }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            if !Task.isCancelled { busy = false }
        }
    }
    private func search() {
        guard !busy else { return }
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        selectedAnime = nil; episodes = []; animes = []; searched = true
        let address = server
        perform {
            let results = try await DanmakuClient(address: address).search(query)
            try Task.checkCancellation(); animes = results
        }
    }
    private func select(_ anime: DanmakuAnime) {
        let address = server
        perform {
            let results = try await DanmakuClient(address: address).episodes(anime)
            try Task.checkCancellation(); episodes = results; selectedAnime = anime
            if results.isEmpty { error = L10n.text("No danmaku found. Try another title or server.") }
        }
    }
    private func load(_ episode: DanmakuEpisode, anime: DanmakuAnime) {
        let address = server
        perform { try await model.load(episode, anime: anime, client: DanmakuClient(address: address)); dismiss() }
    }
}
#endif
