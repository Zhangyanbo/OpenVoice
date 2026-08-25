import Foundation

/// Ollama 的安装检测与官方安装入口。检测必须保持无副作用：不会连接或启动服务。
enum OllamaInstallation {
    private static let applicationPaths = [
        "/Applications/Ollama.app",
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/Ollama.app").path,
    ]

    private static let executablePaths = [
        "/usr/local/bin/ollama",
        "/opt/homebrew/bin/ollama",
        "/Applications/Ollama.app/Contents/Resources/ollama",
    ]

    static var applicationURL: URL? {
        applicationPaths.first(where: { FileManager.default.fileExists(atPath: $0) })
            .map { URL(fileURLWithPath: $0) }
    }

    static var executableURL: URL? {
        executablePaths.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }).map { URL(fileURLWithPath: $0) }
    }

    static var isInstalled: Bool {
        applicationURL != nil || executableURL != nil
    }

}
