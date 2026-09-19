#if os(iOS)
import CarPlay
import UIKit
import BookrestCore

/// Entry point for the CarPlay scene, matched from the
/// `CPTemplateApplicationSceneSessionRoleApplication` entry in Info.plist.
///
/// CarPlay connects and disconnects independently of the phone UI and may connect
/// before the app has ever been shown, so this owns its own bootstrap.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {

    private var coordinator: CarPlayCoordinator?

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        MainActor.assumeIsolated {
            let environment = AppEnvironment.shared
            let coordinator = CarPlayCoordinator(interfaceController: interfaceController,
                                                 environment: environment)
            self.coordinator = coordinator

            Task {
                // The phone scene may not have run yet — make sure credentials,
                // downloads and progress are loaded before drawing any list.
                if environment.isBootstrapping {
                    await environment.bootstrap()
                }
                await coordinator.start()
            }
        }
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        MainActor.assumeIsolated {
            coordinator?.stop()
            coordinator = nil
        }
    }
}
#endif
