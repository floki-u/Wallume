import Foundation
import os

enum HistoryStorageService {
    private static let historyKey = "wallpaperHistory"

    static func loadHistory() -> [WallpaperHistoryItem] {
        guard let data = UserDefaults.standard.data(forKey: historyKey) else {
            return []
        }

        do {
            return try JSONDecoder().decode([WallpaperHistoryItem].self, from: data)
        } catch {
            Log.storage.error("Failed to decode history: \(error.localizedDescription)")
            return []
        }
    }

    static func saveHistory(_ items: [WallpaperHistoryItem]) {
        do {
            let data = try JSONEncoder().encode(items)
            UserDefaults.standard.set(data, forKey: historyKey)
        } catch {
            Log.storage.error("Failed to encode history: \(error.localizedDescription)")
        }
    }
}
