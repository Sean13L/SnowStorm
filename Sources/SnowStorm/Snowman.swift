import SpriteKit
import AppKit

@MainActor
final class Snowman {
    enum Role { case bottom, middle, head }

    final class Ball {
        let role: Role
        let radius: CGFloat
        let node: SKShapeNode
        init(role: Role, radius: CGFloat, node: SKShapeNode) { self.role = role; self.radius = radius; self.node = node }
    }

    private enum Phase {
        case absent(until: TimeInterval)
        case building
        case standing(until: TimeInterval)
        case melting
    }

    /// Preview mode: throw almost immediately so the animation can be checked.
    static var quickThrows = false

    private unowned let scene: SnowScene
    private let root = SKNode()
    private var balls: [Ball] = []
    private var phase: Phase
    private var facing: CGFloat = 1
    private var nextThrow: TimeInterval = 0
    private var nextWave: TimeInterval = 0
    private var animatingUntil: TimeInterval = 0
    private weak var throwArm: SKNode?
    private weak var waveArm: SKNode?

    init(scene: SnowScene) {
        self.scene = scene
        phase = .absent(until: scene.now + 2)
        root.zPosition = 20
        scene.addChild(root)
    }

    func dismiss() {
        root.removeAllActions()
        root.removeFromParent()
        balls.removeAll()
    }

    var isAnimating: Bool {
        switch phase {
        case .building, .melting: return true
        default: return scene.now < animatingUntil
        }
    }

    /// Ball rects in scene coordinates while he can be clicked.
    var clickAreas: [CGRect] {
        guard case .standing = phase else { return [] }
        return balls.map { b in
            let c = CGPoint(x: root.position.x + b.node.position.x, y: root.position.y + b.node.position.y)
            return CGRect(x: c.x - b.radius, y: c.y - b.radius, width: b.radius * 2, height: b.radius * 2)
        }
    }

    // MARK: Lifecycle

    func update() {
        let now = scene.now
        switch phase {
        case .absent(let until):
            if now >= until { build() }
        case .standing(let until):
            if now >= until { melt(); return }
            if Settings.shared.snowballs, now >= nextThrow {
                nextThrow = now + .random(in: 40...110)
                throwSnowball()
            } else if now >= nextWave {
                nextWave = now + .random(in: 60...150)
                wave(times: 2)
            }
        default:
            break
        }
    }

    /// Where he stands: on top of a bottom Dock, or beside a side Dock, or on the screen edge.
    private func groundPoint() -> CGPoint {
        if let d = scene.dockRect {
            if d.width >= d.height {
                let lo = d.minX + 40, hi = max(lo + 1, d.maxX - 40)
                let x = CGFloat.random(in: lo...hi)
                return CGPoint(x: x, y: d.maxY + 1 + scene.dockSnowHeight(atX: x) * 0.6)
            }
            return CGPoint(x: d.minX < scene.size.width / 2 ? d.maxX + 50 : d.minX - 50, y: 0)
        }
        return CGPoint(x: scene.size.width * 0.85, y: 0)
    }

    func groundDidChange() {
        guard case .standing = phase, let d = scene.dockRect, d.width >= d.height else { return }
        if root.position.x < d.minX || root.position.x > d.maxX {
            melt()
        } else if abs(root.position.y - (d.maxY + 1)) > 30 {
            root.position.y = d.maxY + 1 + scene.dockSnowHeight(atX: root.position.x) * 0.6
        }
    }

    private func stackY(_ index: Int) -> CGFloat {
        var y = balls[0].radius
        if index == 0 { return y }
        for i in 1...index { y += balls[i - 1].radius + balls[i].radius - 4 }
        return y
    }

    private func ball(_ role: Role) -> Ball? { balls.first { $0.role == role } }

    // MARK: Building

