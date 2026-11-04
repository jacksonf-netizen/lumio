import SwiftUI

/// A red dot and "Live", for programmes on air now. The red is the guide's now line, so red means
/// live everywhere in Lumio.
struct LiveMarker: View {
    var isPaused = false

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(isPaused ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.red))
                .frame(width: 6, height: 6)
            Text("Live")
        }
        .font(.caption.weight(.medium))
        .accessibilityElement(children: .combine)
        .help(isPaused ? "Paused" : "Live")
    }
}
