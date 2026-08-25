import AppKit
import Combine
import CryptoKit
import Foundation

/// GitHub Release 自动更新。
///
/// 安全边界：Release 只是更新提示的来源，真正安装前仍会校验 DMG 内 App 的
/// Bundle ID、版本、完整代码签名与 Developer Team。校验失败绝不替换当前 App。
final class UpdateManager: ObservableObject {
    static let shared = UpdateManager()

    struct ReleaseInfo {
        let version: String
        let downloadURL: URL
        let assetSize: Int64
        let sha256: String
    }

    enum Phase {
        case idle
        case checking
        case upToDate
        case available
        case downloading
        case installing
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var availableRelease: ReleaseInfo?

    /// AppDelegate 在这里接入与 Fn 悬浮条相同位置的升级提示。
    var onUpdateAvailable: ((String) -> Void)?

    private static let releasesURL = URL(
        string: "https://api.github.com/repos/Zhangyanbo/OpenVoice/releases/latest")!
    private static let expectedBundleID = "com.openvoice.app"
    private static let expectedTeamID = "CYKTJH6DJM"
    private static let maximumAssetSize: Int64 = 1_073_741_824 // 1 GiB
    private static let automaticCheckInterval: TimeInterval = 6 * 60 * 60

    private var checkTimer: Timer?
    private var presentedVersionThisRun: String?
    private var installerProcess: Process?
    private var relaunchProcess: Process?

    private init() {}

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    func startAutomaticChecks() {
        guard checkTimer == nil else { return }
        checkTimer = Timer.scheduledTimer(withTimeInterval: Self.automaticCheckInterval,
                                          repeats: true) { _ in
            Task { @MainActor in
                UpdateManager.shared.checkForUpdates(manual: false)
            }
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            checkForUpdates(manual: false)
        }
    }

    func checkForUpdates(manual: Bool) {
        switch phase {
        case .checking, .downloading, .installing:
            return
        default:
            break
        }

        phase = .checking
        Task { @MainActor in
            do {
                let release = try await Self.fetchLatestRelease()
                guard Self.compareVersions(release.version, currentVersion) == .orderedDescending else {
                    availableRelease = nil
                    phase = .upToDate
                    return
                }

                availableRelease = release
                phase = .available
                let dismissed = SettingsStore.shared.dismissedUpdateVersion
                if dismissed != release.version, presentedVersionThisRun != release.version {
                    presentedVersionThisRun = release.version
                    onUpdateAvailable?(release.version)
                }
            } catch {
                // 自动检查失败不打扰用户；手动检查才把错误留在设置页。
                if manual {
                    phase = .failed(Self.userMessage(for: error))
                } else {
                    phase = availableRelease == nil ? .idle : .available
                }
            }
        }
    }

    func dismissUpdateBubble() {
        guard let version = availableRelease?.version else { return }
        SettingsStore.shared.dismissUpdate(version: version)
    }

    func installAvailableUpdate() {
        guard let release = availableRelease else { return }
        if case .checking = phase { return }
        if case .downloading = phase { return }
        if case .installing = phase { return }

        phase = .downloading
        Task { @MainActor in
            do {
                let prepared = try await Task.detached {
                    try await Self.prepareUpdate(release)
                }.value
                phase = .installing
                try launchInstaller(prepared)
                NSApp.terminate(nil)
            } catch {
                phase = .failed(Self.userMessage(for: error))
            }
        }
    }

    // MARK: - GitHub Release

    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: URL
            let size: Int64
            let digest: String?

            enum CodingKeys: String, CodingKey {
                case name, size, digest
                case browserDownloadURL = "browser_download_url"
            }
        }