    private func makeBall(radius r: CGFloat) -> SKShapeNode {
        let node = SKShapeNode(circleOfRadius: r)
        node.fillColor = NSColor(calibratedRed: 0.82, green: 0.87, blue: 0.96, alpha: 1)
        node.strokeColor = NSColor(calibratedRed: 0.60, green: 0.68, blue: 0.83, alpha: 1)
        node.lineWidth = 1
        let highlight = SKShapeNode(circleOfRadius: r * 0.84)
        highlight.fillColor = .white
        highlight.strokeColor = .clear
        highlight.position = CGPoint(x: -r * 0.12, y: r * 0.12)
        highlight.zPosition = 0.4
        node.addChild(highlight)
        // A few specks make the rolling visible.
        for _ in 0..<3 {
            let speck = SKShapeNode(circleOfRadius: 0.9)
            speck.fillColor = NSColor(calibratedRed: 0.72, green: 0.79, blue: 0.9, alpha: 1)
            speck.strokeColor = .clear
            let a = CGFloat.random(in: 0...(2 * .pi)), d = CGFloat.random(in: 0...(r * 0.6))
            speck.position = CGPoint(x: cos(a) * d, y: sin(a) * d)
            speck.name = "speck"
            speck.zPosition = 0.6
            node.addChild(speck)
        }
        return node
    }

    private func build() {
        root.removeAllChildren()
        root.removeAllActions()
        root.alpha = 1
        root.setScale(1)
        root.position = groundPoint()
        facing = root.position.x > scene.size.width / 2 ? -1 : 1
        balls = [Ball(role: .bottom, radius: 21, node: makeBall(radius: 21)),
                 Ball(role: .middle, radius: 15, node: makeBall(radius: 15)),
                 Ball(role: .head, radius: 10.5, node: makeBall(radius: 10.5))]
        phase = .building

        // Snowballs roll onto the Dock one at a time and stack up.
        var delay: TimeInterval = 0
        let startX = -facing * 170
        for (i, b) in balls.enumerated() {
            b.node.position = CGPoint(x: startX, y: b.radius)
            b.node.alpha = 0
            b.node.zPosition = CGFloat(i)
            root.addChild(b.node)
            let roll = SKAction.group([.moveTo(x: 0, duration: 1.3),
                                       .rotate(byAngle: -facing * 170 / b.radius, duration: 1.3)])
            roll.timingMode = .easeOut
            var steps: [SKAction] = [.wait(forDuration: delay), .fadeIn(withDuration: 0.2), roll,
                                     .rotate(toAngle: 0, duration: 0.15, shortestUnitArc: true)]
            if i > 0 {
                let y = stackY(i)
                let up = SKAction.moveTo(y: y + 10, duration: 0.3); up.timingMode = .easeOut
                let down = SKAction.moveTo(y: y, duration: 0.15); down.timingMode = .easeIn
                steps += [up, down]
            }
            b.node.run(.sequence(steps))
            delay += 1.7
        }
        root.run(.sequence([.wait(forDuration: delay + 0.4), .run { [weak self] in self?.decorate() }]))
    }

