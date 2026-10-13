//
//  MusicBorderGlow.swift
//  Twanotch
//
//  Waves of light that flow along the notch's border while music plays, in the album art's color.
//

import SwiftUI

struct MusicBorderGlow: View {
    let shape: NotchShape
    let color: Color
    /// For the closed notch, which is only as tall as the menu bar: thinner, and kept inside the
    /// shape so the notch does not look any bigger.
    var compact = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Seconds for one wave to travel from a top corner to the middle of the bottom edge.
    private let period: TimeInterval = 1.8
    /// Waves on each half of the border at a time.
    private let waves = 2.0

    var body: some View {
        Group {
            if reduceMotion {
                // A still, even glow instead of moving waves.
                Canvas { context, size in
                    draw(in: &context, size: size, intensity: { _ in 0.35 })
                }
            } else {
                TimelineView(.animation) { timeline in
                    let time = timeline.date.timeIntervalSinceReferenceDate
                    Canvas { context, size in
                        draw(in: &context, size: size, intensity: { position in
                            waveIntensity(at: position, time: time)
                        })
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// Brightness from 0 to 1 at `position` along half the border (0 at a top corner, 1 at the
    /// bottom middle). Crests move from the corners towards the middle.
    private func waveIntensity(at position: Double, time: TimeInterval) -> Double {
        let wave = sin(2 * .pi * (position * waves - time / period))
        return pow(max(0, wave), 2)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, intensity: (Double) -> Double) {
        let path = shape.path(in: CGRect(origin: .zero, size: size))
        if compact {
            context.clip(to: path)
        }
        let visible = visibleFraction(of: size)

        context.drawLayer { glow in
            glow.addFilter(.blur(radius: compact ? 2 : 5))
            strokeWaves(path, visible: visible, in: &glow, lineWidth: compact ? 3 : 6, alpha: 0.6, intensity: intensity)
        }
        strokeWaves(path, visible: visible, in: &context, lineWidth: compact ? 1.5 : 2, alpha: 1, intensity: intensity)
    }

    /// Strokes the visible border in short pieces, each as bright as the wave is there, mirrored
    /// so both halves flow towards the bottom middle.
    private func strokeWaves(
        _ path: Path, visible: Double, in context: inout GraphicsContext,
        lineWidth: CGFloat, alpha: Double, intensity: (Double) -> Double
    ) {
        let pieces = compact ? 24 : 40
        let half = visible / 2
        let style = StrokeStyle(lineWidth: lineWidth, lineCap: .butt)
        for piece in 0..<pieces {
            let start = Double(piece) / Double(pieces)
            let end = Double(piece + 1) / Double(pieces)
            let opacity = alpha * (0.08 + 0.92 * intensity((start + end) / 2))
            let shading = GraphicsContext.Shading.color(color.opacity(opacity))
            // The path runs from the top-left corner round to the top-right one, so the right half
            // is the same distance counted back from the end.
            context.stroke(path.trimmedPath(from: start * half, to: end * half), with: shading, style: style)
            context.stroke(
                path.trimmedPath(from: visible - end * half, to: visible - start * half), with: shading, style: style)
        }
    }

    /// The share of the shape's path that is on screen. The path starts at the top-left corner
    /// and ends along the top edge, which sits against the screen edge and is never seen.
    private func visibleFraction(of size: CGSize) -> Double {
        let visible = 2 * size.height + size.width
        return visible / (visible + size.width)
    }
}
