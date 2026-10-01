import Testing
@testable import SnowGlobe

struct ContextParticlesTests {
    private func items(_ ids: [String], _ state: SnowGlobeContextItem.State = .pending) -> [SnowGlobeContextItem] {
        ids.map { SnowGlobeContextItem(id: $0, state: state) }
    }

    private func run(_ tracker: inout ContextParticles, from start: Float, seconds: Float) -> Float {
        var now = start
        let dt: Float = 1/120
        for _ in 0..<Int(seconds/dt) {
            now += dt
            tracker.advance(dt: dt, now: now, flowFullness: 0.4, rate: 1)
            _ = tracker.takeSlots(now: now, visibleStream: 3000)
        }
        return now
    }

    @Test func sixSlotsWithDistinctHuesAndOverflowQueue() {
        var tracker = ContextParticles()
        tracker.reconcile(items((0..<8).map(String.init)), now: 0)
        let slotted = tracker.entries.compactMap(\.slot)
        #expect(slotted.sorted() == Array(0..<6))
        #expect(tracker.overflowCount == 2)
        #expect(tracker.pendingCount == 8)
        // Hue separation from the other large particles, measured around the wheel.
        func gap(_ a: Float, _ b: Float) -> Float { let d = abs(a-b); return min(d, 1-d) }
        let hues = ContextParticles.hues
        #expect(hues.count == ContextParticles.slotCount)
        for count in 2...hues.count {
            let shown = hues.prefix(count)
            let closest = shown.indices.flatMap { i in shown.indices.filter { $0 > i }.map { gap(shown[i], shown[$0]) } }.min()!
            // Two are opposite; even all six keep at least about a tenth of the wheel apart.
            #expect(closest >= (count == 2 ? 0.49 : count <= 4 ? 0.16 : 0.10), "\(count) particles: closest hues \(closest)")
        }
    }

    @Test func reconcileIsIdempotentAndIgnoresItemsThatArriveCommitted() {
        var tracker = ContextParticles()
        let list = items(["a", "b"]) + items(["old"], .committed)
        tracker.reconcile(list, now: 0)
        tracker.reconcile(list, now: 0)
        #expect(tracker.entries.map(\.id) == ["a", "b"])
    }

    @Test func removalFadesWithoutBreakupAndPromotesOverflow() {
        var tracker = ContextParticles()
        tracker.reconcile(items((0..<7).map(String.init)), now: 0)
        tracker.reconcile(items((1..<7).map(String.init)), now: 0)
        #expect(tracker.entries.first { $0.id == "0" }?.phase == .removing)
        _ = run(&tracker, from: 0, seconds: 0.4)
        #expect(!tracker.entries.contains { $0.id == "0" })
        #expect(tracker.entries.first { $0.id == "6" }?.slot == 0)
        #expect(!tracker.fragmentsActive(at: 0.4), "Removing a file must not break it up")
    }

    @Test func reattachingDuringRemovalRestoresTheParticle() {
        var tracker = ContextParticles()
        tracker.reconcile(items(["a"]), now: 0)
        tracker.reconcile([], now: 0)
        tracker.reconcile(items(["a"]), now: 0)
        #expect(tracker.entries.first?.phase == .holding)
    }

