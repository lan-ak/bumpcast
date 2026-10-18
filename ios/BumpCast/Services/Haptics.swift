import CoreHaptics
import Foundation

/// Soft, sparse, optional haptics (DESIGN_SPEC §5). Never warning/error patterns for turbulence.
@MainActor
final class Haptics {
    static let shared = Haptics()
    static var isSupported: Bool { CHHapticEngine.capabilitiesForHardware().supportsHaptics }

    private var engine: CHHapticEngine?
    private var player: CHHapticAdvancedPatternPlayer?

    /// A continuous breath: intensity swells 0.1 → 0.6 over the inhale and fades back over the exhale.
    func startBreathing(inhale: TimeInterval, exhale: TimeInterval) {
        guard Self.isSupported, let engine = prepareEngine() else { return }
        stop()
        let cycle = inhale + exhale
        let event = CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.1),
            ],
            relativeTime: 0, duration: cycle)
        let curve = CHHapticParameterCurve(
            parameterID: .hapticIntensityControl,
            controlPoints: [
                .init(relativeTime: 0, value: 0.1),
                .init(relativeTime: inhale, value: 0.6),
                .init(relativeTime: cycle, value: 0.1),
            ],
            relativeTime: 0)
        do {
            let pattern = try CHHapticPattern(events: [event], parameterCurves: [curve])
            let player = try engine.makeAdvancedPlayer(with: pattern)
            player.loopEnabled = true
            try player.start(atTime: CHHapticTimeImmediate)
            self.player = player
        } catch {
            self.player = nil
        }
    }

    /// Opt-in "what light chop feels like": gentle irregular taps, intensity ≤ 0.4.
    func playLightChop() {
        guard Self.isSupported, let engine = prepareEngine() else { return }
        let times: [TimeInterval] = [0, 0.18, 0.31, 0.55, 0.7, 0.93, 1.12, 1.4, 1.55, 1.8]
        let events = times.enumerated().map { i, t in
            CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: Float([0.25, 0.4, 0.3, 0.35][i % 4])),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.2),
                ],
                relativeTime: t)
        }
        do {
            let pattern = try CHHapticPattern(events: events, parameters: [])
            try engine.makePlayer(with: pattern).start(atTime: CHHapticTimeImmediate)
        } catch {}
    }

    func stop() {
        try? player?.stop(atTime: CHHapticTimeImmediate)
        player = nil
    }

    private func prepareEngine() -> CHHapticEngine? {
        if let engine { return engine }
        guard let engine = try? CHHapticEngine() else { return nil }
        engine.playsHapticsOnly = true
        engine.resetHandler = { [weak engine] in try? engine?.start() }
        try? engine.start()
        self.engine = engine
        return engine
    }
}
