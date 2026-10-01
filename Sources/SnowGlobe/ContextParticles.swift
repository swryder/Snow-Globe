import Foundation
import simd

/// A file or other piece of context the host has made visible to the agent.
/// Pass the current list on every update; the globe compares it with the
/// previous list, so a rebuilt view never replays or loses an animation.
public struct SnowGlobeContextItem: Identifiable, Hashable, Sendable {
    public enum State: Hashable, Sendable {
        /// Attached but not yet sent: a large particle on its own ring.
        /// Removing a pending item from the list fades it out without a breakup.
        case pending
        /// Sent with the user's turn: the particle breaks up into the stream.
        /// The host may drop committed items from the list at any time afterward.
        case committed
    }
    public var id: String
    public var state: State

    public init(id: String, state: State = .pending) {
        self.id = id
        self.state = state
    }
}

// Mirrors ContextSlot and ContextBody in Particles.metal.
struct ContextSlot {
    var orbit: SIMD4<Float>  // phase, presence, remaining fraction, hue
    var merge: SIMD4<Float>  // breakup start, breakup duration (0 = none), fragment target, recruit gate (0 = not this step)
    var look: SIMD4<Float>   // size scale, snap to orbit, reserved, reserved
}

struct ContextBody {
    var position: SIMD4<Float>
    var velocity: SIMD4<Float>
}

/// CPU bookkeeping for the large context particles. Motion of the particles
/// themselves runs on the GPU; this decides what exists, where on its ring it
/// sits, and when each breakup starts.
struct ContextParticles {
    static let slotCount = 6
    /// Six vivid hues spread around the whole wheel: green, magenta, amber,
    /// cyan, red, blue. Size sets them apart from the stream, so hue only has to
    /// separate them from one another. Each slot fills the widest remaining gap.
    static let hues: [Float] = [0.33, 0.83, 0.13, 0.50, 0.02, 0.64]
    /// Release time within a breakup is duration·hash^exponent. Below 1, few
    /// fragments leave at first and the rate builds into a final crumble.
    /// The GPU recruit code uses the same value.
    static let releaseExponent: Float = 0.6
    static let standardFragments = 80...100
    static let overflowFragments = 150
    /// Each separate commit spreads its breakups over this many seconds.
    static let commitWindow: ClosedRange<Float> = 1.0...1.5
    /// Each slot's ring runs a little faster or slower than the stream's
    /// average, so the large particles pass one another instead of keeping formation.
    static let ringSpeeds: [Float] = [1.00, 0.86, 1.13, 0.93, 1.07, 0.80]

    enum Phase: Equatable {
        case holding
        case merging(start: Float, duration: Float, fragments: Int, recruited: Bool)
        case removing
    }

    struct Entry {
        let id: String
        let order: Int
        var slot: Int?
        var phase: Phase
        var presence: Float = 0
        var angle: Float = 0
    }

    private(set) var entries: [Entry] = []
    private var nextOrder = 0
    private var snaps = Set<Int>()
    private var recruits = Set<Int>()
    private(set) var fragmentsActiveUntil: Float = -.infinity
    var random: () -> Float = { Float.random(in: 0..<1) }

    var pendingCount: Int { entries.filter { $0.phase == .holding }.count }
    var overflowCount: Int { entries.filter { $0.slot == nil && $0.phase == .holding }.count }
    var isVisible: Bool { entries.contains { $0.slot != nil } }

    func hue(forSlot slot: Int) -> Float { Self.hues[slot] }

    /// Apply the host's current list. Idempotent: the same list changes nothing.
    mutating func reconcile(_ items: [SnowGlobeContextItem], now: Float) {
        var listed = [String: SnowGlobeContextItem.State]()
        for item in items where listed[item.id] == nil { listed[item.id] = item.state }
        var committing = Set<String>()
        var committedOverflow = 0
        entries.removeAll { entry in
            guard entry.phase == .holding, entry.slot == nil else { return false }
            switch listed[entry.id] {
            case .committed:
                // Folded into the last visible breakup instead.
                committedOverflow += 1
                return true
            case nil: return true
            case .pending: return false
            }
        }
        for index in entries.indices {
            switch (entries[index].phase, listed[entries[index].id]) {
            case (.holding, .committed): committing.insert(entries[index].id)
            case (.holding, nil): entries[index].phase = .removing
            case (.removing, .pending): entries[index].phase = .holding
            default:
                // A breakup in progress continues even if the host drops the item.
                break
            }
        }
        if !committing.isEmpty {
            scheduleBreakups(entries.indices.filter { committing.contains(entries[$0].id) },
                             extra: committedOverflow, now: now)
        }
        for item in items where item.state == .pending && !entries.contains(where: { $0.id == item.id }) {
            entries.append(Entry(id: item.id, order: nextOrder, slot: nil, phase: .holding))
            nextOrder += 1
        }
        // An item that arrives already committed was handled by a previous view or
        // never shown; it gets no particle.
        assignSlots()
    }

