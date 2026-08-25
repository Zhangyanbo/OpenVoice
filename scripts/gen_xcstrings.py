#!/usr/bin/env python3
# 从中英对照表生成 Sources/Localizable.xcstrings(避免手写大 JSON 出错)
import json

PAIRS = {
    # 侧边栏 / 窗口标题
    "通用": "General",
    "模型": "Models",
    "个性化": "Personalization",
    "隐私": "Privacy",
    "术语表": "Glossary",
    "历史": "History",
    "关于": "About",
    "版本 %@（%@）": "Version %@ (%@)",
    "版本 %@": "Version %@",
    "查看源代码与文档": "View source and documentation",
    "问题反馈": "Report an Issue",
    "在 GitHub 上提交 Issue": "Open an issue on GitHub",
    "光标放到任意 App → 按 Fn → 说话 → 再按 Fn → 文字出现在光标处。":
        "Put the cursor in any app → press Fn → speak → press Fn again → text appears at the cursor.",
    "请求": "Requests",
    "OpenVoice 设置": "OpenVoice Settings",
    "欢迎使用 OpenVoice": "Welcome to OpenVoice",
    # 通用页
    "登录时启动": "Launch at Login",
    "播放提示音": "Play Sounds",
    "录音开始与结束时": "When recording starts and ends",
    "显示语音悬浮条": "Show Floating Bar",
    "过滤本机声音": "Filter Computer Audio",
    "开启后过滤电脑播放的声音，适合会议中同时使用": "Filters out audio played by this computer, ideal for use during meetings",
    "悬浮条可拖动，位置会被记住": "Draggable; its position is remembered",
    "重置位置": "Reset Position",
    "在历史页显示最近一次请求详情": "Show details of the last request on the History tab",
    "快捷键": "Hotkeys",
    "若使用 Fn，请在 系统设置 → 键盘 中把「按下 🌐 键时」设为「无操作」，避免与系统听写冲突。":
        "If you use Fn, set “Press 🌐 key to” to “Do nothing” under System Settings → Keyboard to avoid conflicts with system dictation.",
    "语音输入": "Voice Input",
    "备用快捷键": "Backup Hotkey",
    "翻译": "Translation",
    "%@ + 左 Shift": "%@ + Left Shift",
    "跟随系统": "Follow System",
    "外观": "Appearance",
    "浅色": "Light",
    "深色": "Dark",
    "显示更多": "Show More",
    "转录失败": "Transcription Failed",
    "重新转录": "Re-transcribe",
    "展开详情": "Show Details",
    "收起详情": "Hide Details",
    "旧记录没有模型信息。": "Model information is not available for older entries.",
    "后处理模型": "Post-processing Models",
    "处理说明": "Processing Note",
    "成功": "Succeeded",
    "失败": "Failed",
    "后处理失败，已保留原始转录：%@":
        "Post-processing failed, so the original transcript was kept: %@",
    "重新转录失败：%@": "Re-transcription failed: %@",
    "转录结果为空，原记录未改动。": "The transcript was empty, so the original entry was left unchanged.",
    # 自动更新
    "检查更新…": "Check for Updates…",
    "正在检查…": "Checking…",
    "已是最新版本": "Up to Date",
    "更新到 %@": "Update to %@",
    "更新失败，重试": "Update Failed — Retry",
    "OpenVoice %@ 可以更新": "OpenVoice %@ is available",
    "升级": "Update",
    "正在下载…": "Downloading…",
    "正在安装…": "Installing…",
    "更新失败": "Update failed",
    "更新失败：%@": "Update failed: %@",
    "无法连接 GitHub，请稍后重试": "Could not reach GitHub. Try again later.",
    "GitHub Release 格式无效": "The GitHub Release is invalid",
    "这个 Release 没有 OpenVoice DMG": "This Release does not contain an OpenVoice DMG",
    "更新下载不完整，请重试": "The update download is incomplete. Try again.",
    "更新签名或版本校验失败，已停止安装": "The update failed signature or version verification and was not installed",
    "请先把 OpenVoice 移到“应用程序”文件夹，再进行更新": "Move OpenVoice to Applications before updating",
    "未获得安装权限，更新已取消": "Installation permission was not granted. The update was cancelled.",
    "更新包处理失败，请重试": "The update package could not be processed. Try again.",
    # 个性化页
    "编辑力度": "Editing Effort",
    "控制整理模型对转录文本的改写程度。最低只删除填充词、重复的句子和无意义的口头语，补全标点；中等在此基础上理顺句子，但不增删内容；最高则把转录当作草稿，按原意完全重写。":
        "Controls how much the polishing model may rewrite the transcript. Low only removes filler words, repeated sentences, and meaningless verbal tics, adding punctuation; Medium additionally smooths sentences without adding or removing content; High treats the transcript as a draft and fully rewrites it while preserving your meaning.",
    "格式化程度": "Format Level",
    "控制输出文本的组织形式。最低保持说话时的自然分段，不添加任何结构；中等在内容适合列举时使用简单的项目符号或编号；最高则用小节标题、项目符号等完整层级来组织内容。":
        "Controls how the output text is organized. Low keeps the natural paragraphs of your speech without any added structure; Medium uses simple bullets or numbering when the content suits listing; High organizes content with a full hierarchy of section headings and bullet points.",
    "低": "Low",
    "中": "Medium",
    "高": "High",
    # 隐私页
    "上下文": "Context",
    "开启后，对应内容会随每次语音请求发送给 OpenAI 用于提高转录准确率。上下文只在你主动开始语音输入时通过辅助功能 API 读取；关闭后完全不发送。":
        "When enabled, the corresponding content is sent with each voice request to improve transcription accuracy. Context is read via the Accessibility API only when you actively start voice input; nothing is sent while disabled.",
    "开启后，对应内容会随每次语音请求发送给当前模型的服务商，用于提高转录准确率。上下文只在你主动开始语音输入时通过辅助功能 API 读取；关闭后完全不发送。":
        "When enabled, the corresponding content is sent with each voice request to the provider of the active model to improve transcription accuracy. Context is read via the Accessibility API only when you actively start voice input; nothing is sent while disabled.",
    "使用当前 App 上下文": "Use Current App Context",
    "App 名称与窗口标题": "App name and window title",
    "读取光标附近文字": "Read Text Near Cursor",
    "光标附近与页面中的文字": "Text near the cursor and elsewhere in the page",
    "读取选中文字": "Read Selected Text",
    "本应用不截图、不 OCR、不申请屏幕录制权限、不记录键盘输入。除录音音频与上方选择的上下文外，API Key、术语表、设置与历史记录全部只保存在这台 Mac 上。":
        "This app never takes screenshots, never runs OCR, never requests screen-recording permission, and never logs keystrokes. Apart from the recorded audio and the context selected above, the API key, glossary, settings, and history are stored only on this Mac.",
    "数据边界": "Data Boundary",
    "每次请求只发送：当次录音 + 上方勾选的上下文 + 术语提示":
        "Each request sends only: the recording itself + the context selected above + glossary hints",
    # 语言卡片
    "语言": "Language",
    "界面语言": "Interface Language",
    "语音识别语言": "Recognition Language",
    "自动检测": "Auto Detect",
    "中文": "Chinese",
    "英语": "English",
    "日语": "Japanese",
    "韩语": "Korean",
    "德语": "German",
    "法语": "French",
    "西班牙语": "Spanish",
    # 语言名反向条目:目标语言可能以英文名存储(英文界面用户新增),中文界面下显示中文
    "English": "英语",
    "Japanese": "日语",
    "Korean": "韩语",
    "German": "德语",
    "French": "法语",
    "Spanish": "西班牙语",
    "Russian": "俄语",
    "Portuguese": "葡萄牙语",
    "Italian": "意大利语",
    "Arabic": "阿拉伯语",
    "翻译目标语言": "Translation Languages",
    "默认": "Default",
    "设为默认": "Set as Default",
    "添加翻译语言，如：日语": "Add a translation language, e.g. Japanese",
    "添加": "Add",
    # 服务商与模型
    "服务商": "Providers",
    "API Key 只保存在 macOS 钥匙串中。添加服务商时无需选择模型。":
        "API keys are stored only in the macOS Keychain. You don't need to choose a model when adding a provider.",
    "添加服务商": "Add Provider",
    "添加 %@": "Add %@",
    "验证并添加": "Validate && Add",
    "移除服务商": "Remove Provider",
    "是否删除服务商？": "Delete this provider?",
    "删除服务商": "Delete Provider",
    "将删除 %@ 的 API Key，并移除引用该服务商的模型。API Key 删除后无法找回。":
        "This will delete the API key for %@ and remove models that use this provider. The API key cannot be recovered after deletion.",
    "按从上到下的顺序尝试。当前模型失败时，自动切换到下一个。":
        "Models are tried from top to bottom. If one fails, the next model is used automatically.",
    "语音识别成功后，按从上到下的顺序尝试整理或翻译。":
        "After transcription succeeds, models are tried from top to bottom for polishing or translation.",
    "添加模型": "Add Model",
    "服务商已移除": "Provider Removed",
    "上移": "Move Up",
    "下移": "Move Down",
    "移除模型": "Remove Model",
    "是否移除模型？": "Remove this model?",
    "将从回退顺序中移除 %@。": "%@ will be removed from the fallback order.",
    "修改 API Key": "Change API Key",
    "%@ 无法验证这个 API Key。": "%@ could not validate this API key.",
    "尚未配置语音识别模型。": "No transcription models are configured.",
    "尚未配置语言模型。": "No language models are configured.",
    "所有语音识别模型均失败。最后一次错误：%@":
        "All transcription models failed. Last error: %@",
    "所有语言模型均失败。最后一次错误：%@":
        "All language models failed. Last error: %@",
    "没有可用的服务商或 API Key。": "No provider or API key is available.",
    "模型 %@ 引用的服务商不存在。": "The provider referenced by model %@ does not exist.",
    "%@ 尚未设置 API Key。": "%@ does not have an API key.",
    # 旧 OpenAI 卡片（保留条目供迁移与引导使用）
    "默认模型即当前推荐，普通使用无需修改。API Key 只保存在 macOS 钥匙串。":
        "The default models are the current recommendations; no changes needed for everyday use. Your API key is stored only in the macOS Keychain.",
    "API Key(sk-…)": "API Key (sk-…)",
    "保存并验证": "Save && Validate",
    "取消": "Cancel",
    "正在验证…": "Validating…",
    "已保存到 Keychain": "Saved to Keychain",
    "OpenAI 无法验证这个 API Key": "OpenAI could not validate this API key",
    "未设置": "Not Set",
    "修改": "Change",
    "语音识别模型": "Transcription Model",
    "语言模型": "Language Model",
    "默认（%@）": "Default (%@)",
    # 术语表页
    "搜索": "Search",
    "导入…": "Import…",
    "还没有术语。添加人名、项目名、常被识别错的词。":
        "No terms yet. Add names, project names, and words that often get misrecognized.",
    "没有匹配的术语": "No matching terms",
    "添加术语": "Add Term",
    "选择一个文本文件，每行一个术语": "Choose a text file with one term per line",
    "已导入 %lld 个术语": "Imported %lld terms",
    "已学习 ×%lld": "Learned ×%lld",
    # 历史页
    "保留历史": "Keep History",
    "清空": "Clear",
    "还没有转录记录": "No transcriptions yet",
    "发送的上下文": "Context Sent",
    "术语提示": "Glossary Hint",
    "文字插入": "Insertion Trace",
    "错误": "Error",
    "（无）": "(none)",
    "最近一次请求详情": "Last Request Details",
    "是否删除？": "Delete this entry?",
    "删除": "Delete",
    "语音": "Voice",
    "翻译 → %@": "Translate → %@",
    # 请求页
    "最近一次：%@": "Last: %@",
    "复制全部": "Copy All",
    "还没有发送过请求": "No requests sent yet",
    "系统提示词": "System Prompt",
    "用户提示词": "User Prompt",
    "转录原文": "Raw Transcript",
    "模型回复": "Model Response",
    "（无，请求失败或未到达整理阶段）":
        "(empty — the request failed or never reached the polishing stage)",
    "已复制": "Copied",
    "复制": "Copy",
    "（空）": "(empty)",
    "【系统提示词】": "[System Prompt]",
    "【用户提示词】": "[User Prompt]",
    "【转录原文】": "[Raw Transcript]",
    "【模型回复】": "[Model Response]",
    # 悬浮条
    "正在聆听": "Listening",
    "剩余 %d:%02d": "%d:%02d left",
    "正在转录…": "Transcribing…",
    "重试": "Retry",
    "关闭": "Close",
    # 引导
    "把光标放到任意地方，按 Fn 说话，再按 Fn，\n文字直接出现。":
        "Put your cursor anywhere, press Fn, speak, then press Fn again —\nthe text appears right there.",
    "无账号、无服务器。你的 OpenAI API Key 保存在本机钥匙串，\n音频直接从这台 Mac 发送给 OpenAI。":
        "No account, no server. Your OpenAI API key stays in the local Keychain;\naudio goes straight from this Mac to OpenAI.",
    "无账号、无中间服务器。API Key 只保存在本机钥匙串，\n音频直接从这台 Mac 发送给所选服务商。":
        "No account and no intermediary server. Your API key stays in the local Keychain;\naudio goes straight from this Mac to the selected provider.",
    "设置 OpenAI API Key": "Set Up Your OpenAI API Key",
    "在 platform.openai.com 创建。Key 只保存在 macOS 钥匙串中，不写入配置文件，不进入日志。":
        "Create one at platform.openai.com. Keys are kept only in the macOS Keychain — never written to config files, never logged.",
    "已从钥匙串读取到保存的 API Key": "Loaded your saved API key from the Keychain",
    "已读取 %@ API Key": "Loaded the %@ API key",
    "无法保存 API Key，请重试。": "Could not save the API key. Try again.",
    "默认模型组合": "Default Model Set",
    "语音识别：%@": "Transcription: %@",
    "后处理：%@": "Post-processing: %@",
    "完成引导后，可在「模型」设置中调整。":
        "You can adjust these later under Models in Settings.",
    "更换…": "Replace…",
    "验证并保存": "Validate && Save",
    "如果系统弹出「访问钥匙串」的确认框，请选择「始终允许」，之后不会再询问。":
        "If macOS asks about Keychain access, choose “Always Allow” — it won't ask again.",
    "授予麦克风权限": "Grant Microphone Access",
    "只在语音输入期间使用，录音结束立即停止访问。":
        "Used only during voice input; access stops as soon as the recording ends.",
    "允许使用麦克风": "Allow Microphone",
    "授予辅助功能权限": "Grant Accessibility Access",
    "用于全局快捷键、读取光标附近文字、把结果写回光标位置。不截图、不录屏。":
        "Needed for the global hotkey, reading text near the cursor, and writing results back at the cursor. No screenshots, no screen recording.",
    "打开系统设置": "Open System Settings",
    "已授权": "Granted",
    "未授权": "Not Granted",
    "试一下": "Try It",
    "点击下面的输入框，按 %@，说一句话，再按一次。":
        "Click the field below, press %@, say something, then press it again.",
    "提示：若使用 Fn，请先在 系统设置 → 键盘 中把「按下 🌐 键时」设为「无操作」。":
        "Tip: if you use Fn, first set System Settings → Keyboard → “Press 🌐 key to” to “Do nothing”.",
    "完成": "Done",
    "上一步": "Back",
    "继续": "Continue",
    "✓ 已保存": "✓ Saved",
    "OpenAI 无法验证这个 API Key。": "OpenAI could not validate this API key.",
    # 权限弹窗
    "需要麦克风权限才能进行语音输入。": "Microphone access is required for voice input.",
    "需要辅助功能权限才能在其他 App 中读取和输入文字。":
        "Accessibility access is required to read and insert text in other apps.",
    # 菜单栏 / 主菜单
    "关闭窗口": "Close Window",
    "退出 OpenVoice": "Quit OpenVoice",
    "编辑": "Edit",
    "撤销": "Undo",
    "重做": "Redo",
    "剪切": "Cut",
    "拷贝": "Copy",
    "粘贴": "Paste",
    "全选": "Select All",
    "开始语音输入": "Start Voice Input",
    "开始翻译输入": "Start Translation Input",
    "设置…": "Settings…",
    "转录历史…": "History…",
    "重新打开欢迎引导": "Welcome Guide…",
    "停止录音并转录": "Stop & Transcribe",
    "已学习“%@”": "Learned “%@”",
    "无": "None",
    "右 Command": "Right Command",
    "右 Option": "Right Option",
    # 错误与提示
    "无法开始录音：%@": "Could not start recording: %@",
    "转录失败：%@": "Transcription failed: %@",
    "无法自动输入，结果已复制到剪贴板。":
        "Couldn't insert automatically; the result was copied to the clipboard.",
    "（还没有发送过请求）": "(no requests yet)",
    "尚未设置 OpenAI API Key。": "No OpenAI API key is set.",
    "OpenAI 返回了无法解析的结果。": "OpenAI returned an unparseable response.",
    "OpenAI 请求失败（%lld）：%@": "OpenAI request failed (%lld): %@",
    "没有可用的录音设备。": "No audio input device available.",
    "无法初始化音频转换。": "Could not initialize audio conversion.",
    "OpenAI 账户余额/额度不足。请到 platform.openai.com → Billing 充值。":
        "Insufficient OpenAI credit or quota. Top up at platform.openai.com → Billing.",
    "请求过于频繁被 OpenAI 限流，请稍等几秒后重试。":
        "Rate limited by OpenAI due to frequent requests. Wait a few seconds and retry.",
}

catalog = {
    "sourceLanguage": "zh-Hans",
    "strings": {
        zh: {"localizations": {"en": {"stringUnit": {"state": "translated", "value": en}}}}
        for zh, en in PAIRS.items()
    },
    "version": "1.0",
}

with open("Sources/Localizable.xcstrings", "w", encoding="utf-8") as f:
    json.dump(catalog, f, ensure_ascii=False, indent=2, sort_keys=True)
    f.write("\n")

print(f"OK: {len(PAIRS)} entries")
