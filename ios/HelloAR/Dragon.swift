// Firepearl, Ava's dragon: small, orange, cat-sized. Walks behind you, flies over your head.
import RealityKit
import UIKit
import simd

final class Dragon {
    enum Mode: String, CaseIterable { case auto = "AUTO", walk = "WALK", fly = "FLY", off = "OFF" }

    let root = AnchorEntity(world: SIMD3<Float>(0, 0, 0))
    private(set) var status = "waiting"

    static let walkLag: Float = 0.9
    static let flyLag: Float = 0.4
    static let standHeight: Float = 0.165
    static let stride: Float = 0.26
    static let hover: Float = 0.45
    static let circleRadius: Float = 0.6
    static let wingScale: Float = 1.5
    static let headScale: Float = 1.25

    private let mover = Entity()
    private let torso = Entity()
    private let headPivot = Entity()
    private let mouth = Entity()
    private let jawPivot = Entity()
    let voice = FirepearlVoice()
    private var eyes: [Entity] = []
    private var tail: [ModelEntity] = []
    private var tailSteps: [Float] = []
    private var tailSpikes: [(entity: ModelEntity, segment: Int, height: Float)] = []
    private var tip = ModelEntity()

    private struct Leg {
        let hip: Entity, knee: Entity, ankle: Entity
        let front: Bool
        let phase: Float
        let rest: SIMD2<Float>
    }
    private var legs: [Leg] = []
    private var wings: [(pivot: Entity, side: Float)] = []

    private final class Puff {
        let entity: ModelEntity
        var age: Float = 9
        var velocity = SIMD3<Float>(0, 0, 0)
        var stage = -1
        init(_ e: ModelEntity) { entity = e }
    }
    private var puffs: [Puff] = []
    private var puffMaterials: [RealityKit.Material] = []
    private static let puffLife: Float = 0.6

    private var placed = false
    private var p = SIMD3<Float>(0, 0, 0)
    private var v = SIMD3<Float>(0, 0, 0)
    private var yaw: Float = 0
    private var bank: Float = 0
    private var pitch: Float = 0
    private var headYaw: Float = 0
    private var headPitch: Float = 0
    private var gait: Float = 0
    private var flap: Float = 0
    private var time: Float = 0
    private var flight: Float = 0
    private var walkAmount: Float = 0
    private var wantsFly = false
    private var flyTimer: Float = 0
    private var walkTime: Float = 0
    private var nextTakeoff: Float = 20
    private var idleTime: Float = 0
    private var nextFire: Float = 6
    private var breath: Float = 0
    private var emitCarry: Float = 0
    private var nextBlink: Float = 2
    private var blink: Float = 0
    private var circle: Float = 0
    private var circling = false
    private var trail: [SIMD3<Float>] = []
    private var cum: [Float] = []
    private var lastLeader: SIMD3<Float>?
    private var leaderSpeed: Float = 0

    // petting, voice, hearts
    private var happy: Float = 0
    private var petting: Float = 0
    private var squint: Float = 0
    private var rolling: Float = 0
    private var rollTimer: Float = 0
    private var hopY: Float = 0
    private var hopV: Float = 0
    private var jaw: Float = 0
    private var tailPhase: Float = 0
    private var heartCarry: Float = 0
    private var helloTimer: Float = -1
    private var nextChat: Float = 30
    private var wasFlying = false
    private var wasBreathing = false
    private var lastPetTalk: Float = -100
    private var camera = SIMD3<Float>(0, 0, 0)
    private final class Heart {
        let entity: Entity
        var age: Float = 9
        var drift: Float = 0
        init(_ e: Entity) { entity = e }
    }
    private var hearts: [Heart] = []
    private static let heartLife: Float = 1.6

    init() {
        root.addChild(mover)
        mover.addChild(torso)
        build()
        root.isEnabled = false
    }

    func reset() {
        placed = false
        trail = []; cum = []
        lastLeader = nil
        root.isEnabled = false
        for puff in puffs { puff.age = 9; puff.entity.isEnabled = false }
        for h in hearts { h.age = 9; h.entity.isEnabled = false }
        voice.purr(0)
    }

    // MARK: - building

