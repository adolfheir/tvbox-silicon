import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public struct DanmakuComment: Sendable, Hashable {
    public enum Mode: Int, Sendable { case scroll = 1, bottom = 4, top = 5 }
    public let time: Double
    public let mode: Mode
    public let color: UInt32
    public let text: String

    public init?(time: Double, mode: Int, color: UInt32, text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard time.isFinite, (0...604_800).contains(time), let mode = Mode(rawValue: mode), !text.isEmpty else { return nil }
        self.time = time; self.mode = mode; self.color = color & 0xffffff
        self.text = String(text.replacingOccurrences(of: "\n", with: " ").prefix(120))
    }
}

public enum DanmakuParser {
    public static let maximumBytes = 8 * 1024 * 1024
    public static let maximumComments = 30_000

    /// Dandanplay v2 JSON: p = time,mode,color,user. Bilibili-style XML uses
    /// time,mode,size,color,... instead; these two layouts must not be confused.
    public static func parse(_ data: Data) throws -> [DanmakuComment] {
        guard data.count <= maximumBytes else { throw TVError.unsupported(L10n.text("The danmaku file is too large.")) }
        if data.first(where: { ![9, 10, 13, 32].contains($0) }) == 60 {
            let reader = DanmakuXMLReader()
            return try reader.read(data)
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["comments"] as? [[String: Any]] else {
            throw TVError.unsupported(L10n.text("The service did not return a supported danmaku list."))
        }
        var seen = Set<DanmakuComment>()
        return rows.prefix(maximumComments).compactMap { row -> DanmakuComment? in
            guard let p = row["p"] as? String, let text = row["m"] as? String else { return nil }
            let fields = p.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 3, let time = Double(fields[0]), let mode = Int(fields[1]), let color = UInt32(fields[2]),
                  let comment = DanmakuComment(time: time, mode: mode, color: color, text: text), seen.insert(comment).inserted else { return nil }
            return comment
        }.sorted { $0.time < $1.time }
    }
}

private final class DanmakuXMLReader: NSObject, XMLParserDelegate {
    private var comments: [DanmakuComment] = []
    private var attributes: String?
    private var text = ""
    private var rootIsValid = false
    func read(_ data: Data) throws -> [DanmakuComment] {
        // Local files need no DTD/entity expansion or external network access.
        guard !String(decoding: data, as: UTF8.self).uppercased().contains("<!DOCTYPE") else { throw TVError.unsupported(L10n.text("The service did not return a supported danmaku list.")) }
        let parser = XMLParser(data: data)
        parser.delegate = self; parser.shouldResolveExternalEntities = false
        let valid = parser.parse()
        guard rootIsValid, valid || comments.count >= DanmakuParser.maximumComments else { throw TVError.unsupported(L10n.text("The service did not return a supported danmaku list.")) }
        return Array(Set(comments)).sorted { $0.time < $1.time }
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes fields: [String: String]) {
        if name == "i" { rootIsValid = true }
        if name == "d" { attributes = fields["p"]; text = "" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if attributes != nil, text.count < 512 { text += string }
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        guard name == "d", let p = attributes else { return }
        attributes = nil
        let fields = p.split(separator: ",", omittingEmptySubsequences: false)
        if fields.count >= 4, let time = Double(fields[0]), let mode = Int(fields[1]), let color = UInt32(fields[3]),
           let comment = DanmakuComment(time: time, mode: mode, color: color, text: text) { comments.append(comment) }
        if comments.count >= DanmakuParser.maximumComments { parser.abortParsing() }
    }
}

public struct DanmakuAnime: Identifiable, Sendable, Hashable {
    public let id: String
    public let title: String
    public let type: String
}

public struct DanmakuEpisode: Identifiable, Sendable, Hashable {
    public let id: String
    public let title: String
}

/// Prefer no track to a track from the wrong season or episode.
public enum DanmakuMatcher {
    public static func anime(title: String, in results: [DanmakuAnime]) -> DanmakuAnime? {
        let key = normalized(title)
        guard !key.isEmpty else { return nil }
        var seen = Set<String>()
        let matches = results.filter { normalized($0.title) == key && seen.insert($0.id).inserted }
        return matches.count == 1 ? matches.first : nil
    }

