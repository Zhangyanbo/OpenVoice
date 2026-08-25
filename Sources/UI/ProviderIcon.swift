import SwiftUI

/// 服务商品牌标志保持官方比例；OpenAI 以深色模板置于白底，
/// Google 保留官方彩色标志。
/// OpenAI: https://developers.openai.com/favicon.svg
/// Google: https://developers.google.com/static/identity/images/g-logo.png
struct ProviderIcon: View {
    let kind: ModelProviderKind
    var size: CGFloat = 26

    var body: some View {
        brandImage
            .padding(kind == .google ? size * 0.19 : 0)
            .background(Color.white, in: Circle())
            .overlay(Circle().strokeBorder(Color.black.opacity(0.10), lineWidth: 0.5))
        .frame(width: size, height: size)
        .accessibilityHidden(true)
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
        }
    }
}
