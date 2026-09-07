#if os(macOS)
@testable import SnowGlobe
import AppKit
import Metal
import CoreVideo
import simd

/// Run the exact production kernels offscreen for reproducible visual inspection
/// and numerical checks. PNG previews are SDR; HDR peaks are recorded separately.
enum RenderValidation {
    private static func floatFromHalf(_ bits: UInt16) -> Float {
        let sign = UInt32(bits & 0x8000) << 16
        let exponent = UInt32((bits >> 10) & 0x1f)
        let mantissa = UInt32(bits & 0x03ff)
        if exponent == 0 {
            let magnitude = Float(mantissa) * 5.960464477539063e-8
            return sign == 0 ? magnitude : -magnitude
        }
        let convertedExponent: UInt32 = exponent == 31 ? 255 : exponent + 112
        return Float(bitPattern: sign | (convertedExponent << 23) | (mantissa << 13))
    }

    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw RendererFailure.unavailable(message) }
    }

    static func run(directory: String, speechAudioURL: URL) throws {
        try require(MemoryLayout<Particle>.stride == 64, "Particle CPU/GPU layout mismatch")
        try require(MemoryLayout<Uniforms>.stride == 208, "Uniform CPU/GPU layout mismatch")
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        // Keep established visual regressions at their reference settings.
        var renderer = try ParticleRenderer(initialDisc: 0, initialIdleSpeed: 1.35, initialDensity: 1, initialSize: 1, initialTrailLength: 0.25)
        print("GPU: \(renderer.device.name)")

        func advance(_ seconds: Double) throws {
            let steps = Int(seconds / Double(ParticleRenderer.fixedStep))
            for start in stride(from: 0, to: steps, by: 8) {
                guard let command = renderer.queue.makeCommandBuffer() else {
                    throw RendererFailure.unavailable("Validation command allocation failed")
                }
                for _ in start..<min(start+8,steps) { renderer.step(command: command) }
                command.commit()
                command.waitUntilCompleted()
                if let error = command.error { throw error }
            }
        }

        func stats() throws -> [String: Any] {
            let data = renderer.particles.contents().bindMemory(to: Particle.self, capacity: ParticleRenderer.particleCount)
            var visible = [Int](repeating: 0, count: 5)
            var angularMomentum = [SIMD3<Float>](repeating: .zero, count: 5)
            var collisionCount = 0
            var maxRadius: Float = 0
            var energy: Float = 0
            var totalSpeed: Float = 0
            var nearWall = 0, wallGliding = 0, aboveEquator = 0
            var centralParticles = 0
            var lowY: Float = 1, highY: Float = -1
            var left: Float = 1, right: Float = -1
            for id in 0..<ParticleRenderer.particleCount {
                let p = data[id]
                let values = [p.position, p.velocity, p.orbit, p.appearance]
                try require(values.allSatisfy { vector in (0..<4).allSatisfy { vector[$0].isFinite } }, "Non-finite particle at \(id)")
                maxRadius = max(maxRadius, length(SIMD3(p.position.x,p.position.y,p.position.z)))
                if p.position.w > 0.2 {
                    visible[Int(p.orbit.w)] += 1
                    energy += p.appearance.y
                    if p.velocity.w > 0.03 { collisionCount += 1 }
                    let position = SIMD3(p.position.x,p.position.y,p.position.z)
                    let velocity = SIMD3(p.velocity.x,p.velocity.y,p.velocity.z)
                    angularMomentum[Int(p.orbit.w)] += cross(position,velocity)
                    totalSpeed += length(velocity)*renderer.motionRate
                    if length(position) < 0.45 { centralParticles += 1 }
                    let projectedX = p.position.x * 3.8 / (3.8-p.position.z)
                    left = min(left,projectedX)
                    right = max(right,projectedX)
                    lowY = min(lowY,p.position.y)
                    highY = max(highY,p.position.y)
                    if p.position.y > 0 { aboveEquator += 1 }
                    if length(position) > 0.87 {
                        nearWall += 1
                        if abs(dot(normalize(position),velocity)) < length(velocity)*0.35 {
                            wallGliding += 1
                        }
                    }
                }
            }
            try require(maxRadius <= 0.941, "Particle escaped the glass sphere")
            return ["visibleByCurrent": visible, "collisionAfterglows": collisionCount,
                    "maxRadius": maxRadius, "meanEnergy": energy/Float(max(1,visible.reduce(0,+))),
                    "nearWall": nearWall, "glidingAlongWall": wallGliding,
                    "aboveEquator": aboveEquator, "verticalExtent": [lowY,highY],
                    "horizontalExtent": [left,right],
                    "meanSpeed": totalSpeed/Float(max(1,visible.reduce(0,+))),
                    "motionRate": renderer.motionRate,
                    "spinAxes": angularMomentum.map { v -> [Float] in
                        let axis = v / max(0.0001, length(v))
                        return [axis.x,axis.y,axis.z]
                    },
                    "centralParticles": centralParticles, "discBlend": renderer.disc, "effectiveDisc": renderer.effectiveDisc,
                    "density": renderer.density, "particleSize": renderer.particleSize, "idleSpeed": renderer.idleSpeed, "trailLength": renderer.trailLength, "sparkleLevel": renderer.sparkleLevel,
                    "smoothedActivity": renderer.activity]
        }

        var report: [String: Any] = ["gpu": renderer.device.name, "particleCount": ParticleRenderer.particleCount,
                                     "fixedStepHz": 120, "pngColorSpace": "Display P3 SDR, highlights clipped for preview"]
        for (name, level) in [("idle",Float(0)),("gathering",Float(0.32)),("flow",Float(0.64)),("maximum",Float(1))] {
            renderer.targetActivity = level
            try advance(4.5)
            var state = try stats()
            if name == "idle" {
                try require((state["visibleByCurrent"] as! [Int]).dropFirst().allSatisfy { $0 == 0 }, "Extra idle currents are visible")
                try require((state["meanEnergy"] as! Float) < 0.001, "Idle particles gained color")
                let extent = state["verticalExtent"] as! [Float]
                try require(extent[1]-extent[0] > 1.2, "Idle cloud failed to occupy the globe vertically")
                try require((state["aboveEquator"] as! Int) > 300, "Idle cloud is still concentrated at the bottom")
                try require((state["meanSpeed"] as! Float) < 0.13, "Idle cloud lost its gentle pace")
            }
            if name == "maximum" {
                try require((state["visibleByCurrent"] as! [Int]).allSatisfy { $0 > 2000 }, "Maximum activity is missing a current")
                try require((state["collisionAfterglows"] as! Int) > 0, "Crossing currents produced no collisions")
                try require((state["nearWall"] as! Int) > 1000, "Active currents are not reaching the glass")
                try require((state["nearWall"] as! Int) < 16000, "Active currents have collapsed into a hollow shell")
                try require((state["glidingAlongWall"] as! Int) > 500, "Wall contacts are not preserving tangential flow")
                let extent = state["verticalExtent"] as! [Float]
                try require(extent[1]-extent[0] > 1.5, "Active flow is not filling the globe vertically")
            }
            if name == "gathering" {
                try require((state["aboveEquator"] as! Int) > 50, "Low activity failed to lift wisps into the upper globe")
            }
            for (appearance, value) in [("dark",Float(1)),("light",Float(0))] {
                renderer.targetDark = value
                try advance(1.2)
                let peak = try snapshot(renderer, url: output.appendingPathComponent("\(name)-\(appearance).png"), width: 1200, height: 1000)
                state["\(appearance)PeakLinearValue"] = peak.peak
                if name == "maximum" && appearance == "dark" {
                    try require(peak.peak > 1, "HDR render did not preserve values above SDR white")
                }
            }
            report[name] = state
            print("\(name): \(state)")
        }

        // Abrupt input must change the smoothed state by only a small amount.
        let before = renderer.activity
        renderer.targetActivity = 0
        try advance(0.025)
        try require(before-renderer.activity < 0.10, "Activity transition snapped")
        try advance(9)
        let settled = try stats()
        try require(renderer.activity < 0.001, "Activity failed to return to idle")
        try require((settled["visibleByCurrent"] as! [Int]).dropFirst().allSatisfy { $0 == 0 }, "Upper currents failed to retire")
        try require((settled["meanEnergy"] as! Float) < 0.001, "Settled idle cloud retained color")
        try require((settled["meanSpeed"] as! Float) < 0.13, "Settled idle cloud retained high speed")
        report["settledAfterMaximum"] = settled

        // A portrait-size drawable confirms aspect-preserving resize behavior.
        renderer.targetDark = 1
        try advance(1)
        _ = try snapshot(renderer, url: output.appendingPathComponent("idle-portrait.png"), width: 700, height: 1100)

        // Measure the actual flow at midpoint: two populated currents with
        // perpendicular angular-momentum axes and opposite circulation signs.
        var midpoint: [String: Any] = [:]
        renderer.targetActivity = 0.5
        for (shape, disc) in [("ring",Float(0)),("disc",Float(1))] {
            renderer.targetDisc = disc
            try advance(12)
            let state = try stats()
            let currents = state["visibleByCurrent"] as! [Int]
            let axes = state["spinAxes"] as! [[Float]]
            let primary = SIMD3<Float>(axes[0][0],axes[0][1],axes[0][2])
            let secondary = SIMD3<Float>(axes[1][0],axes[1][1],axes[1][2])
            try require(currents[0] > 5000 && currents[1] > 2300 && currents.dropFirst(2).allSatisfy { $0 == 0 },
                        "Midpoint must show exactly two populated currents in \(shape)")
            try require(abs(dot(primary,secondary)) < 0.25,
                        "Midpoint current planes are not approximately perpendicular in \(shape)")
            let localPrimary = renderer.ringOrientation.inverse.act(primary)
            let localSecondary = renderer.ringOrientation.inverse.act(secondary)
            try require(localPrimary.y < -0.5 && localSecondary.z > 0.5,
                        "Midpoint currents lost opposing circulation in \(shape)")
            midpoint[shape] = state
            for (appearance, dark) in [("dark",Float(1)),("light",Float(0))] {
                renderer.targetDark = dark
                try advance(1.2)
                _ = try snapshot(renderer, url: output.appendingPathComponent("midpoint-\(shape)-\(appearance).png"), width: 1200, height: 1000)
            }
        }
        report["midpoint"] = midpoint

        var comparisons: [String: Any] = [:]
        for (name, level) in [("idle",Float(0)),("active",Float(0.4)),("maximum",Float(1))] {
            renderer.targetActivity = level
            renderer.targetDisc = 0
            renderer.targetDark = 1
            try advance(12)
            let ringState = try stats()
            _ = try snapshot(renderer, url: output.appendingPathComponent("compare-\(name)-ring-dark.png"), width: 1200, height: 1000)
            renderer.targetDark = 0
            try advance(1.2)
            _ = try snapshot(renderer, url: output.appendingPathComponent("compare-\(name)-ring-light.png"), width: 1200, height: 1000)

            let positions = renderer.particles.contents().bindMemory(to: Particle.self, capacity: ParticleRenderer.particleCount)
            let before = (0..<ParticleRenderer.particleCount).map { positions[$0].position }
            renderer.targetDisc = 1
            try advance(0.025)
            try require(renderer.disc < 0.06, "Shape control snapped to the new geometry")
            let after = renderer.particles.contents().bindMemory(to: Particle.self, capacity: ParticleRenderer.particleCount)
            for id in 0..<ParticleRenderer.particleCount {
                let delta = after[id].position-before[id]
                try require(length(SIMD3(delta.x,delta.y,delta.z)) < 0.10, "Shape change teleported a particle")
            }
            try advance(12)
            let discState = try stats()
            if level <= 0.4 {
                try require(renderer.effectiveDisc > 0.999, "Low-effort disc lost its fullness")
                // Ring's organic return plumes can temporarily cross the
                // center too. Judge Disc's retained interior population rather
                // than comparing cloud counts at unrelated flow phases.
                let visible = (discState["visibleByCurrent"] as! [Int]).reduce(0,+)
                try require((discState["centralParticles"] as! Int) > visible/10,
                            "Disc mode did not retain a filled center at \(name)")
            } else {
                try require(renderer.effectiveDisc < 0.001, "Maximum effort retained the disc guide")
                try require((discState["nearWall"] as! Int) > 1000 && (discState["centralParticles"] as! Int) < 500,
                            "High-effort disc failed to release particles toward the glass")
            }
            try require((discState["visibleByCurrent"] as! [Int]) == (ringState["visibleByCurrent"] as! [Int]),
                        "Shape change altered particle admission")
            try require(abs((discState["meanEnergy"] as! Float)-(ringState["meanEnergy"] as! Float)) < 0.03,
                        "Shape change altered particle energy")
            _ = try snapshot(renderer, url: output.appendingPathComponent("compare-\(name)-disc-light.png"), width: 1200, height: 1000)
            renderer.targetDark = 1
            try advance(1.2)
            _ = try snapshot(renderer, url: output.appendingPathComponent("compare-\(name)-disc-dark.png"), width: 1200, height: 1000)
            renderer.targetDisc = 0
            try advance(12)
            let returned = try stats()
            try require(renderer.disc < 0.001, "Shape did not return to Ring")
            try require(renderer.effectiveDisc < 0.001, "Returning to Ring retained disc guidance")
            comparisons[name] = ["ring": ringState,"disc": discState,"returnedToRing": returned]
            print("Shape \(name): center particles Ring=\(ringState["centralParticles"]!), Disc=\(discState["centralParticles"]!), restored Ring=\(returned["centralParticles"]!)")
        }
        report["shapeComparison"] = comparisons

        // Descending energy restores the center without toggling away from Disc.
        renderer.targetDisc = 1
        for level: Float in [0.85, 0.70, 0.55, 0.40] {
            renderer.targetActivity = level
            try advance(12)
            let state = try stats()
            report["discCooling-\(level)"] = state
            _ = try snapshot(renderer, url: output.appendingPathComponent("disc-cooling-\(level).png"), width: 1000, height: 1000)
        }
        let cooled = try stats()
        try require(renderer.effectiveDisc > 0.999 && (cooled["centralParticles"] as! Int) > 700,
                    "Cooling to 40% did not restore the full disc")

        renderer.targetActivity = 0
        renderer.targetDark = 0
        try advance(12)
        var densityCounts: [Int] = []
        for density: Float in [ParticleRenderer.minimumDensity, 1, 2] {
            let oldDensity = renderer.density
            renderer.targetDensity = density
            try advance(0.025)
            try require(abs(renderer.density-oldDensity) < 0.10, "Density change snapped")
            try advance(4)
            let state = try stats()
            densityCounts.append((state["visibleByCurrent"] as! [Int]).reduce(0,+))
            try require((state["meanEnergy"] as! Float) < 0.001 && (state["meanSpeed"] as! Float) < 0.13,
                        "Density changed the idle energy or pace")
            report["density-\(density)"] = state
            _ = try snapshot(renderer, url: output.appendingPathComponent("density-\(density).png"), width: 1000, height: 1000)
        }
        try require(densityCounts[0] < densityCounts[1]/2 && densityCounts[2] > densityCounts[1]*17/10,
                    "Density control did not change actual visible particle population")
        renderer.targetDensity = 1
        renderer.targetSize = 0.5
        try advance(4)
        let small = try snapshot(renderer, url: output.appendingPathComponent("size-small.png"), width: 1000, height: 1000)
        let sizeCount = (try stats()["visibleByCurrent"] as! [Int])
        renderer.targetSize = 20
        try advance(0.025)
        try require(renderer.particleSize < 2.5, "Particle size snapped")
        try advance(4)
        let large = try snapshot(renderer, url: output.appendingPathComponent("size-large.png"), width: 1000, height: 1000)
        try require(large.coloredPixels > small.coloredPixels*3, "Size control did not enlarge rendered particles")
        try require((try stats()["visibleByCurrent"] as! [Int]) == sizeCount, "Size changed particle admission")
        report["sizeCoverage"] = ["small": small.coloredPixels, "large": large.coloredPixels]

        // A disc opened directly at rest must touch the glass throughout slow
        // circulation, while retaining an interior population and idle speed.
        renderer.targetActivity = 0
        renderer.targetDensity = 1
        renderer.targetSize = 1
        try advance(5)
        try renderer.reset()
        var restingSamples: [[String: Any]] = []
        for sample in 0..<7 {
            let state = try stats()
            let count = (state["visibleByCurrent"] as! [Int]).reduce(0,+)
            let extent = state["horizontalExtent"] as! [Float]
            try require((state["nearWall"] as! Int) > count/5 &&
                        (state["glidingAlongWall"] as! Int) > count/6,
                        "Resting disc lost sustained glass contact at sample \(sample)")
            try require((state["centralParticles"] as! Int) > count/12,
                        "Resting disc collapsed into a hollow ring")
            try require(extent[0] < -0.85 && extent[1] > 0.85,
                        "Resting disc no longer reaches both visible sides of the glass")
            try require((state["meanSpeed"] as! Float) < 0.13 &&
                        (state["meanEnergy"] as! Float) < 0.001,
                        "Glass contact changed the idle pace or energy")
            restingSamples.append(state)
            if sample == 0 || sample == 6 {
                _ = try snapshot(renderer, url: output.appendingPathComponent("resting-disc-\(sample).png"), width: 1000, height: 1000)
            }
            try advance(6)
        }
        report["restingGlassContact"] = restingSamples

        // Start identical prewarmed clouds with different clock floors and
        // measure physical displacement over the same real-time interval.
        func idleTravel(speed: Float) throws -> Float {
            let probe = try ParticleRenderer(initialDisc: 1, initialIdleSpeed: speed, initialDensity: 1, initialSize: 1, initialTrailLength: 0.25)
            let data = probe.particles.contents().bindMemory(to: Particle.self, capacity: ParticleRenderer.particleCount)
            let ids = (0..<ParticleRenderer.particleCount).filter { data[$0].position.w > 0.2 }
            let before = ids.map { data[$0].position }
            let command = probe.queue.makeCommandBuffer()!
            for _ in 0..<24 { probe.step(command: command) }
            command.commit()
            command.waitUntilCompleted()
            if let error = command.error { throw error }
            let after = probe.particles.contents().bindMemory(to: Particle.self, capacity: ParticleRenderer.particleCount)
            var total: Float = 0
            for (index,id) in ids.enumerated() {
                let delta = after[id].position-before[index]
                total += length(SIMD3(delta.x,delta.y,delta.z))
                try require(after[id].appearance.y < 0.001, "Idle speed injected activity color")
            }
            return total/Float(ids.count)
        }
        let slowTravel = try idleTravel(speed: 0.5)
        let originalTravel = try idleTravel(speed: 1)
        let defaultTravel = try idleTravel(speed: ParticleRenderer.defaultIdleSpeed)
        let fastTravel = try idleTravel(speed: ParticleRenderer.maximumIdleSpeed)
        try require(fastTravel > slowTravel*4, "Idle speed control did not increase actual movement")
        try require(defaultTravel > originalTravel*3.2 && defaultTravel < originalTravel*4.8,
                    "New idle default did not provide the intended 4× speed increase")
        let oldFloor = renderer.idleSpeed
        renderer.targetIdleSpeed = ParticleRenderer.maximumIdleSpeed
        try advance(0.025)
        try require(renderer.idleSpeed-oldFloor < 0.2, "Idle speed slider snapped")
        try advance(4)
        let fastIdle = try stats()
        try require((fastIdle["visibleByCurrent"] as! [Int]).dropFirst().allSatisfy { $0 == 0 } &&
                    (fastIdle["meanEnergy"] as! Float) < 0.001, "Idle speed admitted activity currents or colors")
        report["idleSpeedControl"] = ["slowTravel": slowTravel,"originalTravel": originalTravel,
                                      "defaultTravel": defaultTravel,"fastTravel": fastTravel,"fastIdle": fastIdle]
        renderer.targetIdleSpeed = 1.35

        // Exercise the crowded collision path at the largest supported settings.
        renderer.targetActivity = 1
        renderer.targetDensity = 2
        renderer.targetSize = 20
        try advance(10)
        report["maximumDensity"] = try stats()
        _ = try snapshot(renderer, url: output.appendingPathComponent("maximum-density-size.png"), width: 700, height: 900)

        renderer.targetActivity = 0.5
        renderer.targetDensity = 0.25
        renderer.targetSize = 1
        try advance(10)
        let history = renderer.history.contents().bindMemory(to: SIMD4<Float>.self,
            capacity: ParticleRenderer.historySamples*ParticleRenderer.particleCount)
        let particles = renderer.particles.contents().bindMemory(to: Particle.self, capacity: ParticleRenderer.particleCount)
        for sample in 0..<ParticleRenderer.historySamples {
            for id in stride(from: 0, to: ParticleRenderer.particleCount, by: 37) {
                let p = history[sample*ParticleRenderer.particleCount+id]
                try require((0..<4).allSatisfy { p[$0].isFinite } && length(SIMD3(p.x,p.y,p.z)) <= 0.941,
                            "Trail history contains an invalid or escaped position")
            }
        }
        for id in stride(from: 0, to: ParticleRenderer.particleCount, by: 37) {
            let newest = history[Int(renderer.historyCursor)*ParticleRenderer.particleCount+id]
            try require(length(newest-particles[id].position) < 0.00001, "Trail head detached from its particle")
        }
        var trailChecks: [String: Any] = [:]
        for (appearance, dark) in [("dark",Float(1)),("light",Float(0))] {
            renderer.targetDark = dark
            try advance(1.5)
            // Freeze the simulation while comparing path coverage and the exact
            // no-trail image, so natural flow drift cannot affect the result.
            let off = try snapshot(renderer, url: output.appendingPathComponent("trails-\(appearance)-off.png"), width: 1000, height: 1000, trailLength: 0)
            let short = try snapshot(renderer, url: output.appendingPathComponent("trails-\(appearance)-short.png"), width: 1000, height: 1000, trailLength: 0.25)
            let long = try snapshot(renderer, url: output.appendingPathComponent("trails-\(appearance)-long.png"), width: 1000, height: 1000, trailLength: 1)
            let restored = try snapshot(renderer, url: output.appendingPathComponent("trails-\(appearance)-restored.png"), width: 1000, height: 1000, trailLength: 0)
            let shortCoverage = short.changedPixels(from: off)
            let longCoverage = long.changedPixels(from: off)
            try require(longCoverage > shortCoverage && shortCoverage > 100,
                        "Longer trails failed to increase visible path coverage in \(appearance)")
            try require(off.pixelHash == restored.pixelHash, "Zero trail length did not restore the original particle render")
            trailChecks[appearance] = ["shortTrailPixels": shortCoverage,"longTrailPixels": longCoverage]
        }
        let oldTrail = renderer.trailLength
        renderer.targetTrailLength = 1
        try advance(0.025)
        try require(renderer.trailLength-oldTrail < 0.1, "Trail slider snapped")
        try advance(1)
        renderer.targetTrailLength = 0
        try advance(4)
        try require(renderer.trailLength < 0.0005, "Trails failed to turn fully off")
        report["trails"] = trailChecks

        // Exercise the user-visible count budget at full effort, including the
        // extended low endpoint. Counts settle to exact integers at full effort, with smooth admission between budgets.
        renderer.targetActivity = 1
        renderer.targetDensity = ParticleRenderer.minimumDensity
        try advance(10)
        let minimumBudget = try stats()
        let minimumCount = (minimumBudget["visibleByCurrent"] as! [Int]).reduce(0,+)
        try require(minimumCount == 10,
                    "The 10-particle limit did not produce exactly 10 particles at full effort")
        renderer.targetSize = 20
        try advance(5)
        try require(renderer.particleSize > 19.99, "Size failed to reach the 20× endpoint")
        for (appearance, dark) in [("dark",Float(1)),("light",Float(0))] {
            renderer.targetDark = dark
            try advance(1.5)
            _ = try snapshot(renderer, url: output.appendingPathComponent("ten-large-\(appearance).png"), width: 1000, height: 1000)
        }
        var sparseCounts: [Int] = []
        for count: Float in [50, 100, 1000] {
            renderer.targetDensity = count/ParticleRenderer.baseParticleCount
            try advance(5)
            let visible = (try stats()["visibleByCurrent"] as! [Int]).reduce(0,+)
            try require(visible == Int(count), "Sparse particle budget did not match its count")
            sparseCounts.append(visible)
        }
        report["sparseCountEndpoints"] = sparseCounts
        report["minimumParticleBudget"] = minimumBudget

        renderer.targetDensity = 0.25
        renderer.targetSize = 1
        renderer.targetTrailLength = 0.25
        var sparkleLevels: [Float] = []
        for effort: Float in [0.10, 0.15, 0.20, 0.50, 0.80, 1] {
            renderer.targetActivity = effort
            try advance(12)
            sparkleLevels.append(renderer.sparkleLevel)
        }
        try require(sparkleLevels[0] < 0.001 && sparkleLevels[1] < 0.001 &&
                    sparkleLevels[2] > 0.01 && sparkleLevels[2] < 0.2 &&
                    sparkleLevels[3] > sparkleLevels[2] && sparkleLevels[3] < 1 &&
                    sparkleLevels[4] > 0.999 && abs(sparkleLevels[5]-sparkleLevels[4]) < 0.001,
                    "Effort sparkle did not start near 15% and plateau at 80%")
        var sparkleChecks: [String: Any] = ["levelsAt10_15_20_50_80_100": sparkleLevels]
        for (appearance, dark) in [("dark",Float(1)),("light",Float(0))] {
            renderer.targetDark = dark
            try advance(1.5)
            let quiet = try snapshot(renderer, url: output.appendingPathComponent("sparkle-\(appearance)-quiet.png"), width: 1000, height: 1000, sparkleLevel: 0)
            let building = try snapshot(renderer, url: output.appendingPathComponent("sparkle-\(appearance)-building.png"), width: 1000, height: 1000, sparkleLevel: sparkleLevels[3])
            let full = try snapshot(renderer, url: output.appendingPathComponent("sparkle-\(appearance)-full.png"), width: 1000, height: 1000, sparkleLevel: 1)
            let buildingPixels = building.changedPixels(from: quiet)
            let fullPixels = full.changedPixels(from: quiet)
            try require(fullPixels > buildingPixels && buildingPixels > 100,
                        "Sparkle failed to build visually in \(appearance)")
            sparkleChecks[appearance] = ["buildingPixels": buildingPixels, "fullPixels": fullPixels]
        }
        report["effortSparkle"] = sparkleChecks

        // Verify actual launch defaults, including confinement at the higher idle floor.
        renderer = try ParticleRenderer()
        try require(abs(renderer.density*ParticleRenderer.baseParticleCount-10_000) < 0.01 &&
                    renderer.particleSize == 1.75 && renderer.idleSpeed == 4 &&
                    abs(renderer.trailLength-0.30) < 0.001 && renderer.speakingTrailLength == 0.5 &&
                    renderer.disc == 1 && renderer.targetDisc == 1,
                    "Launch defaults do not match the requested controls")
        report["launchDefaultsIdle"] = try stats()
        for (appearance, dark) in [("dark",Float(1)),("light",Float(0))] {
            renderer.targetDark = dark
            try advance(2)
            _ = try snapshot(renderer, url: output.appendingPathComponent("defaults-idle-\(appearance).png"), width: 1000, height: 1000)
        }
        renderer.targetActivity = 1
        try advance(10)
        let defaultActive = try stats()
        try require((defaultActive["visibleByCurrent"] as! [Int]).reduce(0,+) == 10_000,
                    "Default full-effort particle count is not 10,000")
        report["launchDefaultsActive"] = defaultActive

        var turning: [[String: Any]] = []
        for effort: Float in [0.5,1] {
            renderer.targetActivity = effort
            try advance(12)
            let before = try stats()
            let startAxes = before["spinAxes"] as! [[Float]]
            _ = try snapshot(renderer, url: output.appendingPathComponent("rotating-\(Int(effort*100))-start.png"), width: 1000, height: 1000)
            try advance(8)
            let after = try stats()
            let endAxes = after["spinAxes"] as! [[Float]]
            var angles: [Float] = []
            for index in 0..<2 {
                let first = SIMD3<Float>(startAxes[index][0],startAxes[index][1],startAxes[index][2])
                let last = SIMD3<Float>(endAxes[index][0],endAxes[index][1],endAxes[index][2])
                angles.append(acos(min(1,max(-1,dot(first,last))))*180/Float.pi)
            }
            try require(angles.allSatisfy { $0 > 10 }, "Current planes remained stationary at \(effort) effort")
            turning.append(["effort": effort,"degreesOverEightSeconds": angles,"before": before,"after": after])
            _ = try snapshot(renderer, url: output.appendingPathComponent("rotating-\(Int(effort*100))-end.png"), width: 1000, height: 1000)
        }
        report["rotatingCurrents"] = turning
        renderer.targetActivity = 0
        try advance(14)
        try require(abs(renderer.ringOrientation.real) > 0.999,
                    "Current frame did not settle back to its idle orientation")
        report["rotationSettledIdle"] = try stats()

        // Measure real simulation response in both directions, including the
        // extra GPU smoothing for color and current admission.
        var effortTransitions: [[String: Any]] = []
        for (name, start, end, deadline) in [
            ("small rise",Float(0),Float(0.05),Double(1.6)),
            ("medium rise",Float(0.30),Float(0.55),Double(1.0)),
            ("large rise",Float(0),Float(1),Double(0.55)),
            ("medium fall",Float(0.65),Float(0.35),Double(1.0)),
            ("large fall",Float(1),Float(0),Double(0.60))
        ] {
            renderer.targetActivity = start
            try advance(14)
            let initial = renderer.activity
            renderer.targetActivity = end
            var timeTo90: Double = 0
            var previous = renderer.activity
            for step in 1...240 {
                let command = renderer.queue.makeCommandBuffer()!
                renderer.step(command: command)
                command.commit()
                command.waitUntilCompleted()
                if let error = command.error { throw error }
                try require(abs(renderer.activity-previous) < 0.065,
                            "Effort jumped abruptly during \(name)")
                try require(renderer.activity >= min(initial,end)-0.00001 &&
                            renderer.activity <= max(initial,end)+0.00001,
                            "Effort overshot during \(name)")
                previous = renderer.activity
                if timeTo90 == 0 && abs(end-renderer.activity) <= abs(end-initial)*0.1 {
                    timeTo90 = Double(step)*Double(ParticleRenderer.fixedStep)
                }
            }
            try require(timeTo90 > 0 && timeTo90 <= deadline,
                        "Effort response is too slow for \(name): \(timeTo90)s")
            if name == "small rise" {
                try require(timeTo90 > 1.3, "Small effort changes lost their gentle easing")
            }
            let state = try stats()
            if name == "large rise" {
                try require((state["meanEnergy"] as! Float) > 0.95 &&
                            (state["visibleByCurrent"] as! [Int]).reduce(0,+) == 10_000,
                            "Color or admission lagged behind the large effort rise")
            } else if name == "large fall" {
                try require((state["meanEnergy"] as! Float) < 0.02 &&
                            (state["visibleByCurrent"] as! [Int]).dropFirst().allSatisfy { $0 == 0 },
                            "Color or extra currents lingered after the large effort fall")
            }
            effortTransitions.append(["transition": name,"timeTo90Percent": timeTo90,"stateAtTwoSeconds": state])
        }
        report["adaptiveEffortTransitions"] = effortTransitions

        var speechChecks: [String: Any] = [:]
        do {
            let envelope = try SpeechEnvelope(url: speechAudioURL)
            try require(envelope.duration > 1 && (envelope.levels.max() ?? 0) > 0.3 &&
                        envelope.levels.contains { $0 < 0.05 }, "Speech envelope missed syllables or pauses")
            renderer = try ParticleRenderer()
            for step in 0..<Int(envelope.duration/Double(ParticleRenderer.fixedStep)) {
                renderer.targetSpeech = envelope.sample(at: Double(step)*Double(ParticleRenderer.fixedStep))
                let command = renderer.queue.makeCommandBuffer()!
                renderer.step(command: command)
                command.commit(); command.waitUntilCompleted()
                if let error = command.error { throw error }
                if step == 179 || step == 299 || step == 419 || step == 659 || step == 899 {
                    _ = try snapshot(renderer, url: output.appendingPathComponent("speech-history-\(step+1).png"), width: 1200, height: 1000)
                }
            }
            let voiced = try stats()
            try require((voiced["meanEnergy"] as! Float) < 0.001 &&
                        (voiced["visibleByCurrent"] as! [Int]).dropFirst().allSatisfy { $0 == 0 },
                        "Speech changed effort colors or admitted extra currents")
            speechChecks["audioDuration"] = envelope.duration
            speechChecks["envelopePeak"] = envelope.levels.max() ?? 0
            speechChecks["spokenIdle"] = voiced
        }
        for (appearance, dark) in [("dark",Float(1)),("light",Float(0))] {
            renderer = try ParticleRenderer(initialDark: dark)
            let quiet = try snapshot(renderer, url: output.appendingPathComponent("speech-\(appearance)-quiet.png"), width: 1000, height: 1000)
            renderer.targetSpeech = SIMD2(0.85,0.5)
            try advance(0.5)
            let speaking = try snapshot(renderer, url: output.appendingPathComponent("speech-\(appearance)-speaking.png"), width: 1000, height: 1000)
            try require(speaking.changedPixels(from: quiet) > 2000,
                        "Speech did not visibly animate the \(appearance) globe")
            speechChecks[appearance] = ["changedPixels": speaking.changedPixels(from: quiet),"state": try stats()]
            renderer.targetSpeechExpression = 0
            try advance(4)
            try require(renderer.uniforms(size: CGSize(width: 1000,height: 1000)).speech.x < 0.001,
                        "Zero speech expression did not disable the animation")
            renderer.targetSpeechExpression = 2
            renderer.targetActivity = 1
            try advance(6)
            speechChecks["maximum-\(appearance)"] = try stats()
            renderer.targetSpeech = .zero
            try advance(2)
            try require(renderer.speechLevel < 0.001 && renderer.speechAccent < 0.001,
                        "Speech animation did not release into silence")
        }
        renderer = try ParticleRenderer()
        renderer.targetSpeech = SIMD2(1,0.6)
        try advance(0.08)
        renderer.targetSpeech = .zero
        try advance(0.30)
        func pulseAge() -> Float {
            var weighted: Float = 0, total: Float = 0
            for age in 0..<ParticleRenderer.speechHistorySamples {
                let index = (renderer.speechHistoryCursor+ParticleRenderer.speechHistorySamples-age)%ParticleRenderer.speechHistorySamples
                let level = renderer.speechHistory[index].x
                weighted += Float(age)*level; total += level
            }
            return weighted/max(0.0001,total)*ParticleRenderer.fixedStep
        }
        let earlyAge = pulseAge()
        try advance(0.40)
        let laterAge = pulseAge()
        try require(laterAge > earlyAge+0.38 && laterAge < earlyAge+0.42,
                    "Speech history did not carry a syllable from left to right at playback speed")
        try advance(5)
        try require(renderer.speechPresence < 0.01 && renderer.speechHistory.allSatisfy { $0 == .zero },
                    "Waveform currents did not release after the phrase tail passed")
        speechChecks["pulseTravelSeconds"] = laterAge-earlyAge
        speechChecks["settledPresence"] = renderer.speechPresence
        // Speaking trails can override an Off baseline, with smooth control changes.
        renderer = try ParticleRenderer(initialTrailLength: 0)
        renderer.targetSpeakingTrailLength = 1
        renderer.targetSpeech = SIMD2(0.85,0.5)
        try advance(2)
        try require(renderer.effectiveTrailLength > 0.995 && renderer.trailLength == 0,
                    "Speech did not temporarily raise trails to 100%")
        for (appearance, dark) in [("dark",Float(1)),("light",Float(0))] {
            renderer.targetDark = dark
            try advance(2)
            let full = try snapshot(renderer, url: output.appendingPathComponent("speech-full-trails-\(appearance).png"), width: 1000, height: 1000)
            let off = try snapshot(renderer, url: output.appendingPathComponent("speech-no-trails-\(appearance).png"), width: 1000, height: 1000, trailLength: 0)
            try require(full.changedPixels(from: off) > 1000,
                        "Automatic full speech trails were not visible in \(appearance)")
        }
        renderer.targetTrailLength = 0.3
        renderer.targetSpeechExpression = 0.5
        renderer.targetSpeakingTrailLength = 0
        let previousSpeakingLength = renderer.speakingTrailLength
        try advance(0.025)
        try require(previousSpeakingLength-renderer.speakingTrailLength < 0.1,
                    "Speaking trail slider jumped abruptly")
        try advance(3)
        try require(renderer.effectiveTrailLength < 0.001 && renderer.trailLength > 0.299,
                    "Speaking trails Off retained the normal trails at reduced expression")
        for (appearance, dark) in [("dark",Float(1)),("light",Float(0))] {
            renderer.targetDark = dark
            try advance(2)
            let automaticOff = try snapshot(renderer, url: output.appendingPathComponent("speaking-trails-off-\(appearance).png"), width: 1000, height: 1000)
            let forcedOff = try snapshot(renderer, url: output.appendingPathComponent("speaking-trails-off-reference-\(appearance).png"), width: 1000, height: 1000, trailLength: 0)
            try require(automaticOff.pixelHash == forcedOff.pixelHash,
                        "Speaking trails Off did not remove all trails in \(appearance)")
        }
        renderer.targetSpeech = .zero
        try advance(8)
        try require(abs(renderer.effectiveTrailLength-0.3) < 0.001,
                    "Speech did not restore the chosen normal trail length after silence")
        speechChecks["adjustableSpeakingTrails"] = true
        // A smaller waveform must not restore the competing return current.
        renderer = try ParticleRenderer()
        renderer.targetSpeech = SIMD2(0.85,0.5)
        renderer.targetSpeechExpression = 0.5
        try advance(5)
        let halfExpression = renderer.uniforms(size: CGSize(width: 1000,height: 1000))
        try require(halfExpression.speech.w < 0.51 && halfExpression.speechLight.w > 0.999,
                    "Return hiding weakened with the speech expression slider")
        for (appearance, dark) in [("dark",Float(1)),("light",Float(0))] {
            renderer.targetDark = dark
            try advance(2)
            _ = try snapshot(renderer, url: output.appendingPathComponent("hidden-return-half-expression-\(appearance).png"), width: 1000, height: 1000, flashFactor: 8)
        }
        renderer.targetSpeech = .zero
        try advance(8)
        try require(renderer.uniforms(size: CGSize(width: 1000,height: 1000)).speechLight.w < 0.001,
                    "Return hiding persisted after the speech history ended")
        speechChecks["independentReturnHiding"] = true
        var flashChecks: [String: Any] = [:]
        for (appearance, dark) in [("dark",Float(1)),("light",Float(0))] {
            renderer = try ParticleRenderer(initialDark: dark)
            renderer.targetSpeech = SIMD2(0.85,0.7)
            try advance(0.025)
            try require(renderer.speechFlashLevel > 0.1 && renderer.speechFlashLevel < 0.4,
                        "Speech pulse lost its rounded attack")
            try advance(2)
            let standard = try snapshot(renderer, url: output.appendingPathComponent("flash-\(appearance)-100.png"), width: 1000, height: 1000, flashFactor: 1)
            let overdrive = try snapshot(renderer, url: output.appendingPathComponent("flash-\(appearance)-800.png"), width: 1000, height: 1000, flashFactor: 8)
            try require(overdrive.peak > 1 && overdrive.peak > standard.peak+0.05 &&
                        overdrive.changedPixels(from: standard) > 500,
                        "Speech flash did not increase HDR output in \(appearance)")
            flashChecks[appearance] = ["standardPeak": standard.peak,"overdrivePeak": overdrive.peak]
            renderer.targetSpeech = .zero
            try advance(0.08)
            try require(renderer.speechFlashLevel > 0.1 && renderer.speechFlashLevel < 0.25 &&
                        renderer.speechFlashAccent > 0.08 && renderer.speechFlashAccent < 0.2 &&
                        renderer.speechLevel > 0.3,
                        "Speech pulse blinked away or retained too much glow at 80 ms")
            try advance(0.10)
            try require(renderer.speechFlashLevel < 0.05 && renderer.speechFlashAccent < 0.04,
                        "Speech pulse did not settle promptly after its rounded release")
            let pause = try snapshot(renderer, url: output.appendingPathComponent("flash-\(appearance)-pause.png"), width: 1000, height: 1000, flashFactor: 8)
            try require(renderer.speechPresence > 0.9 && pause.peak < overdrive.peak-0.2,
                        "Live flash did not subside while waveform history remained in \(appearance)")
            try advance(8)
            let quietLow = try snapshot(renderer, url: output.appendingPathComponent("flash-\(appearance)-silent-low.png"), width: 1000, height: 1000, flashFactor: 0)
            let quietHigh = try snapshot(renderer, url: output.appendingPathComponent("flash-\(appearance)-silent-high.png"), width: 1000, height: 1000, flashFactor: 8)
            try require(quietLow.pixelHash == quietHigh.pixelHash,
                        "Flash factor changed the globe during silence")
        }
        let priorFlash = renderer.flashFactor
        renderer.targetFlashFactor = 8
        try advance(0.025)
        try require(renderer.flashFactor-priorFlash < 0.5, "Flash factor slider snapped")
        speechChecks["flashFactor"] = flashChecks
        // Live mode must move individual particles vertically, not circulate
        // them through a newly drawn waveform. Exercise actual production forces.
        renderer = try ParticleRenderer()
        renderer.targetSpeech = SIMD2(0.8,0.4)
        try advance(3)
        renderer.targetLiveWaveform = 1
        try advance(0.025)
        try require(renderer.liveWaveform > 0 && renderer.liveWaveform < 0.15,
                    "Live waveform toggle snapped instead of blending")
        var liveChecks: [[String: Any]] = []
        for effort: Float in [0,0.5,1] {
            renderer.targetActivity = effort
            renderer.targetSpeech = SIMD2(0.8,0.4)
            try advance(6)
            let pointer = renderer.particles.contents().bindMemory(to: Particle.self, capacity: ParticleRenderer.particleCount)
            let start = Array(UnsafeBufferPointer(start: pointer, count: ParticleRenderer.particleCount))
            var vertical: Float = 0, horizontal: Float = 0, depth: Float = 0
            var count = 0
            for level: Float in [0.12,0.9,0.25,0.7] {
                renderer.targetSpeech = SIMD2(level,0.3)
                try advance(0.12)
                let current = renderer.particles.contents().bindMemory(to: Particle.self, capacity: ParticleRenderer.particleCount)
                for id in 0..<ParticleRenderer.particleCount where start[id].position.w > 0.2 {
                    horizontal += abs(current[id].position.x-start[id].position.x)
                    depth += abs(current[id].position.z-start[id].position.z)
                    vertical += abs(current[id].position.y-start[id].position.y)
                    count += 1
                }
            }
            horizontal /= Float(count); depth /= Float(count); vertical /= Float(count)
            try require(horizontal < 0.003 && depth < 0.003 && vertical > 0.015,
                        "Live waveform still circulated or failed to move vertically at effort \(effort): \(horizontal), \(depth), \(vertical)")
            liveChecks.append(["effort": effort,"meanHorizontalChange": horizontal,
                               "meanDepthChange": depth,"meanVerticalChange": vertical,"state": try stats()])
        }
        renderer.targetActivity = 0
        renderer.targetSpeechExpression = 0.5
        try advance(6)
        for (appearance, dark) in [("dark",Float(1)),("light",Float(0))] {
            renderer.targetDark = dark
            try advance(2)
            for level: Float in [0.1,0.8,0.2,0.65] {
                renderer.targetSpeech = SIMD2(level,0.3)
                try advance(0.06)
            }
            _ = try snapshot(renderer, url: output.appendingPathComponent("live-waveform-\(appearance).png"), width: 1000, height: 1000)
        }
        // The newest snippet clears quickly, while speech presence still holds
        // the particles at their stations between words.
        renderer.targetSpeech = .zero
        try advance(0.7)
        let liveQuiet = renderer.particles.contents().bindMemory(to: Particle.self, capacity: ParticleRenderer.particleCount)
        var meanQuietHeight: Float = 0
        var quietCount = 0
        for id in 0..<ParticleRenderer.particleCount where liveQuiet[id].position.w > 0.2 {
            meanQuietHeight += abs(liveQuiet[id].position.y); quietCount += 1
        }
        meanQuietHeight /= Float(quietCount)
        try require(meanQuietHeight < 0.035 && renderer.speechPresence > 0.9,
                    "Live waveform retained stale amplitude instead of the current snippet")
        renderer.targetLiveWaveform = 0
        renderer.targetSpeechExpression = 1
        renderer.targetSpeech = SIMD2(0.8,0.4)
        try advance(5)
        let flowing = renderer.particles.contents().bindMemory(to: Particle.self, capacity: ParticleRenderer.particleCount)
        var horizontalSpeed: Float = 0
        for id in 0..<ParticleRenderer.particleCount where flowing[id].position.w > 0.2 {
            horizontalSpeed += abs(flowing[id].velocity.x*renderer.motionRate)
        }
        try require(renderer.liveWaveform < 0.001 && horizontalSpeed/Float(quietCount) > 0.05,
                    "Turning Live waveform off failed to restore circulation")
        speechChecks["liveWaveform"] = liveChecks
        speechChecks["liveQuietHeightAfterSnippet"] = meanQuietHeight
        do {
            let envelope = try SpeechEnvelope(url: speechAudioURL)
            // A loud onset may follow silence and contain very little history.
            // Inspect a populated phrase window rather than the first loud bin.
            let detail = stride(from: SpeechEnvelope.waveformDuration,through: envelope.duration,by: 0.24)
                .map { envelope.waveform(at: $0) }
                .max { Set($0.map { $0.x }).count < Set($1.map { $0.x }).count }!
            try require(detail.count == 512 && detail.allSatisfy { $0.x.isFinite && $0.y.isFinite } &&
                        detail.contains { $0.x < -0.1 } && detail.contains { $0.y > 0.1 } &&
                        Set(detail.map { $0.x }).count > 100,
                        "Live waveform did not preserve detailed signed PCM peaks: \(detail.count) pairs, \(Set(detail.map { $0.x }).count) distinct lows")
            try require(envelope.waveform(at: envelope.duration+SpeechEnvelope.waveformDuration).allSatisfy { $0 == .zero },
                        "PCM waveform retained audio past the end of its snippet")
            let meter = SpeechMeter()
            meter.store(SIMD2(0.8,0.4),waveform: detail)
            try require(meter.snapshot().waveform == detail, "Speech meter lost the PCM snapshot")
            meter.store(.zero)
            try require(meter.snapshot().waveform.count == 512 && meter.snapshot().waveform.allSatisfy { $0 == .zero },
                        "Stopping speech did not clear its PCM waveform")
            renderer = try ParticleRenderer()
            renderer.targetLiveWaveform = 1
            renderer.targetSpeech = SIMD2(0.8,0.4)
            renderer.targetSpeakingTrailLength = 1
            try advance(3)
            for step in 0..<Int(min(6,envelope.duration)/Double(ParticleRenderer.fixedStep)) {
                // Match the real 60 Hz audio mailbox while physics runs at 120 Hz.
                if step%2 == 0 {
                    let time = Double(step)*Double(ParticleRenderer.fixedStep)
                    renderer.targetSpeech = envelope.sample(at: time)
                    renderer.targetSpeechWaveform = envelope.waveform(at: time)
                }
                let command = renderer.queue.makeCommandBuffer()!
                renderer.step(command: command)
                command.commit(); command.waitUntilCompleted()
                if let error = command.error { throw error }
                if step == 179 || step == 299 || step == 419 {
                    _ = try snapshot(renderer, url: output.appendingPathComponent("live-pcm-\(step+1).png"), width: 1200, height: 1000)
                }
            }
            renderer.targetSpeech = SIMD2(0.8,0.4)
            renderer.targetSpeechWaveform = detail
            for (appearance, dark) in [("dark",Float(1)),("light",Float(0))] {
                renderer.targetDark = dark
                try advance(2)
                try require(renderer.effectiveTrailLength < 0.0005,
                            "Live mode retained trails despite forcing them Off")
                let automatic = try snapshot(renderer, url: output.appendingPathComponent("live-pcm-\(appearance).png"), width: 1000, height: 1000)
                let off = try snapshot(renderer, url: output.appendingPathComponent("live-pcm-\(appearance)-off-reference.png"), width: 1000, height: 1000, trailLength: 0)
                try require(automatic.pixelHash == off.pixelHash,
                            "Live mode did not render exactly zero trails in \(appearance)")
            }
            speechChecks["livePCM"] = ["samplePairs": detail.count,"snippetSeconds": SpeechEnvelope.waveformDuration,
                                      "distinctNegativePeaks": Set(detail.map { $0.x }).count,"state": try stats()]
        }
        // A real playback completion must release immediately, while a quiet
        // interval within the same speech session retains the waveform.
        var completionChecks: [[String: Any]] = []
        for live: Float in [0,1] {
            renderer = try ParticleRenderer()
            renderer.targetLiveWaveform = live
            renderer.targetSpeechSessionActive = true
            renderer.targetSpeech = SIMD2(0.8,0.4)
            try advance(3)
            renderer.targetSpeech = .zero
            try advance(0.3)
            try require(renderer.speechPresence > 0.95,
                        "A sentence pause incorrectly ended the speech animation")
            renderer.targetSpeechSessionActive = false
            try advance(0.25)
            let quarterSecond = renderer.speechPresence
            try require(quarterSecond < 0.06 && abs(renderer.effectiveTrailLength-renderer.trailLength) < 0.025,
                        "Playback completion did not quickly restore the normal currents and trails")
            try advance(0.35)
            try require(renderer.speechPresence < 0.001 && renderer.speechHistory.allSatisfy { $0 == .zero },
                        "Completed speech retained its waveform history or animation influence")
            let particles = renderer.particles.contents().bindMemory(to: Particle.self, capacity: ParticleRenderer.particleCount)
            var horizontalSpeed: Float = 0
            var visible = 0
            for id in 0..<ParticleRenderer.particleCount where particles[id].position.w > 0.2 {
                horizontalSpeed += abs(particles[id].velocity.x*renderer.motionRate); visible += 1
            }
            try require(horizontalSpeed/Float(visible) > 0.03,
                        "Normal current motion remained frozen after speech completion")
            completionChecks.append(["live": live,"presenceAtQuarterSecond": quarterSecond,
                                     "normalHorizontalSpeed": horizontalSpeed/Float(visible),"state": try stats()])
            renderer.targetSpeechSessionActive = true
            try advance(0.1)
            try require(renderer.speechPresence < 0.001,
                        "A fresh speech session resurrected the completed phrase before audio started")
        }
        let completionMeter = SpeechMeter()
        completionMeter.store(SIMD2(0.8,0.3),sessionActive: true)
        completionMeter.store(.zero)
        try require(completionMeter.snapshot().sessionActive,
                    "A quiet meter sample cleared the active speech session")
        completionMeter.store(.zero,sessionActive: false)
        try require(!completionMeter.snapshot().sessionActive,
                    "Playback completion did not reach the renderer mailbox")
        speechChecks["fastPlaybackCompletion"] = completionChecks
        report["speechAnimation"] = speechChecks

        var connectionChecks: [[String: Any]] = []
        for effort: Float in [0,1] {
            renderer = try ParticleRenderer()
            renderer.targetActivity = effort
            try advance(8)
            let startPointer = renderer.particles.contents().bindMemory(to: Particle.self, capacity: ParticleRenderer.particleCount)
            let start = Array(UnsafeBufferPointer(start: startPointer,count: ParticleRenderer.particleCount))
            let startState = try stats()
            renderer.targetConnected = false
            renderer.targetActivity = 0
            try advance(0.025)
            let falling = renderer.particles.contents().bindMemory(to: Particle.self, capacity: ParticleRenderer.particleCount)
            for id in 0..<ParticleRenderer.particleCount {
                try require(length(falling[id].position-start[id].position) < 0.07,
                            "Disconnect teleported particle \(id)")
            }
            try advance(0.5)
            _ = try stats()
            _ = try snapshot(renderer, url: output.appendingPathComponent("disconnect-falling-\(Int(effort*100)).png"), width: 1000,height: 1000)
            try advance(8)
            let bedPointer = renderer.particles.contents().bindMemory(to: Particle.self, capacity: ParticleRenderer.particleCount)
            let bed = Array(UnsafeBufferPointer(start: bedPointer,count: ParticleRenderer.particleCount))
            for id in 0..<ParticleRenderer.particleCount {
                try require(bed[id].position.w == start[id].position.w,
                            "A particle disappeared while disconnecting")
                try require(bed[id].position.y < -0.73 && length(SIMD3(bed[id].velocity.x,bed[id].velocity.y,bed[id].velocity.z)) < 0.005,
                            "Disconnected particle \(id) did not settle at the bottom: position \(bed[id].position), velocity \(bed[id].velocity), effort \(effort)")
            }
            let bedState = try stats()
            try advance(2)
            let rested = renderer.particles.contents().bindMemory(to: Particle.self, capacity: ParticleRenderer.particleCount)
            for id in 0..<ParticleRenderer.particleCount {
                try require(length(rested[id].position-bed[id].position) < 0.0001,
                            "Disconnected particles continued drifting after settling")
            }
            for (appearance,dark) in [("dark",Float(1)),("light",Float(0))] {
                renderer.targetDark = dark
                try advance(2)
                _ = try snapshot(renderer, url: output.appendingPathComponent("disconnected-\(Int(effort*100))-\(appearance).png"),width: 1000,height: 1000)
            }
            renderer.targetDark = 1
            renderer.targetConnected = true
            try advance(1)
            let rising = try stats()
            try require((rising["verticalExtent"] as! [Float])[1] > -0.2,
                        "Reconnecting did not lift the particles into the globe")
            _ = try snapshot(renderer, url: output.appendingPathComponent("reconnecting-\(Int(effort*100)).png"),width: 1000,height: 1000)
            try advance(6)
            let reconnected = try stats()
            try require(renderer.activity < 0.001 && (reconnected["aboveEquator"] as! Int) > 100,
                        "Reconnecting failed to restore idle circulation")
            connectionChecks.append(["startingEffort": effort,"before": startState,"settled": bedState,"rising": rising,"reconnected": reconnected])
        }
        // Connection state wins over a voice source still sending samples.
        renderer.targetLiveWaveform = 1
        renderer.targetSpeechSessionActive = true
        renderer.targetSpeech = SIMD2(0.8,0.4)
        try advance(3)
        renderer.targetConnected = false
        try advance(1)
        try require(renderer.speechPresence < 0.001 && renderer.speechFlashLevel < 0.001,
                    "Disconnected state retained speech forces or flashing")
        report["connectionStates"] = connectionChecks

        // Small drawables must retain colored particle detail at full effort,
        // instead of overlapping fixed-size halos into a nearly white globe.
        renderer = try ParticleRenderer()
        renderer.targetActivity = 1
        try advance(12)
        var compactChecks: [[String: Any]] = []
        for (appearance,dark) in [("dark",Float(1)),("light",Float(0))] {
            renderer.targetDark = dark
            try advance(2)
            for size in [160,240,360,600,1000] {
                let frame = try snapshot(renderer,url: output.appendingPathComponent("compact-maximum-\(appearance)-\(size).png"),width: size,height: size)
                let globeArea = Double.pi*pow(Double(size)*0.445,2)
                let whiteFraction = Double(frame.brightNeutralPixels)/globeArea
                let vividFraction = Double(frame.vividPixels)/globeArea
                if appearance == "dark" && size <= 360 {
                    try require(whiteFraction < 0.12 && vividFraction > 0.015,
                                "Compact globe lost detail to bloom at \(size) px: white \(whiteFraction), vivid \(vividFraction)")
                    try require(frame.peak > 1,"Compact globe lost its HDR particle highlights")
                }
                compactChecks.append(["appearance": appearance,"drawablePixels": size,
                                      "globeDiameterPoints": Double(size)*0.445,"whiteFraction": whiteFraction,
                                      "vividFraction": vividFraction,"peak": frame.peak])
            }
        }
        report["compactBloom"] = compactChecks

        let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys])
        try json.write(to: output.appendingPathComponent("validation.json"))
        print("PASS: finite simulation, confinement, wisps, wall gliding, five currents, collisions, EDR, smooth settling, resize, energy-driven Disc release and recovery, density range, size coverage, sustained idle glass contact, two perpendicular opposing midpoint currents, adjustable idle movement, crowded collisions, curved trail history, trail-length coverage, exact off rendering, 10–33,600 particle budgets, 20× size, and effort-driven sparkle")
    }

    /// Validate the actual composited GPU output, including large particle halos
    /// at the glass edge and rectangular drawables in both appearances.
    static func checkTransparency(in output: URL) throws {
        try FileManager.default.createDirectory(at: output,withIntermediateDirectories: true)
        for dark: Float in [0,1] {
            let renderer = try ParticleRenderer(initialDark: dark,initialSize: 20,initialTrailLength: 1)
            let width = 320, height = 240
            let opaque = try snapshot(renderer,url: output.appendingPathComponent("opaque-\(dark).png"),width: width,height: height)
            renderer.transparentBackground = true
            let clear = try snapshot(renderer,url: output.appendingPathComponent("clear-\(dark).png"),width: width,height: height)
            var edgePixels = 0
            for y in 0..<height {
                for x in 0..<width {
                    let offset = (y*width+x)*4
                    let radius = hypot(Float(x)+0.5-Float(width)/2,Float(y)+0.5-Float(height)/2)/(Float(height)*0.445)
                    try require(opaque.pixels[offset+3] == 255,"Embedded globe must remain opaque")
                    if radius > 1.01 {
                        try require(clear.pixels[offset..<offset+4].allSatisfy { $0 == 0 },"Floating globe leaked color/alpha outside its circular boundary")
                    } else if radius < 0.99 {
                        try require(clear.pixels[offset..<offset+4] == opaque.pixels[offset..<offset+4],"Transparency changed the globe interior")
                    }
                    if clear.pixels[offset+3] > 0 && clear.pixels[offset+3] < 255 { edgePixels += 1 }
                }
            }
            try require(edgePixels > 0,"Floating globe needs an antialiased edge")
            renderer.transparentBackground = false
            let restored = try snapshot(renderer,url: output.appendingPathComponent("restored-\(dark).png"),width: width,height: height)
            try require(restored.pixels == opaque.pixels,"Returning to embedded rendering changed the frame")
        }
    }

    static func checkGlass(in output: URL) throws {
        try FileManager.default.createDirectory(at: output,withIntermediateDirectories: true)
        let width = 600, height = 600
        func changedInBand(_ a: RenderMetrics, _ b: RenderMetrics, low: Float, high: Float) -> Double {
            var changed = 0, total = 0
            for y in 0..<height { for x in 0..<width {
                let r = hypot(Float(x)+0.5-Float(width)/2,Float(y)+0.5-Float(height)/2)/(Float(height)*0.445)
                guard r >= low && r < high else { continue }
                total += 1
                let i = (y*width+x)*4
                let difference = (0..<3).reduce(0) { $0+abs(Int(a.pixels[i+$1])-Int(b.pixels[i+$1])) }
                if difference > 8 { changed += 1 }
            } }
            return Double(changed)/Double(max(1,total))
        }
        for dark: Float in [0,1] {
            let renderer = try ParticleRenderer(initialDark: dark)
            renderer.transparentBackground = true
            let off = try snapshot(renderer,url: output.appendingPathComponent("particles-\(dark)-off.png"),width: width,height: height,glassEffect: 0)
            let half = try snapshot(renderer,url: output.appendingPathComponent("particles-\(dark)-half.png"),width: width,height: height,glassEffect: 0.5)
            let full = try snapshot(renderer,url: output.appendingPathComponent("particles-\(dark)-full.png"),width: width,height: height,glassEffect: 1)
            let center = changedInBand(off,full,low: 0,high: 0.22)
            let edge = changedInBand(off,full,low: 0.72,high: 0.98)
            print("Glass appearance \(dark): center changed \(center), edge changed \(edge)")
            try require(edge > 0.10 && edge > center*2,"Glass refraction must be strongest at the edge")
            try require(half.changedPixels(from: off) > 100,"Midpoint glass setting has no optical effect")
            try require(full.changedPixels(from: half) > 100,"Glass strength does not change the optical effect")
            try require(full.pixels[0..<4].allSatisfy { $0 == 0 },"Glass optics leaked outside the globe")
            let restored = try snapshot(renderer,url: output.appendingPathComponent("particles-\(dark)-restored.png"),width: width,height: height,glassEffect: 0)
            try require(restored.pixels == off.pixels,"Glass Off must restore the original rendering")
        }
        // A synthetic desktop provides reproducible, permission-free validation
        // of pixel-buffer import, orientation, viewport motion, and refraction.
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferMetalCompatibilityKey as String: true,
                                         kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        try require(CVPixelBufferCreate(nil,width,height,kCVPixelFormatType_32BGRA,attributes as CFDictionary,&buffer) == kCVReturnSuccess,"Could not create test backdrop")
        let desktop = buffer!
        CVPixelBufferLockBaseAddress(desktop,[])
        let bytes = CVPixelBufferGetBaseAddress(desktop)!.assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(desktop)
        for y in 0..<height { for x in 0..<width {
            let i = y*row+x*4
            let line = x%30 < 3 || y%30 < 3
            bytes[i] = line ? 35 : UInt8(70+y*170/height)
            bytes[i+1] = line ? 35 : UInt8(70+x*150/width)
            bytes[i+2] = line ? 35 : 230
            bytes[i+3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(desktop,[])
        let mailbox = GlassBackdrop()
        mailbox.store(desktop)
        let renderer = try ParticleRenderer(initialDark: 1,initialDensity: ParticleRenderer.minimumDensity)
        renderer.transparentBackground = true
        renderer.glassBackdrop = mailbox
        renderer.opacity = 0.5
        let nearOff = try snapshot(renderer,url: output.appendingPathComponent("desktop-near-off.png"),width: width,height: height,glassEffect: 0.0002)
        let lensed = try snapshot(renderer,url: output.appendingPathComponent("desktop-lensed.png"),width: width,height: height,glassEffect: 1)
        try require(changedInBand(nearOff,lensed,low: 0.72,high: 0.98) > 0.25,"Live backdrop was not refracted")
        // The grid's warped positions must stay fixed as transparency reveals it.
        // Comparing contrast rather than brightness isolates lens geometry from opacity.
        renderer.opacity = 0.1
        let clearLens = try snapshot(renderer,url: output.appendingPathComponent("desktop-90-percent-transparent.png"),width: width,height: height,glassEffect: 1)
        var count = 0.0, sumA = 0.0, sumB = 0.0, sumAA = 0.0, sumBB = 0.0, sumAB = 0.0
        for y in 0..<height { for x in 0..<width {
            let r = hypot(Float(x)+0.5-Float(width)/2,Float(y)+0.5-Float(height)/2)/(Float(height)*0.445)
            guard r > 0.72 && r < 0.98 else { continue }
            let i = (y*width+x)*4
            let a = Double(lensed.pixels[i]), b = Double(clearLens.pixels[i])
            count += 1; sumA += a; sumB += b
            sumAA += a*a; sumBB += b*b; sumAB += a*b
        } }
        let correlation = (count*sumAB-sumA*sumB)/sqrt((count*sumAA-sumA*sumA)*(count*sumBB-sumB*sumB))
        print("Desktop lens geometry correlation at 50% and 90% transparency: \(correlation)")
        try require(correlation > 0.97,"Transparency must reveal desktop refraction without weakening its geometry")
        renderer.opacity = 0
        let fullyClear = try snapshot(renderer,url: output.appendingPathComponent("desktop-clear-glass.png"),width: width,height: height,glassEffect: 1)
        let clearUnlensed = try snapshot(renderer,url: output.appendingPathComponent("desktop-clear-unlensed.png"),width: width,height: height,glassEffect: 0.0002)
        try require(changedInBand(clearUnlensed,fullyClear,low: 0.72,high: 0.98) > 0.25,"Fully clear glass must retain desktop refraction")
        renderer.opacity = 0.5
        let middle = ((height/2)*width+width/2)*4
        let top = ((height/4+12)*width+width/2+12)*4
        let bottom = ((height*3/4+12)*width+width/2+12)*4
        try require(lensed.pixels[middle+3] == 255,"Captured refraction must replace the underlying image without double exposure")
        try require(nearOff.pixels[bottom+2] > nearOff.pixels[top+2],"Backdrop was vertically flipped")
        mailbox.updateViewport(CGRect(x: 0.1,y: 0.1,width: 0.6,height: 0.6))
        let moved = try snapshot(renderer,url: output.appendingPathComponent("desktop-moved.png"),width: width,height: height,glassEffect: 1)
        try require(moved.changedPixels(from: lensed) > 1000,"Backdrop coordinates did not follow the moving globe")
        mailbox.clear()
        let unavailable = try snapshot(renderer,url: output.appendingPathComponent("desktop-unavailable.png"),width: width,height: height,glassEffect: 1)
        try require(abs(Int(unavailable.pixels[middle+3])-128) <= 1,"Capture loss must restore native transparency")
        renderer.opacity = 0
        let clearSnow = try snapshot(renderer,url: output.appendingPathComponent("clear-glass-no-capture.png"),width: width,height: height,glassEffect: 1)
        try require(clearSnow.peak > 0.01,"Fully clear glass must leave particles visible after capture loss")
        try require(clearSnow.pixels[middle+3] == 0,"Clear glass must reveal the native desktop between particles after capture loss")
    }

    /// Compare the same stationary particle/trail image over several glass
    /// backgrounds. Its premultiplied color and coverage must never be faded
    /// by the glass slider, including HDR emission and capture-loss fallback.
    static func checkGlassOpacity(in output: URL) throws {
        try FileManager.default.createDirectory(at: output,withIntermediateDirectories: true)
        let width = 320, height = 240
        var pixelBuffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        try require(CVPixelBufferCreate(nil,width,height,kCVPixelFormatType_32BGRA,attributes,&pixelBuffer) == kCVReturnSuccess,"Could not create opacity test backdrop")
        let desktop = pixelBuffer!
        CVPixelBufferLockBaseAddress(desktop,[])
        let bytes = CVPixelBufferGetBaseAddress(desktop)!.assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(desktop)
        for y in 0..<height { for x in 0..<width {
            let i = y*row+x*4
            bytes[i] = 80; bytes[i+1] = 130; bytes[i+2] = 200; bytes[i+3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(desktop,[])
        let mailbox = GlassBackdrop()
        mailbox.store(desktop)
        for dark: Float in [0,1] {
            let renderer = try ParticleRenderer(initialDark: dark,initialSize: 4,initialTrailLength: 1)
            renderer.transparentBackground = true
            let particles = renderer.particles.contents().bindMemory(to: Particle.self,capacity: ParticleRenderer.particleCount)
            let visibility = (0..<ParticleRenderer.particleCount).map { particles[$0].position.w }
            func setSnowVisible(_ visible: Bool) {
                for id in 0..<ParticleRenderer.particleCount { particles[id].position.w = visible ? visibility[id] : 0 }
            }
            func frame(_ name: String, glass: Float, trail: Float = 1) throws -> RenderMetrics {
                try snapshot(renderer,url: output.appendingPathComponent("\(dark)-\(glass)-\(name).png"),width: width,height: height,trailLength: trail,glassEffect: glass,retainLinearPixels: true)
            }
            for strength: Float in [0,1] {
                renderer.opacity = 0
                renderer.glassBackdrop = nil
                let snow = try frame("snow",glass: strength)
                let heads = try frame("heads",glass: strength,trail: 0)
                let reference = snow.linearPixels!
                try require(snow.peak > 0.1,"Clear glass faded particle brightness")
                try require(reference.enumerated().filter { $0.offset%4 == 3 && $0.element > 0.05 }.count > 100,"Clear glass erased particle coverage")
                try require(snow.changedPixels(from: heads) > 100,"Clear glass erased particle trails")
                for captured in [false,true] {
                    renderer.glassBackdrop = captured ? mailbox : nil
                    for opacity: Float in [0,0.5,1] {
                        renderer.opacity = opacity
                        let name = "\(captured)-\(opacity)"
                        setSnowVisible(false)
                        let background = try frame("glass-\(name)",glass: strength).linearPixels!
                        setSnowVisible(true)
                        let combined = try frame("combined-\(name)",glass: strength).linearPixels!
                        var maxError: Float = 0
                        // Stay inside the AA fringe: it has separately filtered coverage.
                        for y in 0..<height { for x in 0..<width {
                            guard hypot(Float(x)+0.5-Float(width)/2,Float(y)+0.5-Float(height)/2) < Float(height)*0.445*0.98 else { continue }
                            let i = (y*width+x)*4
                            for channel in 0..<4 {
                                let expected = reference[i+channel]+background[i+channel]*(1-reference[i+3])
                                maxError = max(maxError,abs(combined[i+channel]-expected))
                            }
                        } }
                        // The original fully opaque, optics-off pass blends each
                        // translucent particle into a half-float background. Its
                        // accumulated rounding differs from the isolated layer.
                        let tolerance: Float = strength == 0 && opacity == 1 ? 0.05 : 0.006
                        try require(maxError < tolerance,"Glass opacity \(opacity) changed particle/trail color or coverage (dark=\(dark), refraction=\(strength), capture=\(captured), error=\(maxError))")
                    }
                }
            }
        }
        print("PASS: Glass transparency preserves particle/trail brightness and coverage in both appearances, with refraction on/off and capture present/absent")
    }

    private struct RenderMetrics {
        let peak: Float
        let coloredPixels: Int
        let brightNeutralPixels: Int
        let vividPixels: Int
        let pixelHash: Int
        let pixels: Data
        let linearPixels: [Float]?

        func changedPixels(from baseline: RenderMetrics) -> Int {
            pixels.withUnsafeBytes { (current: UnsafeRawBufferPointer) in
                baseline.pixels.withUnsafeBytes { (original: UnsafeRawBufferPointer) in
                    var changed = 0
                    for offset in stride(from: 0, to: current.count, by: 4) {
                        let difference = abs(Int(current[offset])-Int(original[offset]))
                                       + abs(Int(current[offset+1])-Int(original[offset+1]))
                                       + abs(Int(current[offset+2])-Int(original[offset+2]))
                        if difference > 6 { changed += 1 }
                    }
                    return changed
                }
            }
        }
    }

    private static func snapshot(_ renderer: ParticleRenderer, url: URL, width: Int, height: Int, trailLength: Float? = nil, sparkleLevel: Float? = nil, flashFactor: Float? = nil, glassEffect: Float? = nil, retainLinearPixels: Bool = false) throws -> RenderMetrics {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget, .shaderRead]
        guard let texture = renderer.device.makeTexture(descriptor: descriptor),
              let command = renderer.queue.makeCommandBuffer() else {
            throw RendererFailure.unavailable("Could not allocate validation render target")
        }
        renderer.render(command: command, texture: texture, scale: 2, edr: 4, trailOverride: trailLength, sparkleOverride: sparkleLevel, flashOverride: flashFactor,glassOverride: glassEffect)
        command.commit()
        command.waitUntilCompleted()
        if let error = command.error { throw error }
        var halfPixels = [UInt16](repeating: 0, count: width*height*4)
        halfPixels.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: width*8, from: MTLRegionMake2D(0,0,width,height), mipmapLevel: 0)
        }
        var pixels = [UInt8](repeating: 255, count: width*height*4)
        var peak: Float = 0
        var coloredPixels = 0
        var brightNeutralPixels = 0
        var vividPixels = 0
        for pixel in 0..<width*height {
            let alpha = floatFromHalf(halfPixels[pixel*4+3])
            try require(alpha.isFinite && alpha >= 0 && alpha <= 1.001,"Invalid rendered alpha")
            pixels[pixel*4+3] = UInt8(min(255,max(0,(alpha*255).rounded())))
            let rgb = (0..<3).map { floatFromHalf(halfPixels[pixel*4+$0]) }
            if rgb.min()! < rgb.max()!*0.65 { coloredPixels += 1 }
            if rgb.min()! > 0.90 { brightNeutralPixels += 1 }
            if rgb.max()! > 0.40 && rgb.min()! < rgb.max()!*0.55 { vividPixels += 1 }
            for channel in 0..<3 {
                let linear = floatFromHalf(halfPixels[pixel*4+channel])
                try require(linear.isFinite, "Non-finite rendered pixel")
                peak = max(peak,linear)
                let bounded = min(1,max(0,alpha > 0 ? linear/alpha : 0))
                let encoded = bounded <= 0.0031308 ? bounded*12.92 : 1.055*pow(bounded,1/2.4)-0.055
                pixels[pixel*4+channel] = UInt8(min(255,max(0,encoded*255)))
            }
        }
        let data = Data(pixels)
        let provider = CGDataProvider(data: data as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: width*4, space: CGColorSpace(name: CGColorSpace.displayP3)!,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let bitmap = NSBitmapImageRep(cgImage: image)
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
        return RenderMetrics(peak: peak, coloredPixels: coloredPixels, brightNeutralPixels: brightNeutralPixels, vividPixels: vividPixels, pixelHash: data.hashValue, pixels: data,linearPixels: retainLinearPixels ? halfPixels.map(floatFromHalf) : nil)
    }
}

#endif