    public static func episode(name: String, in episodes: [DanmakuEpisode]) -> DanmakuEpisode? {
        if let number = episodeNumber(name) {
            let matches = episodes.filter { episodeNumber($0.title) == number }
            return matches.count == 1 ? matches.first : nil
        }
        let movies = ["正片", "电影", "電影", "剧场版", "劇場版", "hd", "hd中字", "hd国语", "1080p", "720p", "蓝光", "藍光", "完整版", "fullmovie"]
        return episodes.count == 1 && movies.contains(normalized(name)) ? episodes.first : nil
    }

    public static func episodeNumber(_ name: String) -> Int? {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for pattern in [#"^(?:第\s*)?([0-9]{1,4})\s*(?:[集话話回]|$)"#,
                        #"^ep(?:isode)?\.?\s*([0-9]{1,4})(?:\D|$)"#] {
            if let expression = try? NSRegularExpression(pattern: pattern),
               let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
               let range = Range(match.range(at: 1), in: value), let number = Int(value[range]), number > 0 { return number }
        }
        let expression = try! NSRegularExpression(pattern: #"^第([零〇一二两三四五六七八九十百]+)[集话話回]"#)
        guard let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range(at: 1), in: value) else { return nil }
        let digits: [Character: Int] = ["零":0,"〇":0,"一":1,"二":2,"两":2,"三":3,"四":4,"五":5,"六":6,"七":7,"八":8,"九":9]
        var total = 0, digit = 0
        for char in value[range] {
            if let number = digits[char] { digit = number }
            else { total += max(1, digit) * (char == "百" ? 100 : 10); digit = 0 }
        }
        let number = total + digit
        return number > 0 ? number : nil
    }

    private static func normalized(_ text: String) -> String {
        String(text.folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
}

/// Automatic matching and manual searches send only titles and IDs. Video URLs,
/// subscription URLs, headers and credentials are never sent to this service.
public struct DanmakuClient: Sendable {
    public static let defaultServer = "https://danmaku-api.152468.xyz"
    public let server: URL

    public init(address: String = Self.defaultServer) throws {
        let url = try WebAddress.resolve(address.trimmingCharacters(in: .whitespacesAndNewlines))
        guard url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw TVError.unsupported(L10n.text("Enter the danmaku server base URL, without a query or fragment."))
        }
        // Accept either a server root (including a self-hosted token path) or /api/v2.
        var value = url.absoluteString
        while value.hasSuffix("/") { value.removeLast() }
        if value.hasSuffix("/api/v2") { value = String(value.dropLast(7)) }
        guard let base = URL(string: value) else { throw TVError.invalidURL }
        server = base
    }

    public func search(_ keyword: String) async throws -> [DanmakuAnime] {
        let data = try await request("search/anime", query: [.init(name: "keyword", value: keyword)])
        let root = try object(data)
        guard let rows = root["animes"] as? [[String: Any]] else { throw unsupported() }
        return rows.prefix(100).compactMap { row in
            guard let id = Self.identifier(row["bangumiId"] ?? row["animeId"]), let title = row["animeTitle"] as? String else { return nil }
            return DanmakuAnime(id: id, title: title, type: row["typeDescription"] as? String ?? "")
        }
    }

    public func episodes(_ anime: DanmakuAnime) async throws -> [DanmakuEpisode] {
        let root = try object(try await request("bangumi/" + anime.id))
        guard let bangumi = root["bangumi"] as? [String: Any], let rows = bangumi["episodes"] as? [[String: Any]] else { throw unsupported() }
        return rows.prefix(5_000).compactMap { row in
            guard let id = Self.identifier(row["episodeId"]), let title = row["episodeTitle"] as? String else { return nil }
            return DanmakuEpisode(id: id, title: title)
        }
    }

    public func comments(_ episode: DanmakuEpisode) async throws -> [DanmakuComment] {
        try DanmakuParser.parse(await request("comment/" + episode.id, query: [
            .init(name: "withRelated", value: "true"), .init(name: "chConvert", value: "0")]))
    }

    private static func identifier(_ value: Any?) -> String? {
        let text = (value as? String) ?? (value as? NSNumber)?.stringValue
        guard let text, !text.isEmpty, text.count <= 64, text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return text
    }

    private func request(_ path: String, query: [URLQueryItem] = []) async throws -> Data {
        var parts = URLComponents(url: server.appending(path: "api/v2/" + path), resolvingAgainstBaseURL: false)!
        parts.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: parts.url!, timeoutInterval: 25)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Yingxia/1.0.2 (danmaku; https://github.com/adolfheir/tvbox-silicon)", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            if status == 401 || status == 403 { throw TVError.unsupported(L10n.text("This danmaku server requires authorization. Choose a compatible public or self-hosted server.")) }
            throw TVError.unsupported(L10n.text("The server returned HTTP %lld.", status))
        }
        if response.expectedContentLength > DanmakuParser.maximumBytes { throw TVError.unsupported(L10n.text("The danmaku file is too large.")) }
        var data = Data()
        for try await byte in bytes {
            if data.count >= DanmakuParser.maximumBytes { throw TVError.unsupported(L10n.text("The danmaku file is too large.")) }
            data.append(byte)
        }
        try Task.checkCancellation()
        return data
    }

