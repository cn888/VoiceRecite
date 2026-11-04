import SwiftUI

struct ContentView: View {
    @StateObject private var engine = RecitationEngine()

    @State private var text: String = ""
    @State private var threshold: Double = -40
    @State private var useSpeech: Bool = true
    @State private var permissionError: String?
    @FocusState private var editing: Bool

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()

            ScrollView {
                VStack(spacing: 16) {
                    header
                    content
                    footer
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .alert("需要权限", isPresented: alertBinding) {
            Button("知道了", role: .cancel) { permissionError = nil }
        } message: {
            Text(permissionError ?? "")
        }
    }

    private var alertBinding: Binding<Bool> {
        Binding(get: { permissionError != nil },
                set: { if !$0 { permissionError = nil } })
    }

    // MARK: - 头部
    private var header: some View {
        VStack(spacing: 6) {
            Text("🎤 朗读闯关")
                .font(.system(size: 30, weight: .heavy, design: .rounded))
            Text("大声读完上面的内容，就给你奖励")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var content: some View {
        switch engine.state {
        case .idle:
            idleView
        case .recording:
            recordingView
        case .passed:
            passedView
        case .failed(let reason):
            failedView(reason)
        }
    }

    // MARK: - 待机：输入 + 参数
    private var idleView: some View {
        VStack(spacing: 16) {
            editorCard
            settingCard
            startButton
        }
    }

    private var editorCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            label("① 在这里输入要朗读的一段话")
            TextField("例如：今天天气很好，我们一起大声朗读吧。", text: $text, axis: .vertical)
                .focused($editing)
                .lineLimit(3...8)
                .font(.system(size: 17))
                .padding(12)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(.separator), lineWidth: 0.5))
            HStack {
                Text("字数：\(TextMatch.normalize(text).count)")
                Spacer()
                if !text.isEmpty {
                    Button("清空") { text = "" }
                        .font(.footnote)
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var settingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            label("② 朗读要求")

            Toggle("用语音识别判断「是否读完」", isOn: $useSpeech)
                .font(.subheadline)

            HStack(spacing: 10) {
                Text("音量达标线")
                    .font(.subheadline)
                Slider(value: $threshold, in: -60...(-15), step: 1)
                Text("\(Int(threshold)) dB")
                    .font(.system(.footnote, design: .monospaced))
                    .frame(width: 58, alignment: .trailing)
            }

            Text("声音低于这条线就判定「声音小」，读的过程中会实时检查。数值越靠近 0 越严格。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var startButton: some View {
        Button(action: start) {
            HStack(spacing: 8) {
                Image(systemName: "mic.fill")
                Text("开始朗读")
                    .fontWeight(.bold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(canStart ? Color.accentColor : Color.gray.opacity(0.4),
                        in: RoundedRectangle(cornerRadius: 16))
            .foregroundStyle(.white)
            .font(.system(size: 18))
        }
        .disabled(!canStart)
    }

    private var canStart: Bool {
        TextMatch.normalize(text).count >= 2
    }

    // MARK: - 朗读中
    private var recordingView: some View {
        VStack(spacing: 14) {
            readingCard
            meterCard
            Text(engine.hint)
                .font(.subheadline)
                .foregroundStyle(engine.isVoiceLoud ? Color.secondary : Color.orange)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            Button(action: { engine.judgeNow() }) {
                Text("我读完了")
                    .fontWeight(.bold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16))
                    .foregroundStyle(.white)
            }

            Button("取消") { engine.cancel() }
                .foregroundStyle(.secondary)
        }
    }

    private var readingCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                label("正在朗读")
                Spacer()
                if engine.mode == .timer {
                    Text("时长判定")
                        .font(.caption2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.orange.opacity(0.15), in: Capsule())
                        .foregroundStyle(.orange)
                }
            }
            Text(highlighted)
                .lineSpacing(8)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var meterCard: some View {
        VStack(spacing: 10) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(.systemGray5))
                    Capsule()
                        .fill(engine.isVoiceLoud ? Color.green : Color.orange)
                        .frame(width: max(2, geo.size.width * engine.level))
                    // 达标线
                    Rectangle()
                        .fill(Color.red.opacity(0.7))
                        .frame(width: 2)
                        .offset(x: geo.size.width * CGFloat((threshold + 60) / 60))
                }
            }
            .frame(height: 18)

            HStack {
                Text(String(format: "%.0f dB", engine.decibel))
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("已读 \(Int(engine.progress * 100))%")
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: engine.progress)
                .tint(.accentColor)
        }
        .padding(14)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var highlighted: AttributedString {
        var out = AttributedString()
        var idx = 0
        for ch in engine.displayText {
            var piece = AttributedString(String(ch))
            if TextMatch.isWord(ch) {
                if idx < engine.pointer {
                    piece.foregroundColor = .green
                    piece.font = .system(size: 26, weight: .bold)
                } else {
                    piece.foregroundColor = .primary
                    piece.font = .system(size: 26)
                }
                idx += 1
            } else {
                piece.foregroundColor = .secondary
                piece.font = .system(size: 24)
            }
            out.append(piece)
        }
        return out
    }

    // MARK: - 通过
    private var passedView: some View {
        VStack(spacing: 14) {
            VStack(spacing: 12) {
                Text("🎉")
                    .font(.system(size: 76))
                Text("全部读完！")
                    .font(.system(size: 26, weight: .heavy, design: .rounded))
                Text("声音够大，完整读完了整段内容，奖励你一朵小红花 🌸")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { i in
                        Image(systemName: "star.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(.yellow)
                            .shadow(color: .orange.opacity(0.5), radius: 4)
                            .scaleEffect(1.0)
                            .animation(.spring(response: 0.4, dampingFraction: 0.5).delay(Double(i) * 0.12),
                                       value: engine.state)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(24)
            .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 20))

            Button(action: { engine.start(with: engine.displayText) }) {
                Text("再读一遍")
                    .fontWeight(.bold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16))
                    .foregroundStyle(.white)
            }

            Button("换一段文字") { engine.cancel() }
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 不通过
    private func failedView(_ reason: String) -> some View {
        VStack(spacing: 14) {
            VStack(spacing: 12) {
                Text("😣")
                    .font(.system(size: 66))
                Text("不通过")
                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                Text(reason)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text(String(format: "有效音量占比 %.0f%%，要求 ≥ %.0f%%",
                            engine.loudRatio * 100, engine.minLoudRatio * 100))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(24)
            .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 20))

            Button(action: { engine.start(with: engine.displayText) }) {
                Text("重新开始")
                    .fontWeight(.bold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(Color.orange, in: RoundedRectangle(cornerRadius: 16))
                    .foregroundStyle(.white)
            }

            Button("换一段文字") { engine.cancel() }
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 底部
    private var footer: some View {
        Text("提示：戴上耳机效果更好；安静环境下把手机放近一点，音量条要经常超过红线。")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .padding(.top, 4)
    }

    private func label(_ s: String) -> some View {
        Text(s)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    // MARK: - 开始
    private func start() {
        editing = false
        engine.thresholdDB = threshold
        engine.useSpeechRecognition = useSpeech
        engine.requestPermissions(needSpeech: useSpeech) { err in
            if let err {
                permissionError = err
                return
            }
            engine.start(with: text)
        }
    }
}

#Preview {
    ContentView()
}
