# 🎤 朗读闯关 VoiceRecite (iOS)

给小朋友练朗读的闯关 App：**自己输入一段话 → 跟着大声朗读 → 实时检测音量，声音小不通过 → 读完给奖励。**

这一版刻意不内置古诗词，先当作测试版：上面的文本框由你自己输入任何一段话，下面的朗读区实时监听。

## 玩法

1. 在「① 在这里输入要朗读的一段话」里输入内容（测试期随便写；以后接古诗词只需要换文案来源）。
2. 「② 朗读要求」里可调 **音量达标线**（默认 −40 dBFS，越靠近 0 越严格），可开关「用语音识别判断是否读完」。
3. 点 **开始朗读**：麦克风打开，出现音量条（绿色），红线是达标线。
4. 朗读过程中：
   - 音量条经常越过红线 → 判定「够大声」；
   - 语音识别实时匹配，读过的字变 **绿色加粗**，进度条同步前进；
   - 连续读了一小会儿有效音量仍不达标 → **立即不通过**（声音小）；
   - 全部读完且音量达标 → **立刻通过，撒奖励**。
5. 不通过会告诉你原因（声音太小 / 没读完 / 读得太短），可以「重新开始」或「换一段文字」。

## 判定逻辑

| 判定 | 说明 |
|---|---|
| 是否够大声 | 每 ~23ms 算一次 RMS → dBFS；低于达标线算「声音小」 |
| 是否读完 | 语音识别（zh-CN）结果归一化后与朗读稿逐字比对，完成度 ≥95% 才算读完 |
| 声音小不通过 | 有效音量时间占比 < 60% → 读的过程中直接判不通过 |
| 读完奖励 | 完成度 100% + 音量达标 → 震动 + 音效 + 🎉 三星奖励 |
| 兜底 | 语音识别不可用（无网络/无权限）时自动改用「时长判定」：大声读够字数对应时长即可 |

## 参数（`RecitationEngine.swift` 里可改）

```swift
var thresholdDB     = -40    // 音量达标线（dBFS）
var minLoudRatio    = 0.6    // 有效音量时间占比下限
var passProgress    = 0.95   // 识别模式判「读完」的完成度
var secondsPerChar  = 0.26   // 时长兜底：每字秒数
var silenceToFinish = 2.0    // 停顿多久算读完
```

## 构建（不依赖 Mac）

GitHub Actions 的 macOS runner 编译 → zsign 签名 → OTA 二维码安装。

```bash
xcodegen generate && xcodebuild build -project VoiceRecite.xcodeproj -scheme VoiceRecite \
  -configuration Release -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" ARCHS=arm64
```

## 文件

```
project.yml                       XcodeGen 工程定义（含麦克风/语音识别权限文案）
VoiceRecite/VoiceReciteApp.swift  入口
VoiceRecite/ContentView.swift     三个界面：输入 / 朗读中 / 结果
VoiceRecite/RecitationEngine.swift 麦克风采集 + 音量 + 识别 + 判定
VoiceRecite/TextMatch.swift       文本归一化与逐字比对
.github/workflows/build.yml       出未签名 IPA
```

## 后续可加

- 内置古诗词库 + 逐句提示（换掉输入框即可）
- 录音回放，让孩子对比
- 历史记录与小红花累积
