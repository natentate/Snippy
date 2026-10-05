import AppKit

/// Checks GitHub Releases for a newer build and installs it with scripts/install.sh.
@MainActor
enum Updater {
    static let repo = "natentate/Snippy"
    static let installCommand = "curl -fsSL https://raw.githubusercontent.com/\(repo)/main/scripts/install.sh | bash"

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Silent daily check on launch; only speaks up when an update exists.
    static func checkOnLaunchIfNeeded() {
        guard Preferences.autoCheckUpdates else { return }
        let last = Preferences.defaults.double(forKey: Preferences.Key.lastUpdateCheck)
        guard Date().timeIntervalSince1970 - last > 60 * 60 * 24 else { return }
        Task { await check(interactive: false) }
    }

    static func check(interactive: Bool) async {
        Preferences.defaults.set(Date().timeIntervalSince1970, forKey: Preferences.Key.lastUpdateCheck)
        do {
            let latest = try await latestVersion()
            if isNewer(latest, than: currentVersion) {
                promptToInstall(latest)
            } else if interactive {
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = "Snippy is up to date"
                alert.informativeText = "You're running version \(currentVersion)."
                alert.runModal()
            }
        } catch {
            if interactive { Alerts.show(error, title: "Couldn't check for updates") }
        }
    }

    private static func latestVersion() async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else {
            throw SnippyError("No published release was found.")
        }
        return tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let lhs = a.split(separator: ".").map { Int($0) ?? 0 }
        let rhs = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(lhs.count, rhs.count) {
            let l = i < lhs.count ? lhs[i] : 0, r = i < rhs.count ? rhs[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    private static func promptToInstall(_ version: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Snippy \(version) is available"
        alert.informativeText = "You have \(currentVersion). Snippy will download the update, replace itself in Applications and relaunch."
        alert.addButton(withTitle: "Install & Relaunch")
        alert.addButton(withTitle: "Later")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        install()
    }

    static func install() {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("snippy-update.log").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        // Detached so the script survives Snippy quitting during the update.
        process.arguments = ["-c", "nohup bash -c '\(installCommand)' > '\(log)' 2>&1 &"]
        do {
            try process.run()
            HUD.show("Downloading update…", symbol: "arrow.down.circle.fill", duration: 10)
        } catch {
            Alerts.show(error, title: "Couldn't start the update")
        }
    }
}
