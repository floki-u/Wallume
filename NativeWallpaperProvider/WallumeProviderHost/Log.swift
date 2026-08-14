import os

enum Log {
    static let general = Logger(subsystem: "com.wallume.app", category: "General")
    static let video = Logger(subsystem: "com.wallume.app", category: "Video")
    static let storage = Logger(subsystem: "com.wallume.app", category: "Storage")
    static let login = Logger(subsystem: "com.wallume.app", category: "LaunchAtLogin")
    static let update = Logger(subsystem: "com.wallume.app", category: "Update")
}
