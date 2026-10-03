import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            Preferences.registerDefaults()
            NSApp.mainMenu = makeMainMenu()
            menuBar = MenuBarController()
            HotKeyCenter.shared.onTrigger = { action in
                CaptureCoordinator.shared.perform(action)
            }
            HotKeyCenter.shared.reloadAll()
            if Preferences.hideDesktopIcons { DesktopIconsHider.shared.setHidden(true) }
            if !Permissions.hasScreenRecording {
                // Triggers the system prompt on first launch.
                CGRequestScreenCaptureAccess()
            }
            if !Preferences.defaults.bool(forKey: "didShowWelcome") {
                Preferences.defaults.set(true, forKey: "didShowWelcome")
                HUD.show("Snippy is running in your menu bar", symbol: "viewfinder", duration: 3)
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for url in urls { EditorWindowController.openFile(url) }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { SettingsWindowController.shared.show() }
        return false
    }

    /// An (invisible) main menu so standard shortcuts like ⌘C / ⌘V / ⌘A work in text fields.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Snippy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        return main
    }
}
