import SwiftUI

@main
struct OtocloudApp: App {
    @StateObject private var lab = Lab()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(lab)
        }
    }
}
