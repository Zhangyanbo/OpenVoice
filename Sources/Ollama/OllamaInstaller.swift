import Foundation

/// 无终端窗口的 macOS 安装器：下载官方 ZIP、验证签名，再把已验证的 App
/// 写入 /Applications。OpenVoice 直接启动 App，不安装也不依赖 CLI 链接。
enum OllamaInstaller {
    enum InstallerError: LocalizedError {
        case invalidDownload
        case cancelled
        case failed

        var errorDescription: String? {
            switch self {
            case .invalidDownload:
                return tr("下载的 Ollama 无法通过签名验证，安装已停止。")
            case .cancelled:
                return tr("已取消安装 Ollama。")
            case .failed:
                return tr("Ollama 安装失败，请重试。")
            }
        }
    }

    private static let downloadURL = URL(string: "https://ollama.com/download/Ollama-darwin.zip")!

    static func install() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenVoice-Ollama-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let (temporaryArchive, response) = try await URLSession.shared.download(from: downloadURL)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else { throw InstallerError.failed }
        let archive = workspace.appendingPathComponent("Ollama-darwin.zip")
        try FileManager.default.moveItem(at: temporaryArchive, to: archive)

        let unpacked = workspace.appendingPathComponent("unpacked", isDirectory: true)
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        let unzip = try await run("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path])
        guard unzip.status == 0 else { throw InstallerError.invalidDownload }

        let app = unpacked.appendingPathComponent("Ollama.app", isDirectory: true)
        guard Bundle(url: app)?.bundleIdentifier == "com.electron.ollama" else {
            throw InstallerError.invalidDownload
        }
        let signature = try await run("/usr/bin/codesign",
                                      ["--verify", "--deep", "--strict", app.path])
        guard signature.status == 0 else { throw InstallerError.invalidDownload }

        let source = shellQuote(app.path)
        let destination = shellQuote("/Applications/Ollama.app")
        // 管理员用户通常可以直接写 /Applications；只有确实无权限时才请求提权。
        let directInstall = try await run("/usr/bin/ditto", [app.path, "/Applications/Ollama.app"])
        if directInstall.status == 0 { return }

        let command = "/bin/rm -rf \(destination) && /usr/bin/ditto \(source) \(destination)"
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let authorization = try await run("/usr/bin/osascript", [
            "-e", "do shell script \"\(escaped)\" with administrator privileges",
        ])
        guard authorization.status == 0 else {
            if authorization.output.contains("(-128)") ||
                authorization.output.localizedCaseInsensitiveContains("cancel") {
                throw InstallerError.cancelled
            }
            throw InstallerError.failed
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func run(_ executable: String, _ arguments: [String]) async throws
        -> (status: Int32, output: String) {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = pipe
            process.terminationHandler = { process in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: (
                    process.terminationStatus,
                    String(data: data, encoding: .utf8) ?? ""
                ))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
