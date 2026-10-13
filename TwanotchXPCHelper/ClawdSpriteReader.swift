//
//  ClawdSpriteReader.swift
//  TwanotchXPCHelper
//
//  Reads the Clawd pixel sprites from the Claude desktop app installed on this Mac, so Twanotch can
//  animate Clawd without shipping Anthropic's artwork. The sandboxed app cannot read another app's
//  bundle, so the helper does it. Returns nil when Claude is not installed or its format changed.
//

import Foundation
import JavaScriptCore

enum ClawdSpriteReader {
    /// LookingAround, Waving and Excited play while idle, Laptop while Claude works, and Walking
    /// carries Clawd along the closed notch.
    static let names = ["LookingAround", "Waving", "Excited", "Laptop", "Walking"]

    private static let archivePaths = [
        "/Applications/Claude.app/Contents/Resources/app.asar",
        NSHomeDirectory() + "/Applications/Claude.app/Contents/Resources/app.asar",
    ]

    /// JSON `{name: {w, h, fps, palette, ax, ay, frames}}`; each frame is one base-36 palette index
    /// per pixel, row by row, with "." for transparent.
    static func read() -> Data? {
        for path in archivePaths {
            if let literal = spriteTable(in: path), let json = decode(literal) {
                return json
            }
        }
        return nil
    }

    /// The sprite table is an object literal `{LookingAround:{cat:"Core",w:24,...},...}` inside the
    /// app's bundled JavaScript; find it by a sprite name rather than the minified names around it.
    private static func spriteTable(in path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped),
              let marker = data.range(of: Data("LookingAround:{cat:".utf8))
        else { return nil }

        let open = UInt8(ascii: "{"), close = UInt8(ascii: "}")
        let searchLimit = 4 << 20
        var start: Int?
        var depth = 0
        var index = marker.lowerBound - 1
        while index >= max(data.startIndex, marker.lowerBound - searchLimit) {
            let byte = data[index]
            if byte == close {
                depth += 1
            } else if byte == open {
                if depth == 0 {
                    start = index
                    break
                }
                depth -= 1
            }
            index -= 1
        }
        guard let start else { return nil }

        depth = 0
        index = start
        while index < min(data.endIndex, start + searchLimit) {
            let byte = data[index]
            if byte == open {
                depth += 1
            } else if byte == close {
                depth -= 1
                if depth == 0 {
                    return String(data: data[start...index], encoding: .utf8)
                }
            }
            index += 1
        }
        return nil
    }

    private static func decode(_ literal: String) -> Data? {
        guard let context = JSContext() else { return nil }
        var failed = false
        context.exceptionHandler = { _, _ in failed = true }
        context.evaluateScript(decodeScript)
        let result = context.objectForKeyedSubscript("decode")?.call(withArguments: [literal, names])
        guard !failed, let json = result?.toString(), result?.isString == true, json != "{}" else { return nil }
        return Data(json.utf8)
    }

    /// Base frame plus per-frame deltas, the way the desktop app decodes them. The anchor is the bottom
    /// centre of `a0`, where Clawd stands, so different animations line up.
    private static let decodeScript = """
        function decode(literal, names) {
          const table = (new Function('return (' + literal + ')'))();
          const out = {};
          for (const name of names) {
            const t = table[name];
            if (!t || typeof t.base !== 'string' || !Array.isArray(t.deltas)) continue;
            const px = Array.from(t.base, (c) => (c === '.' ? -1 : parseInt(c, 36)));
            const frames = [px.slice()];
            for (const delta of t.deltas) {
              if (delta) {
                for (const cell of delta.split(',')) {
                  const k = cell.length - 1;
                  px[parseInt(cell.slice(0, k), 36)] = cell[k] === '.' ? -1 : parseInt(cell[k], 36);
                }
              }
              frames.push(px.slice());
            }
            const a = Array.isArray(t.a0) && t.a0[2] > 0 ? t.a0 : [0, 0, t.w, t.h];
            out[name] = {
              w: t.w, h: t.h, fps: t.fps, palette: t.palette,
              ax: a[0] + a[2] / 2, ay: a[1] + a[3],
              frames: frames.map((f) => f.map((v) => (v < 0 ? '.' : v.toString(36))).join('')),
            };
          }
          return JSON.stringify(out);
        }
        """
}