    private func object(_ data: Data) throws -> [String: Any] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], root["success"] as? Bool != false else { throw unsupported() }
        return root
    }
    private func unsupported() -> TVError { .unsupported(L10n.text("The danmaku server could not complete this request. Try another server.")) }
}

/// Deterministic media-time layout. Seeking, pausing and changing playback speed
/// require no wall-clock animation resets; every position comes from AVPlayer time.
public struct DanmakuTimeline: Sendable {
    public struct Item: Sendable {
        public let comment: DanmakuComment
        public let lane: Int
        public let width: Double
        public let duration: Double
    }
    public let items: [Item]
    public let speed: Double
    private let maximumDuration: Double

    public init(comments: [DanmakuComment], width: Double, lanes: Int, fontSize: Double) {
        speed = max(80, width / 8)
        var scroll = Array(repeating: -Double.infinity, count: max(1, min(12, lanes)))
        var top = Array(repeating: -Double.infinity, count: 2)
        var bottom = top
        var result: [Item] = []
        for comment in comments.sorted(by: { $0.time < $1.time }) {
            // A conservative bound avoids overlaps for CJK, emoji and Latin text.
            let textWidth = Double(comment.text.utf16.count) * fontSize + 12
            let lane: Int
            let duration: Double
            switch comment.mode {
            case .scroll:
                guard let free = scroll.firstIndex(where: { $0 <= comment.time }) else { continue }
                lane = free; duration = (width + textWidth) / speed
                scroll[free] = comment.time + (textWidth + 24) / speed
            case .top:
                guard let free = top.firstIndex(where: { $0 <= comment.time }) else { continue }
                lane = free; duration = 4; top[free] = comment.time + duration
            case .bottom:
                guard let free = bottom.firstIndex(where: { $0 <= comment.time }) else { continue }
                lane = free; duration = 4; bottom[free] = comment.time + duration
            }
            result.append(Item(comment: comment, lane: lane, width: textWidth, duration: duration))
        }
        items = result
        maximumDuration = result.map(\.duration).max() ?? 0
    }

    public func visible(at time: Double) -> [Item] {
        guard time.isFinite else { return [] }
        var low = 0, high = items.count
        while low < high {
            let mid = (low + high) / 2
            if items[mid].comment.time < time - maximumDuration { low = mid + 1 } else { high = mid }
        }
        var result: [Item] = []
        for item in items.dropFirst(low) {
            if item.comment.time > time { break }
            if time < item.comment.time + item.duration { result.append(item) }
        }
        return result
    }
}
