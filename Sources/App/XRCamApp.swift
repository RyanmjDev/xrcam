import SwiftUI

@main
struct XRCamApp: App {
    var body: some Scene {
        WindowGroup {
            StreamView()
                .preferredColorScheme(.dark)
        }
    }
}
