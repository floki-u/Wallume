import AppIntents

struct WallumeProviderHostShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SetWallpaperIntent(),
            phrases: [
                "Set my wallpaper in \(.applicationName)",
                "Change my wallpaper with \(.applicationName)",
                "Set video wallpaper in \(.applicationName)",
                "Change desktop background in \(.applicationName)",
            ],
            shortTitle: "Set Wallpaper",
            systemImageName: "photo.fill",
        )
    }
}
