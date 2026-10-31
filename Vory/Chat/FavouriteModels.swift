import Foundation
import Observation
import SwiftUI
import VoryCore

/// A model kept at the top of the model list (#401): its provider's slug and the model's name, as the gateway lists them.
struct FavouriteModel: Hashable, Codable, Identifiable, Sendable {
    var provider: String
    var model: String
    var id: String { provider + "::" + model }

    enum CodingKeys: String, CodingKey { case provider = "p", model = "m" }
}

/// Each gateway's favourite models, in the order the person keeps them (#401). A tester with about a thousand models
/// across several providers dug through each provider's list to switch; these sit on top of the model menu and the
/// model list, by gateway (a model belongs to the gateway that offers it).
///
/// Saved in UserDefaults (`storageKey`: one JSON map, gateway id to its list) and carried to the person's other devices
/// by `CloudMerge`, one cloud entry per favourite and one for each gateway's order, so an add on one device and a
/// removal on another never bring a removed favourite back, and the order is the last one set.
@MainActor @Observable
final class FavouriteModels {
    static let shared = FavouriteModels()
    static let storageKey = "models.favourites"

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var observer: NSObjectProtocol?
    /// Gateway id (`GatewayConnection.id.uuidString`) to its favourites, in order.
    private(set) var all: [String: [FavouriteModel]] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        all = Self.decode(defaults.string(forKey: Self.storageKey))
        // The sync writes the same key when another device changed it: read it again.
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: defaults, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    func reload() {
        let fresh = Self.decode(defaults.string(forKey: Self.storageKey))
        if fresh != all { all = fresh }
    }

    func list(_ gateway: UUID) -> [FavouriteModel] { all[gateway.uuidString] ?? [] }

    func contains(_ f: FavouriteModel, _ gateway: UUID) -> Bool { list(gateway).contains(f) }

    func toggle(_ f: FavouriteModel, _ gateway: UUID) {
        if contains(f, gateway) { remove(f, gateway) } else { add(f, gateway) }
    }

    /// At the end of the list.
    func add(_ f: FavouriteModel, _ gateway: UUID) {
        guard !contains(f, gateway) else { return }
        all[gateway.uuidString, default: []].append(f)
        save()
    }

    func remove(_ f: FavouriteModel, _ gateway: UUID) {
        guard var l = all[gateway.uuidString], let i = l.firstIndex(of: f) else { return }
        l.remove(at: i)
        all[gateway.uuidString] = l.isEmpty ? nil : l
        save()
    }

    func move(_ gateway: UUID, from source: IndexSet, to destination: Int) {
        guard var l = all[gateway.uuidString] else { return }
        l.move(fromOffsets: source, toOffset: destination)
        all[gateway.uuidString] = l
        save()
    }

    private func save() {
        // The demo's favourites (#392) stay for the app's run: never stored or synced.
        var kept = all
        kept[GatewayConnection.demoID.uuidString] = nil
        if let s = Self.encode(kept) { defaults.set(s, forKey: Self.storageKey) } else { defaults.removeObject(forKey: Self.storageKey) }
    }

    /// The stored form: a JSON object, gateway id to a list of `{"p", "m"}`; nil when there is nothing to keep.
    nonisolated static func encode(_ m: [String: [FavouriteModel]]) -> String? {
        let kept = m.filter { !$0.value.isEmpty }
        guard !kept.isEmpty else { return nil }
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return (try? e.encode(kept)).map { String(decoding: $0, as: UTF8.self) }
    }

    nonisolated static func decode(_ s: String?) -> [String: [FavouriteModel]] {
        guard let s, let d = s.data(using: .utf8) else { return [:] }
        return (try? JSONDecoder().decode([String: [FavouriteModel]].self, from: d)) ?? [:]
    }
}

extension ModelOptionsResult {
    /// Whether the gateway offers this model from this provider now. A favourite it no longer offers stays in the list,
    /// shown as unavailable, until the person removes it.
    func offers(_ f: FavouriteModel) -> Bool {
        providers.contains { p in p.slug == f.provider && ((p.models ?? []).contains(f.model) || (p.featuredModels ?? []).contains(f.model)) }
    }

    /// The provider's name, for a favourite's line; its slug when the gateway no longer lists it.
    func providerName(_ slug: String) -> String { providers.first { $0.slug == slug }?.name ?? slug }
}
