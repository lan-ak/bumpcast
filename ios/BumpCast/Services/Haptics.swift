import CoreHaptics
import Foundation
import UIKit

/// Soft, sparse, optional haptics (DESIGN_SPEC §5). Never warning/error patterns for turbulence.
@MainActor
final class Haptics {
    static let shared = Haptics()
    static var isSupported: Bool { CHHapticEngine.capabilitiesForHardware().supportsHaptics }

    private var engine: CHHapticEngine?
    private var player: CHHapticAdvancedPatternPlayer?
    /// iOS stopped the engine (the app went to the background, an audio interruption): it and its
    /// players need starting again before the next use.
    private var engineStopped = false
    /// The breath being played, and when it began, so it picks up in step with the orb.
    private var breath: (inhale: TimeInterval, exhale: TimeInterval, startedAt: Date)?

    private init() {
        // iOS stops the engine in the background; the breath carries on when the app is back.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { Haptics.shared.resumeBreathing() }
        }
    }

    /// A continuous breath: intensity swells 0.1 → 0.6 over the inhale and fades back over the exhale.
    func startBreathing(inhale: TimeInterval, exhale: TimeInterval) {
        guard Self.isSupported else { return }
        stop()
        breath = (inhale, exhale, .now)
        playBreath()
    }

    /// Plays the breath from where it is now in its cycle.
    private func playBreath() {
        guard let breath, let engine = prepareEngine() else { return }
        try? player?.stop(atTime: CHHapticTimeImmediate)
        player = nil
        let cycle = breath.inhale + breath.exhale
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
                .init(relativeTime: breath.inhale, value: 0.6),
                .init(relativeTime: cycle, value: 0.1),
            ],
            relativeTime: 0)
        do {
            let pattern = try CHHapticPattern(events: [event], parameterCurves: [curve])
            let player = try engine.makeAdvancedPlayer(with: pattern)
            player.loopEnabled = true
            try player.start(atTime: CHHapticTimeImmediate)
            let offset = Date.now.timeIntervalSince(breath.startedAt).truncatingRemainder(dividingBy: cycle)
            if offset > 0.05 { try? player.seek(toOffset: offset) }
            self.player = player
        } catch {
            self.player = nil
        }
    }

    /// Back in the foreground (or after the engine reset): the breath starts again if it stopped.
    private func resumeBreathing() {
        guard breath != nil, engineStopped || player == nil else { return }
        playBreath()
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
        breath = nil
        try? player?.stop(atTime: CHHapticTimeImmediate)
        player = nil
    }

    /// The engine, started. One iOS stopped is started again, and replaced if it won't start.
    private func prepareEngine() -> CHHapticEngine? {
        if let engine {
            guard engineStopped else { return engine }
            if (try? engine.start()) != nil {
                engineStopped = false
                return engine
            }
            self.engine = nil
        }
        guard let engine = try? CHHapticEngine() else { return nil }
        engine.playsHapticsOnly = true
        // Both arrive on a CoreHaptics queue. A stopped engine's players are gone with it.
        engine.stoppedHandler = { _ in
            Task { @MainActor in
                Haptics.shared.engineStopped = true
                Haptics.shared.player = nil
            }
        }
        // The haptic server restarted: the engine and its players have to be started again.
        engine.resetHandler = {
            Task { @MainActor in
                Haptics.shared.engineStopped = true
                Haptics.shared.player = nil
                Haptics.shared.resumeBreathing()
            }
        }
        do {
            try engine.start()
        } catch {
            return nil
        }
        engineStopped = false
        self.engine = engine
        return engine
    }
}
