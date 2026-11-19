#if APPSTORE
import SwiftUI

// Messages cards (they read Messages' database and send replies) are not in the Mac App Store edition.
struct MessagesSettingsPane: View { var body: some View { NotInEditionView(title: "Messages") } }

@MainActor
enum MessagesFeature {
    static func start() {}
    static func registerSelfTests() {}
    static func registerGallery() {}
}
#endif
