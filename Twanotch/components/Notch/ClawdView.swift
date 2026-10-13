//
//  ClawdView.swift
//  Twanotch
//
//  Clawd, animated with the sprites of the Claude desktop app installed on this Mac: looks around,
//  waves and bounces while idle, types on a laptop while Claude Code works, and waves while a
//  prompt waits in the notch. Without the desktop app it falls back to the still mascot.
//

import SwiftUI

/// One decoded sprite: frames of palette indices, positioned around the point Clawd stands on.
private struct ClawdSprite {
    struct Run {
        let color: Int
        let rect: CGRect
    }

    let fps: Double
    let palette: [Color]
    /// Each frame as horizontal runs of one colour, in pixels relative to the anchor.
    let frames: [[Run]]
    let bounds: CGRect

    init?(_ raw: [String: Any]) {
        guard let width = raw["w"] as? Int, let height = raw["h"] as? Int, width > 0, height > 0,
              let fps = raw["fps"] as? Double, fps > 0,
              let palette = raw["palette"] as? [String],
              let ax = raw["ax"] as? Double, let ay = raw["ay"] as? Double,
              let rawFrames = raw["frames"] as? [String], !rawFrames.isEmpty
        else { return nil }

        var frames: [[Run]] = []
        for frame in rawFrames {
            let pixels = Array(frame.utf8)
            guard pixels.count == width * height else { return nil }
            var runs: [Run] = []
            for y in 0..<height {
                var x = 0
                while x < width {
                    guard let color = Self.index(pixels[y * width + x]), color < palette.count else {
                        x += 1
                        continue
                    }
                    var end = x + 1
                    while end < width, Self.index(pixels[y * width + end]) == color { end += 1 }
                    runs.append(Run(
                        color: color,
                        rect: CGRect(x: Double(x) - ax, y: Double(y) - ay, width: Double(end - x), height: 1)))
                    x = end
                }
            }
            frames.append(runs)
        }

        self.fps = fps
        self.palette = palette.map(Self.color)
        self.frames = frames
        bounds = CGRect(x: -ax, y: -ay, width: Double(width), height: Double(height))
    }

    /// "#rrggbb"; anything else is drawn in Clawd's orange.
    private static func color(_ hex: String) -> Color {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return ClaudeMascot.tint }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255)
    }

    /// Base-36 palette index, or nil for a transparent pixel.
    private static func index(_ byte: UInt8) -> Int? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return Int(byte - UInt8(ascii: "0"))
        case UInt8(ascii: "a")...UInt8(ascii: "z"): return Int(byte - UInt8(ascii: "a")) + 10
        default: return nil
        }
    }
}

/// Several sprites played back to back on one loop.
private struct ClawdAnimation {
    let frames: [(sprite: ClawdSprite, runs: [ClawdSprite.Run])]
    let durations: [Double]
    let total: Double
    let bounds: CGRect

    init?(_ sprites: [ClawdSprite]) {
        guard !sprites.isEmpty else { return nil }
        var frames: [(sprite: ClawdSprite, runs: [ClawdSprite.Run])] = []
        var durations: [Double] = []
        for sprite in sprites {
            for runs in sprite.frames {
                frames.append((sprite, runs))
                durations.append(1 / sprite.fps)
            }
        }
        self.frames = frames
        self.durations = durations
        total = durations.reduce(0, +)
        bounds = sprites.dropFirst().reduce(sprites[0].bounds) { $0.union($1.bounds) }
    }

    func frame(at time: TimeInterval) -> (sprite: ClawdSprite, runs: [ClawdSprite.Run]) {
        var t = time.truncatingRemainder(dividingBy: total)
        for (index, duration) in durations.enumerated() {
            if t < duration { return frames[index] }
            t -= duration
        }
        return frames[frames.count - 1]
    }
}

@MainActor
final class ClawdSprites: ObservableObject {
    static let shared = ClawdSprites()

