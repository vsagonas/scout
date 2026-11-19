#if APPSTORE
import SwiftUI

// The Terminal (a real login shell) is not in the Mac App Store edition. Names stay so the Registry compiles.
struct TerminalWorkspaceView: View { var body: some View { NotInEditionView(title: "Terminal").notchContent() } }
struct TerminalSettingsPane: View { var body: some View { NotInEditionView(title: "Terminal") } }

@MainActor
enum TerminalFeature {
    static func start() {}
    static func registerSelfTests() {}
    static func registerGallery() {}
}
#endif
