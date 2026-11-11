import SpriteKit
import AppKit

/// Piles are stored as a height map with one column per this many points.
let pileColumnWidth: CGFloat = 3
private let gravity: CGFloat = -620

final class Flake {
    let node: SKSpriteNode
    let vy: CGFloat
    let depth: CGFloat
    var phase: CGFloat
    let swayAmp: CGFloat
    let swaySpeed: CGFloat
    /// Only "near" flakes collide; far ones drift past, which reads as depth.
    let canLand: Bool

    init(node: SKSpriteNode, vy: CGFloat, depth: CGFloat, phase: CGFloat, swayAmp: CGFloat, swaySpeed: CGFloat, canLand: Bool) {
        self.node = node; self.vy = vy; self.depth = depth; self.phase = phase
        self.swayAmp = swayAmp; self.swaySpeed = swaySpeed; self.canLand = canLand
    }
}

/// Anything falling under gravity: shed snow, snapped icicles, burst snowballs.
final class Debris {
    let node: SKNode
    var v: CGVector
    let spin: CGFloat
    /// Snow clumps settle on whatever they fall onto; icicles just fall.
    let canLand: Bool
    /// The pile a clump came from. It can't land back there, or a spill would
    /// just drop straight back onto the snow it left.
    let source: ObjectIdentifier?
    init(node: SKNode, v: CGVector, spin: CGFloat, canLand: Bool = false, source: ObjectIdentifier? = nil) {
        self.node = node; self.v = v; self.spin = spin; self.canLand = canLand; self.source = source
    }
}

final class StuckFlake {
    let node: SKSpriteNode
    let baseAlpha: CGFloat
    var remaining: Double
    init(node: SKSpriteNode, remaining: Double) { self.node = node; self.baseAlpha = node.alpha; self.remaining = remaining }
}

final class Projectile {
    let node: SKNode
    let start: CGPoint
    let v: CGVector
    let duration: CGFloat
    let target: CGPoint
    var t: CGFloat = 0
    init(node: SKNode, start: CGPoint, v: CGVector, duration: CGFloat, target: CGPoint) {
        self.node = node; self.start = start; self.v = v; self.duration = duration; self.target = target
    }
}

/// An icicle is one shared pre-drawn texture stretched to its current length, so
/// every icicle on screen batches into a single draw instead of a stroked shape each.
@MainActor
final class Icicle {
    let node = SKSpriteNode(texture: Art.icicle)
    let x: CGFloat
    let maxLength: CGFloat
    let width: CGFloat
    var length: CGFloat = 0.6

    init(x: CGFloat, maxLength: CGFloat, width: CGFloat) {
        self.x = x; self.maxLength = maxLength; self.width = width
        node.anchorPoint = CGPoint(x: 0.5, y: 1)   // hangs down from the window's edge
        node.zPosition = 1
        redrawIfNeeded()
    }

    func redrawIfNeeded() {
        node.size = CGSize(width: width, height: max(0.5, length))
    }
}

/// The snow resting on one surface.
@MainActor
final class PileState {
    var surface: Surface
    var localRect: CGRect
    /// Sits at the surface's top-left corner; holds the snow image and the icicles.
    let node = SKNode()
    /// The pile's outline, drawn into a small image whenever it changes. A sprite
    /// costs SpriteKit one quad per frame, where a filled shape node re-copies its
    /// whole triangulated outline every frame.
    let sprite = SKSpriteNode()
    var heights: [CGFloat]
    var visible: [Bool]
    /// Heights may have changed since the last redraw.
    var dirty = false
    /// The surface moved, resized or got covered: redraw on the next chance regardless.
    var shapeChanged = true
    /// Heights as of the last redraw, to skip redraws nobody could see.
    var builtHeights: [CGFloat] = []
    var lastBuild: TimeInterval = 0
    var stillSince: TimeInterval
    var nextIcicle: TimeInterval
    var icicles: [Icicle] = []
    let capJitter = CGFloat.random(in: 0.8...1.0)
    /// Snow that arrived where the pile was already full; released bit by bit as falling clumps.
    var overflow: CGFloat = 0
    var nextSpill: TimeInterval = 0
    /// How far the rounded corner falls below the flat top edge, per column.
    private(set) var drops: [CGFloat] = []
    /// Max-height multiplier per column: snow stacks less on the steep part of a corner.
    private(set) var slopeCaps: [CGFloat] = []
    /// Extra depth snow can bank up into the curve of a rounded corner, per column,
    /// so a full pile squares the corner off a little instead of tracing it exactly.
    private(set) var cornerFill: [CGFloat] = []

    init(surface: Surface, localRect: CGRect, now: TimeInterval) {
        self.surface = surface
        self.localRect = localRect
        let n = Self.columns(for: localRect.width)
        heights = Array(repeating: 0, count: n)
        visible = Array(repeating: true, count: n)
        stillSince = now
        nextIcicle = now
        computeProfile(width: localRect.width)
        node.zPosition = 5
        sprite.anchorPoint = .zero
        sprite.isHidden = true
        node.addChild(sprite)
    }

    private static let fill = NSColor.white.cgColor
    private static let rim = NSColor(calibratedRed: 0.70, green: 0.78, blue: 0.92, alpha: 0.9).cgColor

