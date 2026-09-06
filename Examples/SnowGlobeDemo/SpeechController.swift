import AppKit
import AVFoundation
import Combine
import NaturalLanguage
import SnowGlobe

struct SpeechClip {
    let text: String
    let audio: Data
    let envelope: SpeechEnvelope
}

/// `say` is macOS's local speech engine, invoked with arguments, never a shell.
/// Each job owns its process and scratch directory; Stop cancels synthesis too.
final class SpeechSynthesisJob {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if let process, process.isRunning { process.terminate() }
    }

    func render(_ sentence: String, in directory: URL, index: Int) throws -> SpeechClip {
        let url = directory.appendingPathComponent("sentence-\(index).aiff")
        let errorURL = directory.appendingPathComponent("sentence-\(index).log")
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let errorFile = try FileHandle(forWritingTo: errorURL)
        defer { try? errorFile.close() }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        task.arguments = ["-v","Jamie (Premium)","-o",url.path,"--",sentence]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = errorFile
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        process = task
        do { try task.run() } catch { process = nil; lock.unlock(); throw error }
        lock.unlock()
        task.waitUntilExit()
        lock.lock(); process = nil; let stopped = cancelled; lock.unlock()
        if stopped { throw CancellationError() }
        guard task.terminationStatus == 0 else {
            let details = (try? String(contentsOf: errorURL, encoding: .utf8)) ?? ""
            throw SpeechFailure.unavailable("Could not synthesize Jamie (Premium). \(details.prefix(250))")
        }
        return try SpeechClip(text: sentence, audio: Data(contentsOf: url), envelope: SpeechEnvelope(url: url))
    }
}

final class SpeechController: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let sampleText = "Hello, I'm Jamie, and this is what it looks like when the globe speaks. A quiet phrase gives the particles a gentle breath, while a little excitement sends light dancing through the currents."
    @Published var text = SpeechController.sampleText
    @Published private(set) var isActive = false
    @Published private(set) var status = "Jamie (Premium)"
    @Published private(set) var currentSentence = ""
    @Published private(set) var error: String?
    let meter = SpeechMeter()
    private var job: SpeechSynthesisJob?
    private var generation = UUID()
    private var clips: [SpeechClip] = []
    private var activeClip: SpeechClip?
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var allPrepared = false
    private var completedSentences = 0
    private var meterSamples = 0
    private var peakLevel: Float = 0
    private var quietSamples = 0

    static func sentences(in text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var sentences: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { sentences.append(sentence) }
            return true
        }
        return sentences
    }

    func speak() {
        stop()
        error = nil
        let sentences = Self.sentences(in: text)
        guard !sentences.isEmpty else { error = "Enter some text to speak."; return }
        guard text.count <= 5_000 else { error = "Please keep this speech test under 5,000 characters."; return }
        isActive = true
        meter.store(.zero,sessionActive: true)
        status = "Preparing Jamie…"
        completedSentences = 0; meterSamples = 0; quietSamples = 0; peakLevel = 0
        let token = generation
        let newJob = SpeechSynthesisJob()
        job = newJob
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SnowGlobeSpeech-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                for (index,sentence) in sentences.enumerated() {
                    let clip = try newJob.render(sentence,in: directory,index: index)
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.generation == token else { return }
                        self.clips.append(clip)
                        if self.player == nil { self.playNext() }
                    }
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == token else { return }
                    self.allPrepared = true
                    if self.player == nil { self.playNext() }
                }
            } catch is CancellationError {
                // Stop owns the visible state and invalidates callbacks.
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == token else { return }
                    self.stop(); self.error = error.localizedDescription
                }
            }
        }
    }

    func stop() {
        generation = UUID()
        job?.cancel(); job = nil
        player?.stop(); player = nil
        timer?.invalidate(); timer = nil
        clips.removeAll(); activeClip = nil; allPrepared = false
        meter.store(.zero,sessionActive: false)
        isActive = false; status = "Jamie (Premium)"; currentSentence = ""
    }

    private func playNext() {
        guard isActive else { return }
        guard !clips.isEmpty else {
            if allPrepared {
                writePlaybackReport()
                stop()
            } else {
                status = "Preparing next sentence…"
            }
            return
        }
        let clip = clips.removeFirst()
        do {
            let audio = try AVAudioPlayer(data: clip.audio)
            audio.delegate = self
            guard audio.prepareToPlay(), audio.play() else {
                throw SpeechFailure.unavailable("The speech audio could not start playing.")
            }
            player = audio; activeClip = clip
            currentSentence = clip.text; status = "Speaking · Jamie"
            let tick = Timer(timeInterval: 1.0/60.0, repeats: true) { [weak self] _ in self?.updateMeter() }
            timer = tick
            RunLoop.main.add(tick,forMode: .common)
        } catch { stop(); self.error = error.localizedDescription }
    }

    private func updateMeter() {
        guard let player, player.isPlaying, let clip = activeClip else { meter.store(.zero); return }
        // The player's clock, not synthesis progress or wall time, chooses the
        // corresponding audio envelope. Pauses therefore stay quiet naturally.
        let playbackTime = player.currentTime
        let sample = clip.envelope.sample(at: playbackTime)
        meter.store(sample,waveform: clip.envelope.waveform(at: playbackTime))
        meterSamples += 1; peakLevel = max(peakLevel,sample.x)
        if sample.x < 0.05 { quietSamples += 1 }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        timer?.invalidate(); timer = nil
        self.player = nil; activeClip = nil; meter.store(.zero)
        if !flag { stop(); error = "Speech playback stopped unexpectedly."; return }
        completedSentences += 1
        playNext()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        stop(); self.error = error?.localizedDescription ?? "Speech audio could not be decoded."
    }

    private func writePlaybackReport() {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--speech-log"), args.count > index+1 else { return }
        let report: [String: Any] = ["voice": "Jamie (Premium)","completedSentences": completedSentences,
                                   "meterSamples": meterSamples,"peakLevel": peakLevel,"quietSamples": quietSamples]
        if let data = try? JSONSerialization.data(withJSONObject: report,options: [.prettyPrinted,.sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: args[index+1]))
        }
    }

    deinit { job?.cancel(); player?.stop(); timer?.invalidate() }
}

private enum SpeechFailure: LocalizedError {
    case unavailable(String)
    var errorDescription: String? { switch self { case .unavailable(let message): return message } }
}
