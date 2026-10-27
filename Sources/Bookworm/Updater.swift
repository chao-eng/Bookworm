import SwiftUI
import Sparkle

/// Thin Sparkle wrapper. Feed URL + EdDSA public key live in Info.plist.
/// Automatic daily checks are enabled there too; this object just exposes
/// a `checkForUpdates` action so the menu item can call it and disable
/// itself while a check is already in flight.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    private let controller: SPUStandardUpdaterController
    @Published private(set) var canCheck: Bool = true

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        canCheck = controller.updater.canCheckForUpdates
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheck)
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
