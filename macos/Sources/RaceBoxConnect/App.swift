import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApplication.shared.applicationIconImage = AppArtwork.icon
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let client = RaceBoxClient.shared
        if client.busy {
            let alert = NSAlert()
            alert.messageText = client.operation.isErase ? "Memory is being cleared" : "Finish this adventure?"
            alert.informativeText = client.operation.isErase
                ? "Quitting may leave device memory partially erased. Keep the app open until clearing finishes."
                : "Live captures will be finalized. In-progress downloads will be marked incomplete."
            alert.addButton(withTitle: "Keep Open")
            alert.addButton(withTitle: "Quit")
            if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
        }
        client.shutdown()
        if let message = client.errorMessage {
            let alert = NSAlert()
            alert.messageText = "An operation needs attention"
            alert.informativeText = message
            alert.addButton(withTitle: "Keep Open")
            alert.addButton(withTitle: "Quit Anyway")
            if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
        }
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct RaceBoxConnectApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var client = RaceBoxClient.shared
    @StateObject private var preferences = Preferences.shared

    var body: some Scene {
        WindowGroup("RaceBox Connect") {
            DashboardView()
                .environmentObject(client)
                .environmentObject(preferences)
                .frame(minWidth: 990, minHeight: 710)
        }
        .defaultSize(width: 1120, height: 820)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("RaceBox") {
                Button("Find Devices") { client.scan() }
                    .keyboardShortcut("r", modifiers: [.command])
                    .disabled(client.connected || client.connecting)
                Button("Download Recordings") { client.downloadHistory() }
                    .keyboardShortcut("d", modifiers: [.command])
                    .disabled(!client.connected || client.busy)
                Button(client.capturing ? "Stop Live Capture" : "Start Live Capture") {
                    if client.capturing { client.stopCapture() } else { client.startCapture() }
                }
                .keyboardShortcut("l", modifiers: [.command])
                .disabled(!client.connected || (client.busy && !client.capturing))
            }
        }
        Settings {
            PreferencesView()
                .environmentObject(preferences)
                .environmentObject(client)
        }
    }
}
