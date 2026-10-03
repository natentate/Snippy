import AppKit

struct HistoryItem: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case image, video, gif }

    var id = UUID()
    var path: String
    var kind: Kind
    var date: Date
    /// Whether the file lives in the app's private history folder (not saved by the user).
    var isInternal: Bool

    var url: URL { URL(fileURLWithPath: path) }
    var exists: Bool { FileManager.default.fileExists(atPath: path) }
}

/// Keeps the most recent captures so they can be reopened from the menu bar.
final class HistoryStore {
    static let shared = HistoryStore()
    static let limit = 30

    private(set) var items: [HistoryItem] = []

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Snippy/History", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var indexURL: URL { HistoryStore.directory.appendingPathComponent("history.json") }

    private init() {
        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? JSONDecoder().decode([HistoryItem].self, from: data) {
            items = decoded.filter(\.exists)
        }
    }

    func add(url: URL, kind: HistoryItem.Kind, isInternal: Bool) {
        items.removeAll { $0.path == url.path }
        items.insert(HistoryItem(path: url.path, kind: kind, date: Date(), isInternal: isInternal), at: 0)
        while items.count > HistoryStore.limit {
            let removed = items.removeLast()
            if removed.isInternal { try? FileManager.default.removeItem(at: removed.url) }
        }
        persist()
    }

    /// Updates an entry after its file was moved (e.g. saved out of the internal history folder).
    func replace(path old: String, with new: URL, isInternal: Bool) {
        guard let index = items.firstIndex(where: { $0.path == old }) else { return }
        items[index].path = new.path
        items[index].isInternal = isInternal
        persist()
    }

    func clear() {
        for item in items where item.isInternal { try? FileManager.default.removeItem(at: item.url) }
        items.removeAll()
        persist()
    }

    func prune() {
        items = items.filter(\.exists)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: indexURL) }
    }
}