        let tagName: String
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case assets
            case tagName = "tag_name"
        }
    }

    private static func fetchLatestRelease() async throws -> ReleaseInfo {
        var request = URLRequest(url: releasesURL)
        request.timeoutInterval = 20
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("OpenVoice-Updater", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.releaseUnavailable
        }
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        let version = normalizedVersion(release.tagName)
        guard !version.isEmpty else { throw UpdateError.invalidRelease }

        let dmgAssets = release.assets.filter { $0.name.lowercased().hasSuffix(".dmg") }
        guard let asset = dmgAssets.first(where: { $0.name.caseInsensitiveCompare("OpenVoice.dmg") == .orderedSame })
                ?? dmgAssets.first else {
            throw UpdateError.missingDMG
        }
        guard asset.size > 0, asset.size <= maximumAssetSize,
              let digest = asset.digest?.lowercased(), digest.hasPrefix("sha256:"),
              digest.count == 71,
              isAllowedDownloadURL(asset.browserDownloadURL) else {
            throw UpdateError.invalidRelease
        }
        return ReleaseInfo(version: version,
                           downloadURL: asset.browserDownloadURL,
                           assetSize: asset.size,
                           sha256: String(digest.dropFirst("sha256:".count)))
    }

    private static func normalizedVersion(_ tag: String) -> String {
        var value = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("v") { value.removeFirst() }
        return value
    }

    static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.compare(rhs, options: [.numeric, .caseInsensitive])
    }

    private static func isAllowedDownloadURL(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "github.com" || host.hasSuffix(".github.com")
            || host.hasSuffix(".githubusercontent.com")
    }

    // MARK: - 下载、挂载与校验

    private struct PreparedUpdate {
        let stagedApp: URL
        let temporaryRoot: URL
    }

    private static func prepareUpdate(_ release: ReleaseInfo) async throws -> PreparedUpdate {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("OpenVoiceUpdate-\(UUID().uuidString)", isDirectory: true)
        let dmg = root.appendingPathComponent("OpenVoice.dmg")
        let mount = root.appendingPathComponent("Mount", isDirectory: true)
        let staged = root.appendingPathComponent("OpenVoice.app", isDirectory: true)

        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            var request = URLRequest(url: release.downloadURL)
            request.timeoutInterval = 120
            request.setValue("OpenVoice-Updater", forHTTPHeaderField: "User-Agent")
            let (downloaded, response) = try await URLSession.shared.download(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let finalURL = http.url, isAllowedDownloadURL(finalURL) else {
                throw UpdateError.downloadFailed
            }
            try fm.moveItem(at: downloaded, to: dmg)

            let size = try dmg.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init) ?? 0
            guard size == release.assetSize,
                  try sha256(of: dmg) == release.sha256 else {
                throw UpdateError.downloadFailed
            }

            try fm.createDirectory(at: mount, withIntermediateDirectories: true)
            try await run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly",
                                                "-mountpoint", mount.path, dmg.path])
            do {
                let source = mount.appendingPathComponent("OpenVoice.app", isDirectory: true)
                guard fm.fileExists(atPath: source.path) else { throw UpdateError.invalidRelease }
                try await run("/usr/bin/ditto", [source.path, staged.path])
                try await run("/usr/bin/hdiutil", ["detach", mount.path])
            } catch {
                _ = try? await run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
                throw error
            }

            try validate(stagedApp: staged, expectedVersion: release.version)
            return PreparedUpdate(stagedApp: staged, temporaryRoot: root)
        } catch {
            try? fm.removeItem(at: root)
            throw error
        }
    }

    private static func validate(stagedApp: URL, expectedVersion: String) throws {
        guard let bundle = Bundle(url: stagedApp),
              bundle.bundleIdentifier == expectedBundleID,
              let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              compareVersions(version, expectedVersion) == .orderedSame else {
            throw UpdateError.identityMismatch
        }

        let requirement = "anchor apple generic and identifier \"\(expectedBundleID)\" "
            + "and certificate leaf[subject.OU] = \"\(expectedTeamID)\""
        try runSync("/usr/bin/codesign", ["--verify", "--deep", "--strict", "--verbose=2",
                                                 "-R=\(requirement)", stagedApp.path])
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 退出后替换并重启

    private func launchInstaller(_ prepared: PreparedUpdate) throws {
        let fm = FileManager.default
        let target = Bundle.main.bundleURL.resolvingSymlinksInPath()
        guard target.pathExtension.lowercased() == "app",
              Bundle(url: target)?.bundleIdentifier == Self.expectedBundleID else {
            throw UpdateError.unsupportedInstallLocation
        }
        if (try? target.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) == true {
            throw UpdateError.unsupportedInstallLocation
        }

        let args = [String(ProcessInfo.processInfo.processIdentifier),
                    prepared.stagedApp.path, target.path, prepared.temporaryRoot.path]
        let parent = target.deletingLastPathComponent()
        if fm.isWritableFile(atPath: parent.path) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", Self.installerScript, "openvoice-updater"] + args
            try process.run()
            installerProcess = process
        } else {
            // 管理员权限只执行编译进 App 的固定脚本，不从可写临时目录加载脚本，
            // 避免授权弹窗期间脚本被替换形成提权漏洞。
            let command = (["/usr/bin/nohup", "/bin/sh", "-c", Self.installerScript,
                            "openvoice-updater"] + args)
                .map(Self.shellQuote).joined(separator: " ") + " >/dev/null 2>&1 &"
            let source = "do shell script \(Self.appleScriptString(command)) with administrator privileges"
            var error: NSDictionary?
            guard NSAppleScript(source: source)?.executeAndReturnError(&error) != nil,
                  error == nil else {
                throw UpdateError.authorizationCancelled
            }
        }
        try launchRelaunchWatcher(target: target, temporaryRoot: prepared.temporaryRoot)
    }

    private func launchRelaunchWatcher(target: URL, temporaryRoot: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", Self.relaunchWatcherScript, "openvoice-relauncher",
                             String(ProcessInfo.processInfo.processIdentifier),
                             target.path, temporaryRoot.path]
        try process.run()
        relaunchProcess = process
    }

    /// 单行脚本可安全作为 `sh -c` 的一个参数传给管理员进程。
    /// 成功或回滚后只写标记；重新打开 App 始终由原用户权限的 watcher 完成。
    private static let installerScript =
        "set -eu; app_pid=\"$1\"; source_app=\"$2\"; target_app=\"$3\"; temp_root=\"$4\"; "
        + "backup_app=\"${target_app}.openvoice-backup\"; attempts=0; "
        + "while /bin/kill -0 \"$app_pid\" 2>/dev/null; do /bin/sleep 0.2; "
        + "attempts=$((attempts + 1)); if [ \"$attempts\" -ge 300 ]; then exit 1; fi; done; "
        + "/bin/rm -rf \"$backup_app\"; if [ -e \"$target_app\" ]; then /bin/mv \"$target_app\" \"$backup_app\"; fi; "
        + "if /usr/bin/ditto \"$source_app\" \"$target_app\"; then /bin/rm -rf \"$backup_app\"; "
        + "/usr/bin/touch \"$temp_root/installed\"; else /bin/rm -rf \"$target_app\"; "
        + "if [ -e \"$backup_app\" ]; then /bin/mv \"$backup_app\" \"$target_app\"; fi; "
        + "/usr/bin/touch \"$temp_root/failed\"; exit 1; fi"

    private static let relaunchWatcherScript =
        "app_pid=\"$1\"; target_app=\"$2\"; temp_root=\"$3\"; attempts=0; "
        + "while /bin/kill -0 \"$app_pid\" 2>/dev/null; do /bin/sleep 0.2; "
        + "attempts=$((attempts + 1)); if [ \"$attempts\" -ge 300 ]; then exit 1; fi; done; "
        + "attempts=0; while [ ! -e \"$temp_root/installed\" ] && [ ! -e \"$temp_root/failed\" ]; do "
        + "/bin/sleep 0.2; attempts=$((attempts + 1)); if [ \"$attempts\" -ge 600 ]; then exit 1; fi; done; "
        + "/usr/bin/open \"$target_app\"; /bin/rm -rf \"$temp_root\""

    // MARK: - 子进程与错误

    @discardableResult
    private static func run(_ executable: String, _ arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = pipe
            process.terminationHandler = { process in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(decoding: data, as: UTF8.self)
                if process.terminationStatus == 0 {
                    continuation.resume(returning: output)
                } else {
                    continuation.resume(throwing: UpdateError.commandFailed(output))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private static func runSync(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw UpdateError.commandFailed(output)
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private static func appleScriptString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func userMessage(for error: Error) -> String {
        if let updateError = error as? UpdateError { return updateError.errorDescription ?? tr("更新失败") }
        return tr("更新失败：%@", error.localizedDescription)
    }
}

private enum UpdateError: LocalizedError {
    case releaseUnavailable
    case invalidRelease
    case missingDMG
    case downloadFailed
    case identityMismatch
    case unsupportedInstallLocation
    case authorizationCancelled
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .releaseUnavailable: return tr("无法连接 GitHub，请稍后重试")
        case .invalidRelease: return tr("GitHub Release 格式无效")
        case .missingDMG: return tr("这个 Release 没有 OpenVoice DMG")
        case .downloadFailed: return tr("更新下载不完整，请重试")
        case .identityMismatch: return tr("更新签名或版本校验失败，已停止安装")
        case .unsupportedInstallLocation: return tr("请先把 OpenVoice 移到“应用程序”文件夹，再进行更新")
        case .authorizationCancelled: return tr("未获得安装权限，更新已取消")
        case .commandFailed: return tr("更新包处理失败，请重试")
        }
    }
}
