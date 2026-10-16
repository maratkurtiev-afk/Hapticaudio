import SwiftUI
import AVFoundation
import CoreHaptics
import UniformTypeIdentifiers

@main
struct HapticAudioApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

final class HapticPlayer: ObservableObject {
    @Published var title = "Трек не выбран"
    @Published var playing = false
    var gain: Float = 1.0

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var file: AVAudioFile?
    private var hEngine: CHHapticEngine?
    private var hPlayer: CHHapticAdvancedPatternPlayer?
    private var restartTimer: Timer?
    private let q = DispatchQueue(label: "haptic.send")
    private var lp1: Float = 0, lp2: Float = 0, env: Float = 0

    init() { engine.attach(node) }

    func load(_ url: URL) {
        stop()
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        let dst = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: dst)
        guard (try? FileManager.default.copyItem(at: url, to: dst)) != nil,
              let f = try? AVAudioFile(forReading: dst) else { title = "Файл не открылся"; return }
        file = f
        title = url.deletingPathExtension().lastPathComponent
    }

    func play() {
        guard let file = file, !playing else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        let fmt = file.processingFormat
        engine.connect(node, to: engine.mainMixerNode, format: fmt)
        let sr = Float(fmt.sampleRate)
        let a1 = 1 - exp(-2 * Float.pi * 2000 / sr)   // верх полосы ~2 кГц
        let a2 = 1 - exp(-2 * Float.pi * 100 / sr)    // низ полосы ~100 Гц
        lp1 = 0; lp2 = 0; env = 0
        engine.mainMixerNode.removeTap(onBus: 0)
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buf, _ in
            self?.analyze(buf, a1, a2)
        }
        startHaptics()
        node.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async { self?.stop() }
        }
        try? engine.start()
        node.play()
        playing = true
    }

    func stop() {
        guard playing else { return }
        playing = false
        restartTimer?.invalidate()
        node.stop()
        engine.mainMixerNode.removeTap(onBus: 0)
        engine.stop()
        try? hPlayer?.stop(atTime: CHHapticTimeImmediate)
        hEngine?.stop(completionHandler: nil)
        hEngine = nil; hPlayer = nil
        file?.framePosition = 0
    }

    // Огибающая полосы 100 Гц–2 кГц -> intensity, «яркость» (доля верхов) -> sharpness
    private func analyze(_ buf: AVAudioPCMBuffer, _ a1: Float, _ a2: Float) {
        guard let ch = buf.floatChannelData?[0] else { return }
        let n = Int(buf.frameLength)
        var eBand: Float = 0, eHi: Float = 0
        for i in 0..<n {
            let x = ch[i]
            lp1 += a1 * (x - lp1)
            lp2 += a2 * (lp1 - lp2)
            let band = lp1 - lp2, hi = x - lp1
            eBand += band * band
            eHi += hi * hi
        }
        let rms = sqrt(eBand / Float(max(n, 1)))
        let bright = eHi / (eHi + eBand + 1e-9)
        let level = min(1, pow(rms * 4 * gain, 0.6))
        env = level > env ? level : env * 0.7 + level * 0.3   // быстрая атака, мягкий спад
        let sharp = min(1, max(0, 0.3 + bright * 2.0))
        let out = env
        q.async { [weak self] in self?.send(out, sharp) }
    }

    private func send(_ i: Float, _ s: Float) {
        try? hPlayer?.sendParameters([
            CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: i, relativeTime: 0),
            // предполагаю, что sharpness-control добавляется к базе 0.5; если нет, поправим
            CHHapticDynamicParameter(parameterID: .hapticSharpnessControl, value: s - 0.5, relativeTime: 0)
        ], atTime: CHHapticTimeImmediate)
    }

    private func startHaptics() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            let e = try CHHapticEngine()
            e.isAutoShutdownEnabled = false
            e.resetHandler = { [weak self] in try? self?.hEngine?.start(); self?.makePlayer() }
            try e.start()
            hEngine = e
            makePlayer()
            // непрерывное событие живёт максимум 30 с, перезапускаем
            restartTimer = Timer.scheduledTimer(withTimeInterval: 28, repeats: true) { [weak self] _ in
                try? self?.hPlayer?.stop(atTime: CHHapticTimeImmediate)
                try? self?.hPlayer?.start(atTime: CHHapticTimeImmediate)
            }
        } catch { print("haptics:", error) }
    }

    private func makePlayer() {
        let ev = CHHapticEvent(eventType: .hapticContinuous, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)
        ], relativeTime: 0, duration: 30)
        do {
            hPlayer = try hEngine?.makeAdvancedPlayer(with: CHHapticPattern(events: [ev], parameters: []))
            try hPlayer?.start(atTime: CHHapticTimeImmediate)
        } catch { print("player:", error) }
    }
}

struct ContentView: View {
    @StateObject private var p = HapticPlayer()
    @State private var picking = false
    @State private var gain = 1.0

    var body: some View {
        VStack(spacing: 24) {
            Text(p.title).font(.headline).multilineTextAlignment(.center)
            Button("Выбрать трек") { picking = true }
            Button(p.playing ? "Стоп" : "Играть") { p.playing ? p.stop() : p.play() }
                .buttonStyle(.borderedProminent)
            VStack {
                Text("Сила вибрации")
                Slider(value: $gain, in: 0.2...3)
            }.onChange(of: gain) { p.gain = Float($0) }
        }
        .padding()
        .fileImporter(isPresented: $picking, allowedContentTypes: [.audio]) { r in
            if case .success(let url) = r { p.load(url) }
        }
    }
}
