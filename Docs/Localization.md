# 翻译贡献指南

EasySub 默认跟随系统应用语言，目前支持简体中文（`zh-Hans`）和 English（`en`）。
用户可在设置的“语言”区域选择其他语言；退出并重新打开后，界面、菜单、
文件选择器和通知统一使用新语言。切换前请完成下载，当前队列不会跨重启保存。
系统首选语言没有可用翻译时，由 macOS 匹配后续首选语言，最终回退到英文。
应用名称 **EasySub** 在所有语言中保持不变。

## 修改现有翻译

在 Xcode 中打开 `Sources/EasySubApp/Localizable.xcstrings`，编辑相应语言列。
也可以直接编辑此 JSON 文件。英文为源语言；不要修改 key 来调整译文。
保留 `%@`、`%d`、`%lld` 等格式占位符及其类型、数量；需要调整顺序时使用
位置占位符（例如 `%1$lld`）。数量表达可使用 String Catalog 的 plural variations。
文件名、字幕标题、路径和服务返回的原始内容不属于应用翻译。

新增 UI 文案应使用 SwiftUI 的本地化字符串字面量或 `LocalizedStringKey`；
非 View 文案使用 `String(localized:)`。不要把需要翻译的动态文案先转成普通
`String` 再传给 `Text`、`Button` 或 `Label`。品牌名称可使用 `Text(verbatim:)`。

## 增加语言

1. 在 String Catalog 中添加语言并完成翻译，保留英文作为回退。
2. 在 `Sources/EasySubCore/ApplicationLanguage.swift` 增加对应语言代码。
3. 在 `SettingsView` 的语言 Picker 中添加选项；语言名称用该语言自身的写法，
   使用 `Text(verbatim:)`，确保用户切换到不熟悉的语言后仍能找回。
4. 在 `Scripts/generate_project.py` 的 `knownRegions` 中加入语言代码，
   然后执行 `python3 Scripts/generate_project.py`，提交生成的工程变化。
5. 构建应用并检查主窗口、设置、字幕选择、空状态、错误提示和完成通知。
   分别验证默认跟随系统、手动选择、重新启动后保持选择，以及恢复跟随系统。
   关注长译文是否截断、占位符是否正常、应用名是否仍为 EasySub。

语言选择通过应用域的 `AppleLanguages` 保存，恢复跟随系统时移除覆盖值，
不会修改全局系统语言。采用下次启动生效，是为了与 macOS 原生菜单和对话框
保持一致，无需替换系统 Bundle 或拦截本地化 API。
