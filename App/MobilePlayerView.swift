#if os(iOS)
import SwiftUI
import AVKit
import TVCore

/// One transport surface owns touch handling. AVKit only renders video, so its
/// controls and full-screen recognizers cannot compete with our buttons.
struct PlaybackView: View {
    let channel: Channel
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var session = PlaybackSession()
    @State private var showsControls = true
    @State private var hideTask: Task<Void, Never>?
    @State private var panel: PlayerPanel?
    @State private var scrubbing = false
    @State private var scrubPosition = 0.0
    @State private var swipe: PlaybackScrub?
    @State private var swipeTarget = 0.0
    @State private var swipeRejected = false
    @GestureState private var swipeTouchActive = false
    @State private var fillsFrame = false
    @State private var previousIdleTimer: Bool?
    @State private var controlsLocked = false
    @State private var skipMark: EpisodeSkipMark?
    @State private var markedPosition: Double?
    @State private var showsSkipMark = false

    private var current: Channel { store.playing ?? channel }
    private var controlsVisible: Bool {
        if controlsLocked || swipe != nil { return false }
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "qaPlayerControls") { return true }
        #endif
        return showsControls || !session.isPlaying || session.loading || session.error != nil || panel != nil
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            NativePlayerView(player: session.player, danmaku: session.danmaku, fillsFrame: fillsFrame)
                .ignoresSafeArea().allowsHitTesting(false)
            GeometryReader { geometry in
              Color.clear.contentShape(Rectangle())
                .gesture(TapGesture(count: 2).exclusively(before: TapGesture()).onEnded { result in
                    guard !controlsLocked, swipe == nil else { return }
                    switch result {
                    case .first: session.togglePlayback(); poke()
                    case .second:
                        if controlsVisible && session.isPlaying { hideTask?.cancel(); showsControls = false }
                        else { poke() }
                    }
                })
                .simultaneousGesture(seekGesture(width: geometry.size.width))
                .accessibilityIdentifier("player.surface")
            }
            if controlsVisible { controls.transition(.opacity) }
            if let swipe { seekPreview(swipe) }
            if controlsLocked {
                iconButton("lock.fill", L10n.text("Unlock controls"), id: "player.unlock") {
                    controlsLocked = false; poke()
                }
                .background(.black.opacity(0.4), in: Circle()).foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing).padding(.trailing, 12)
            }
            if session.error != nil && !controlsLocked { failure }
            else if let episode = store.resolvingEpisode {
                ProgressView(L10n.text("Loading %@…", episode.name)).padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .allowsHitTesting(false)
            } else if session.loading || session.buffering {
                LoadingCard(appearAfter: session.loading ? 0 : 1.5) { session.loadingProgress }
                    .padding(.horizontal, 24).padding(.top, 78)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .allowsHitTesting(false)
            }
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "qaPlaybackProbe") { probe }
            #endif
        }
        .preferredColorScheme(.dark)
        .onAppear {
            session.history = store.playbackHistory
            session.skipDefaults = store.playbackDefaults
            previousIdleTimer = UIApplication.shared.isIdleTimerDisabled
            session.setPlaybackActive(scenePhase == .active)
            updateWakeLock()
            start(current)
        }
        .onChange(of: store.playing) { _, channel in if let channel { start(channel) } }
        .onChange(of: session.isPlaying) { _, playing in if playing { poke() } else { showsControls = true } }
        .onChange(of: swipeTouchActive) { _, active in
            if !active {
                // onEnded commits first; cancellation has no onEnded callback.
                Task { @MainActor in
                    guard !swipeTouchActive else { return }
                    resetSwipe()
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { resetSwipe(rejectRemainingTouch: true) }
            updateWakeLock()
            session.setPlaybackActive(phase == .active)
            if phase != .active { store.cancelEpisodeSelection() }
        }
        .onDisappear {
            resetSwipe(rejectRemainingTouch: true)
            hideTask?.cancel(); session.onPlaybackEnded = nil; session.stop()
            store.cancelEpisodeSelection()
            UIApplication.shared.isIdleTimerDisabled = previousIdleTimer ?? false
        }
        .sheet(item: $panel, onDismiss: { poke() }) { panel in
            switch panel {
            case .episodes: PlayerEpisodesView(channel: current) { episode in
                self.panel = nil
                store.selectEpisode(episode, from: current)
            }
            case .options: options
            case .danmaku: DanmakuSettingsView(model: session.danmaku, channelName: current.name)
            case .skip: EpisodeSkipSettingsView(session: session)
            }
        }
        .alert(L10n.text(skipMark == .intro ? "Intro" : "Outro"), isPresented: $showsSkipMark) {
            Button(L10n.text("Confirm")) { session.applySkipSettings(markedSettings) }
                .disabled(markedSettings.validationError(duration: session.duration) != nil)
                .accessibilityIdentifier("player.mark.confirm")
            Button(L10n.text("Cancel"), role: .cancel) {}
        } message: {
            let question = L10n.text(skipMark == .intro ? "Use %@ as the intro end?" : "Use %@ as the outro start?",
                                     EpisodeSkipSettings.formatTime(markedPosition ?? 0))
            Text(question + (markedSettings.validationError(duration: session.duration).map { "\n\n" + $0 } ?? ""))
        }
        .onChange(of: showsSkipMark) { _, showing in
            if !showing { session.endEditingSkip(); poke() }
        }
        .alert(L10n.text("Unable to Complete"), isPresented: Binding(get: { store.episodeError != nil }, set: { if !$0 { store.episodeError = nil } })) {
            Button(L10n.text("OK")) { store.episodeError = nil }
        } message: { Text(store.episodeError ?? "") }
        #if DEBUG
        .task {
            if UserDefaults.standard.bool(forKey: "qaDanmakuFile") {
                try? session.danmaku.importFile(URL.cachesDirectory.appending(path: "qa-danmaku.json"))
            }
            if let title = UserDefaults.standard.string(forKey: "qaDanmakuTitle") {
                do {
                    let client = try DanmakuClient()
                    let animes = try await client.search(title)
                    if let anime = animes.first(where: { $0.title == title }) ?? animes.first,
                       let episode = try await client.episodes(anime).first {
                        try await session.danmaku.load(episode, anime: anime, client: client)
                    }
                } catch { try? Data(error.localizedDescription.utf8).write(to: URL.cachesDirectory.appending(path: "qa-danmaku-error.txt")) }
            }
            if UserDefaults.standard.bool(forKey: "qaDanmakuSettings") { panel = .danmaku }
            if UserDefaults.standard.bool(forKey: "qaSkipSettings") {
                for _ in 0..<60 {
                    guard !Task.isCancelled else { return }
                    if session.duration > 0 { panel = .skip; break }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
        #endif
    }

    private var controls: some View {
        ZStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    iconButton("chevron.left", L10n.text("Close"), id: "player.close") { dismiss() }
                    Text(current.name).font(.headline).lineLimit(1).accessibilityIdentifier("player.title")
                    Spacer(minLength: 4)
                    if current.skipScope != nil {
                        Button { markSkip(.intro) } label: {
                            Text(L10n.text("Intro")).padding(.horizontal, 8).frame(minHeight: 48).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(session.loading).accessibilityIdentifier("player.markIntro")
                        Button { markSkip(.outro) } label: {
                            Text(L10n.text("Outro")).padding(.horizontal, 8).frame(minHeight: 48).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(session.loading).accessibilityIdentifier("player.markOutro")
                    }
                    iconButton("lock.open", L10n.text("Lock controls"), id: "player.lock") { controlsLocked = true; poke() }
                    iconButton("ellipsis", L10n.text("More"), id: "player.more") { panel = .options; poke() }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom))
                Spacer(minLength: 8)
                VStack(spacing: 6) {
                    Slider(value: Binding(get: { scrubbing ? scrubPosition : min(session.position, max(1, session.duration)) },
                                          set: { scrubPosition = $0 }), in: 0...max(1, session.duration)) { editing in
                        if editing { scrubbing = true; poke() }
                        else { session.seek(to: scrubPosition); scrubbing = false; poke() }
                    }
                    .tint(.white).disabled(session.duration <= 0 || session.loading)
                    .accessibilityLabel(L10n.text("Playback position"))
                    .accessibilityIdentifier("player.progress")
                    HStack(spacing: 12) {
                        Text("\(EpisodeSkipSettings.formatTime(scrubbing ? scrubPosition : session.position)) / \(EpisodeSkipSettings.formatTime(session.duration))")
                            .font(.caption).monospacedDigit()
                        Spacer(minLength: 0)
                        if store.catalog(for: current) != nil {
                            iconButton("forward.end.fill", L10n.text("Next episode"), id: "player.next") {
                                if let next = store.nextEpisode(after: current) { store.selectEpisode(next, from: current); poke() }
                            }.disabled(store.nextEpisode(after: current) == nil || store.resolvingEpisode != nil)
                            Button { panel = .episodes; poke() } label: {
                                Label(L10n.text("Episodes"), systemImage: "list.bullet")
                                    .font(.subheadline.weight(.semibold)).padding(.horizontal, 8).frame(minHeight: 48)
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityIdentifier("player.episodes")
                        }
                    }
                }
                .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 12)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom))
            }
            if session.error == nil && store.resolvingEpisode == nil {
                Button { session.togglePlayback(); poke() } label: {
                    Image(systemName: session.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 32, weight: .semibold)).frame(width: 80, height: 80)
                        .background(.black.opacity(0.35), in: Circle()).contentShape(Circle())
                }
                .buttonStyle(.plain).disabled(session.loading)
                .accessibilityLabel(L10n.text(session.isPlaying ? "Pause" : "Play"))
                .accessibilityValue(session.isPlaying ? "playing" : "paused")
                .accessibilityIdentifier("player.playPause")
                .keyboardShortcut(.space, modifiers: [])
            }
        }
        .foregroundStyle(.white)
    }

    private func iconButton(_ symbol: String, _ label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 20, weight: .semibold))
                .frame(width: 48, height: 48).contentShape(Rectangle()) }
            .buttonStyle(.plain).accessibilityLabel(label).accessibilityIdentifier(id)
    }

    private var options: some View {
        @Bindable var store = store
        return NavigationStack {
            Form {
                Section(L10n.text("Skip intro / outro")) {
                    Toggle(L10n.text("Auto skip"), isOn: Binding(get: { session.skipSettings.enabled }, set: {
                        var settings = session.skipSettings; settings.enabled = $0; session.applySkipSettings(settings)
                    })).accessibilityIdentifier("player.autoSkip")
                    if session.skipSettings.introEnd > 0 {
                        Button { panel = .skip } label: {
                            HStack { Text(L10n.text("Intro")); Spacer(); Text(EpisodeSkipSettings.formatTime(session.skipSettings.introEnd)).monospacedDigit() }
                        }.accessibilityIdentifier("player.skip")
                    }
                    if session.skipSettings.outroLength > 0 {
                        Button { panel = .skip } label: {
                            HStack { Text(L10n.text("Outro remaining")); Spacer(); Text(EpisodeSkipSettings.formatTime(session.skipSettings.outroLength)).monospacedDigit() }
                        }.accessibilityIdentifier("player.skip.outroTime")
                    }
                    Text(L10n.text("Applies to all films. The outro is remembered as time remaining."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    if store.catalog(for: current) != nil {
                        Toggle(L10n.text("Auto-play next episode"), isOn: $store.autoPlayNext)
                            .accessibilityIdentifier("player.autoNext")
                    }
                    Picker(L10n.text("Playback speed"), selection: Binding(get: { session.speed }, set: { session.setSpeed($0) })) {
                        ForEach([Float(0.5), 0.75, 1, 1.25, 1.5, 2], id: \.self) { Text(String(format: "%g×", $0)).tag($0) }
                    }
                    Toggle(L10n.text("Fill Window"), isOn: $fillsFrame)
                }
                Section {
                    Button { panel = .danmaku } label: { Label(L10n.text("Danmaku"), systemImage: "text.bubble") }
                        .accessibilityIdentifier("player.danmaku")
                }

            }
            .navigationTitle(L10n.text("Playback Options"))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("Done")) { panel = nil } } }
        }
        .presentationDetents([.medium, .large])
    }

    private var failure: some View {
        VStack(spacing: 16) {
            Text(session.error ?? "").multilineTextAlignment(.center)
            Button(L10n.text("Retry")) { start(current) }.buttonStyle(.borderedProminent)
        }
        .padding(24).frame(maxWidth: 440).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18)).padding()
    }

    private func start(_ channel: Channel) {
        resetSwipe(rejectRemainingTouch: true)
        scrubbing = false
        session.start(channel)
        if let catalog = store.catalog(for: channel), let next = store.nextEpisode(after: channel) {
            session.danmaku.prefetch(PlaybackHistoryContext(origin: catalog.client.origin, site: catalog.client.site, video: catalog.video, episode: next))
        }
        session.onPlaybackEnded = {
            poke()
            if scenePhase == .active, store.autoPlayNext, let next = store.nextEpisode(after: channel) { store.selectEpisode(next, from: channel) }
        }
        poke()
    }

    private func markSkip(_ mark: EpisodeSkipMark) {
        markedPosition = session.player.currentTime().seconds
        skipMark = mark
        session.beginEditingSkip()
        showsSkipMark = true; poke()
    }

    private var markedSettings: EpisodeSkipSettings {
        var settings = session.skipSettings
        if skipMark == .intro { settings.introEnd = markedPosition ?? .nan }
        else { settings.outroLength = session.duration - (markedPosition ?? .nan) }
        return settings
    }

    private func poke() {
        showsControls = true; hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled, session.isPlaying, panel == nil, !scrubbing, swipe == nil else { return }
            withAnimation(.easeOut(duration: 0.2)) { showsControls = false }
        }
    }

    private var canSwipeSeek: Bool {
        !controlsLocked && !session.loading && session.error == nil && !scrubbing &&
        panel == nil && !showsSkipMark && store.resolvingEpisode == nil && scenePhase == .active &&
        session.duration.isFinite && session.duration > 0
    }

    private func seekGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .updating($swipeTouchActive) { _, active, _ in active = true }
            .onChanged { value in
                guard canSwipeSeek, !swipeRejected else { return }
                if swipe == nil {
                    guard PlaybackScrub.isHorizontal(x: value.translation.width, y: value.translation.height) else {
                        swipeRejected = true; return
                    }
                    swipe = PlaybackScrub(position: session.player.currentTime().seconds,
                                          duration: session.duration, width: width)
                    hideTask?.cancel()
                }
                if let swipe { swipeTarget = swipe.target(translation: value.translation.width) }
            }
            .onEnded { value in
                if canSwipeSeek, let swipe {
                    session.seek(to: swipe.target(translation: value.translation.width))
                }
                resetSwipe()
            }
    }

    private func resetSwipe(rejectRemainingTouch: Bool = false) {
        let wasSeeking = swipe != nil
        swipe = nil; swipeRejected = rejectRemainingTouch && swipeTouchActive
        if wasSeeking { poke() }
    }

    private func seekPreview(_ swipe: PlaybackScrub) -> some View {
        let delta = swipeTarget - swipe.origin
        return VStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: delta < 0 ? "backward.fill" : "forward.fill")
                Text("\(delta < 0 ? "−" : "+")\(EpisodeSkipSettings.formatTime(abs(delta)))")
            }.font(.title2.weight(.semibold))
            Text("\(EpisodeSkipSettings.formatTime(swipeTarget)) / \(EpisodeSkipSettings.formatTime(swipe.duration))")
                .font(.headline)
            ProgressView(value: swipeTarget, total: swipe.duration).tint(.white)
            Text(L10n.text("Release to seek")).font(.caption).foregroundStyle(.white.opacity(0.8))
        }
        .monospacedDigit().padding(24).frame(width: 270)
        .foregroundStyle(.white).background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 16))
        .allowsHitTesting(false).accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("Playback position"))
        .accessibilityValue(String(swipeTarget)).accessibilityIdentifier("player.seekPreview")
    }

    private func updateWakeLock() {
        // Cover pause, seeking and buffering as well as active decoding. Restore
        // the prior application setting on exit; never write screen brightness.
        UIApplication.shared.isIdleTimerDisabled = scenePhase == .active ? true : previousIdleTimer ?? false
    }

    #if DEBUG
    private var probe: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
          VStack {
            Text(EpisodeSkipSettings.formatTime(session.position)).accessibilityIdentifier("player.qa.position").accessibilityValue(String(session.position))
            Text("Resume").accessibilityIdentifier("player.qa.resume").accessibilityValue(String(session.restoredPosition ?? -1))
            Text(session.danmaku.automaticState).accessibilityIdentifier("player.qa.danmaku").accessibilityValue(String(session.danmaku.comments.count))
            Text("Awake").accessibilityIdentifier("player.qa.awake").accessibilityValue(UIApplication.shared.isIdleTimerDisabled ? "1" : "0")
            Text("Brightness").accessibilityIdentifier("player.qa.brightness").accessibilityValue(String(Double(UIScreen.main.brightness)))
        }
        .font(.caption2).padding(8).background(.black.opacity(0.6))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).allowsHitTesting(false)
        }
    }
    #endif
}

