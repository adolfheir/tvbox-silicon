import Foundation
import Testing
@testable import TVCore

private final class SpeedProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "speed-test.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let validHeaders = request.value(forHTTPHeaderField: "X-Media-Token") == "fixture" && request.value(forHTTPHeaderField: "Cache-Control") == "no-cache"
        var status = validHeaders ? 200 : 403, mime = "application/vnd.apple.mpegurl"
        let body: Data
        switch url.path {
        case "/master": body = Data("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000000\nvideo.m3u8\n".utf8)
        case "/video.m3u8": body = Data("#EXTM3U\n#EXTINF:6,\npayload.ts\n#EXT-X-ENDLIST\n".utf8)
        case "/loop": body = Data("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\nloop\n".utf8)
        case "/payload.ts": mime = "video/mp2t"; body = Data(repeating: 0x47, count: 6 * 1024 * 1024)
        case "/html": mime = "text/html"; body = Data("<html>Blocked</html>".utf8)
        case "/unavailable": status = 503; body = Data("Unavailable".utf8)
        default: body = Data()
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if url.path == "/stall" { return }
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func speedConfig() -> URLSessionConfiguration {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [SpeedProtocol.self]
    return config
}
private func speedChannel(_ path: String) -> Channel {
    Channel(name: "Speed fixture", url: URL(string: "https://speed-test.invalid/" + path)!, headers: ["X-Media-Token": "fixture"])
}

@Test func speedTestDownloadsHLSMediaWithHeadersAndCapsServersIgnoringRange() async throws {
    let sample = try await MediaSpeedTester().measure(speedChannel("master"), configuration: speedConfig())
    #expect(sample.receivedBytes == MediaSpeedTester.maximumBytes)
    #expect(sample.bytesPerSecond > 0)
    #expect(sample.advertisedBitrate == 1_000_000)
    #expect(sample.firstByteDelay >= 0)
}

@Test func speedTestRejectsHTTPFailuresHTMLAndManifestLoops() async {
    for path in ["unavailable", "html", "loop"] {
        await #expect(throws: (any Error).self) {
            _ = try await MediaSpeedTester().measure(speedChannel(path), configuration: speedConfig())
        }
    }
}

@Test func speedTestCancelsAnUnresponsiveTransferPromptly() async throws {
    let task = Task { try await MediaSpeedTester().measure(speedChannel("stall"), configuration: speedConfig()) }
    try await Task.sleep(for: .milliseconds(30))
    let start = ContinuousClock.now
    task.cancel()
    do { _ = try await task.value; Issue.record("Cancelled transfer returned a successful speed") }
    catch { #expect(error is CancellationError) }
    #expect(start.duration(to: .now) < .seconds(1))
}

@Test func speedPlaylistResolvesVariantsAndByteRangesWithoutDownloadingKeys() throws {
    let origin = URL(string: "https://example.com/path/list.m3u8")!
    let master = try SpeedPlaylist("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\nlow/index.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=9000\n../high.m3u8", origin: origin)
    #expect(master.variants.map(\.bandwidth) == [1000, 9000])
    #expect(master.variants.last?.url.absoluteString == "https://example.com/high.m3u8")
    let media = try SpeedPlaylist("#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"key\"\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXT-X-BYTERANGE:100@20\nmedia.mp4\n#EXT-X-BYTERANGE:50\nmedia.mp4", origin: origin)
    #expect(media.segments.count == 2)
    #expect(media.segments[0].range == 20...119)
    #expect(media.segments[1].range == 120...169)
    #expect(media.segments[0].url.absoluteString == "https://example.com/path/media.mp4")
}

@Test func speedPlaylistRejectsLocalFilesAndInvalidByteRanges() {
    for text in ["#EXTM3U\nfile:///etc/passwd", "#EXTM3U\n#EXT-X-BYTERANGE:100\na.ts", "#EXTM3U\n#EXT-X-BYTERANGE:100@9223372036854775800\na.ts"] {
        #expect(throws: (any Error).self) { _ = try SpeedPlaylist(text, origin: URL(string: "https://example.com/list.m3u8")!) }
    }
}