    private func decorate() {
        guard let mid = ball(.middle), let head = ball(.head) else {
            phase = .standing(until: scene.now + 600)
            return
        }
        var parts: [SKNode] = []

        // Scarf, then he puts it on.
        let red = NSColor(calibratedRed: 0.86, green: 0.16, blue: 0.22, alpha: 1)
        let scarf = SKShapeNode(rectOf: CGSize(width: mid.radius * 1.9, height: 6), cornerRadius: 3)
        scarf.fillColor = red; scarf.strokeColor = red.blended(withFraction: 0.3, of: .black) ?? red
        scarf.position = CGPoint(x: 0, y: mid.radius - 2.5)
        scarf.zPosition = 3
        let tail = SKShapeNode(rectOf: CGSize(width: 5, height: 13), cornerRadius: 2)
        tail.fillColor = red; tail.strokeColor = scarf.strokeColor
        tail.position = CGPoint(x: facing * mid.radius * 0.45, y: mid.radius - 9)
        tail.zRotation = facing * 0.15
        tail.zPosition = 3
        mid.node.addChild(scarf); mid.node.addChild(tail)
        parts += [scarf, tail]

        // Coal buttons.
        for y in [3.0, -4.5] as [CGFloat] {
            let b = SKShapeNode(circleOfRadius: 1.4)
            b.fillColor = NSColor(white: 0.12, alpha: 1); b.strokeColor = .clear
            b.position = CGPoint(x: 0, y: y); b.zPosition = 2
            mid.node.addChild(b); parts.append(b)
        }

        // Stick arms; the one on the facing side throws, the other waves.
        func arm(side: CGFloat) -> SKShapeNode {
            let path = CGMutablePath()
            path.move(to: .zero); path.addLine(to: CGPoint(x: 17, y: 7))
            path.move(to: CGPoint(x: 11, y: 4.5)); path.addLine(to: CGPoint(x: 14, y: 10))
            let a = SKShapeNode(path: path)
            a.strokeColor = NSColor(calibratedRed: 0.42, green: 0.27, blue: 0.14, alpha: 1)
            a.lineWidth = 2; a.lineCap = .round
            a.position = CGPoint(x: side * mid.radius * 0.85, y: 2)
            a.xScale = side
            a.zPosition = -0.3
            mid.node.addChild(a)
            return a
        }
        let throwing = arm(side: facing), waving = arm(side: -facing)
        throwArm = throwing; waveArm = waving
        parts += [throwing, waving]

        // Face.
        for x in [-3.6, 3.6] as [CGFloat] {
            let eye = SKShapeNode(circleOfRadius: 1.5)
            eye.fillColor = NSColor(white: 0.1, alpha: 1); eye.strokeColor = .clear
            eye.position = CGPoint(x: x + facing * 1, y: 2.5); eye.zPosition = 2
            head.node.addChild(eye); parts.append(eye)
        }
        let carrotPath = CGMutablePath()
        carrotPath.move(to: CGPoint(x: 0, y: 1.8)); carrotPath.addLine(to: CGPoint(x: 0, y: -1.8))
        carrotPath.addLine(to: CGPoint(x: facing * 10, y: -0.6)); carrotPath.closeSubpath()
        let carrot = SKShapeNode(path: carrotPath)
        carrot.fillColor = NSColor(calibratedRed: 0.97, green: 0.52, blue: 0.12, alpha: 1)
        carrot.strokeColor = NSColor(calibratedRed: 0.8, green: 0.38, blue: 0.06, alpha: 1)
        carrot.lineWidth = 0.6
        carrot.position = CGPoint(x: facing * 1.5, y: -1)
        carrot.zPosition = 2
        carrot.name = "carrot"
        head.node.addChild(carrot); parts.append(carrot)

        for (i, part) in parts.enumerated() {
            part.alpha = 0
            part.run(.sequence([.wait(forDuration: Double(i) * 0.08), .fadeIn(withDuration: 0.3)]))
        }
        root.run(.sequence([.wait(forDuration: Double(parts.count) * 0.08 + 0.4),
                            .run { [weak self] in self?.wave(times: 3) }]))

        phase = .standing(until: scene.now + .random(in: 600...1100))
        nextThrow = scene.now + (Self.quickThrows ? 1.5 : .random(in: 15...40))
        nextWave = scene.now + .random(in: 60...150)
    }

    private func wave(times: Int) {
        guard let arm = waveArm else { return }
        let once = SKAction.sequence([.rotate(byAngle: 0.6, duration: 0.22), .rotate(byAngle: -0.6, duration: 0.22)])
        arm.run(.repeat(once, count: times))
        animatingUntil = max(animatingUntil, scene.now + 0.5 * Double(times) + 0.3)
    }

    // MARK: Snowball fight

