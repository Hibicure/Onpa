import SwiftUI

@main
struct OnpaLabApp: App {
    @StateObject private var lab = Lab()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(lab)
        }
    }
}