    @Published fileprivate private(set) var animations: [ClawdActivity: ClawdAnimation] = [:]
    @Published fileprivate private(set) var walk: ClawdWalk?
    /// Played at each end of a walk.
    @Published fileprivate private(set) var lookAround: ClawdAnimation?
    private var loading = false

    private init() {}

    /// Reads the sprites once; a missing desktop app leaves the still mascot in place.
    func load() {
        guard animations.isEmpty, !loading else { return }
        loading = true
        Task {
            defer { loading = false }
            guard let data = await XPCHelperClient.shared.fetchClawdSprites(),
                  let raw = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]]
            else { return }
            let sprite = { (name: String) in raw[name].flatMap(ClawdSprite.init) }
            let sequences: [ClawdActivity: [String]] = [
                .idle: ["LookingAround", "Waving", "Excited"],
                .working: ["Laptop"],
                .waiting: ["Waving"],
            ]
            var animations: [ClawdActivity: ClawdAnimation] = [:]
            for (activity, names) in sequences {
                animations[activity] = ClawdAnimation(names.compactMap(sprite))
            }
            self.animations = animations
            walk = sprite("Walking").flatMap(ClawdWalk.init)
            lookAround = sprite("LookingAround").flatMap { ClawdAnimation([$0]) }
        }
    }
}

struct ClawdView: View {
    let activity: ClawdActivity
    /// The box Clawd is fitted into, keeping square pixels.
    let size: CGSize
    @ObservedObject private var sprites = ClawdSprites.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let animation = sprites.animations[activity] ?? sprites.animations[.idle] {
                if reduceMotion {
                    // A still first frame, so Clawd keeps its look without moving.
                    Canvas { canvas, canvasSize in
                        draw(animation, at: 0, in: canvas, size: canvasSize)
                    }
                } else {
                    TimelineView(.periodic(from: .now, by: 1.0 / 12)) { context in
                        Canvas { canvas, canvasSize in
                            draw(animation, at: context.date.timeIntervalSinceReferenceDate, in: canvas, size: canvasSize)
                        }
                    }
                }
            } else {
                ClaudeMascot()
                    .fill(ClaudeMascot.tint)
                    .aspectRatio(16 / 11, contentMode: .fit)
            }
        }
        .frame(width: size.width, height: size.height)
        .onAppear { sprites.load() }
        .accessibilityLabel(accessibilityLabel)
    }

    private func draw(_ animation: ClawdAnimation, at time: TimeInterval, in canvas: GraphicsContext, size: CGSize) {
        let bounds = animation.bounds
        let scale = min(size.width / bounds.width, size.height / bounds.height)
        // Stand on the bottom edge, centred.
        let origin = CGPoint(
            x: (size.width - bounds.width * scale) / 2 - bounds.minX * scale,
            y: size.height - bounds.maxY * scale)
        let (sprite, runs) = animation.frame(at: time)
        for run in runs {
            let rect = CGRect(
                x: origin.x + run.rect.minX * scale, y: origin.y + run.rect.minY * scale,
                width: run.rect.width * scale, height: run.rect.height * scale)
            canvas.fill(Path(rect), with: .color(sprite.palette[run.color]))
        }
    }

    private var accessibilityLabel: Text {
        switch activity {
        case .idle: Text("Claude is idle")
        case .working: Text("Claude is working")
        case .waiting: Text("Claude is waiting for your answer")
        }
    }
}

/// The Walking sprite cut into its parts: turning to the side, the steps facing right, and turning
/// back to the front. The side view is told apart by the shading on Clawd's back.
private struct ClawdWalk {
    typealias Frame = [ClawdSprite.Run]

    let sprite: ClawdSprite
    let intro: [Frame]
    let steps: [Frame]
    let outro: [Frame]

    init?(_ sprite: ClawdSprite) {
        let side = sprite.frames.indices.filter { index in sprite.frames[index].contains { $0.color == 1 } }
        guard let first = side.first, let last = side.last else { return nil }
        self.sprite = sprite
        intro = Array(sprite.frames[..<first])
        steps = Array(sprite.frames[first...last])
        outro = Array(sprite.frames[(last + 1)...])
    }
}