    private func throwSnowball() {
        guard let arm = throwArm, ball(.middle) != nil,
              let target = scene.pickSnowballTarget(awayFrom: root.position) else { return }
        animatingUntil = scene.now + 3
        arm.run(.sequence([.rotate(byAngle: 1.1, duration: 0.35),
                           .rotate(byAngle: -1.7, duration: 0.12),
                           .rotate(byAngle: 0.6, duration: 0.3)]))
        root.run(.sequence([.wait(forDuration: 0.45), .run { [weak self, weak arm] in
            guard let self, let arm, arm.parent != nil else { return }
            let hand = arm.convert(CGPoint(x: 17, y: 7), to: self.scene)
            self.scene.launchSnowball(from: hand, to: target)
        }]))
    }

    // MARK: Clicks

    /// Clicking bursts one snowball at a time. Bottom: he drops a level.
    /// Middle: his head tumbles into the snow. Head: it bursts.
    func handleClick(at p: CGPoint) {
        guard case .standing = phase else { return }
        let local = CGPoint(x: p.x - root.position.x, y: p.y - root.position.y)
        guard let hit = balls.last(where: { hypot(local.x - $0.node.position.x, local.y - $0.node.position.y) <= $0.radius + 4 }) else { return }

        let center = CGPoint(x: root.position.x + hit.node.position.x, y: root.position.y + hit.node.position.y)
        scene.burst(at: center, radius: hit.radius)
        hit.node.removeFromParent()
        balls.removeAll { $0 === hit }

        if hit.role == .middle, let head = ball(.head) {
            balls.removeAll { $0 === head }
            tumble(head, by: facing * .random(in: 35...60))
        }
        if balls.isEmpty {
            phase = .absent(until: scene.now + .random(in: 40...80))
            return
        }
        animatingUntil = scene.now + 0.6
        for (i, b) in balls.enumerated() {
            let y = stackY(i)
            guard abs(b.node.position.y - y) > 0.5 else { continue }
            let drop = SKAction.moveTo(y: y, duration: 0.25); drop.timingMode = .easeIn
            let squash = SKAction.sequence([.scaleX(to: 1.1, y: 0.9, duration: 0.07), .scale(to: 1, duration: 0.1)])
            b.node.run(.sequence([drop, squash]))
        }
    }

    /// Detaches a ball and lets it roll off onto the ground, then melt.
    private func tumble(_ b: Ball, by dx: CGFloat) {
        b.node.move(toParent: scene.effects)
        let groundY = root.position.y + b.radius * root.yScale
        let fall = SKAction.group([.moveBy(x: dx, y: groundY - b.node.position.y, duration: 0.7),
                                   .rotate(byAngle: -dx / b.radius, duration: 0.7)])
        fall.timingMode = .easeIn
        b.node.run(.sequence([fall, .wait(forDuration: 5), .fadeOut(withDuration: 3), .removeFromParent()]))
    }

    // MARK: Melting

    /// The carrot falls, the head slides off, and the rest slumps into the snow.
    private func melt() {
        phase = .melting
        if let head = ball(.head) {
            if let carrot = head.node.childNode(withName: "carrot") {
                carrot.move(toParent: scene.effects)
                let drop = SKAction.group([.moveTo(y: root.position.y + 2, duration: 0.8),
                                           .rotate(byAngle: -facing * 1.4, duration: 0.8)])
                drop.timingMode = .easeIn
                carrot.run(.sequence([.wait(forDuration: 0.3), drop, .wait(forDuration: 6),
                                      .fadeOut(withDuration: 2), .removeFromParent()]))
            }
            root.run(.sequence([.wait(forDuration: 1.8), .run { [weak self] in
                guard let self, let head = self.ball(.head) else { return }
                self.balls.removeAll { $0 === head }
                self.tumble(head, by: self.facing * 30)
            }]))
        }
        let slump = SKAction.group([.scaleX(to: 1.3, y: 0.25, duration: 9), .fadeOut(withDuration: 9.5)])
        slump.timingMode = .easeIn
        root.run(.sequence([.wait(forDuration: 3.2), slump, .run { [weak self] in
            guard let self else { return }
            self.root.removeAllChildren()
            self.root.setScale(1)
            self.root.alpha = 1
            self.balls.removeAll()
            self.phase = .absent(until: self.scene.now + .random(in: 150...320))
        }]))
    }
}
