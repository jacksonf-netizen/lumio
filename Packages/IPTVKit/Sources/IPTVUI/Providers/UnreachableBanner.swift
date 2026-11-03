import SwiftUI
import IPTVCore

/// Strip above Live TV when a provider can't be reached on any of its server links, so empty
/// previews and failed streams have an explanation.
struct UnreachableBanner: View {
    let state: AppState

    var body: some View {
        let providers = state.providers.unreachable
        if !providers.isEmpty {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .foregroundStyle(.red)
                    Text(message(providers))
                        .font(.callout)
                        .lineLimit(2)
                    Spacer(minLength: 12)
                    Button("Show in Settings") {
                        UserDefaults.standard.set("providers", forKey: "settingsTab")
                        state.section = .settings
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.red.opacity(0.08))
                Divider()
            }
        }
    }

    private func message(_ providers: [Provider]) -> String {
        if providers.count == 1 {
            return "Can't reach \(providers[0].name): none of its server links answer. Lumio keeps checking."
        }
        let names = providers.map(\.name).formatted(.list(type: .and))
        return "Can't reach \(names): none of their server links answer. Lumio keeps checking."
    }
}
