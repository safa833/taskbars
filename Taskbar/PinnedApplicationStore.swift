import Foundation

struct PinnedApplicationRecord: Codable {
    let identity: ApplicationIdentity
    let displayName: String
}

final class PinnedApplicationStore {
    private let defaults: UserDefaults
    private let storageKey = "behavior.pinnedApplications.v1"
    private(set) var records: [PinnedApplicationRecord]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([PinnedApplicationRecord].self, from: data) {
            var seen = Set<ApplicationIdentity>()
            records = decoded.filter { seen.insert($0.identity).inserted }
        } else {
            records = []
        }
    }

    func contains(_ identity: ApplicationIdentity) -> Bool {
        records.contains { $0.identity == identity }
    }

    func pin(identity: ApplicationIdentity, displayName: String) {
        let record = PinnedApplicationRecord(identity: identity, displayName: displayName)
        if let index = records.firstIndex(where: { $0.identity == identity }) {
            records[index] = record
        } else {
            records.append(record)
        }
        save()
    }

    func unpin(_ identity: ApplicationIdentity) {
        records.removeAll { $0.identity == identity }
        save()
    }

    func reorder(accordingTo orderedIdentities: [ApplicationIdentity]) {
        let recordsByIdentity = Dictionary(
            uniqueKeysWithValues: records.map { ($0.identity, $0) }
        )
        var reordered = orderedIdentities.compactMap { recordsByIdentity[$0] }
        let reorderedIdentities = Set(reordered.map(\.identity))
        reordered.append(contentsOf: records.filter { !reorderedIdentities.contains($0.identity) })
        records = reordered
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
