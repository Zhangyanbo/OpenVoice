import Foundation

/// OpenAI API 客户端:语音转录 + 文本整理/翻译 + Key 验证。
/// 音频与最小上下文直接从本机发给 OpenAI,不经过任何中间服务器。
struct OpenAIClient: ModelProviderClient {
    enum ClientError: LocalizedError {
        case noAPIKey
        case invalidKey
        case http(Int, String)
        case badResponse

        var errorDescription: String? {
            switch self {
            case .noAPIKey: return tr("尚未设置 OpenAI API Key。")
            case .invalidKey: return tr("OpenAI 无法验证这个 API Key。")
            case .http(let code, let message): return tr("OpenAI 请求失败（%lld）：%@", code, message)
            case .badResponse: return tr("OpenAI 返回了无法解析的结果。")
            }
        }
    }

    let apiKey: String
    private let base = URL(string: "https://api.openai.com/v1")!
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        // 用户可把单模型超时设到 120 秒；实际回退时限由 ModelRouter 控制。
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config)
    }()

    // MARK: - Key 验证

    func validateKey() async throws {
        var request = URLRequest(url: base.appendingPathComponent("models"))
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.badResponse }
        if http.statusCode == 401 { throw ClientError.invalidKey }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.http(http.statusCode, "")
        }
    }

    // MARK: - 语音转录

    /// - Parameters:
    ///   - prompt: 术语表提示,提高专有名词识别率
    ///   - language: ISO 639-1 码;nil 表示自动检测
    func transcribe(wav: Data, model: String, prompt: String?, language: String?) async throws -> String {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: base.appendingPathComponent("audio/transcriptions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", model)
        field("response_format", "json")
        if let language, language != "auto", !language.isEmpty { field("language", language) }
        if let prompt, !prompt.isEmpty { field("prompt", prompt) }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        try Self.checkHTTP(data: data, response: response)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else { throw ClientError.badResponse }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Chat(结构化输出)

    /// 整理/翻译请求。用 Structured Outputs 强制模型只输出 {"text": "..."},
    /// 从 schema 层面保证不会混入解释、引号等转录内容之外的东西。
    ///
    /// 成本闸门:
    /// - reasoning_effort 固定 minimal——推理模型不传时默认 medium,
    ///   思考 token 隐藏计费,对听写这种轻任务纯属浪费;
    /// - max_completion_tokens 按转录长度估算上限(含思考 token)。
    /// 非推理模型不认识 reasoning_effort 会返回 400,此时去掉该参数重试一次。
    /// - Parameter transcript: 原始转录文本,用于估算输出上限
    func chat(model: String, system: String, user: String, transcript: String) async throws -> String {
        var payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "response_format": [
                "type": "json_schema",
                "json_schema": [
                    "name": "dictation_output",
                    "strict": true,
                    "schema": [
                        "type": "object",
                        "properties": [
                            "text": [
                                "type": "string",
                                "description": "整理后用于直接插入光标位置的最终文本",
                            ],
                        ],
                        "required": ["text"],
                        "additionalProperties": false,
                    ],
                ],
            ],
            "max_completion_tokens": Self.outputTokenCeiling(forTranscript: transcript),
            "reasoning_effort": "minimal",
        ]
        do {
            return try await sendChat(payload: payload)
        } catch ClientError.http(let code, let message)
                    where code == 400 && message.lowercased().contains("reasoning_effort") {
            payload.removeValue(forKey: "reasoning_effort")
            return try await sendChat(payload: payload)
        }
    }

    private func sendChat(payload: [String: Any]) async throws -> String {
        var request = URLRequest(url: base.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)
        try Self.checkHTTP(data: data, response: response)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else { throw ClientError.badResponse }

        // 从 JSON 中取出 text 字段;万一模型/网关不支持 json_schema 而返回了裸文本,
        // 降级为原样使用,不让一次转录白白失败
        if let contentData = content.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: contentData) as? [String: Any],
           let text = object["text"] as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 输出 token 上限估算:CJK 约 1 token/字,其余约 4 字符/token。
    /// 3 倍余量覆盖翻译膨胀、列表化改写;+256 覆盖 JSON 结构与 minimal 档的少量思考 token
    static func outputTokenCeiling(forTranscript text: String) -> Int {
        var cjk = 0, other = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x2E80...0x9FFF, 0x3040...0x30FF, 0xAC00...0xD7AF, 0xF900...0xFAFF:
                cjk += 1
            default:
                other += 1
            }
        }
        return max(512, (cjk + (other + 3) / 4) * 3 + 256)
    }

    private static func checkHTTP(data: Data, response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw ClientError.badResponse }
        if http.statusCode == 401 { throw ClientError.invalidKey }
        guard (200..<300).contains(http.statusCode) else {
            var message = ""
            var code = ""
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = json["error"] as? [String: Any] {
                message = String(((err["message"] as? String) ?? "").prefix(200))
                code = (err["code"] as? String) ?? (err["type"] as? String) ?? ""
            }
            // 429 有两种截然不同的含义,给用户能直接行动的提示
            if http.statusCode == 429 {
                if code == "insufficient_quota" || message.lowercased().contains("quota") {
                    throw ClientError.http(429, tr("OpenAI 账户余额/额度不足。请到 platform.openai.com → Billing 充值。"))
                }
                throw ClientError.http(429, tr("请求过于频繁被 OpenAI 限流，请稍等几秒后重试。"))
            }
            throw ClientError.http(http.statusCode, message)
        }
    }
}
