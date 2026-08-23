import Foundation

/// 轻量本地化入口:所有用户可见文案统一经 `tr()` 解析。
///
/// 采用 Apple 标准机制:String Catalog(`Localizable.xcstrings`,
/// 开发语言 zh-Hans,源码中的中文字符串即 key,en 翻译在 catalog 中维护)。
///
/// 语言选择:
/// - 「跟随系统」走主 Bundle 的标准解析,由系统按用户首选语言挑选;
/// - 强制中文/英文时加载对应 lproj 子 Bundle —— 这是业界通用的运行时切换方案。
enum L10n {
    private static var bundleCache: [String: Bundle] = [:]

    /// 实际生效的语言(设置选「跟随系统」时按系统首选语言推断)
    static var effective: SettingsStore.AppLanguage {
        switch SettingsStore.shared.appLanguage {
        case .system:
            return Locale.preferredLanguages.first?.hasPrefix("zh") == true ? .zhHans : .en
        case let forced:
            return forced
        }
    }

    static func string(forKey key: String) -> String {
        let bundle: Bundle
        switch SettingsStore.shared.appLanguage {
        case .system:
            bundle = .main
        case .zhHans:
            bundle = lproj("zh-Hans")
        case .en:
            bundle = lproj("en")
        }
        // 找不到翻译时回落到 key 本身(中文源文案)
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    private static func lproj(_ code: String) -> Bundle {
        if let cached = bundleCache[code] { return cached }
        let bundle = Bundle.main.path(forResource: code, ofType: "lproj")
            .flatMap { Bundle(path: $0) } ?? .main
        bundleCache[code] = bundle
        return bundle
    }

    /// 语言显示名:目标语言列表存的是用户可读的名字(如「英语」,历史数据或用户新增),
    /// catalog 中有对应条目的按界面语言翻译,没有的原样显示。
    static func languageName(_ stored: String) -> String {
        tr(stored)
    }
}

/// 本地化字符串。key 为中文源文案,String Catalog 提供 en 翻译。
func tr(_ key: String) -> String {
    L10n.string(forKey: key)
}

/// 带参数的本地化字符串,key 使用 printf 风格占位符(%@、%lld、%d)。
func tr(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: L10n.string(forKey: key), arguments: arguments)
}
