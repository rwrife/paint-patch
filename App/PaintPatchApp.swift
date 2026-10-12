import SwiftUI
import PaintPatchKit

@main
struct PaintPatchApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("Paint Patch")
                .font(.headline)
                .accessibilityIdentifier("app.title")
            Text("Offline paint-sampling notebook")
                .font(.subheadline)
        }
        .padding()
    }
}
