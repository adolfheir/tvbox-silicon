import Foundation

public struct MediaSpeedMeasurement: Sendable {
    public let receivedBytes: Int
    public let elapsed: TimeInterval
    public let firstByteDelay: TimeInterval
    public let advertisedBitrate: Double?
    public var bytesPerSecond: Double { Double(receivedBytes) / max(0.001, elapsed) }
}

/// Samples media, never a catalog response or the size of an HLS manifest.
public struct MediaSpeedTester: Sendable {
    public static let maximumBytes = 4 * 1024 * 1024
    public static let sampleSeconds: TimeInterval = 5
    public init() {}

    public func measure(_ channel: Channel, configuration: URLSessionConfiguration = .ephemeral) async throws -> MediaSpeedMeasurement {
        let began = Date()
        var read = try await fetch(channel.url, headers: channel.headers, configuration: configuration)
        var seen = Set<URL>()
        var bitrate: Double?
        for _ in 0..<4 {
            try Task.checkCancellation()
            let text = String(decoding: read.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\u{feff}")))
            guard text.hasPrefix("#EXTM3U") else {
                try validateMedia(read)
                return MediaSpeedMeasurement(receivedBytes: read.data.count, elapsed: read.elapsed,
                                             firstByteDelay: began.timeIntervalSinceNow * -1 - read.elapsed + read.firstByteDelay,
                                             advertisedBitrate: bitrate)
            }
            guard read.data.count <= 512 * 1024 else { throw TVError.unsupported(L10n.text("The media playlist is too large to test.")) }
            let origin = read.response.url ?? channel.url
            guard seen.insert(origin).inserted else { throw TVError.unsupported(L10n.text("The media playlist contains a loop.")) }
            let playlist = try SpeedPlaylist(text, origin: origin)
            if let variant = playlist.variants.max(by: { $0.bandwidth < $1.bandwidth }) {
                bitrate = variant.bandwidth > 0 ? variant.bandwidth : bitrate
                read = try await fetch(variant.url, headers: channel.headers, configuration: configuration)
                continue
            }
            guard !playlist.segments.isEmpty else { throw TVError.unsupported(L10n.text("No media data was available to test.")) }
            var bytes = 0, elapsed = 0.0, delay = 0.0
            let resolving = Date().timeIntervalSince(began)
            for segment in playlist.segments.prefix(3) {
                let remaining = Self.maximumBytes - bytes
                let time = Self.sampleSeconds - elapsed
                guard remaining > 0, time > 0.05 else { break }
                let payload = try await fetch(segment.url, headers: channel.headers, range: segment.range,
                                              maximumBytes: remaining, seconds: time, configuration: configuration)
                try validateMedia(payload)
                if bytes == 0 { delay = resolving + payload.firstByteDelay }
                bytes += payload.data.count; elapsed += payload.elapsed
            }
            guard bytes > 0 else { throw TVError.unsupported(L10n.text("No media data was available to test.")) }
            return MediaSpeedMeasurement(receivedBytes: bytes, elapsed: elapsed, firstByteDelay: delay, advertisedBitrate: bitrate)
        }
        throw TVError.unsupported(L10n.text("The media playlist contains too many redirects."))
    }

    private func fetch(_ url: URL, headers: [String: String], range: ClosedRange<Int64>? = nil,
                       maximumBytes: Int = Self.maximumBytes, seconds: TimeInterval = Self.sampleSeconds,
                       configuration: URLSessionConfiguration) async throws -> SpeedRead {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw TVError.invalidURL }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 12)
        request.setValue(HTTPClient.userAgent, forHTTPHeaderField: "User-Agent")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let first = range?.lowerBound ?? 0
        let last = min(range?.upperBound ?? .max, first + min(Int64(maximumBytes) - 1, Int64.max - first))
        request.setValue("bytes=\(first)-\(last)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let result = try await SpeedTransfer(configuration: configuration, limit: min(maximumBytes, Int(last - first + 1)), seconds: seconds).load(request)
        if first > 0 && result.response.statusCode != 206 {
            throw TVError.unsupported(L10n.text("The source does not honor media byte ranges."))
        }
        return result
    }