    private mutating func scheduleBreakups(_ indices: [Int], extra: Int, now: Float) {
        let window = Self.commitWindow.lowerBound + (Self.commitWindow.upperBound-Self.commitWindow.lowerBound)*random()
        let last = indices.max { entries[$0].order < entries[$1].order }
        for index in indices {
            // One item uses the whole window; several overlap with jittered starts
            // so they finish together within it without breaking in unison.
            let duration = indices.count == 1 ? window : window*(0.62+0.18*random())
            let start = now + (window-duration)*random()
            let span = Self.standardFragments
            var fragments = span.lowerBound + Int(Float(span.count)*random()) % span.count
            if index == last && (extra > 0 || overflowCount > 0) { fragments = Self.overflowFragments }
            entries[index].phase = .merging(start: start, duration: duration, fragments: fragments, recruited: false)
            fragmentsActiveUntil = max(fragmentsActiveUntil, start+duration+Self.fragmentAfterglow)
        }
    }

    /// Seconds after release during which a fragment keeps its tint, sparkle, and trail.
    static let fragmentAfterglow: Float = 6

    private mutating func assignSlots() {
        var used = Set(entries.compactMap(\.slot))
        for index in entries.indices where entries[index].slot == nil && entries[index].phase == .holding {
            guard let free = (0..<Self.slotCount).first(where: { !used.contains($0) }) else { break }
            entries[index].slot = free
            entries[index].presence = 0
            // Golden-angle starts keep a new particle away from the recent ones.
            entries[index].angle = (2.39996 * Float(entries[index].order)).truncatingRemainder(dividingBy: 2 * .pi)
            used.insert(free)
            snaps.insert(free)
        }
    }

    /// - Parameters:
    ///   - flowFullness: The shader's spatial fullness, 0.40 + 0.60·activity.
    ///   - rate: The motion clock rate applied to orbital speed.
    mutating func advance(dt: Float, now: Float, flowFullness: Float, rate: Float) {
        // Around the main stream's average orbital speed, so the large
        // particles travel with the flow, each at its own ring's pace.
        let streamSpeed = 0.98 * (0.13 + 1.48*pow(flowFullness, 1.6)) * dt * rate
        for index in entries.indices.reversed() {
            if let slot = entries[index].slot {
                entries[index].angle = (entries[index].angle + streamSpeed*Self.ringSpeeds[slot])
                    .truncatingRemainder(dividingBy: 2 * .pi)
            }
            switch entries[index].phase {
            case .holding:
                entries[index].presence += (1-entries[index].presence) * (1-exp(-dt*7))
            case .removing:
                entries[index].presence -= dt/0.30
                if entries[index].presence <= 0 { entries.remove(at: index) }
            case .merging(let start, let duration, let fragments, let recruited):
                entries[index].presence += (1-entries[index].presence) * (1-exp(-dt*7))
                if !recruited && now >= start, let slot = entries[index].slot {
                    recruits.insert(slot)
                    entries[index].phase = .merging(start: start, duration: duration, fragments: fragments, recruited: true)
                }
                // Keep the slot until every fragment has read its position.
                if now >= start+duration+0.05 { entries.remove(at: index) }
            }
        }
        assignSlots()
    }

    /// Fraction of the particle not yet released as fragments.
    static func remaining(progress: Float) -> Float {
        1 - pow(min(1, max(0, progress)), 1/releaseExponent)
    }

    /// One step's GPU parameters. Snaps and recruit flags apply to this step only.
    /// - Parameter visibleStream: Estimated visible particles in the main stream.
    mutating func takeSlots(now: Float, visibleStream: Float) -> (slots: [ContextSlot], recruiting: [Int]) {
        var slots = [ContextSlot](repeating: ContextSlot(orbit: .zero, merge: .zero, look: .zero), count: Self.slotCount)
        let growLast = overflowCount > 0
        let lastVisible = entries.filter { $0.slot != nil && $0.phase == .holding }.max { $0.order < $1.order }?.order
        for entry in entries {
            guard let slot = entry.slot else { continue }
            var remaining: Float = 1
            var merge = SIMD4<Float>.zero
            if case .merging(let start, let duration, let fragments, _) = entry.phase {
                remaining = Self.remaining(progress: (now-start)/duration)
                // Gather about three candidates per wanted fragment; an atomic
                // counter on the GPU then admits the exact number.
                let gate = recruits.contains(slot) ? min(1, max(0.0005, 3*Float(fragments)/max(1, visibleStream))) : 0
                merge = SIMD4(start, duration, Float(fragments), gate)
            }
            // A small overshoot as the particle arrives draws the eye to it.
            let p = min(1, max(0, entry.presence))
            let pop = 1 + 1.2*p*(1-p)*(entry.phase == .holding ? 1 : 0)
            let scale = pop * (growLast && entry.order == lastVisible ? 1.2 : 1)
            slots[slot] = ContextSlot(orbit: SIMD4(entry.angle, p*p*(3-2*p), remaining, Self.hues[slot]),
                                      merge: merge,
                                      look: SIMD4(scale, snaps.contains(slot) ? 1 : 0, 0, 0))
        }
        let recruiting = recruits.sorted()
        snaps.removeAll()
        recruits.removeAll()
        return (slots, recruiting)
    }

    func fragmentsActive(at now: Float) -> Bool { now < fragmentsActiveUntil }
}