/// Clawd walking back and forth across `width`, looking around at each end; with Reduce Motion,
/// or without the desktop app's sprites, Clawd stands still at the start.
struct ClawdWalker: View {
    let width: CGFloat
    /// Height of the sprites' tallest pose, which fixes Clawd's size.
    let height: CGFloat
    @ObservedObject private var sprites = ClawdSprites.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Points a second.
    private let speed: CGFloat = 10

    var body: some View {
        Group {
            if !reduceMotion, let walk = sprites.walk, let look = sprites.lookAround {
                TimelineView(.periodic(from: .now, by: 1.0 / 24)) { context in
                    Canvas { canvas, size in
                        let scale = size.height / walk.sprite.bounds.height
                        let pose = pose(walk: walk, look: look, scale: scale,
                                        at: context.date.timeIntervalSinceReferenceDate)
                        draw(pose, scale: scale, in: canvas, size: size)
                    }
                }
            } else {
                ClawdView(activity: .idle, size: CGSize(width: height * 4 / 3, height: height))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: width, height: height)
        .onAppear { sprites.load() }
        .accessibilityLabel(Text("Claude is idle"))
    }

    private struct Pose {
        let runs: [ClawdSprite.Run]
        let palette: [Color]
        /// Left edge of the sprite's box, in points from the start of the track.
        let x: CGFloat
        let facingLeft: Bool
    }

    /// Where Clawd is and what it shows at `time`: one leg turns to the side, walks across, turns
    /// back and looks around; the next leg does the same the other way.
    private func pose(walk: ClawdWalk, look: ClawdAnimation, scale: CGFloat, at time: TimeInterval) -> Pose {
        let fps = walk.sprite.fps
        let travel = max(0, width - walk.sprite.bounds.width * scale)
        let introLength = Double(walk.intro.count) / fps
        let moveLength = Double(travel / speed)
        let outroLength = Double(walk.outro.count) / fps
        let leg = introLength + moveLength + outroLength + look.total

        let cycle = time.truncatingRemainder(dividingBy: 2 * leg)
        let goingLeft = cycle >= leg
        var t = cycle.truncatingRemainder(dividingBy: leg)
        let start: CGFloat = goingLeft ? travel : 0
        let end: CGFloat = goingLeft ? 0 : travel
        let frame = { (frames: [ClawdWalk.Frame], time: Double) in frames[min(Int(time * fps), frames.count - 1)] }

        if t < introLength {
            return Pose(runs: frame(walk.intro, t), palette: walk.sprite.palette, x: start, facingLeft: goingLeft)
        }
        t -= introLength
        if t < moveLength {
            let runs = walk.steps[Int(t * fps) % walk.steps.count]
            let x = start + (end - start) * CGFloat(t / moveLength)
            return Pose(runs: runs, palette: walk.sprite.palette, x: x, facingLeft: goingLeft)
        }
        t -= moveLength
        if t < outroLength {
            return Pose(runs: frame(walk.outro, t), palette: walk.sprite.palette, x: end, facingLeft: goingLeft)
        }
        t -= outroLength
        let (sprite, runs) = look.frame(at: t)
        return Pose(runs: runs, palette: sprite.palette, x: end, facingLeft: false)
    }

    private func draw(_ pose: Pose, scale: CGFloat, in canvas: GraphicsContext, size: CGSize) {
        // Every pose stands on the bottom edge, around the same anchor as the Walking sprite.
        let anchorX = pose.x - (sprites.walk?.sprite.bounds.minX ?? 0) * scale
        for run in pose.runs {
            let minX = pose.facingLeft ? -run.rect.maxX : run.rect.minX
            let rect = CGRect(
                x: anchorX + minX * scale, y: size.height + run.rect.minY * scale,
                width: run.rect.width * scale, height: run.rect.height * scale)
            canvas.fill(Path(rect), with: .color(pose.palette[run.color]))
        }
    }
}
