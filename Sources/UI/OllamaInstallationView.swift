import SwiftUI
import Combine

/// 添加模型来源时显示安装状态。这里只检查文件是否存在，绝不启动 Ollama。
struct OllamaInstallationView: View {
    @ObservedObject private var ollama = OllamaModelManager.shared
    @State private var confirmingInstallation = false
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 9) {
            if ollama.ollamaInstalled {
                Label(tr("Ollama 已安装"), systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.green)
            } else if ollama.installationInProgress {
                ProgressView().controlSize(.small)
                Text(tr("正在下载并安装 Ollama…"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                Text(tr("尚未安装 Ollama"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(tr("安装 Ollama")) { confirmingInstallation = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .overlay(alignment: .bottomLeading) {
            if let error = ollama.installationError {
                Text(error)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.red)
                    .offset(y: 17)
            }
        }
        .onAppear { ollama.refreshInstallation() }
        .onReceive(timer) { _ in ollama.refreshInstallation() }
        .confirmationDialog(tr("安装 Ollama？"), isPresented: $confirmingInstallation) {
            Button(tr("下载并安装")) { ollama.installOllama() }
            Button(tr("取消"), role: .cancel) {}
        } message: {
            Text(tr("OpenVoice 将下载并验证 Ollama 官方版本，然后安装到“应用程序”文件夹。只有当前账户没有写入权限时，macOS 才会要求管理员授权。"))
        }
    }
}