private enum EpisodeSkipMark { case intro, outro }

private enum PlayerPanel: String, Identifiable {
    case episodes, options, danmaku, skip
    var id: String { rawValue }
}

private struct PlayerEpisodesView: View {
    let channel: Channel
    let select: (Episode) -> Void
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var flag: String?

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            if let catalog = store.catalog(for: channel) {
                let activeFlag = flag ?? channel.historyContext?.episodeFlag ?? catalog.playlist.flags.first ?? ""
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(L10n.text("Auto-play next episode"), isOn: $store.autoPlayNext)
                        .accessibilityIdentifier("player.autoNext")
                    if catalog.playlist.flags.count > 1 {
                        Picker(L10n.text("Playback line"), selection: Binding(get: { activeFlag }, set: { flag = $0 })) {
                            ForEach(catalog.playlist.flags, id: \.self) { Text($0.isEmpty ? L10n.text("Play") : SourceLabel($0).text).tag($0) }
                        }.pickerStyle(.menu)
                    }
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 115), spacing: 10)], spacing: 10) {
                                ForEach(catalog.playlist.episodes(for: activeFlag)) { episode in
                                    let selected = episode.name == channel.historyContext?.episodeName && episode.flag == channel.historyContext?.episodeFlag
                                    Button {
                                        if selected { dismiss() } else { select(episode) }
                                    } label: {
                                        Text(episode.name).font(.subheadline.weight(selected ? .bold : .regular))
                                            .frame(maxWidth: .infinity, minHeight: 48).padding(.horizontal, 6)
                                            .background(selected ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                                    }
                                    .buttonStyle(.plain).foregroundStyle(selected ? Color.accentColor : .primary)
                                    .accessibilityIdentifier("player.episode.\(episode.name)")
                                    .accessibilityAddTraits(selected ? .isSelected : [])
                                    .id(episode.id)
                                }
                            }
                        }
                        .onAppear {
                            if let id = channel.historyContext?.episodeID { proxy.scrollTo(id, anchor: .center) }
                        }
                    }
                }.padding(20)
                .navigationTitle(catalog.video.name)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("Done")) { dismiss() } } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
#endif