    /// Draws the snow outline (white body with a light-blue rim) into the sprite.
    func setPath(_ path: CGPath, scale: CGFloat) {
        let box = path.boundingBoxOfPath
        guard !path.isEmpty, box.width > 0, box.height > 0 else {
            sprite.isHidden = true
            return
        }
        let frame = box.insetBy(dx: -1, dy: -1).offsetBy(dx: 0, dy: 1)
        let w = Int(ceil(frame.width * scale)), h = Int(ceil(frame.height * scale))
        let bytesPerRow = w * 4
        var pixels = Data(count: bytesPerRow * h)
        let drawn: Bool = pixels.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -frame.minX, y: -frame.minY)
            // The rim: the same shape in light blue, 1 pt higher, peeking out along the top.
            ctx.saveGState()
            ctx.translateBy(x: 0, y: 1)
            ctx.addPath(path)
            ctx.setFillColor(Self.rim)
            ctx.fillPath()
            ctx.restoreGState()
            ctx.addPath(path)
            ctx.setFillColor(Self.fill)
            ctx.fillPath()
            return true
        }
        guard drawn else { return }
        // Hand SpriteKit the pixels as they are. Making the texture from a CGImage
        // would have it redraw the whole image into a buffer of its own first.
        let texture = SKTexture(data: pixels, size: CGSize(width: w, height: h), flipped: true)
        texture.filteringMode = .linear
        sprite.texture = texture
        sprite.size = CGSize(width: CGFloat(w) / scale, height: CGFloat(h) / scale)
        sprite.position = frame.origin
        sprite.isHidden = false
    }

    static func columns(for width: CGFloat) -> Int { max(1, Int(ceil(width / pileColumnWidth))) }

    var averageHeight: CGFloat { heights.reduce(0, +) / CGFloat(heights.count) }
    var hasSnow: Bool { heights.contains { $0 > 0.05 } }

    func reset(width: CGFloat) {
        let n = Self.columns(for: width)
        heights = Array(repeating: 0, count: n)
        visible = Array(repeating: true, count: n)
        computeProfile(width: width)
        overflow = 0
        shapeChanged = true
    }

    var cornerRadius: CGFloat { surface.kind.cornerRadius }

    /// Traces the rounded top corners: a quarter circle of radius r at each end.
    func computeProfile(width w: CGFloat) {
        let r = min(cornerRadius, w / 2)
        drops = []
        slopeCaps = []
        cornerFill = []
        for c in 0..<heights.count {
            let x = min(w, (CGFloat(c) + 0.5) * pileColumnWidth)
            let d = max(0, min(x, w - x))
            if r > 0, d < r {
                let dx = r - d
                let dy = sqrt(max(0, r * r - dx * dx))
                drops.append(r - dy)
                // Even the steepest part holds a little, and snow fills about half of
                // the corner's dip: rounded, but softer than the window's own curve.
                slopeCaps.append(0.35 + 0.65 * dy / r)
                cornerFill.append((r - dy) * 0.5)
            } else {
                drops.append(0)
                slopeCaps.append(1)
                cornerFill.append(0)
            }
        }
    }

    /// Keeps the snow when a window is resized from its right edge.
    func resample(width: CGFloat) {
        let n = Self.columns(for: width)
        if n != heights.count {
            let old = heights
            heights = (0..<n).map { old[min(old.count - 1, $0 * old.count / n)] }
            visible = Array(repeating: true, count: n)
        }
        computeProfile(width: width)
        for c in 0..<n { heights[c] = min(heights[c], surface.kind.maxPile * slopeCaps[c] + cornerFill[c]) }
        shapeChanged = true
    }
}

@MainActor
final class SnowScene: SKScene {
    let screenFrame: CGRect
    /// Desired frame rate: full speed for fast motion, less for gentle snow, a trickle at rest.
    var onFrameRateChange: ((Int) -> Void)?
    var onSnowmanAreaChange: (([CGRect]) -> Void)?

    private(set) var now: TimeInterval = 0
    let effects = SKNode()
    private(set) var dockRect: CGRect?

    private var lastUpdate: TimeInterval = 0
    private var flakes: [Flake] = []
    private var debris: [Debris] = []
    private var stuck: [StuckFlake] = []
    private var projectiles: [Projectile] = []
    private var piles: [String: PileState] = [:]
    private var landables: [PileState] = []
    private var occluders: [(order: Int, rect: CGRect)] = []
    private var menuBarRect: CGRect?
    private var hostsSnowman = false
    private var snowman: Snowman?
    private var spawnCarry: Double = 0
    private var windPhase = CGFloat.random(in: 0...10)
    private var lastFrameRate: Int?
    /// Number of clumps spilled off full piles (used by the preview as a sanity check).
    private(set) var spillCount = 0
    private var lastSnowmanArea: [CGRect] = []
    /// Number of falling clumps that settled on another surface (preview sanity check).
    private(set) var clumpLandings = 0
    /// The display's top refresh rate. Frame rates are picked to divide it evenly:
    /// 40 fps on a 60 Hz monitor alternates 1- and 2-refresh frames, which judders.
    var displayMaxFPS = 60
    /// What this screen saw last time, so moves on other screens cost nothing here.
    private var lastMine: [Surface]?
    private var lastDock: Surface?
    /// Rotates which dirty piles get their path rebuilt, a few per frame.
    private var rebuildCursor = 0

