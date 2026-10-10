import Foundation
import TVCore
@preconcurrency import AVFoundation
import CoreVideo

/// A real-network, desktop decoder smoke check. This does not establish iPad playback.
@MainActor enum PlaybackAcceptance {
    struct Record: Codable {
        var source: String
        var stage = "home"
        var title: String?
        var mediaHost: String?
        var playbackSeconds = 0.0
        var decodedFrames = 0
        var downloadedBytes: Int64 = 0
        var videoTracks = 0
        var ok = false
        var error: String?
    }

    static func run(address: String, output: String, filters: [String]) async throws {
        let config = try await HTTPClient().subscription(WebAddress.resolve(address))
        let sites = config.sites.filter { site in
            filters.contains { site.key.contains($0) || site.name.contains($0) }
        }
        guard !sites.isEmpty else { throw TVError.unsupported("No matching sources") }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var records: [Record] = []
        for site in sites {
            var record = Record(source: site.key)
            do {
                let client = CatalogClient(site: site, origin: config.origin, jarURL: config.spiderURL)
                    .with(parses: config.parseServices)
                let home = try await client.home()
                var videos = home.videos
                if videos.isEmpty, let category = home.categories.first {
                    record.stage = "category"
                    videos = try await client.list(category: category.id, query: "", page: 1).videos
                }
                guard let first = videos.first else { throw TVError.unsupported("No videos") }
                record.stage = "detail"
                let video = try await client.detail(first.id)
                record.title = video.name
                guard let episode = video.episodes.first else { throw TVError.unsupported("No episodes") }
                record.stage = "resolve"
                let channel = try await client.playback(episode)
                record.mediaHost = channel.url.host()
                record.stage = "decode"
                let asset = AVURLAsset(url: channel.url, options: ["AVURLAssetHTTPHeaderFieldsKey": channel.headers])
                let item = AVPlayerItem(asset: asset)
                let frames = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ])
                item.add(frames)
                let player = AVPlayer(playerItem: item)
                defer { player.pause(); player.replaceCurrentItem(with: nil) }
                player.isMuted = true
                player.play()
                let deadline = Date().addingTimeInterval(45)
                while Date() < deadline {
                    if item.status == .failed { throw item.error ?? TVError.unsupported("Decoder failed") }
                    let time = player.currentTime()
                    if time.seconds.isFinite { record.playbackSeconds = time.seconds }
                    if frames.hasNewPixelBuffer(forItemTime: time),
                       frames.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) != nil {
                        record.decodedFrames += 1
                    }
                    if record.playbackSeconds >= 8 { break }
                    try await Task.sleep(for: .milliseconds(200))
                }
                player.pause()
                record.downloadedBytes = item.accessLog()?.events.reduce(0) { $0 + $1.numberOfBytesTransferred } ?? 0
                record.videoTracks = max((try? await asset.loadTracks(withMediaType: .video).count) ?? 0,
                                         item.tracks.filter { $0.assetTrack?.mediaType == .video }.count)
                player.replaceCurrentItem(with: nil)
                record.ok = record.playbackSeconds >= 3 && (record.videoTracks == 0 || record.decodedFrames > 0)
                if record.ok { record.stage = "done" }
                else { record.error = "Playback did not advance or video produced no decoded frame" }
            } catch { record.error = error.localizedDescription }
            records.append(record)
            try encoder.encode(records).write(to: URL(fileURLWithPath: output), options: .atomic)
            print("\(record.ok ? "PASS" : "FAIL") \(record.source): \(record.stage), \(record.playbackSeconds)s, \(record.decodedFrames) frames; \(record.error ?? "")")
        }
        guard records.allSatisfy(\.ok) else { throw TVError.unsupported("One or more playback checks failed; see the JSON report") }
    }
}
