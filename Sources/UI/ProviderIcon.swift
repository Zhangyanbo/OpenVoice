import SwiftUI

/// 模型来源标志保持官方比例并统一置于白底圆形中。
/// OpenAI: https://developers.openai.com/favicon.svg
/// Google: https://developers.google.com/static/identity/images/g-logo.png
/// Ollama: https://github.com/ollama/ollama/blob/main/docs/ollama-logo.svg
/// OpenCode: https://github.com/anomalyco/opencode/tree/dev/packages/ui/src/assets/icons/provider
struct ProviderIcon: View {
    let kind: ModelProviderKind
    var size: CGFloat = 26

    var body: some View {
        brandImage
            .padding(iconPadding)
            .background(Color.white, in: Circle())
            .overlay(Circle().strokeBorder(Color.black.opacity(0.10), lineWidth: 0.5))
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var iconPadding: CGFloat {
        switch kind {
        case .openAI: return 0
        case .google: return size * 0.19
        case .ollama: return size * 0.20
        case .openCodeZen, .openCodeGo: return size * 0.19
        }
    }

    @ViewBuilder private var brandImage: some View {
        switch kind {
        case .openAI:
            Image("ProviderOpenAI")
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .foregroundStyle(Color(red: 0.12, green: 0.13, blue: 0.14))
        case .google:
            Image("ProviderGoogle")
                .renderingMode(.original)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        case .ollama:
            Image("ProviderOllama")
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .foregroundStyle(Color(red: 0.12, green: 0.13, blue: 0.14))
        case .openCodeZen:
            Image("ProviderOpenCode")
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .foregroundStyle(Color(red: 0.12, green: 0.13, blue: 0.14))
        case .openCodeGo:
            Image("ProviderOpenCodeGo")
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .foregroundStyle(Color(red: 0.12, green: 0.13, blue: 0.14))
        }
    }
}