    private static func paint(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, glow: Float = 0.25, rough: Float = 0.55) -> RealityKit.Material {
        let c = UIColor(red: r, green: g, blue: b, alpha: 1)
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: c)
        m.emissiveColor = .init(color: c)
        m.emissiveIntensity = glow
        m.roughness = PhysicallyBasedMaterial.Roughness(floatLiteral: rough)
        m.metallic = PhysicallyBasedMaterial.Metallic(floatLiteral: 0)
        return m
    }

    private static func rx(_ a: Float) -> simd_quatf { simd_quatf(angle: a, axis: SIMD3<Float>(1, 0, 0)) }
    private static func ry(_ a: Float) -> simd_quatf { simd_quatf(angle: a, axis: SIMD3<Float>(0, 1, 0)) }
    private static func rz(_ a: Float) -> simd_quatf { simd_quatf(angle: a, axis: SIMD3<Float>(0, 0, 1)) }

    @discardableResult
    private func add(_ mesh: MeshResource, _ mat: RealityKit.Material, to parent: Entity, at pos: SIMD3<Float>,
                     scale: SIMD3<Float> = SIMD3<Float>(1, 1, 1), turn: simd_quatf? = nil) -> ModelEntity {
        let e = ModelEntity(mesh: mesh, materials: [mat])
        e.position = pos
        e.scale = scale
        if let turn { e.orientation = turn }
        parent.addChild(e)
        return e
    }

    /// A cone standing on `base`, tipped by `turn`. The cone mesh is centred, so shift it up half its height.
    @discardableResult
    private func spike(_ cone: MeshResource, _ mat: RealityKit.Material, to parent: Entity, base: SIMD3<Float>,
                       height h: Float, radius r: Float, turn: simd_quatf, flat: Float = 1) -> ModelEntity {
        add(cone, mat, to: parent, at: base + turn.act(SIMD3<Float>(0, h / 2, 0)),
            scale: SIMD3<Float>(2 * r, h, 2 * r * flat), turn: turn)
    }

    private func build() {
        let ball = MeshResource.generateSphere(radius: 1)
        let cone = MeshResource.generateCone(height: 1, radius: 0.5)
        let orange = Self.paint(1.0, 0.45, 0.08)
        let cream = Self.paint(1.0, 0.84, 0.50, glow: 0.2)
        let ember = Self.paint(0.86, 0.20, 0.04, glow: 0.3)
        let membrane = Self.paint(1.0, 0.63, 0.22, glow: 0.3, rough: 0.7)
        let ivory = Self.paint(1.0, 0.96, 0.84, glow: 0.15, rough: 0.35)
        let green = Self.paint(0.25, 0.85, 0.35, glow: 0.4, rough: 0.2)
        let black = Self.paint(0.02, 0.02, 0.03, glow: 0, rough: 0.15)
        let white = Self.paint(1, 1, 1, glow: 1, rough: 0.1)

        torso.position = SIMD3<Float>(0, Self.standHeight, 0)

        // body, belly, chest
        add(ball, orange, to: torso, at: .zero, scale: SIMD3<Float>(0.085, 0.075, 0.14))
        add(ball, cream, to: torso, at: SIMD3<Float>(0, -0.022, 0.015), scale: SIMD3<Float>(0.068, 0.058, 0.118))
        add(ball, cream, to: torso, at: SIMD3<Float>(0, 0.0, 0.112), scale: SIMD3<Float>(0.058, 0.062, 0.05))

        // back spikes
        for (z, h) in [(Float(0.07), Float(0.028)), (0.02, 0.032), (-0.035, 0.030), (-0.085, 0.025)] {
            let y = 0.075 * sqrtf(max(0, 1 - (z / 0.14) * (z / 0.14))) - 0.004
            spike(cone, ember, to: torso, base: SIMD3<Float>(0, y, z), height: h, radius: 0.012, turn: Self.rx(-0.4))
        }

        // neck, with a cream throat and little spikes
        let neckA = SIMD3<Float>(0, 0.035, 0.115), neckB = SIMD3<Float>(0, 0.13, 0.165)
        for k in 0..<4 {
            let t = Float(k) / 3
            let c = neckA + (neckB - neckA) * t
            let r: Float = 0.052 - 0.012 * t
            add(ball, orange, to: torso, at: c, scale: SIMD3<Float>(repeating: r))
            add(ball, cream, to: torso, at: c + SIMD3<Float>(0, -0.01, 0.014), scale: SIMD3<Float>(repeating: r * 0.82))
            if k > 0 {
                spike(cone, ember, to: torso, base: c + SIMD3<Float>(0, r * 0.9, -0.006), height: 0.02, radius: 0.009, turn: Self.rx(-0.6))
            }
        }

        // head: big round skull, snout, jaw, nostrils, eyes, horns, ear frills
        headPivot.position = SIMD3<Float>(0, 0.15, 0.17)
        headPivot.scale = SIMD3<Float>(repeating: Self.headScale)
        torso.addChild(headPivot)
        add(ball, orange, to: headPivot, at: SIMD3<Float>(0, 0.02, 0.03), scale: SIMD3<Float>(0.062, 0.055, 0.065))
        add(.generateBox(width: 0.07, height: 0.045, depth: 0.075, cornerRadius: 0.02), orange,
            to: headPivot, at: SIMD3<Float>(0, 0.002, 0.09))
        jawPivot.position = SIMD3<Float>(0, -0.012, 0.06)
        headPivot.addChild(jawPivot)
        add(.generateBox(width: 0.058, height: 0.018, depth: 0.065, cornerRadius: 0.008), cream,
            to: jawPivot, at: SIMD3<Float>(0, -0.009, 0.028))
        add(ball, Self.paint(0.45, 0.05, 0.08, glow: 0.1), to: headPivot, at: SIMD3<Float>(0, -0.016, 0.085),
            scale: SIMD3<Float>(0.026, 0.009, 0.038))
        for s in [Float(-1), 1] {
            add(ball, black, to: headPivot, at: SIMD3<Float>(0.017 * s, 0.02, 0.126), scale: SIMD3<Float>(repeating: 0.0055))

            let eye = Entity()
            eye.position = SIMD3<Float>(0.038 * s, 0.032, 0.07)
            headPivot.addChild(eye)
            add(ball, green, to: eye, at: .zero, scale: SIMD3<Float>(repeating: 0.02))
            let out = simd_normalize(SIMD3<Float>(0.4 * s, 0.1, 0.9))
            add(ball, black, to: eye, at: out * 0.012, scale: SIMD3<Float>(repeating: 0.0115))
            let glint = simd_normalize(SIMD3<Float>(0.3 * s, 0.5, 0.8))
            add(ball, white, to: eye, at: glint * 0.022, scale: SIMD3<Float>(repeating: 0.0045))
            eyes.append(eye)

            spike(cone, ivory, to: headPivot, base: SIMD3<Float>(0.03 * s, 0.064, 0.005), height: 0.065, radius: 0.014,
                  turn: Self.rz(-0.3 * s) * Self.rx(-0.8))
            spike(cone, membrane, to: headPivot, base: SIMD3<Float>(0.052 * s, 0.035, -0.005), height: 0.045, radius: 0.018,
                  turn: Self.rz(-1.15 * s) * Self.rx(-0.5), flat: 0.3)
        }
        mouth.position = SIMD3<Float>(0, -0.008, 0.135)
        headPivot.addChild(mouth)

        // tail: nine tapering beads, three spikes, a diamond spade
        for k in 0..<9 {
            let r: Float = 0.048 * powf(0.85, Float(k)) + 0.004
            tail.append(add(ball, orange, to: torso, at: .zero, scale: SIMD3<Float>(repeating: r)))
            tailSteps.append(0.036 * powf(0.93, Float(k)))
            if k == 1 || k == 3 || k == 5 {
                let h: Float = 0.024 - 0.002 * Float(k)
                tailSpikes.append((spike(cone, ember, to: torso, base: .zero, height: h, radius: 0.009, turn: Self.rx(-0.5)), k, h))
            }
        }
        tip = add(Chakra.octahedron(radius: 1), ember, to: torso, at: .zero, scale: SIMD3<Float>(0.03, 0.008, 0.042))

        // legs: front pair straight, hind pair z-shaped; trot = diagonal pairs in phase (+x is her left)
        let specs: [(SIMD3<Float>, Bool, Float)] = [
            (SIMD3<Float>(0.055, -0.035, 0.085), true, 0), (SIMD3<Float>(-0.055, -0.035, 0.085), true, .pi),
            (SIMD3<Float>(0.06, -0.03, -0.075), false, .pi), (SIMD3<Float>(-0.06, -0.03, -0.075), false, 0),
        ]
        for (hipPos, front, phase) in specs {
            let l1: Float = front ? 0.065 : 0.07, l2: Float = front ? 0.055 : 0.06
            let hip = Entity(); hip.position = hipPos; torso.addChild(hip)
            add(ball, orange, to: hip, at: .zero, scale: SIMD3<Float>(repeating: front ? 0.034 : 0.045))
            add(.generateBox(width: 0.036, height: l1 + 0.012, depth: 0.04, cornerRadius: 0.016), orange,
                to: hip, at: SIMD3<Float>(0, -l1 / 2, 0))
            let knee = Entity(); knee.position = SIMD3<Float>(0, -l1, 0); hip.addChild(knee)
            add(.generateBox(width: 0.03, height: l2 + 0.01, depth: 0.032, cornerRadius: 0.013), orange,
                to: knee, at: SIMD3<Float>(0, -l2 / 2, 0))
            let ankle = Entity(); ankle.position = SIMD3<Float>(0, -l2, 0); knee.addChild(ankle)
            add(.generateBox(width: 0.042, height: 0.018, depth: 0.056, cornerRadius: 0.008), orange,
                to: ankle, at: SIMD3<Float>(0, -0.004, 0.012))
            for dx in [Float(-0.013), 0, 0.013] {
                spike(cone, ivory, to: ankle, base: SIMD3<Float>(dx, -0.007, 0.036), height: 0.016, radius: 0.0045, turn: Self.rx(.pi / 2))
            }
            legs.append(Leg(hip: hip, knee: knee, ankle: ankle, front: front, phase: phase,
                            rest: front ? SIMD2<Float>(0, 0) : SIMD2<Float>(-0.35, 0.7)))
        }

        // wings: bat membranes with finger bones, hinged at the shoulders
        for s in [Float(1), -1] {
            let pivot = Entity()
            pivot.position = SIMD3<Float>(0.05 * s, 0.055, 0.06)
            torso.addChild(pivot)
            add(Self.wingMesh(side: s), membrane, to: pivot, at: .zero)
            let m = SIMD3<Float>(s, 1, 1) * Self.wingScale
            let o = Self.wingOutline.map { $0 * m }
            for (a, b, t) in [(o[0], o[1], Float(0.012)), (o[1], o[2], 0.007), (o[1], o[4], 0.006), (o[1], o[6], 0.006)] {
                let bone = MeshResource.generateBox(width: t, height: t, depth: simd_distance(a, b), cornerRadius: t * 0.45)
                add(bone, ember, to: pivot, at: (a + b) / 2, turn: simd_quatf(from: SIMD3<Float>(0, 0, 1), to: simd_normalize(b - a)))
            }
            spike(cone, ivory, to: pivot, base: o[1], height: 0.02, radius: 0.005, turn: Self.rx(0.9))
            wings.append((pivot, s))
        }

        // fire
        puffMaterials = [Self.paint(1, 0.95, 0.6, glow: 1.0), Self.paint(1, 0.6, 0.1, glow: 0.9),
                         Self.paint(0.9, 0.2, 0.05, glow: 0.6), Self.paint(0.35, 0.3, 0.3, glow: 0.1)]
        for _ in 0..<28 {
            let e = ModelEntity(mesh: ball, materials: [puffMaterials[0]])
            e.isEnabled = false
            root.addChild(e)
            puffs.append(Puff(e))
        }
        let pink = Self.paint(1.0, 0.35, 0.6, glow: 0.8, rough: 0.3)
        for _ in 0..<12 {
            let h = Entity()
            for sx in [Float(-1), 1] {
                add(ball, pink, to: h, at: SIMD3<Float>(0.32 * sx, 0.18, 0), scale: SIMD3<Float>(0.4, 0.4, 0.22))
            }
            add(cone, pink, to: h, at: SIMD3<Float>(0, -0.2, 0), scale: SIMD3<Float>(1.15, 0.85, 0.44), turn: Self.rx(.pi))
            h.isEnabled = false
            root.addChild(h)
            hearts.append(Heart(h))
        }
    }

    /// Outline of the dragon's left wing (+x), root front â†’ wrist â†’ three finger tips with scalloped skin â†’ root back.
    static let wingOutline: [SIMD3<Float>] = [
        SIMD3(0, 0, 0.035), SIMD3(0.09, 0.015, 0.065), SIMD3(0.23, 0, 0.02), SIMD3(0.165, 0, -0.035),
        SIMD3(0.20, -0.005, -0.10), SIMD3(0.125, 0, -0.075), SIMD3(0.11, -0.01, -0.155), SIMD3(0.055, 0, -0.085),
        SIMD3(0, 0, -0.06),
    ]
    static let wingHub = SIMD3<Float>(0.07, 0.005, 0)

    static func wingMesh(side s: Float) -> MeshResource {
        let m = SIMD3<Float>(s, 1, 1) * wingScale
        let hub = wingHub * m
        let rim = wingOutline.map { $0 * m }
        var pos: [SIMD3<Float>] = [], nor: [SIMD3<Float>] = [], idx: [UInt32] = []
        for i in 0..<rim.count {
            var a = rim[i], b = rim[(i + 1) % rim.count]
            var n = simd_cross(a - hub, b - hub)
            guard simd_length(n) > 1e-9 else { continue }
            n = simd_normalize(n)
            if n.y < 0 { swap(&a, &b); n = -n }
            for (tri, nn) in [([hub, a, b], n), ([hub, b, a], -n)] {
                let base = UInt32(pos.count)
                pos += tri
                nor += [nn, nn, nn]
                idx += [base, base + 1, base + 2]
            }
        }
        var d = MeshDescriptor(name: "dragon-wing")
        d.positions = MeshBuffers.Positions(pos)
        d.normals = MeshBuffers.Normals(nor)
        d.primitives = .triangles(idx)
        return try! MeshResource.generate(from: [d])
    }

    // MARK: - following

    private func recordTrail(_ q: SIMD3<Float>) {
        if let last = trail.last {
            let d = simd_length(SIMD2<Float>(q.x - last.x, q.z - last.z))
            guard d >= 0.05 else { return }
            trail.append(q); cum.append(cum.last! + d)
        } else {
            trail.append(q); cum.append(0)
        }
        if trail.count > 3000 {
            let drop = 1000, shift = cum[drop]
            trail.removeFirst(drop); cum.removeFirst(drop)
            cum = cum.map { $0 - shift }
        }
    }

    private func trailPoint(lag: Float) -> SIMD3<Float>? {
        guard let total = cum.last, total >= lag else { return nil }
        let d = total - lag
        var lo = 0, hi = cum.count - 1
        while hi - lo > 1 { let mid = (lo + hi) / 2; if cum[mid] <= d { lo = mid } else { hi = mid } }
        let span = cum[hi] - cum[lo]
        let t = span > 0 ? (d - cum[lo]) / span : 0
        return trail[lo] + (trail[hi] - trail[lo]) * t
    }

    private static func flat(_ a: SIMD3<Float>) -> SIMD3<Float> { SIMD3<Float>(a.x, 0, a.z) }
    private static func wrap(_ a: Float) -> Float { atan2f(sinf(a), cosf(a)) }
    private static func clamp(_ x: Float, _ lo: Float, _ hi: Float) -> Float { min(max(x, lo), hi) }

    /// leaderFloor/leaderHead: the person it follows. viewer: the camera, when the camera is someone else (BODY mode).
    func update(dt rawDt: Float, mode: Mode, leaderFloor: SIMD3<Float>, leaderHead: SIMD3<Float>,
                viewer: SIMD3<Float>?, camera: SIMD3<Float>, cameraForward: SIMD3<Float>, fire: Bool) {
        guard mode != .off else {
            if root.isEnabled { reset() }
            voice.purr(0)
            status = "off"
            return
        }
        let dt = Self.clamp(rawDt, 0, 0.05)
        time += dt
        self.camera = camera
        root.isEnabled = true
        let floorY = leaderFloor.y

        if !placed {
            var f = Self.flat(cameraForward)
            f = simd_length(f) > 1e-3 ? simd_normalize(f) : SIMD3<Float>(0, 0, -1)
            let spot = viewer == nil ? Self.flat(camera) + f * 1.2 : Self.flat(leaderFloor) + simd_cross(f, SIMD3<Float>(0, 1, 0)) * 0.5
            p = SIMD3<Float>(spot.x, floorY + 0.8, spot.z)
            v = .zero
            let toCam = camera - p
            yaw = atan2f(toCam.x, toCam.z)
            wantsFly = mode != .walk
            flyTimer = mode == .auto ? 2.5 : 0
            walkTime = 0
            circling = false
            placed = true
            helloTimer = 1.8
            rollTimer = 0; rolling = 0; happy = 0; petting = 0
        }

        recordTrail(leaderFloor)
        if let last = lastLeader, dt > 0 {
            let inst = simd_length(Self.flat(leaderFloor - last)) / dt
            leaderSpeed += (min(inst, 5) - leaderSpeed) * min(1, 4 * dt)
        }
        lastLeader = leaderFloor
        let moving = leaderSpeed > 0.3
        let distToLeader = simd_length(Self.flat(p - leaderFloor))

        switch mode {
        case .walk: wantsFly = false
        case .fly: wantsFly = true
        case .auto:
            if leaderSpeed > 1.5 { flyTimer = max(flyTimer, 3) }
            if distToLeader > 4 { flyTimer = max(flyTimer, 2) }
            if flyTimer > 0 {
                flyTimer -= dt
                wantsFly = true
            } else {
                wantsFly = false
                walkTime += dt
                if walkTime > nextTakeoff {
                    walkTime = 0
                    nextTakeoff = Float.random(in: 18...35)
                    flyTimer = Float.random(in: 8...13)
                }
            }
        case .off: break
        }

        // petting: she stops for scratches; enough of them and she rolls over for a belly rub
        petting = max(0, petting - 1.5 * dt)
        happy = max(0, happy - 0.04 * dt)
        let petted = petting > 0.05
        if petted && mode != .fly { wantsFly = false; flyTimer = 0 }
        squint += ((petted ? 1 : 0) - squint) * min(1, 5 * dt)
        if happy > 0.85 && rollTimer <= 0 && rolling < 0.05 && flight < 0.05 {
            rollTimer = 4
            voice.say(.roll)
            voice.giggle()
            for _ in 0..<3 { spawnHeart() }
        }
        if rollTimer > 0 {
            if petted { rollTimer = max(rollTimer, 1.5) }
            rollTimer -= dt
            if rollTimer <= 0 { happy = 0.45 }
        }
        rolling += ((rollTimer > 0 ? 1 : 0) - rolling) * min(1, 3 * dt)

        // where to be
        var target = p
        let headTop = leaderHead.y + 0.05
        if wantsFly {
            if moving {
                circling = false
                target = trailPoint(lag: Self.flyLag) ?? leaderFloor
                target.y = headTop + Self.hover
            } else {
                if !circling {
                    circle = atan2f(p.z - leaderHead.z, p.x - leaderHead.x)
                    circling = true
                }
                circle += dt * 0.9
                let r = Self.circleRadius
                target = SIMD3<Float>(leaderHead.x + cosf(circle) * r,
                                      headTop + Self.hover + 0.08 * sinf(2 * circle),
                                      leaderHead.z + sinf(circle) * r)
            }
        } else {
            circling = false
            let lagPoint = trailPoint(lag: Self.walkLag)
            if moving, let lp = lagPoint {
                target = lp
            } else if let viewer {
                var away = Self.flat(leaderFloor - viewer)
                away = simd_length(away) > 1e-3 ? simd_normalize(away) : SIMD3<Float>(0, 0, -1)
                let right = simd_cross(away, SIMD3<Float>(0, 1, 0))
                target = leaderFloor + right * 0.45 + away * 0.1
            } else if distToLeader > 2.2, let lp = lagPoint {
                target = lp
            } else if distToLeader < 0.5 {
                var out = Self.flat(p - leaderFloor)
                out = simd_length(out) > 1e-3 ? simd_normalize(out) : SIMD3<Float>(0, 0, 1)
                target = leaderFloor + out * 0.7
            }
            target.y = floorY
        }

        if (petted || rollTimer > 0) && !wantsFly { target = SIMD3<Float>(p.x, floorY, p.z) }

        // a damped spring toward the target
        let k: Float = wantsFly ? 2.4 : 3.2
        v += ((target - p) * (k * k) - v * (2 * k)) * dt
        var h = SIMD2<Float>(v.x, v.z)
        let maxH: Float = wantsFly ? 4 : 2.4
        if simd_length(h) > maxH { h = simd_normalize(h) * maxH; v.x = h.x; v.z = h.y }
        v.y = Self.clamp(v.y, -2.5, 2.5)
        p += v * dt
        if p.y < floorY { p.y = floorY; v.y = max(v.y, 0) }
        if !wantsFly && p.y - floorY < 0.01 { p.y = floorY; v.y = 0 }

        let height = p.y - floorY
        flight += ((wantsFly || height > 0.03 ? 1 : 0) - flight) * min(1, 6 * dt)
        let hs = simd_length(SIMD2<Float>(v.x, v.z))
        walkAmount += (min(hs / 0.5, 1) * (1 - flight) - walkAmount) * min(1, 8 * dt)
        gait += hs * dt / Self.stride * 2 * .pi + rolling * 7 * dt
        if hopV != 0 || hopY > 0 {
            hopV -= 9.8 * dt
            hopY += hopV * dt
            if hopY <= 0 { hopY = 0; hopV = 0 }
        }
        flap += dt * 2 * .pi * (3.2 + 1.5 * max(0, v.y))

        // heading, bank, pitch
        var want = yaw
        if hs > 0.15 {
            want = atan2f(v.x, v.z)
        } else {
            let d = leaderFloor - p
            if simd_length(Self.flat(d)) > 0.05 { want = atan2f(d.x, d.z) }
        }
        let turn = Self.wrap(want - yaw) * min(1, 5 * dt)
        yaw += turn
        let yawRate = dt > 0 ? turn / dt : 0
        let bankWant = Self.clamp(-yawRate * 0.25, -0.6, 0.6) * flight
        bank += (bankWant - bank) * min(1, 4 * dt)
        let pitchWant = flight * (Self.clamp(0.1 * hs - 0.25 * v.y, -0.45, 0.45) - 0.15 * (1 - min(hs, 1)))
        pitch += (pitchWant - pitch) * min(1, 4 * dt)

        let bob = 0.006 * walkAmount * abs(sinf(gait)) - 0.02 * flight * sinf(flap) + 0.003 * sinf(1.6 * time)
        mover.position = p
        mover.orientation = Self.ry(yaw) * Self.rx(pitch) * Self.rz(bank)
        let roll = rolling * rolling * (3 - 2 * rolling)
        torso.position = SIMD3<Float>(0, Self.standHeight + bob + (0.095 - Self.standHeight) * roll + hopY, 0)
        torso.orientation = Self.rz(Float.pi * roll)

        poseLegs()
        poseWings()
        poseTail()
        poseHead(lookAt: viewer ?? leaderHead, dt: dt)
        fireAndStatus(fire: fire, moving: moving, mode: mode, dt: dt)
        talkAndHearts(moving: moving, dt: dt)
    }

    private func poseLegs() {
        let fb = flight
        for leg in legs {
            let ph = gait + leg.phase
            let amount = max(walkAmount, 0.7 * rolling)
            var th = leg.rest.x + 0.5 * amount * sinf(ph)
            var kn = leg.rest.y + 0.9 * amount * max(0, -cosf(ph))
            let tuck = leg.front ? SIMD2<Float>(-0.7, 1.6) : SIMD2<Float>(0.9 + 0.1 * sinf(flap), 0.4)
            th += (tuck.x - th) * fb
            kn += (tuck.y - kn) * fb
            leg.hip.orientation = Self.rx(th)
            leg.knee.orientation = Self.rx(kn)
            leg.ankle.orientation = Self.rx(-(th + kn) * (1 - fb) + 0.5 * fb)
        }
    }

    private func poseWings() {
        let fb = flight
        let foldedRoll: Float = 0.6 + 0.04 * sinf(2.3 * time)
        let roll = foldedRoll + (0.25 + 0.8 * sinf(flap) - foldedRoll) * fb + 0.12 * squint * sinf(22 * time)
        let sweep = 0.9 + (0.15 - 0.9) * fb
        let open = 0.45 + 0.55 * fb
        for w in wings {
            w.pivot.orientation = Self.ry(sweep * w.side) * Self.rz(roll * w.side)
            w.pivot.scale = SIMD3<Float>(open, 1, 0.7 + 0.3 * fb)
        }
    }

    private func poseTail() {
        let fb = flight
        let sway = (0.5 + 0.5 * (1 - walkAmount)) * (1 - 0.6 * fb) + 0.6 * happy + 0.4 * squint
        var yawA: Float = 0
        var pitA: Float = -0.3 + 0.25 * fb
        var q = SIMD3<Float>(0, -0.005, -0.125)
        var dir = SIMD3<Float>(0, 0, -1)
        for k in 0..<tail.count {
            let kf = Float(k)
            yawA += sway * 0.22 * sinf(tailPhase - 0.55 * kf)
            pitA += (k > 4 ? 0.13 : 0.02) * (1 - fb) + 0.06 * sinf(flap - 0.6 * kf) * fb
            dir = SIMD3<Float>(sinf(yawA) * cosf(pitA), sinf(pitA), -cosf(yawA) * cosf(pitA))
            q += dir * tailSteps[k]
            tail[k].position = q
            for sp in tailSpikes where sp.segment == k {
                let r = tail[k].scale.x
                let turn = Self.ry(-yawA) * Self.rx(-0.5)
                sp.entity.position = q + SIMD3<Float>(0, r * 0.85, 0) + turn.act(SIMD3<Float>(0, sp.height / 2, 0))
                sp.entity.orientation = turn
            }
        }
        tip.position = q + dir * 0.03
        tip.orientation = simd_quatf(from: SIMD3<Float>(0, 0, -1), to: simd_normalize(dir))
    }

    private func poseHead(lookAt: SIMD3<Float>, dt: Float) {
        let fwd = SIMD3<Float>(sinf(yaw), 0, cosf(yaw))
        let headWorld = p + SIMD3<Float>(0, 0.32, 0) + fwd * 0.17
        let d = lookAt - headWorld
        let c = cosf(yaw), s = sinf(yaw)
        let lx = d.x * c - d.z * s, lz = d.x * s + d.z * c
        let weight = 1 - 0.65 * walkAmount
        var hy = Self.clamp(atan2f(lx, lz), -1.0, 1.0) * weight
        var hp = Self.clamp(-atan2f(d.y, hypotf(lx, lz)), -0.8, 0.6) * weight - pitch
        if breath > 0 { hy *= 0.3; hp = -0.25 }
        hp -= 0.35 * squint
        headYaw += (hy - headYaw) * min(1, 6 * dt)
        headPitch += (hp - headPitch) * min(1, 6 * dt)
        headPivot.orientation = Self.ry(headYaw) * Self.rx(headPitch) * Self.rz(0.3 * squint * sinf(1.3 * time))
        tailPhase += dt * (2.2 + 5 * squint + 3 * happy)
        let jawWant: Float = breath > 0 ? 0.9 : (voice.speaking ? 0.35 + 0.35 * abs(sinf(16 * time)) : 0)
        jaw += (jawWant - jaw) * min(1, 12 * dt)
        jawPivot.orientation = Self.rx(0.5 * jaw)
    }

    private func fireAndStatus(fire: Bool, moving: Bool, mode: Mode, dt: Float) {
        nextBlink -= dt
        if nextBlink <= 0 { blink = 0.14; nextBlink = Float.random(in: 2.5...5.5) }
        let lid: Float = blink > 0 ? 0.1 : 1
        blink -= dt
        for e in eyes { e.scale = SIMD3<Float>(1, min(lid, 1 - 0.7 * squint), 1) }

        if fire { breath = 0.9 }
        if !moving && !wantsFly && flight < 0.05 { idleTime += dt } else { idleTime = 0 }
        nextFire -= dt
        if mode == .auto && idleTime > 3 && nextFire <= 0 {
            breath = 0.8
            nextFire = Float.random(in: 12...25)
        }
        if breath > 0 {
            breath -= dt
            emitCarry += dt * 30
            while emitCarry >= 1 { emitCarry -= 1; emitPuff() }
        }
        for puff in puffs where puff.age < Self.puffLife {
            puff.age += dt
            guard puff.age < Self.puffLife else { puff.entity.isEnabled = false; continue }
            puff.velocity *= max(0, 1 - 1.5 * dt)
            puff.velocity.y += 0.6 * dt
            puff.entity.position += puff.velocity * dt
            let u = puff.age / Self.puffLife
            puff.entity.scale = SIMD3<Float>(repeating: 0.012 + 0.05 * u)
            let stage = u < 0.2 ? 0 : (u < 0.5 ? 1 : (u < 0.8 ? 2 : 3))
            if stage != puff.stage {
                puff.stage = stage
                puff.entity.model?.materials = [puffMaterials[stage]]
            }
        }

        if breath > 0 { status = "breathing fire!" }
        else if rolling > 0.5 { status = "rolling over for belly rubs!" }
        else if squint > 0.5 { status = "loves the scratches" }
        else if wantsFly { status = circling ? "circling over your head" : "flying over you" }
        else if flight > 0.05 { status = "landing" }
        else if walkAmount > 0.2 { status = "walking behind you" }
        else { status = "sitting near you" }
    }

    // MARK: - petting and talking

    /// The point touches are tested against, in world space; nil while she is hidden.
    func touchCentre() -> SIMD3<Float>? {
        guard root.isEnabled, placed else { return nil }
        return mover.convert(position: SIMD3<Float>(0, 0.2, 0.06), to: nil)
    }

    /// A stroke across her; amount is roughly how far the finger moved, in dragon-widths.
    func pet(_ amount: Float) {
        petting = min(1, petting + amount * 0.6)
        happy = min(1, happy + amount * 0.05)
        if happy > 0.15 && time - lastPetTalk > 6 {
            lastPetTalk = time
            voice.say(.pet)
        }
    }

    /// A tap on the nose: a little hop and a giggle.
    func boop() {
        if hopY == 0 && flight < 0.05 { hopV = 1.1 }
        happy = min(1, happy + 0.1)
        voice.giggle()
        if Bool.random() { voice.say(.boop) }
        spawnHeart()
    }

    private func talkAndHearts(moving: Bool, dt: Float) {
        voice.purr(min(1, squint * 1.2 + rolling * 0.6))
        if helloTimer > 0 {
            helloTimer -= dt
            if helloTimer <= 0 { voice.chirp(); voice.say(.hello) }
        }
        if breath > 0 && !wasBreathing { voice.whoosh() }
        if breath <= 0 && wasBreathing && Float.random(in: 0...1) < 0.4 { voice.say(.fire) }
        wasBreathing = breath > 0
        if wantsFly && !wasFlying {
            voice.trill()
            if Float.random(in: 0...1) < 0.6 { voice.say(.takeoff) }
        }
        if !wantsFly && wasFlying && Float.random(in: 0...1) < 0.4 { voice.say(.land) }
        wasFlying = wantsFly
        nextChat -= dt
        if nextChat <= 0 && squint < 0.1 {
            nextChat = Float.random(in: 25...50)
            if moving && !wantsFly { voice.say(.follow) } else if !wantsFly { voice.say(.idle) }
        }

        heartCarry += dt * 2.5 * squint
        while heartCarry >= 1 { heartCarry -= 1; spawnHeart() }
        for h in hearts where h.age < Self.heartLife {
            h.age += dt
            guard h.age < Self.heartLife else { h.entity.isEnabled = false; continue }
            let u = h.age / Self.heartLife
            h.entity.position += SIMD3<Float>(0.06 * h.drift * cosf(6 * h.age), 0.22, 0) * dt
            let size: Float = 0.035 * min(1, u / 0.12) * (u > 0.7 ? (1 - u) / 0.3 : 1)
            h.entity.scale = SIMD3<Float>(repeating: max(size, 0.0001))
            let to = camera - h.entity.position
            h.entity.orientation = Self.ry(atan2f(to.x, to.z))
        }
    }

    private func spawnHeart() {
        guard let h = hearts.first(where: { $0.age >= Self.heartLife }) else { return }
        h.age = 0
        h.drift = Float.random(in: -1...1)
        h.entity.position = headPivot.convert(position: SIMD3<Float>(0, 0.08, 0.02), to: root)
        h.entity.scale = SIMD3<Float>(repeating: 0.0001)
        h.entity.isEnabled = true
    }

    private func emitPuff() {
        guard let puff = puffs.first(where: { $0.age >= Self.puffLife }) else { return }
        let from = mouth.convert(position: .zero, to: root)
        let dir = simd_normalize(headPivot.convert(direction: SIMD3<Float>(0, 0, 1), to: root))
        let jitter = SIMD3<Float>(Float.random(in: -1...1), Float.random(in: -1...1), Float.random(in: -1...1)) * 0.22
        puff.age = 0
        puff.stage = -1
        puff.velocity = dir * 1.3 + jitter + SIMD3<Float>(0, 0.15, 0)
        puff.entity.position = from
        puff.entity.scale = SIMD3<Float>(repeating: 0.012)
        puff.entity.isEnabled = true
    }
}
