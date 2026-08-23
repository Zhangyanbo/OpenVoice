import SwiftUI
import AppKit

/// 应用标识图形,用于设置侧边栏、引导页等界面内部。
///
/// 优先使用用户提供的透明底图标(构建脚本从 icon/ 拷入 app 包):
/// - 深色环境用 icon_transparent_white.png(白色光标)
/// - 浅色环境用 icon_transparent_black.png(黑色光标)
/// 绿色呼吸点两版一致。文件缺失时退回渐变占位图形。
struct AppMark: View {
    @Environment(\.colorScheme) private var colorScheme
    var size: CGFloat

    var body: some View {
        if let image = Self.load(dark: colorScheme == .dark) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: "mic.fill")
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(
                    LinearGradient(colors: [Color(red: 0.35, green: 0.55, blue: 0.95),
                                            Color(red: 0.25, green: 0.4, blue: 0.85)],
                                   startPoint: .top, endPoint: .bottom),
                    in: RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
        }
    }

    private static func load(dark: Bool) -> NSImage? {
        let name = dark ? "icon_transparent_white" : "icon_transparent_black"
        guard let path = Bundle.main.path(forResource: name, ofType: "png") else { return nil }
        return NSImage(contentsOfFile: path)
    }
}
