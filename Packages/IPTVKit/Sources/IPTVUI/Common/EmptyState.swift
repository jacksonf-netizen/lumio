import SwiftUI

/// Lightweight empty / placeholder state. Used instead of ContentUnavailableView, whose first use
/// cost over a second at launch on macOS 26+ (measured), which broke the < 1 s launch target.
public struct EmptyState<Actions: View>: View {
    let title: String
    let systemImage: String
    let message: String?
    let actions: Actions

    public init(_ title: String, systemImage: String, message: String? = nil, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.systemImage = systemImage
        self.message = message
        self.actions = actions()
    }

    public var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.secondary)
            Text(title).font(.title2.weight(.semibold))
            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                    .textSelection(.enabled)
            }
            actions.padding(.top, 4)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EmptyState where Actions == EmptyView {
    public init(_ title: String, systemImage: String, message: String? = nil) {
        self.init(title, systemImage: systemImage, message: message) { EmptyView() }
    }
}