    @Test func commitStaggersBreakupsWithinTheWindow() {
        var tracker = ContextParticles()
        var sequence: [Float] = [0.9, 0.1, 0.7, 0.3, 0.5, 0.2, 0.8, 0.4, 0.6, 0.15]
        tracker.random = { sequence.isEmpty ? 0.5 : sequence.removeFirst() }
        tracker.reconcile(items(["a", "b", "c"]), now: 0)
        let now = run(&tracker, from: 0, seconds: 0.5)
        tracker.reconcile(items(["a", "b", "c"], .committed), now: now)
        var starts: [Float] = []
        for entry in tracker.entries {
            guard case .merging(let start, let duration, let fragments, _) = entry.phase else {
                Issue.record("\(entry.id) did not start breaking up"); continue
            }
            #expect(start >= now && start+duration <= now+ContextParticles.commitWindow.upperBound+0.001)
            #expect(ContextParticles.standardFragments.contains(fragments))
            starts.append(start)
        }
        #expect(Set(starts).count == 3, "Breakups should not start in unison")
        // The committed list may be dropped by the host; breakups still finish.
        tracker.reconcile([], now: now)
        #expect(tracker.entries.count == 3)
        let end = run(&tracker, from: now, seconds: 1.6)
        #expect(tracker.entries.isEmpty && !tracker.isVisible)
        #expect(tracker.fragmentsActive(at: end))
    }

    @Test func overflowFoldsIntoTheLastBreakup() {
        var tracker = ContextParticles()
        tracker.reconcile(items((0..<8).map(String.init)), now: 0)
        tracker.reconcile(items((0..<8).map(String.init), .committed), now: 0)
        #expect(tracker.overflowCount == 0)
        let counts = tracker.entries.map { entry -> Int in
            if case .merging(_, _, let fragments, _) = entry.phase { return fragments }
            return 0
        }
        #expect(counts.last == ContextParticles.overflowFragments)
        #expect(counts.dropLast().allSatisfy { ContextParticles.standardFragments.contains($0) })
    }

    @Test func recruitGateOpensForExactlyOneStep() {
        var tracker = ContextParticles()
        tracker.random = { 0 }
        tracker.reconcile(items(["a"]), now: 0)
        tracker.reconcile(items(["a"], .committed), now: 0)
        var recruitSteps = 0
        var now: Float = 0
        for _ in 0..<240 {
            now += 1/120
            tracker.advance(dt: 1/120, now: now, flowFullness: 0.4, rate: 1)
            let step = tracker.takeSlots(now: now, visibleStream: 3000)
            if !step.recruiting.isEmpty {
                recruitSteps += 1
                #expect(step.slots[0].merge.w > 0 && step.slots[0].merge.w <= 1)
            } else {
                #expect(step.slots[0].merge.w == 0)
            }
        }
        #expect(recruitSteps == 1)
    }

    @Test func eachSlotRunsItsOwnRingSpeed() {
        #expect(Set(ContextParticles.ringSpeeds).count == ContextParticles.slotCount)
        #expect(ContextParticles.ringSpeeds.allSatisfy { (0.75...1.2).contains($0) },
                "Rings stay near the stream's pace")
        var tracker = ContextParticles()
        tracker.reconcile(items(["a", "b", "c"]), now: 0)
        let start = tracker.takeSlots(now: 0, visibleStream: 3000).slots.map(\.orbit.x)
        _ = run(&tracker, from: 0, seconds: 0.2)
        let later = tracker.takeSlots(now: 0.2, visibleStream: 3000).slots.map(\.orbit.x)
        let travel = (0..<3).map { later[$0]-start[$0] }
        #expect(Set(travel.map { ($0*1000).rounded() }).count == 3, "Particles move in lockstep: \(travel)")
        #expect(Set(start.prefix(3)).count == 3, "New particles start on top of each other")
    }

    @Test func remainingFractionShrinksSlowlyThenCrumbles() {
        #expect(ContextParticles.remaining(progress: 0) == 1)
        #expect(ContextParticles.remaining(progress: 1) == 0)
        let early = 1-ContextParticles.remaining(progress: 0.25)
        let late = ContextParticles.remaining(progress: 0.75)-ContextParticles.remaining(progress: 1)
        #expect(early < late, "Shedding should build toward the end")
    }

    @Test func accessibilityCountsPendingFiles() {
        // The tracker and the view count the same thing: attached, unsent files.
        var tracker = ContextParticles()
        tracker.reconcile(items(["a", "b"]) + items(["c"], .committed), now: 0)
        #expect(tracker.pendingCount == 2)
    }
}
