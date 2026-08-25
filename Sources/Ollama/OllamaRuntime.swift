import Foundation

/// 仅在真正调用或下载 Ollama 模型时确保服务就绪。
/// 设置页的安装检测不会经过这里，因此不会为了显示状态而启动 Ollama。
actor OllamaRuntime {
    static let shared = OllamaRuntime()

    enum RuntimeError: LocalizedError {
        case notInstalled
        case failedToStart

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return tr("Ollama 尚未安装。")
            case .failedToStart:
                return tr("Ollama 无法启动，请打开 Ollama 后重试。")
            }
        }
    }

    private var serveProcess: Process?
    private var starting = false
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1
        configuration.timeoutIntervalForResource = 1
        return URLSession(configuration: configuration)
    }()

    func ensureRunning() async throws {
        if await isReachable() { return }
        guard OllamaInstallation.isInstalled else { throw RuntimeError.notInstalled }

        // actor 在 await 时可重入；后来的请求等待首个启动流程，避免重复拉起。
        if starting {
            for _ in 0..<80 {
                if await isReachable() { return }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            throw RuntimeError.failedToStart
        }

        starting = true
        defer { starting = false }
        try start()
        for _ in 0..<80 {
            if await isReachable() { return }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw RuntimeError.failedToStart
    }

    private func start() throws {
        if let applicationURL = OllamaInstallation.applicationURL {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            // 后台打开并隐藏窗口；Ollama 自己负责启动本地服务。
            process.arguments = ["-gj", applicationURL.path]
            try process.run()
            return
        }
        guard let executableURL = OllamaInstallation.executableURL else {
            throw RuntimeError.notInstalled
        }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["serve"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        serveProcess = process
    }

    private func isReachable() async -> Bool {
        var request = URLRequest(url: OllamaEndpoint.nativeBase.appendingPathComponent("version"))
        request.timeoutInterval = 1
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200..<300).contains(http.statusCode)
        } catch {
            return false
        }
    }
}