    private func validateMedia(_ read: SpeedRead) throws {
        guard !read.data.isEmpty else { throw TVError.unsupported(L10n.text("No media data was available to test.")) }
        let type = read.response.mimeType?.lowercased() ?? ""
        let prefix = String(decoding: read.data.prefix(256), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if type.contains("html") || type.contains("json") || type.contains("xml") || type.contains("mpegurl") ||
            prefix.hasPrefix("<html") || prefix.hasPrefix("<!doctype") || prefix.hasPrefix("<?xml") || prefix.hasPrefix("#extm3u") {
            throw TVError.unsupported(L10n.text("The source returned a page instead of media data."))
        }
    }
}

struct SpeedPlaylist {
    struct Variant { let url: URL; let bandwidth: Double }
    struct Segment { let url: URL; let range: ClosedRange<Int64>? }
    var variants: [Variant] = []
    var segments: [Segment] = []
    init(_ text: String, origin: URL) throws {
        var bandwidth: Double?
        var byteRange: (length: Int64, offset: Int64?)?
        var previousEnd: Int64?, previousURL: URL?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                let fields = line.dropFirst("#EXT-X-STREAM-INF:".count).split(separator: ",")
                bandwidth = fields.first { $0.hasPrefix("BANDWIDTH=") }.flatMap { Double($0.dropFirst("BANDWIDTH=".count)) } ?? 0
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                let parts = line.dropFirst("#EXT-X-BYTERANGE:".count).split(separator: "@")
                guard let length = parts.first.flatMap({ Int64($0) }), length > 0 else { throw TVError.invalidConfiguration }
                let offset = parts.count == 2 ? Int64(parts[1]) : nil
                guard parts.count <= 2, parts.count != 2 || offset != nil else { throw TVError.invalidConfiguration }
                byteRange = (length, offset)
            } else if !line.isEmpty && !line.hasPrefix("#") {
                guard let url = URL(string: line, relativeTo: origin)?.absoluteURL,
                      ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw TVError.invalidURL }
                if let value = bandwidth { variants.append(Variant(url: url, bandwidth: value)); bandwidth = nil }
                else {
                    var range: ClosedRange<Int64>?
                    if let spec = byteRange {
                        guard let start = spec.offset ?? (previousURL == url ? previousEnd : nil), start >= 0,
                              spec.length <= Int64.max - start else { throw TVError.invalidConfiguration }
                        range = start...(start + spec.length - 1); previousEnd = start + spec.length; previousURL = url
                    }
                    segments.append(Segment(url: url, range: range)); byteRange = nil
                }
            }
        }
    }
}

private struct SpeedRead { let data: Data; let response: HTTPURLResponse; let elapsed: TimeInterval; let firstByteDelay: TimeInterval }

/// Cancels even when a server ignores Range; the payload retained in memory is bounded.
private final class SpeedTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let configuration: URLSessionConfiguration
    let limit: Int
    let seconds: TimeInterval
    private let lock = NSLock()
    private var session: URLSession?, task: URLSessionDataTask?
    private var continuation: CheckedContinuation<SpeedRead, Error>?
    private var response: HTTPURLResponse?
    private var data = Data()
    private var began = Date(), firstByte: Date?
    private var failure: Error?
    private var cancelled = false, limited = false
    init(configuration: URLSessionConfiguration, limit: Int, seconds: TimeInterval) {
        self.configuration = configuration; self.limit = limit; self.seconds = seconds
    }
    func load(_ request: URLRequest) async throws -> SpeedRead {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !cancelled else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation; began = Date()
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                let task = session.dataTask(with: request); self.task = task
                task.resume(); lock.unlock()
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [weak self] in
                    guard let self else { return }
                    self.lock.lock(); let task = self.task; self.limited = true; self.lock.unlock(); task?.cancel()
                }
            }
        } onCancel: {
            self.lock.lock(); self.cancelled = true; let task = self.task; self.lock.unlock(); task?.cancel()
        }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        lock.lock(); self.response = response as? HTTPURLResponse
        if let response = self.response, !(200..<300).contains(response.statusCode) { failure = TVError.http(response.statusCode) }
        else if self.response == nil { failure = TVError.invalidConfiguration }
        let valid = failure == nil; lock.unlock(); completionHandler(valid ? .allow : .cancel)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        lock.lock()
        if firstByte == nil { firstByte = Date() }
        data.append(chunk.prefix(max(0, limit - data.count)))
        let full = data.count >= limit
        if full { limited = true }
        lock.unlock(); if full { dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation; self.continuation = nil
        let result: Result<SpeedRead, Error>
        if cancelled { result = .failure(CancellationError()) }
        else if let failure { result = .failure(failure) }
        else if let error, !limited { result = .failure(error) }
        else if let response, let firstByte, !data.isEmpty {
            result = .success(SpeedRead(data: data, response: response, elapsed: Date().timeIntervalSince(began), firstByteDelay: firstByte.timeIntervalSince(began)))
        } else { result = .failure(URLError(.timedOut)) }
        self.task = nil; self.session = nil
        lock.unlock(); session.invalidateAndCancel(); continuation?.resume(with: result)
    }
}
