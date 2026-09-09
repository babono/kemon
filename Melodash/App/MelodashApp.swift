//
//  MelodashApp.swift
//  Melodash
//
//  Created by Muhammad Nurul Akbar on 01/07/26.
//

import SwiftUI
import SwiftData
import Sparkle

@main
struct MelodashApp: App {
    /// Sparkle's updater. Melodash ships direct from melodash.app rather than
    /// the App Store, so nothing else will tell users a new build exists.
    ///
    /// `startingUpdater: true` begins the scheduled background check on launch;
    /// the interval and the "check automatically?" prompt come from the
    /// SU* keys in Info.plist.
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    private let sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Song.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 1152, idealWidth: 1280, maxWidth: .infinity, minHeight: 720, idealHeight: 800, maxHeight: .infinity)
        }
        .modelContainer(sharedModelContainer)
        .commands {
            // Puts "Check for Updates…" in the app menu, where macOS users
            // look for it. The item disables itself while a check is running.
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
        }
    }
}

/// Menu item backing "Check for Updates…".
///
/// Sparkle exposes `canCheckForUpdates` as a KVO-observable property; this
/// mirrors it into SwiftUI so the item greys out mid-check instead of letting
/// the user stack up concurrent checks.
private struct CheckForUpdatesView: View {
    private let updater: SPUUpdater
    @State private var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        self.updater = updater
    }

    var body: some View {
        Button("Check for Updates…") {
            updater.checkForUpdates()
        }
        .disabled(!canCheckForUpdates)
        .onReceive(updater.publisher(for: \.canCheckForUpdates)) { canCheckForUpdates = $0 }
    }
}
