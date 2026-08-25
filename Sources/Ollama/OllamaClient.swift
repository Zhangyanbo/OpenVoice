import Foundation

/// 本机 Ollama 客户端。通过 Ollama 的 OpenAI 兼容接口发送请求，
/// 不需要 API Key；只有真正请求模型时才按需启动本地服务。
struct OllamaClient: ModelProviderClient {
    enum ClientError: LocalizedError {
        case unavailable
        case http(Int, String)
        case badResponse

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return tr("无法连接 Ollama。请确认 Ollama 已安装并正在运行。")
            case .http(let code, let message):
                return tr("Ollama 请求失败（%lld）：%@", code, message)
            case .badResponse:
                return tr("Ollama 返回了无法解析的结果。")
            }
        }
    }

    private let base = OllamaEndpoint.openAIBase
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        // 首次加载本地模型可能明显慢于后续请求。
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config)
    }()

    func transcribe(wav: Data, model: String, prompt: String?, language: String?) async throws -> String {
        try await OllamaRuntime.shared.ensureRunning()
        // Gemma 4 官方音频输入上限为 30 秒。分段严格限定在 Gemma 4，
        // 不改变 Ollama 未来其他模型，更不会影响 OpenAI / Gemini 的请求路径。
        let chunks = model.hasPrefix("gemma4:") ? Self.gemma4Chunks(from: wav) : [wav]
        var transcripts: [String] = []
        for chunk in chunks {
            let text = try await transcribeChunk(chunk, model: model, prompt: prompt, language: language)
            if !text.isEmpty { transcripts.append(text) }
        }
        guard !transcripts.isEmpty else { throw ClientError.badResponse }
        return transcripts.joined(separator: " ")
    }

    private func transcribeChunk(_ wav: Data, model: String,
                                 prompt: String?, language: String?) async throws -> String {
        var lines = [
            "Transcribe the speech accurately and verbatim.",
            "Return only the transcript as plain text, without Markdown, labels, commentary, timestamps, or quotation marks.",
            "Preserve the spoken language, wording, punctuation intent, names, and capitalization. Do not summarize or translate.",
        ]
        if let language, language != "auto", !language.isEmpty {
            lines.append("The expected spoken language code is \(language).")
        }
        if let prompt, !prompt.isEmpty {
            lines.append("Preferred spellings for names and domain terms: \(prompt)")
        }
        let payload: [String: Any] = [
            "model": model,
            "stream": false,
            "reasoning_effort": "none",
            "temperature": 0,
            "max_tokens": Self.transcriptionTokenCeiling(wavByteCount: wav.count),
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "text", "text": lines.joined(separator: "\n")],
                    [
                        "type": "input_audio",
                        "input_audio": ["data": wav.base64EncodedString(), "format": "wav"],
                    ],
                ],
            ]],
        ]
        return try await sendChat(payload: payload, structured: false)
    }

    func chat(model: String, system: String, user: String, transcript: String) async throws -> String {
        try await OllamaRuntime.shared.ensureRunning()
        let payload: [String: Any] = [
            "model": model,
            "stream": false,
            "reasoning_effort": "none",
            "temperature": 0,
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
            "max_tokens": OpenAIClient.outputTokenCeiling(forTranscript: transcript),
        ]
        return try await sendChat(payload: payload, structured: true)
    }

    private func sendChat(payload: [String: Any], structured: Bool) async throws -> String {
        var request = URLRequest(url: base.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        // Ollama 的本地兼容接口会忽略 token，但部分兼容层要求存在此头。
        request.setValue("Bearer ollama", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where [URLError.cannotConnectToHost,
                                             .cannotFindHost,
                                             .networkConnectionLost,
                                             .notConnectedToInternet].contains(error.code) {
            throw ClientError.unavailable
        }
        try Self.checkHTTP(data: data, response: response)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw ClientError.badResponse
        }
        let cleaned = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if structured,
           let contentData = cleaned.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: contentData) as? [String: Any],
           let text = object["text"] as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return cleaned
    }

    private static func transcriptionTokenCeiling(wavByteCount: Int) -> Int {
        let seconds = max(1, (wavByteCount - 44) / 32_000)
        return min(4_096, max(512, seconds * 12 + 256))
    }

    /// AudioRecorder 固定生成 44 字节头的 16 kHz / mono / PCM16 WAV。
    /// 仅当它确实符合这个格式且超过 30 秒时，切成 28 秒的独立合法 WAV。
    private static func gemma4Chunks(from wav: Data) -> [Data] {
        let headerSize = 44
        let bytesPerSecond = 16_000 * 2
        let chunkBytes = 28 * bytesPerSecond
        guard wav.count > headerSize + 30 * bytesPerSecond,
              wav.count >= headerSize,
              String(data: wav.prefix(4), encoding: .ascii) == "RIFF",
              String(data: wav[8..<12], encoding: .ascii) == "WAVE",
              String(data: wav[36..<40], encoding: .ascii) == "data" else {
            return [wav]
        }

        // 复制成新的 Data，使切片索引从 0 开始；dropFirst 返回的集合仍可能
        // 保留原始起始索引，不能直接用字节偏移下标。
        let pcm = Data(wav.dropFirst(headerSize))
        var chunks: [Data] = []
        var offset = 0
        while offset < pcm.count {
            let end = min(pcm.count, offset + chunkBytes)
            chunks.append(AudioRecorder.wavFile(fromPCM: Data(pcm[offset..<end]), sampleRate: 16_000))
            offset = end
        }
        return chunks
    }

    private static func checkHTTP(data: Data, response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw ClientError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            var message = ""
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let error = json["error"] as? String {
                    message = error
                } else if let error = json["error"] as? [String: Any] {
                    message = (error["message"] as? String) ?? ""
                }
            }
            throw ClientError.http(http.statusCode, String(message.prefix(200)))
        }
    }
}
