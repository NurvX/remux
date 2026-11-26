import SwiftUI

/// Creates the GNU Screen dashboard for a saved server. Injected through the
/// environment so library views stay independent of the root model.
struct ScreenDashboardFactory: Sendable {
    let make: @MainActor @Sendable (SavedServer) -> ScreenDashboardModel

    init(_ make: @escaping @MainActor @Sendable (SavedServer) -> ScreenDashboardModel) {
        self.make = make
    }
}

extension EnvironmentValues {
    @Entry var screenDashboardFactory: ScreenDashboardFactory? = nil
}
