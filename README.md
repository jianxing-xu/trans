# Trans

Trans 是一款轻量的原生 macOS 菜单栏翻译工具。第一版包含

- 任意应用中选中文本后显示翻译浮层，点击翻译，再次点击复制结果。
- `Control + Option + Space` 呼出全局翻译面板。
- 输入停止 450ms 后实时翻译，中文默认译为英文，其他输入默认译为中文。
- `Shift + Enter` 保存当前翻译到历史记录并清空输入框。
- 主面板和划词结果气泡支持使用系统语音朗读翻译结果。
- 本地翻译历史、微软翻译、阿里云机器翻译、OpenAI 兼容 LLM 和 Ollama 配置。
- 翻译服务支持启用、拖动排序和按优先级自动降级。

## 环境

- macOS 12 或更高版本
- Xcode Command Line Tools 14 或更高版本

项目不含第三方依赖，也不要求安装完整 Xcode。界面使用 SwiftUI，窗口、菜单栏、全局快捷键和辅助功能通过 AppKit、Carbon 与 Accessibility API 实现。

## 构建

```sh
./Scripts/build-app.sh
open build/Trans.app
```

脚本直接调用 Command Line Tools 中的 `swiftc`，不依赖 SwiftPM。也可以使用 Xcode 打开 `Package.swift` 进行开发。首次使用划词翻译时，需要在“系统设置 > 隐私与安全性 > 辅助功能”中允许 Trans。

## 翻译服务

设置中提供微软公共、微软订阅、阿里翻译、OpenAI 兼容 LLM 和 Ollama 五个独立服务。服务可单独启用并拖动排序；翻译时从上到下尝试，当前服务不可用或未完成配置时自动使用下一项。各服务地址均可修改。

Ollama 默认连接 `http://10.162.9.12:11434`，使用 `hy-mt2-1.8b` 模型和 `/api/chat` 非流式接口；system/user 消息及提示词规则与 LLM 服务保持一致。

阿里翻译渠道默认使用机器翻译电商专业版 HTTPS 接口，`SourceLanguage` 固定为 `auto`，`Scene` 固定为 `title`。微软订阅、阿里翻译和 LLM 需要填写各自凭据后才能使用。

API 密钥与阿里云 AccessKey 保存在 macOS Keychain；其他设置和最近 100 条翻译历史保存在 `UserDefaults`。

## 测试

```sh
swift test
```

`swift test` 需要完整可用的 SwiftPM；只安装 Command Line Tools 时，执行构建脚本即可完成全量源码编译检查。
