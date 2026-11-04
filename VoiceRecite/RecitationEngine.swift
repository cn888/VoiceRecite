import AVFoundation
import AudioToolbox
import Speech
import Combine
import SwiftUI
import UIKit

enum SessionState: Equatable {
    case idle
    case recording
    case passed
    case failed(String)
}

enum JudgeMode {
    case speech   // 语音识别判定「是否读完」
    case timer    // 识别不可用时，按时长兜底
}

final class RecitationEngine: NSObject, ObservableObject {

    // MARK: - 给界面看的状态
    @Published var state: SessionState = .idle
    @Published var level: Double = 0            // 0...1 音量条
    @Published var decibel: Double = -80        // dBFS 实时音量
    @Published var isVoiceLoud: Bool = true     // 最近是否够大声
    @Published var progress: Double = 0         // 读完进度 0...1
    @Published var pointer: Int = 0             // 已读到的「字数」（用于逐字高亮）
    @Published var expectedCount: Int = 0
    @Published var transcript: String = ""      // 实时识别文本
    @Published var hint: String = ""
    @Published var loudRatio: Double = 1        // 达标音量时间占比
    @Published var elapsed: Double = 0
    @Published var mode: JudgeMode = .speech
    @Published var displayText: String = ""     // 正在朗读的原文

    // MARK: - 可调参数
    /// 低于这个 dBFS 就算「声音太小」
    var thresholdDB: Double = -40
    /// 达标音量时间占比至少要这么多
    var minLoudRatio: Double = 0.6
    /// 识别模式下，完成度达到多少算读完（留识别容错）
    var passProgress: Double = 0.95
    /// 按时长兜底时：每字大约多少秒
    var secondsPerChar: Double = 0.26
    /// 停顿多久算读完
    var silenceToFinish: Double = 2.0
    var useSpeechRecognition: Bool = true

    // MARK: - 私有
    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var timer: Timer?
    private var tapInstalled = false

    private var expected: [Character] = []
    private var consumed = 0
    private var startedSpeaking = false
    private var finished = false
    private var totalSeconds: Double = 0
    private var loudSeconds: Double = 0
    private var targetSeconds: Double = 1
    private var lastLoudAt = Date()
    private var startAt = Date()

    // MARK: - 权限
    func requestPermissions(needSpeech: Bool, completion: @escaping (String?) -> Void) {
        func askSpeech(_ done: @escaping (String?) -> Void) {
            guard needSpeech else { done(nil); return }
            let msg = "语音识别权限被拒绝：设置 → 隐私与安全 → 语音识别，打开「朗读闯关」后重开应用。"
            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized:
                done(nil)
            case .notDetermined:
                SFSpeechRecognizer.requestAuthorization { _ in
                    DispatchQueue.main.async {
                        done(SFSpeechRecognizer.authorizationStatus() == .authorized ? nil : msg)
                    }
                }
            default:
                done(msg)
            }
        }

