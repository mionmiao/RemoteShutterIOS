import SwiftUI
import UIKit

@main
struct RemoteShutterApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var hub = ServiceHub.shared

    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(hub)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // 仅在前台禁止自动锁屏；退到后台系统自动恢复原来的「自动锁定」设置，
                // 主力机分时场景下不需要改全局设置。
                UIApplication.shared.isIdleTimerDisabled = true
                hub.onForeground()
            case .background:
                UIApplication.shared.isIdleTimerDisabled = false
                hub.onBackground()
            default:
                break
            }
        }
    }
}
