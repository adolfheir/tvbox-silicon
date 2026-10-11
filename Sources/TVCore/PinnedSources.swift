import Foundation
import Observation

/// Subscription-qualified keys survive imports and cannot pin an unrelated site's reused key.
@MainActor @Observable public final class PinnedSources {
    private var keys: [String]
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        keys = defaults.stringArray(forKey: "pinnedSources.v1") ?? []
    }
    private func key(_ site: Site, origin: URL) -> String { EpisodeSkipSettings.scope(origin: origin, source: site.key, video: "") }
    public func contains(_ site: Site, origin: URL) -> Bool { keys.contains(key(site, origin: origin)) }
    public func toggle(_ site: Site, origin: URL) {
        let key = key(site, origin: origin)
        if keys.contains(key) { keys.removeAll { $0 == key } } else { keys.append(key) }
        defaults.set(keys, forKey: "pinnedSources.v1")
    }
    public func arrange(_ sites: [Site], origin: URL) -> [Site] {
        let rank = Dictionary(keys.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
        return sites.enumerated().sorted {
            let lhs = rank[key($0.element, origin: origin)] ?? Int.max
            let rhs = rank[key($1.element, origin: origin)] ?? Int.max
            return lhs == rhs ? $0.offset < $1.offset : lhs < rhs
        }.map(\.element)
    }
}
