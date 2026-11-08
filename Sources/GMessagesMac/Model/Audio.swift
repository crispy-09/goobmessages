import Foundation
import AVFoundation

/// Records a voice message as AAC in an .m4a container ("audio/mp4", the format the libgm bridge sends voice notes in).
/// The recording lives in a private temp file only until it is read back into memory.
@MainActor
final class VoiceRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var level: Double = 0          // 0…1, for the live meter

    static let maxDuration: TimeInterval = 5 * 60
    /// Microphone access needs a real .app with a usage description in its Info.plist.
    static var isAvailable: Bool { AppEnv.isBundled }

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var fileURL: URL?

    /// Starts recording. Returns an error message to show, or nil on success.
    func start() async -> String? {
        guard Self.isAvailable else { return "Voice messages need the app built with scripts/make_app.sh." }
        guard !isRecording else { return nil }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            if !(await AVCaptureDevice.requestAccess(for: .audio)) { return "Microphone access was denied." }
        default:
            return "Microphone access is off. Turn it on in System Settings → Privacy & Security → Microphone."
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gmm-voice-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ]
        do {
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.isMeteringEnabled = true
            guard r.record(forDuration: Self.maxDuration) else { return "Couldn't start recording." }
            recorder = r
            fileURL = url
            elapsed = 0
            isRecording = true
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Stops and returns the recording, or nil if it was shorter than half a second.
    func finish() -> OutgoingAttachment? {
        guard let r = recorder, let url = fileURL else { return nil }
        let duration = r.currentTime
        r.stop()
        reset()
        defer { try? FileManager.default.removeItem(at: url) }
        guard duration >= 0.5, let data = try? Data(contentsOf: url) else { return nil }
        return OutgoingAttachment(data: data, name: "Voice message.m4a", mime: "audio/mp4", preview: nil)
    }

    func cancel() {
        recorder?.stop()
        recorder?.deleteRecording()
        if let url = fileURL { try? FileManager.default.removeItem(at: url) }
        reset()
    }

    private func tick() {
        guard let r = recorder else { return }
        guard r.isRecording else { return }          // hit maxDuration: the UI's Send button still works
        r.updateMeters()
        elapsed = r.currentTime
        let db = Double(r.averagePower(forChannel: 0))          // -160 … 0 dBFS
        level = max(0, min(1, (db + 50) / 50))
    }

    private func reset() {
        timer?.invalidate()
        timer = nil
        recorder = nil
        fileURL = nil
        isRecording = false
        level = 0
    }
}

/// Plays one audio attachment at a time, straight from memory (decrypted audio is never written to disk).
@MainActor
final class AudioPlayback: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = AudioPlayback()

    @Published private(set) var currentID: String?
    @Published private(set) var isPlaying = false
    @Published private(set) var progress: Double = 0       // 0…1
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var loadingID: String?

    private var player: AVAudioPlayer?
    private var timer: Timer?

    func toggle(_ item: MediaItem, model: AppModel) async -> String? {
        if currentID == item.id, let p = player {
            if p.isPlaying { p.pause(); isPlaying = false } else { p.play(); isPlaying = true; startTimer() }
            return nil
        }
        stop()
        loadingID = item.id
        defer { if loadingID == item.id { loadingID = nil } }
        guard let data = await model.mediaData(for: item) else { return "Couldn't download the audio." }
        do {
            let p = try AVAudioPlayer(data: data)
            p.delegate = self
            p.prepareToPlay()
            player = p
            currentID = item.id
            duration = p.duration
            progress = 0
            p.play()
            isPlaying = true
            startTimer()
            return nil
        } catch {
            return "This audio format can't be played here. Use Save… to open it in another app."
        }
    }

    func stop() {
        player?.stop()
        player = nil
        timer?.invalidate(); timer = nil
        currentID = nil
        isPlaying = false
        progress = 0
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let p = self.player, p.duration > 0 else { return }
                self.progress = p.currentTime / p.duration
            }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.progress = 0
            self.timer?.invalidate(); self.timer = nil
        }
    }
}

extension TimeInterval {
    /// "0:07", "1:23"
    var clockString: String {
        let s = Int(self.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
