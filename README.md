# OpenVoice

开源的 macOS 菜单栏 AI 语音输入法:

> **光标放到任意地方 → 按 Fn → 说话 → 再按 Fn → 文字直接出现。**

- 无服务器、无账号。用你自己的 OpenAI API Key(保存在 macOS Keychain)。
- 语音识别默认 `gpt-4o-transcribe`,再由便宜的纯文本模型(默认 `gpt-5.6-luna`)结合上下文和个人术语表做轻量整理。
- 上下文只通过 macOS Accessibility API 在你主动按下快捷键时读取;**不截图、不 OCR、不申请屏幕录制权限**。

## 功能

| 操作 | 快捷键 |
|---|---|
| 语音输入 | `Fn`(按一次开始,再按一次结束) |
| 翻译输入 | `Fn + 左 Shift` 开始,`Fn` 结束 |
| 取消录音 | `Esc` |

- 悬浮条显示录音音量与状态,可拖动,位置自动记忆,多显示器跟随当前窗口。
- 选中一段文字后说指令(如"翻译成中文""把这个写短一点")会直接替换选中内容。
- 个人术语表:手动添加/导入,或从你对刚插入文字的即时修改中自动学习(可关闭)。
- 设置 → 高级 可查看每次请求实际发送给 OpenAI 的上下文与术语提示。

## 构建

需要 Xcode 15+ 与 [xcodegen](https://github.com/yonaskolb/XcodeGen)(`brew install xcodegen`):

```bash
xcodegen
xcodebuild -project OpenVoice.xcodeproj -scheme OpenVoice \
  -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/OpenVoice.app
```

## 首次使用

1. 启动后按引导填入 OpenAI API Key(即时验证,存入 Keychain);
2. 授予 **麦克风** 与 **辅助功能** 权限;
3. **重要**:在 系统设置 → 键盘 → "按下 🌐 键时" 选择 **"无操作"**,否则 Fn 会触发系统听写/表情面板;
4. 在引导最后的输入框里试一句。

### 常见问题

- **快捷键突然失灵 / 读不到上下文**(系统设置里开关却是开的):TCC 里残留了旧签名的授权记录。执行
  `tccutil reset Accessibility com.openvoice.app` 后重新授权。工程默认用本机 Developer ID 证书签名以保持签名稳定;若你的机器没有证书,把 `project.yml` 里的 `CODE_SIGN_IDENTITY` 改回 `"-"`(ad-hoc),但每次重编译后都需要重新授权。
- **某些 App 里无法直接插入**:自动降级为剪贴板粘贴;两者都不行时结果会留在剪贴板并提示。

## 隐私

每次请求只发送:当次录音音频 + Accessibility API 能直接读到的少量光标附近文本 + 术语提示。其余一切(Key、术语表、设置)只存本机。详见 `spec.md` §18。

## License

MIT
