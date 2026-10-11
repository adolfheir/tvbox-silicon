import SwiftUI
import TVCore

struct SearchPoster: Identifiable, Sendable {
    let site: Site
    let video: Video
    var id: String { "\(site.id.utf8.count):\(site.id)\(video.id)" }
}

@MainActor @Observable final class SearchSpeedModel {
    enum Status {
        case queued, resolving, measuring, cancelled
        case success(MediaSpeedMeasurement, String)
        case failure(String)
        var speed: Double? { if case .success(let value, _) = self { value.bytesPerSecond } else { nil } }
    }
    private(set) var results: [String: Status] = [:]
    private(set) var busy = false
    private(set) var completed = 0
    private(set) var total = 0
    private var task: Task<Void, Never>?
    private var generation = UUID()
    func start(_ items: [SearchPoster], config: Subscription) {
        stop(); results = Dictionary(items.map { ($0.id, .queued) }, uniquingKeysWith: { first, _ in first })
        completed = 0; total = items.count; busy = !items.isEmpty
        let generation = generation
        task = Task { [weak self] in
            for item in items {
                guard let self, !Task.isCancelled, self.generation == generation else { return }
                self.results[item.id] = .resolving
                do {
                    let client = CatalogClient(site: item.site, origin: config.origin, jarURL: config.spiderURL).with(parses: config.parseServices)
                    let video = try await client.detail(item.video.id)
                    try Task.checkCancellation()
                    guard let episode = video.episodes.first else { throw TVError.unsupported(L10n.text("No episodes are available to test.")) }
                    let channel = try await client.playback(episode)
                    guard !Task.isCancelled, self.generation == generation else { return }
                    self.results[item.id] = .measuring
                    let sample = try await MediaSpeedTester().measure(channel)
                    guard !Task.isCancelled, self.generation == generation else { return }
                    self.results[item.id] = .success(sample, "\(episode.flag) · \(episode.name)")
                } catch {
                    guard !Task.isCancelled, self.generation == generation else { return }
                    self.results[item.id] = .failure(error.localizedDescription)
                }
                self.completed += 1
            }
            guard let self, self.generation == generation else { return }
            self.busy = false; self.task = nil
        }
    }
    func stop() {
        generation = UUID(); task?.cancel(); task = nil; busy = false
        for (id, status) in results {
            switch status { case .queued, .resolving, .measuring: results[id] = .cancelled; default: break }
        }
    }
    func reset() { stop(); results = [:]; completed = 0; total = 0 }
}