    init(screenFrame: CGRect) {
        self.screenFrame = screenFrame
        super.init(size: screenFrame.size)
        backgroundColor = .clear
        scaleMode = .resizeFill
        anchorPoint = .zero
        effects.zPosition = 15
        addChild(effects)
    }
    required init?(coder: NSCoder) { fatalError("not supported") }

    func toLocal(_ r: CGRect) -> CGRect { r.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY) }

    // MARK: Surfaces

    func apply(surfaces all: [Surface]) {
        let settings = Settings.shared
        var mine = all.filter { $0.rect.intersects(screenFrame) }
        // A bank of snow along the bottom edge of the screen, like snow gathering at
        // the bottom of a window pane. It's in front of app windows (maximized
        // windows reach the very bottom and would hide it), but behind the Dock.
        // Clumps spilling off windows and the Dock end up here too.
        mine.append(Surface(id: "ground", kind: .ground,
                            rect: CGRect(x: screenFrame.minX, y: screenFrame.minY - 1, width: screenFrame.width, height: 1),
                            order: -500))
        let dock = all.first { $0.kind == .dock }
        // Surfaces arrive for every screen. Skip the work when nothing on this one changed.
        if mine == lastMine, dock == lastDock { return }
        lastMine = mine
        lastDock = dock

        occluders = mine.filter { $0.kind == .window || $0.kind == .widget || $0.kind == .dock }
            .map { ($0.order, toLocal($0.rect)) }
        menuBarRect = settings.surfaceEnabled(.menuBar) ? mine.first { $0.kind == .menuBar }.map { toLocal($0.rect) } : nil

        dockRect = dock.flatMap { screenFrame.intersects($0.rect) ? toLocal($0.rect) : nil }
        if let dock {
            hostsSnowman = screenFrame.contains(CGPoint(x: dock.rect.midX, y: dock.rect.midY))
        } else {
            hostsSnowman = screenFrame.origin == .zero
        }

        var seen = Set<String>()
        for s in mine where s.kind != .menuBar && settings.surfaceEnabled(s.kind) {
            let local = toLocal(s.rect)
            // A window whose top is at or above the screen top (full screen) has nowhere to hold snow.
            guard local.maxY < size.height - 4 || s.kind == .dock else { continue }
            seen.insert(s.id)

            if let pile = piles[s.id] {
                let old = pile.surface.rect
                let moved = abs(old.minX - s.rect.minX) > 0.5 || abs(old.maxY - s.rect.maxY) > 0.5
                if moved && s.kind != .dock {
                    // Dragging a window: the snow slides off and tumbles down.
                    let velocity = CGVector(dx: (s.rect.minX - old.minX) / 0.15, dy: (s.rect.maxY - old.maxY) / 0.15)
                    shed(pile, velocity: velocity)
                    pile.reset(width: local.width)
                    pile.stillSince = now
                } else if abs(old.width - s.rect.width) > 0.5 || moved {
                    pile.resample(width: local.width)
                    snapIcicles(of: pile, beyond: local.width)
                }
                pile.surface = s
                pile.localRect = local
            } else {
                let pile = PileState(surface: s, localRect: local, now: now)
                addChild(pile.node)
                piles[s.id] = pile
            }
        }
        // Closed, hidden or disabled: the whole pile drops at once.
        for (id, pile) in piles where !seen.contains(id) {
            shed(pile, velocity: .zero)
            pile.node.removeFromParent()
            piles[id] = nil
        }

        for pile in piles.values {
            pile.node.position = CGPoint(x: pile.localRect.minX, y: pile.localRect.maxY)
            for icicle in pile.icicles {
                icicle.node.position = CGPoint(x: icicle.x, y: -pile.localRect.height)
            }
            recomputeVisibility(pile)
            pile.shapeChanged = true
        }
        landables = piles.values.sorted { $0.surface.order < $1.surface.order }
        updateSnowmanPresence()
        snowman?.groundDidChange()
    }

    func settingsChanged() {
        lastMine = nil   // surface toggles change what's kept, so the next apply must run
        let s = Settings.shared
        if !s.icicles {
            for pile in piles.values { snapIcicles(of: pile, beyond: -1) }
        }
        updateSnowmanPresence()
    }

    func shakeOffAllSnow() {
        for pile in piles.values { shed(pile, velocity: CGVector(dx: 0, dy: 300)) }
        for s in stuck { s.node.removeFromParent() }
        stuck.removeAll()
    }

    private func updateSnowmanPresence() {
        let want = hostsSnowman && Settings.shared.snowman
        if want, snowman == nil {
            snowman = Snowman(scene: self)
        } else if !want, let sm = snowman {
            sm.dismiss()
            snowman = nil
        }
    }

    func isOccluded(_ p: CGPoint, order: Int) -> Bool {
        occluders.contains { $0.order < order && $0.rect.contains(p) }
    }

    private func recomputeVisibility(_ pile: PileState) {
        let r = pile.localRect
        for c in 0..<pile.heights.count {
            let p = CGPoint(x: r.minX + (CGFloat(c) + 0.5) * pileColumnWidth, y: r.maxY - pile.drops[c] + 3)
            pile.visible[c] = p.x <= r.maxX && p.x >= 0 && p.x <= size.width && !isOccluded(p, order: pile.surface.order)
        }
        for icicle in pile.icicles {
            icicle.node.isHidden = isOccluded(CGPoint(x: r.minX + icicle.x, y: r.minY - 3), order: pile.surface.order)
        }
    }

    // MARK: Frame loop

    /// Debug only (`--frame-log <path>`): frame gaps for this screen, in ms.
    var frameLog: [Double]?
    var frameLogPath: String?
    var wallLast: CFTimeInterval = 0

    override func update(_ currentTime: TimeInterval) {
        if frameLog != nil {
            let t = CACurrentMediaTime()
            if wallLast > 0 { frameLog!.append((t - wallLast) * 1000) }
            wallLast = t
            // negative marker = requested fps + 1000·(debris>40) + 2000·projectile + 4000·snowman animating
            let why = (debris.count > 40 ? 1000 : 0) + (projectiles.isEmpty ? 0 : 2000) + ((snowman?.isAnimating ?? false) ? 4000 : 0)
            frameLog!.append(-Double((lastFrameRate ?? 0) + why))
            if frameLog!.count >= 2400, let path = frameLogPath {
                try? frameLog!.map { String(format: "%.2f", $0) }.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
                frameLog = nil
            }
        }
        let raw = lastUpdate == 0 ? 1.0 / 60 : max(0, currentTime - lastUpdate)
        lastUpdate = currentTime
        now += min(raw, 0.5)
        let dt = CGFloat(min(raw, 1.0 / 20))

        let settings = Settings.shared
        let intensity = settings.intensity
        windPhase += dt * 0.12
        let wind = (sin(windPhase) * 0.8 + sin(windPhase * 2.3 + 1) * 0.35) * intensity.windStrength

        if settings.snowing { spawnFlakes(dt: dt, intensity: intensity) } else { spawnCarry = 0 }
        stepFlakes(dt: dt, wind: wind)
        stepDebris(dt: dt)
        stepStuck(dt: dt)
        stepProjectiles(dt: dt)
        stepPiles(dt: dt, settings: settings)
        snowman?.update()
        report(settings: settings)
    }

    private func report(settings: Settings) {
        // A handful of slow clumps sliding off a pile doesn't need full speed; a window
        // shedding its whole pile, a snowball or a blizzard does.
        // Only quick motion needs 60 fps: a snowball in flight or a window shedding its
        // whole pile. The snowman's rolling and waving, a blizzard, or a splat melting
        // over several seconds look the same at ~40; slowly drifting snow at ~24 (film rate).
        let fast = debris.count > 40 || !projectiles.isEmpty
        let lively = (snowman?.isAnimating ?? false) || (settings.snowing && settings.intensity == .blizzard)
        let busy = settings.snowing || !flakes.isEmpty || !debris.isEmpty || !effects.children.isEmpty
        let rate = fast ? fastRate : (lively ? evenRate(near: 40) : (busy ? evenRate(near: 24) : restRate))
        if rate != lastFrameRate {
            lastFrameRate = rate
            onFrameRateChange?(rate)
        }
        let area = snowman?.clickAreas ?? []
        if area != lastSnowmanArea {
            lastSnowmanArea = area
            onSnowmanAreaChange?(area)
        }
    }

    private var fastRate: Int { min(60, displayMaxFPS) }
    /// The even divisor of the display rate closest to 40: 30 on 60 Hz, 40 on 120 Hz.
    /// The even divisor of the display rate closest to `target`, so frames are evenly
    /// spaced: near 24 that's 24 on 120 Hz, 25 on 75 Hz and 30 on 60 Hz.
    private func evenRate(near target: Double) -> Int {
        let hz = max(24, displayMaxFPS)
        // Ties go to the faster rate: 75 Hz near 30 gives 37 fps, not 25.
        return hz / max(1, Int((Double(hz) / target - 0.01).rounded()))
    }
    private var restRate: Int { displayMaxFPS % 5 == 0 ? 5 : max(1, displayMaxFPS / 12) }

    // MARK: Flakes

    private func spawnFlakes(dt: CGFloat, intensity: Intensity) {
        spawnCarry += intensity.spawnRate * Double(size.width / 1440) * Double(dt)
        while spawnCarry >= 1 {
            spawnCarry -= 1
            if flakes.count < intensity.maxFlakes { addFlake(speed: intensity.speed) }
        }
    }

    private func addFlake(speed: CGFloat) {
        let depth = CGFloat.random(in: 0.3...1)
        let node = SKSpriteNode(texture: Art.flake)
        // Slightly larger than strictly realistic: fewer, bigger flakes read as the
        // same snowfall for less work per frame.
        let d = (1.8 + 5.8 * depth * depth) * .random(in: 0.8...1.2)
        node.size = CGSize(width: d, height: d)
        node.alpha = 0.45 + 0.55 * depth
        node.zPosition = depth > 0.6 ? 11 : 10   // two layers so sprites batch
        node.position = CGPoint(x: .random(in: -40...(size.width + 40)), y: size.height + 10)
        addChild(node)
        flakes.append(Flake(node: node,
                            vy: (26 + 64 * depth) * .random(in: 0.85...1.15) * speed,
                            depth: depth,
                            phase: .random(in: 0...(2 * .pi)),
                            swayAmp: .random(in: 5...20) * depth,
                            swaySpeed: .random(in: 0.6...1.7),
                            canLand: depth > 0.6))
    }

    private func stepFlakes(dt: CGFloat, wind: CGFloat) {
        var i = 0
        while i < flakes.count {
            let f = flakes[i]
            let p0 = f.node.position
            f.phase += f.swaySpeed * dt
            var p = CGPoint(x: p0.x + (wind * (0.35 + 0.65 * f.depth) + cos(f.phase) * f.swayAmp) * dt,
                            y: p0.y - f.vy * dt)
            var gone = p.y < -12
            if !gone && f.canLand {
                if let (pile, column) = landing(x: p.x, from: p0.y, to: p.y) {
                    deposit(on: pile, column: column, amount: f.node.size.width * 0.3)
                    gone = true
                } else if let bar = menuBarRect, stuck.count < 90, bar.contains(p), CGFloat.random(in: 0...1) < 0.012 {
                    // A dusting that clings to the menu bar for a while, then melts.
                    f.node.position = p
                    stuck.append(StuckFlake(node: f.node, remaining: .random(in: 20...45)))
                    flakes.swapAt(i, flakes.count - 1)
                    flakes.removeLast()
                    continue
                }
            } else if !gone, landOnGround(x: p.x, from: p0.y, to: p.y) {
                // Far flakes drift past windows, but everything ends up at the bottom.
                deposit(on: piles["ground"]!, column: Int(p.x / pileColumnWidth), amount: f.node.size.width * 0.3)
                gone = true
            }
            if gone {
                f.node.removeFromParent()
                flakes.swapAt(i, flakes.count - 1)
                flakes.removeLast()
                continue
            }
            if p.x < -60 { p.x += size.width + 120 } else if p.x > size.width + 60 { p.x -= size.width + 120 }
            f.node.position = p
            i += 1
        }
    }

    /// The pile whose snow surface the path from y0 down to y1 crosses at x, front-most first.
    /// Clumps (`sure`) always stick; single flakes only sometimes do.
    private func landing(x: CGFloat, from y0: CGFloat, to y1: CGFloat, sure: Bool = false,
                         excluding source: ObjectIdentifier? = nil) -> (PileState, Int)? {
        for pile in landables {
            let r = pile.localRect
            guard x >= r.minX, x < r.maxX, y1 < r.maxY + 40 else { continue }
            let c = Int((x - r.minX) / pileColumnWidth)
            guard c < pile.heights.count, pile.visible[c] else { continue }
            let top = r.maxY - pile.drops[c] + pile.heights[c]
            guard y0 >= top, y1 < top else { continue }
            // A front surface blocks anything behind it, even the clump's own pile.
            if let source, ObjectIdentifier(pile) == source { return nil }
            if sure || CGFloat.random(in: 0...1) < pile.surface.kind.landingChance {
                return (pile, c)
            }
        }
        return nil
    }

    private func landOnGround(x: CGFloat, from y0: CGFloat, to y1: CGFloat) -> Bool {
        guard y1 < 30, let ground = piles["ground"] else { return false }
        let c = Int(x / pileColumnWidth)
        guard c >= 0, c < ground.heights.count, ground.visible[c] else { return false }
        let top = ground.localRect.maxY + ground.heights[c]
        return y0 >= top && y1 < top && CGFloat.random(in: 0...1) < ground.surface.kind.landingChance
    }

    /// Tallest the snow can get in one column. It rounds off at the ends and thins
    /// out on the curve of a rounded corner.
    private func capacity(of pile: PileState, column c: Int) -> CGFloat {
        let maxH = pile.surface.kind.maxPile * pile.capJitter
        let n = pile.heights.count
        let edge = CGFloat(min(c, n - 1 - c)) * pileColumnWidth + pileColumnWidth / 2
        return maxH * min(1, sqrt(edge / (maxH * 1.2))) * pile.slopeCaps[c] + pile.cornerFill[c]
    }

    private func deposit(on pile: PileState, column c0: Int, amount: CGFloat) {
        let n = pile.heights.count
        for k in -3...3 {
            let c = c0 + k
            guard c >= 0, c < n else { continue }
            let cap = capacity(of: pile, column: c)
            let before = pile.heights[c]
            let filled = before + amount * exp(-CGFloat(k * k) / 4) * 0.45
            if filled > cap { pile.overflow += filled - cap }
            pile.heights[c] = min(cap, filled)
            // A full spot that only adds to the overflow hasn't changed shape.
            if pile.heights[c] != before { pile.dirty = true }
        }
    }

    /// A full pile can't hold more. Break a clump off a full spot and let it fall,
    /// leaving a dent that new snow fills again.
    private func spill(from pile: PileState) {
        let n = pile.heights.count
        guard n > 6 else { pile.overflow = 0; return }
        let full = (0..<n).filter { pile.visible[$0] && pile.heights[$0] > 1 && pile.heights[$0] >= capacity(of: pile, column: $0) * 0.85 }
        guard !full.isEmpty else { pile.overflow = 0; return }

        // Most clumps slide off the ends, around the rounded corners; the rest drop
        // straight off the front of the pile.
        let edgeBand = Int(pile.cornerRadius / pileColumnWidth) + 4
        let nearEdges = full.filter { $0 < edgeBand || $0 >= n - edgeBand }
        let center: Int
        if !nearEdges.isEmpty, CGFloat.random(in: 0...1) < 0.6 { center = nearEdges.randomElement()! } else { center = full.randomElement()! }
        let direction: CGFloat = center < n / 2 ? -1 : 1
        let atEdge = center < edgeBand || center >= n - edgeBand

        let r = pile.localRect
        let half = Int.random(in: 1...3)
        let depth = CGFloat.random(in: 0.3...0.55)
        var removed: CGFloat = 0
        for c in max(0, center - half)...min(n - 1, center + half) {
            let falloff = 1 - CGFloat(abs(c - center)) / CGFloat(half + 1)
            let take = pile.heights[c] * depth * falloff
            pile.heights[c] -= take
            removed += take
        }
        pile.overflow = max(0, pile.overflow - removed)
        spillCount += 1
        pile.dirty = true

        let x = r.minX + (CGFloat(center) + 0.5) * pileColumnWidth
        let y = r.maxY - pile.drops[center] + pile.heights[center]
        for _ in 0..<min(8, Int(removed / 2.5) + 1) {
            let v = atEdge
                ? CGVector(dx: direction * .random(in: 25...70), dy: .random(in: -10...15))
                : CGVector(dx: .random(in: -15...15), dy: .random(in: 0...20))
            spawnChunk(at: CGPoint(x: x + .random(in: -4...4), y: y + .random(in: -2...2)), v: v, size: .random(in: 3...6.5),
                       from: pile)
        }
    }

    /// Height of the snow on the Dock at a local x, used to seat the snowman.
    func dockSnowHeight(atX x: CGFloat) -> CGFloat {
        guard let pile = piles["dock"] else { return 0 }
        let c = Int((x - pile.localRect.minX) / pileColumnWidth)
        return (0..<pile.heights.count).contains(c) ? pile.heights[c] : 0
    }

    // MARK: Piles and icicles

    private func stepPiles(dt: CGFloat, settings: Settings) {
        // Rebuilding an SKShapeNode path re-tessellates it, the priciest thing a pile
        // does. Cap it at a few piles per frame and rotate who goes first, so many
        // windows don't all rebuild on the same frame and cause a hitch.
        let interval = settings.snowing ? 0.4 : 0.6
        var budget = 4
        let n = landables.count
        if n > 0 {
            rebuildCursor %= n
            for k in 0..<n where budget > 0 {
                let pile = landables[(rebuildCursor + k) % n]
                if pile.shapeChanged || (pile.dirty && now - pile.lastBuild > interval && visiblyChanged(pile)) {
                    rebuildPath(pile)
                    budget -= 1
                }
            }
            rebuildCursor += 1
        }
        for pile in landables {
            if !settings.snowing, pile.hasSnow {
                for c in 0..<pile.heights.count where pile.heights[c] > 0 {
                    pile.heights[c] = max(0, pile.heights[c] - 0.25 * dt)
                }
                pile.dirty = true
            }
            if pile.surface.kind == .ground {
                pile.overflow = 0   // nothing below the screen's edge for clumps to fall onto
            } else if pile.overflow >= 1.5, now >= pile.nextSpill {
                pile.nextSpill = now + .random(in: 0.2...0.8)
                spill(from: pile)
            }
            guard pile.surface.kind == .window else { continue }

            // Leave a window still and icicles start to grow along its bottom edge.
            if settings.icicles, settings.snowing, now - pile.stillSince > 18, now >= pile.nextIcicle,
               pile.icicles.count < max(1, Int(pile.localRect.width / 75)), pile.localRect.minY > 40,
               pile.averageHeight > 1.2 {
                pile.nextIcicle = now + .random(in: 3...9)
                addIcicle(to: pile)
            }
            for icicle in pile.icicles {
                icicle.length = settings.snowing ? min(icicle.maxLength, icicle.length + 0.3 * dt) : icicle.length - 0.12 * dt
                icicle.redrawIfNeeded()
            }
            pile.icicles.removeAll { icicle in
                guard icicle.length <= 0.2 else { return false }
                icicle.node.removeFromParent()
                return true
            }
        }
    }

    /// Redrawing a pile means rasterizing its outline and uploading a texture, so
    /// skip it until some spot has moved by half a point, or two seconds have passed.
    private func visiblyChanged(_ pile: PileState) -> Bool {
        if now - pile.lastBuild > 2 { return true }
        let h = pile.heights, b = pile.builtHeights
        guard h.count == b.count else { return true }
        for c in 0..<h.count where abs(h[c] - b[c]) > 0.5 { return true }
        return false
    }

    private func rebuildPath(_ pile: PileState) {
        let path = CGMutablePath()
        let n = pile.heights.count
        let w = pile.localRect.width
        var c = 0
        while c < n {
            guard pile.visible[c], pile.heights[c] > 0.35 else { c += 1; continue }
            // One closed shape per visible run: along the snow's surface, then back
            // along the (possibly curved) edge it rests on.
            // Points on a straight stretch add nothing to the shape, only to the
            // tessellation cost, so only keep columns where the line bends.
            let start = c
            while c < n, pile.visible[c], pile.heights[c] > 0.35 { c += 1 }
            let last = c - 1
            let top = { (k: Int) -> CGFloat in pile.heights[k] - pile.drops[k] }
            let base = { (k: Int) -> CGFloat in -pile.drops[k] }
            let xAt = { (k: Int) -> CGFloat in min(w, (CGFloat(k) + 0.5) * pileColumnWidth) }
            path.move(to: CGPoint(x: CGFloat(start) * pileColumnWidth, y: base(start)))
            for k in start...last where k == start || k == last || abs(top(k + 1) - 2 * top(k) + top(k - 1)) > 0.12 {
                path.addLine(to: CGPoint(x: xAt(k), y: top(k)))
            }
            path.addLine(to: CGPoint(x: min(w, CGFloat(c) * pileColumnWidth), y: base(last)))
            for k in stride(from: last, through: start, by: -1)
            where k == start || k == last || abs(base(k + 1) - 2 * base(k) + base(k - 1)) > 0.05 {
                path.addLine(to: CGPoint(x: xAt(k), y: base(k)))
            }
            path.closeSubpath()
        }
        // An empty pile's sprite is hidden so SpriteKit skips it (its icicles stay).
        // Snow is a soft white shape, so 1 pixel per point is plenty even on Retina,
        // and it's a quarter of the pixels to rasterize and upload on each redraw.
        pile.setPath(path, scale: 1)
        pile.dirty = false
        pile.shapeChanged = false
        pile.builtHeights = pile.heights
        pile.lastBuild = now
    }

    private func addIcicle(to pile: PileState) {
        let r = pile.localRect
        let inset = max(6, pile.cornerRadius)
        guard r.width > inset * 2 + 10 else { return }
        let x = CGFloat.random(in: inset...(r.width - inset))
        guard !isOccluded(CGPoint(x: r.minX + x, y: r.minY - 3), order: pile.surface.order) else { return }
        let icicle = Icicle(x: x, maxLength: .random(in: 7...28), width: .random(in: 3...6))
        icicle.node.position = CGPoint(x: x, y: -r.height)
        pile.node.addChild(icicle.node)
        pile.icicles.append(icicle)
    }

    /// Moving a window snaps its icicles off. `beyond < 0` snaps them all.
    private func snapIcicles(of pile: PileState, beyond width: CGFloat) {
        pile.icicles.removeAll { icicle in
            guard width < 0 || icicle.x > width else { return false }
            icicle.node.move(toParent: self)
            if debris.count < 1800 {
                debris.append(Debris(node: icicle.node, v: CGVector(dx: .random(in: -20...20), dy: .random(in: 0...30)),
                                     spin: .random(in: -3...3)))
            } else {
                icicle.node.removeFromParent()
            }
            return true
        }
    }

    private func shed(_ pile: PileState, velocity: CGVector) {
        let r = pile.localRect
        let vx = max(-260, min(260, velocity.dx * 0.35))
        let vy = max(-100, min(200, velocity.dy * 0.2))
        var budget = 380
        for c in 0..<pile.heights.count where pile.visible[c] && pile.heights[c] > 0.6 && budget > 0 {
            let h = pile.heights[c]
            let count = Int(h / 3) + (CGFloat.random(in: 0...1) < (h / 3).truncatingRemainder(dividingBy: 1) ? 1 : 0)
            for _ in 0..<count where budget > 0 {
                budget -= 1
                spawnChunk(at: CGPoint(x: r.minX + (CGFloat(c) + 0.5) * pileColumnWidth, y: r.maxY - pile.drops[c] + .random(in: 0...h)),
                           v: CGVector(dx: vx + .random(in: -25...25), dy: vy + .random(in: 0...50)),
                           size: .random(in: 3...7), from: pile)
            }
        }
        pile.heights = Array(repeating: 0, count: pile.heights.count)
        pile.dirty = true
        snapIcicles(of: pile, beyond: -1)
    }

    // MARK: Debris, bursts, snowballs

    func spawnChunk(at p: CGPoint, v: CGVector, size d: CGFloat, from pile: PileState? = nil) {
        guard debris.count < 1800 else { return }
        let node = SKSpriteNode(texture: Art.flake)
        node.size = CGSize(width: d, height: d)
        node.position = p
        node.zPosition = 9
        addChild(node)
        debris.append(Debris(node: node, v: v, spin: 0, canLand: true, source: pile.map(ObjectIdentifier.init)))
    }

    func burst(at p: CGPoint, radius: CGFloat) {
        for _ in 0..<Int(radius * 1.4) {
            let a = CGFloat.random(in: 0...(2 * .pi))
            let speed = CGFloat.random(in: 60...220)
            let offset = CGFloat.random(in: 0...radius)
            spawnChunk(at: CGPoint(x: p.x + cos(a) * offset, y: p.y + sin(a) * offset),
                       v: CGVector(dx: cos(a) * speed, dy: sin(a) * speed + 90),
                       size: .random(in: 3...8))
        }
    }

    private func stepDebris(dt: CGFloat) {
        var i = 0
        while i < debris.count {
            let d = debris[i]
            d.v.dy += gravity * dt
            d.v.dx *= (1 - 0.6 * dt)
            let p0 = d.node.position
            let p = CGPoint(x: p0.x + d.v.dx * dt, y: p0.y + d.v.dy * dt)
            d.node.position = p
            if d.spin != 0 { d.node.zRotation += d.spin * dt }
            // A falling clump that reaches another surface's snow settles into it. If
            // that pile is already full, the extra feeds its overflow and spills on.
            if d.canLand, d.v.dy < 0, settledOnSurface(d, from: p0.y, to: p) {
                d.node.removeFromParent()
                debris.swapAt(i, debris.count - 1)
                debris.removeLast()
            } else if p.y < -40 {
                d.node.removeFromParent()
                debris.swapAt(i, debris.count - 1)
                debris.removeLast()
            } else {
                i += 1
            }
        }
    }

    private func settledOnSurface(_ d: Debris, from y0: CGFloat, to p: CGPoint) -> Bool {
        guard let (pile, column) = landing(x: p.x, from: y0, to: p.y, sure: true, excluding: d.source) else { return false }
        let size = (d.node as? SKSpriteNode)?.size.width ?? 4
        deposit(on: pile, column: column, amount: size * 0.4)
        clumpLandings += 1
        return true
    }

    private func stepStuck(dt: CGFloat) {
        stuck.removeAll { s in
            s.remaining -= Double(dt)
            if s.remaining < 3 { s.node.alpha = s.baseAlpha * CGFloat(max(0, s.remaining) / 3) }
            if s.remaining <= 0 { s.node.removeFromParent(); return true }
            return false
        }
    }

    /// Picks a visible spot on a window, icon or the Dock for the snowman to aim at.
    func pickSnowballTarget(awayFrom origin: CGPoint) -> CGPoint? {
        let candidates = landables.filter { $0.localRect.width > 40 && $0.surface.kind != .ground }
        for _ in 0..<12 {
            guard let pile = candidates.randomElement() else { return nil }
            let r = pile.localRect
            let point: CGPoint
            switch pile.surface.kind {
            case .dock:
                point = CGPoint(x: .random(in: r.minX...r.maxX), y: r.midY)
            case .desktopIcon:
                point = CGPoint(x: r.midX, y: r.maxY - min(20, r.height * 0.35))
            default:
                let depth = CGFloat.random(in: 14...max(15, min(90, r.height * 0.4)))
                point = CGPoint(x: .random(in: (r.minX + 20)...(r.maxX - 20)), y: r.maxY - depth)
            }
            guard point.x > 0, point.x < size.width, point.y > 0, point.y < size.height,
                  hypot(point.x - origin.x, point.y - origin.y) > 140,
                  !isOccluded(point, order: pile.surface.order) else { continue }
            return point
        }
        return nil
    }

    func launchSnowball(from start: CGPoint, to target: CGPoint) {
        let ball = SKShapeNode(circleOfRadius: 5)
        ball.fillColor = .white
        ball.strokeColor = NSColor(calibratedRed: 0.62, green: 0.70, blue: 0.84, alpha: 1)
        ball.lineWidth = 1
        ball.position = start
        ball.zPosition = 16
        addChild(ball)
        let g: CGFloat = -800
        let dx = target.x - start.x, dy = target.y - start.y
        let duration = 0.75 + hypot(dx, dy) / 2600
        let v = CGVector(dx: dx / duration, dy: (dy - 0.5 * g * duration * duration) / duration)
        projectiles.append(Projectile(node: ball, start: start, v: v, duration: duration, target: target))
    }

    private func stepProjectiles(dt: CGFloat) {
        let g: CGFloat = -800
        projectiles.removeAll { p in
            p.t += dt
            if p.t >= p.duration {
                p.node.removeFromParent()
                splat(at: p.target)
                return true
            }
            p.node.position = CGPoint(x: p.start.x + p.v.dx * p.t, y: p.start.y + p.v.dy * p.t + 0.5 * g * p.t * p.t)
            return false
        }
    }

    /// A snowball hit: it sticks, slides down, and melts away.
    private func splat(at p: CGPoint) {
        let blob = SKNode()
        blob.position = p
        let fill = NSColor.white
        let stroke = NSColor(calibratedRed: 0.70, green: 0.78, blue: 0.92, alpha: 0.9)
        let core = SKShapeNode(circleOfRadius: 6.5)
        core.fillColor = fill; core.strokeColor = stroke; core.lineWidth = 0.8
        blob.addChild(core)
        for _ in 0..<6 {
            let a = CGFloat.random(in: 0...(2 * .pi))
            let dot = SKShapeNode(circleOfRadius: .random(in: 2...3.5))
            dot.fillColor = fill; dot.strokeColor = stroke; dot.lineWidth = 0.6
            dot.position = CGPoint(x: cos(a) * .random(in: 6...10), y: sin(a) * .random(in: 5...8))
            dot.zPosition = -0.1
            core.zPosition = 0
            blob.addChild(dot)
        }
        effects.addChild(blob)
        let slide = SKAction.moveBy(x: 0, y: -.random(in: 40...90), duration: 8)
        slide.timingMode = .easeIn
        let melt = SKAction.sequence([.wait(forDuration: 4),
                                      .group([.fadeOut(withDuration: 4), .scaleX(to: 0.6, y: 0.4, duration: 4)])])
        blob.run(.sequence([.wait(forDuration: 1), .group([slide, melt]), .removeFromParent()]))
        for _ in 0..<8 {
            let a = CGFloat.random(in: 0...(2 * .pi))
            spawnChunk(at: p, v: CGVector(dx: cos(a) * .random(in: 40...120), dy: sin(a) * 80 + 60), size: .random(in: 2...4))
        }
    }

    // MARK: Clicks

    func handleSnowmanClick(at p: CGPoint) {
        snowman?.handleClick(at: p)
    }
}
