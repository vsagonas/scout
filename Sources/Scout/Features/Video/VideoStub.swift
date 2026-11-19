#if APPSTORE
import SwiftUI

// Video downloads (they run yt-dlp) are not in the Mac App Store edition.
struct VideoSettingsSection: View { var body: some View { EmptyView() } }
struct VideoBanner: View { var body: some View { EmptyView() } }

@MainActor
enum VideoFeature {
    static func start() {}
    static func registerSelfTests() {}
    static func registerGallery() {}
}
#endif
