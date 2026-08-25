import Foundation
import Combine

/// Ollama 本地服务的统一地址。推理走 OpenAI 兼容接口，
/// 模型管理走原生 /api；两条路径都只访问本机回环地址。
enum OllamaEndpoint {
    static let host = URL(string: "http://127.0.0.1:11434")!
    static let openAIBase = host.appendingPathComponent("v1")
    static let nativeBase = host.appendingPathComponent("api")
}

/// 设置页使用的本地模型状态与下载器。
/// 已下载模型清单会持久化，因此 Ollama 退出后不会把“无法连接”误判成“尚未下载”。
@MainActor
final class OllamaModelManager: ObservableObject {
    static let shared = OllamaModelManager()

    enum ModelState: Equatable {
        case checking
        case installed
        case missing
        case downloading(Double)
        case failed(String)
        case unavailable
    }

    private struct TagsResponse: Decodable {
        struct LocalModel: Decodable {
            let name: String
            let model: String?
        }
        let models: [LocalModel]
    }

    private struct PullEvent: Decodable {
        let status: String?
        let digest: String?
        let total: UInt64?
        let completed: UInt64?
        let error: String?
    }

    private enum ManagerError: LocalizedError {
        case unavailable
        case http(Int)
        case pull(String)
        case incomplete

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return tr("无法连接 Ollama。请确认 Ollama 已安装并正在运行。")
            case .http(let code):
                return tr("Ollama 模型下载请求失败（%lld）。", code)
            case .pull(let message):
                return tr("Ollama 模型下载失败：%@", message)
            case .incomplete:
                return tr("Ollama 下载意外中断，请重试。")
            }
        }
    }

    @Published private(set) var installedModelIDs: Set<String>
    @Published private(set) var connectionAvailable: Bool?
    @Published private(set) var downloadStates: [String: ModelState] = [:]
    @Published private(set) var ollamaInstalled: Bool
    @Published private(set) var installationInProgress = false
    @Published private(set) var installationError: String?

    private var refreshTask: Task<Void, Never>?
    private var downloadTasks: [String: Task<Void, Never>] = [:]
    private var installationTask: Task<Void, Never>?

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        // 大模型下载可持续很久；请求仍有 60 秒无数据超时，总时限放宽到 7 天。
        config.timeoutIntervalForResource = 7 * 24 * 60 * 60
        return URLSession(configuration: config)
    }()

    private static let installedModelsCacheKey = "ollamaInstalledModelIDs"

    private init() {
        let cached = Set(UserDefaults.standard.stringArray(
            forKey: Self.installedModelsCacheKey) ?? [])
        installedModelIDs = cached.union(Self.modelsFromLocalManifests())
        ollamaInstalled = OllamaInstallation.isInstalled
        persistInstalledModels()
    }

    func state(for modelID: String) -> ModelState {
        if let state = downloadStates[modelID] { return state }
        if installedModelIDs.contains(modelID) { return .installed }
        switch connectionAvailable {
        case .some(true): return .missing
        case .some(false): return .unavailable
        case .none: return .checking
        }
    }

    /// 只检查 App / CLI 是否存在，不连接、更不会启动 Ollama。
    func refreshInstallation() {
        ollamaInstalled = OllamaInstallation.isInstalled
        let localModels = Self.modelsFromLocalManifests()
        if !localModels.isEmpty {
            installedModelIDs.formUnion(localModels)
            persistInstalledModels()
        }
        if ollamaInstalled {
            installationInProgress = false
            installationError = nil
        }
    }

    /// 在 App 内下载官方签名版本；仅最终写系统目录时弹出 macOS 授权窗口。
    func installOllama() {
        guard installationTask == nil else { return }
        installationInProgress = true
        installationError = nil
        installationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await OllamaInstaller.install()
                ollamaInstalled = true
            } catch {
                installationError = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
            installationInProgress = false
            installationTask = nil
        }
    }

    /// 模型页出现及停留期间调用。重复刷新会合并，不并发请求。
    func refresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer { refreshTask = nil }
            do {
                var request = URLRequest(url: OllamaEndpoint.nativeBase.appendingPathComponent("tags"))
                request.timeoutInterval = 8
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else {
                    connectionAvailable = false
                    return
                }
                let result = try JSONDecoder().decode(TagsResponse.self, from: data)
                installedModelIDs = Set(result.models.flatMap { item in
                    [item.name, item.model].compactMap { $0 }
                })
                persistInstalledModels()
                ollamaInstalled = true
                connectionAvailable = true
                // 外部下载完成后，清除旧的失败状态，使行状态回到“已配置”。
                for modelID in installedModelIDs {
                    if case .failed = downloadStates[modelID] {
                        downloadStates.removeValue(forKey: modelID)
                    }
                }
            } catch {
                connectionAvailable = false
            }
        }
    }

    func download(modelID: String) {
        guard downloadTasks[modelID] == nil else { return }
        downloadStates[modelID] = .downloading(0)
        downloadTasks[modelID] = Task { [weak self] in
            guard let self else { return }
            do {
                try await OllamaRuntime.shared.ensureRunning()
                try await pull(modelID: modelID)
                installedModelIDs.insert(modelID)
                persistInstalledModels()
                ollamaInstalled = true
                connectionAvailable = true
                downloadStates.removeValue(forKey: modelID)
            } catch is CancellationError {
                downloadStates.removeValue(forKey: modelID)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                downloadStates[modelID] = .failed(message)
            }
            downloadTasks.removeValue(forKey: modelID)
        }
    }

    private func pull(modelID: String) async throws {
        var request = URLRequest(url: OllamaEndpoint.nativeBase.appendingPathComponent("pull"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": modelID,
            "stream": true,
        ])

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch let error as URLError where [URLError.cannotConnectToHost,
                                             .cannotFindHost,
                                             .networkConnectionLost,
                                             .notConnectedToInternet].contains(error.code) {
            connectionAvailable = false
            throw ManagerError.unavailable
        }
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw ManagerError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        connectionAvailable = true

        var completedByDigest: [String: UInt64] = [:]
        var totalByDigest: [String: UInt64] = [:]
        var succeeded = false
        for try await line in bytes.lines {
            guard !line.isEmpty, let data = line.data(using: .utf8) else { continue }
            let event = try JSONDecoder().decode(PullEvent.self, from: data)
            if let error = event.error, !error.isEmpty { throw ManagerError.pull(error) }
            if event.status == "success" {
                succeeded = true
                downloadStates[modelID] = .downloading(1)
                continue
            }
            guard let digest = event.digest,
                  let total = event.total, total > 0,
                  let completed = event.completed else { continue }
            totalByDigest[digest] = total
            completedByDigest[digest] = min(completed, total)

            let completedBytes = completedByDigest.values.reduce(UInt64(0), +)
            let discoveredTotal = totalByDigest.values.reduce(UInt64(0), +)
            let expectedTotal = Self.expectedDownloadBytes(for: modelID) ?? discoveredTotal
            let denominator = max(discoveredTotal, expectedTotal)
            let progress = denominator > 0 ? Double(completedBytes) / Double(denominator) : 0
            if case .downloading(let previous) = downloadStates[modelID] {
                // 新发现 layer 时分母会增大；界面进度不应倒退。
                downloadStates[modelID] = .downloading(min(0.99, max(previous, progress)))
            }
        }
        guard succeeded else { throw ManagerError.incomplete }
    }

    private static func expectedDownloadBytes(for modelID: String) -> UInt64? {
        switch modelID {
        case "gemma4:e2b-it-qat": return 4_300_000_000
        case "gemma4:e4b-it-qat": return 6_100_000_000
        default: return nil
        }
    }

    private func persistInstalledModels() {
        UserDefaults.standard.set(installedModelIDs.sorted(),
                                  forKey: Self.installedModelsCacheKey)
    }

    /// Ollama 只有在完整下载成功后才会写入 manifest。读取它可以在服务未运行时
    /// 区分“已经下载”和“当前无法连接”，而且不会访问网络或拉起 Ollama。
    private static func modelsFromLocalManifests() -> Set<String> {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ollama/models/manifests", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }

        var modelIDs = Set<String>()
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }
            let relative = url.path.dropFirst(root.path.count)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let parts = relative.split(separator: "/").map(String.init)
            // registry / namespace / model[/submodel] / tag
            guard parts.count >= 4 else { continue }
            let namespace = parts[1]
            let modelPath = parts[2..<(parts.count - 1)].joined(separator: "/")
            let tag = parts[parts.count - 1]
            guard !modelPath.isEmpty, !tag.isEmpty else { continue }
            let prefix = namespace == "library" ? "" : "\(namespace)/"
            modelIDs.insert("\(prefix)\(modelPath):\(tag)")
        }
        return modelIDs
    }
}
