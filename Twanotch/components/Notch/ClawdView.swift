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
        }
    }
}

struct ClawdView: View {
    let activity: ClawdActivity
    /// The box Clawd is fitted into, keeping square pixels.
    let size: CGSize
    @ObservedObject private var sprites = ClawdSprites.shared

    var body: some View {
        Group {
            if let animation = sprites.animations[activity] ?? sprites.animations[.idle] {
                TimelineView(.periodic(from: .now, by: 1.0 / 12)) { context in
                    Canvas { canvas, canvasSize in
                        draw(animation, at: context.date.timeIntervalSinceReferenceDate, in: canvas, size: canvasSize)
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
