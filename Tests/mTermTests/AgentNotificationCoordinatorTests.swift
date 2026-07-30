import XCTest
@testable import mTerm

@MainActor
final class AgentNotificationCoordinatorTests: XCTestCase {
    func testCoordinatorAllowsNotificationsToBeUnavailable() {
        let coordinator = AgentNotificationCoordinator(center: nil)

        coordinator.start()
        coordinator.prepareAuthorization()
        coordinator.applicationDidBecomeActive()
        coordinator.deliver(.codex, from: .shell())
    }
}