        func askMic(_ done: @escaping (String?) -> Void) {
            let msg = "麦克风权限被拒绝：设置 → 隐私与安全 → 麦克风，打开「朗读闯关」后重开应用。"
            let handler: (Bool) -> Void = { ok in
                DispatchQueue.main.async { done(ok ? nil : msg) }
            }
            if #available(iOS 17.0, *) {
                switch AVAudioApplication.shared.recordPermission {
                case .granted:
                    done(nil)
                case .denied:
                    done(msg)
                default:
                    AVAudioApplication.requestRecordPermission(completionHandler: handler)
                }
            } else {
                switch AVAudioSession.sharedInstance().recordPermission {
                case .granted:
                    done(nil)
                case .denied:
                    done(msg)
                default:
                    AVAudioSession.sharedInstance().requestRecordPermission(handler)
                }
            }
        }

        askSpeech { speechError in
            if let speechError { completion(speechError); return }
            askMic { micError in completion(micError) }
        }
    }

    // MARK: - 开始朗读
    func start(with text: String) {
        stopAudio()

        let chars = TextMatch.normalize(text)
        guard !chars.isEmpty else {
            state = .failed("请先在上面输入要朗读的内容")
            return
        }

        displayText = text
        expected = chars
        expectedCount = chars.count
        pointer = 0
        consumed = 0
        progress = 0
        transcript = ""
        totalSeconds = 0
        loudSeconds = 0
        loudRatio = 1
        elapsed = 0
        startedSpeaking = false
        finished = false
        isVoiceLoud = true
        hint = ""
        startAt = Date()
        lastLoudAt = Date()
        targetSeconds = max(1.0, Double(chars.count) * secondsPerChar)

        // 判定方式
        mode = .timer
        recognizer = nil
        if useSpeechRecognition,
           let r = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")),
           r.isAvailable {
            recognizer = r
            mode = .speech
        }

        state = .recording
        hint = mode == .speech
            ? "请大声开始朗读…"
            : "语音识别不可用，改用时长判定：大声读完全部内容即可"

        do {
            try startAudio()
        } catch {
            state = .failed("麦克风启动失败：\(error.localizedDescription)")
            return
        }

        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    /// 手动判定（自己觉得读完了）
    func judgeNow() {
        guard state == .recording, !finished else { return }
        judgeAfterReading()
    }

    func cancel() {
        stopAudio()
        finished = true
        transcript = ""
        hint = ""
        progress = 0
        pointer = 0
        state = .idle
    }

    // MARK: - 音频
    private func startAudio() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement,
                                options: [.duckOthers, .defaultToSpeaker])
        try session.setActive(true)

        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "VoiceRecite", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "没有可用的麦克风"])
        }

        if mode == .speech, let recognizer {
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            req.taskHint = .dictation
            req.addsPunctuation = false
            request = req
            task = recognizer.recognitionTask(with: req) { [weak self] result, error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let result {
                        self.handleRecognition(result.bestTranscription.formattedString)
                    }
                    if error != nil, self.mode == .speech, self.state == .recording, !self.finished {
                        // 识别断了不要判死，退化成时长判定
                        self.mode = .timer
                        self.hint = "语音识别中断，已切换为时长判定"
                    }
                }
            }
        }

        input.removeTap(onBus: 0)
        tapInstalled = false
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.request?.append(buffer)

            guard let data = buffer.floatChannelData?[0] else { return }
            let n = Int(buffer.frameLength)
            guard n > 0 else { return }

            var sum: Float = 0
            for i in 0..<n {
                let v = data[i]
                sum += v * v
            }
            let rms = sqrt(sum / Float(n))
            let db = 20.0 * log10(max(Double(rms), 1e-7))
            let seconds = Double(n) / format.sampleRate
            DispatchQueue.main.async { self.handleFrame(db: db, seconds: seconds) }
        }
        tapInstalled = true

        engine.prepare()
        try engine.start()
    }

    func stopAudio() {
        timer?.invalidate()
        timer = nil
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning {
            engine.stop()
        }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - 每帧音量（约 1/43 秒）
    private func handleFrame(db: Double, seconds: Double) {
        decibel = db
        level = max(0, min(1, (db + 60) / 60))
        guard state == .recording, !finished else { return }

        // 等第一声够大的声音，之后才开始计时
        if !startedSpeaking {
            if db >= thresholdDB {
                startedSpeaking = true
                lastLoudAt = Date()
            }
            return
        }

        totalSeconds += seconds
        if db >= thresholdDB {
            loudSeconds += seconds
            lastLoudAt = Date()
            isVoiceLoud = true
        } else if Date().timeIntervalSince(lastLoudAt) > 0.5 {
            isVoiceLoud = false
        }

        if totalSeconds > 0.3 {
            loudRatio = loudSeconds / totalSeconds
        }

        // 实时把关：读了一会儿有效音量还是不达标 → 立即不通过
        if totalSeconds > 2.5, loudRatio < minLoudRatio {
            fail("声音太小，不通过 😣\n有效音量只占 \(Int(loudRatio * 100))%，请凑近一点、大声重新读一遍。")
        }
    }

    // MARK: - 语音识别
    private func handleRecognition(_ text: String) {
        guard state == .recording, mode == .speech, !finished else { return }
        transcript = text

        let chars = TextMatch.normalize(text)
        guard chars.count > consumed else { return }
        let fresh = chars[consumed...]
        consumed = chars.count

        var p = pointer
        for ch in fresh where p < expected.count {
            if ch == expected[p] { p += 1 }
        }
        pointer = p
        progress = expected.isEmpty ? 0 : min(1, Double(pointer) / Double(expected.count))

        // 全读完且音量达标 → 立刻给奖励
        if pointer >= expected.count, loudRatio >= minLoudRatio {
            pass()
        }
    }

    // MARK: - 心跳
    private func tick() {
        guard state == .recording, !finished else { return }
        elapsed = Date().timeIntervalSince(startAt)

        if !startedSpeaking {
            if elapsed > 6 {
                hint = "还没听到声音：请检查麦克风，然后大声开始朗读"
            }
            return
        }

        let silence = Date().timeIntervalSince(lastLoudAt)

        switch mode {
        case .speech:
            if pointer >= expected.count {
                pass()
                return
            }
            if silence > silenceToFinish {
                judgeAfterReading()
                return
            }
            hint = isVoiceLoud ? "👂 正在听…请继续大声读完" : "🔈 声音太小了，大点声！"

        case .timer:
            progress = min(1, loudSeconds / targetSeconds)
            pointer = Int(Double(expected.count) * progress)
            if loudSeconds >= targetSeconds, silence > 0.8 {
                pass()
                return
            }
            if silence > max(silenceToFinish, 2.5) {
                judgeAfterReading()
                return
            }
            hint = isVoiceLoud ? "👂 正在听…请继续大声读完" : "🔈 声音太小了，大点声！"
        }
    }

    // MARK: - 判定
    private func judgeAfterReading() {
        guard state == .recording, !finished else { return }

        if loudRatio < minLoudRatio {
            fail("声音太小，不通过 😣\n有效音量只占 \(Int(loudRatio * 100))%，请大声重新读一遍。")
            return
        }

        switch mode {
        case .speech:
            if progress >= passProgress {
                pass()
            } else {
                fail("还没读完，或者没听清楚 😣\n完成度只有 \(Int(progress * 100))%，请大声、完整地读完全部内容。")
            }
        case .timer:
            if loudSeconds >= targetSeconds {
                pass()
            } else {
                fail(String(format: "读得太短或声音太小 😣\n有效朗读 %.1f 秒，至少需要 %.1f 秒。", loudSeconds, targetSeconds))
            }
        }
    }

    private func pass() {
        guard state == .recording else { return }
        finished = true
        progress = 1
        pointer = expected.count
        isVoiceLoud = true
        stopAudio()
        hint = "全部读完，音量达标！"
        // 成功反馈
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        AudioServicesPlaySystemSound(1057)
        state = .passed
    }

    private func fail(_ reason: String) {
        guard state == .recording else { return }
        finished = true
        stopAudio()
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        state = .failed(reason)
    }
}
