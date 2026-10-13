//
//  ClaudeHooksInstaller.swift
//  TwanotchXPCHelper
//
//  Adds or removes the Claude Code hooks that send permission requests, questions and activity to the notch.
//  The sandboxed app cannot write ~/.claude/settings.json, so the helper does it. JavaScriptCore does
//  the merge so key order and the two-space layout Claude Code writes stay as they were.
//

import Foundation
import JavaScriptCore

enum ClaudeHooksInstaller {
    /// Returns nil on success, or a message describing why settings.json was left alone.
    static func configure(install: Bool, port: Int, token: String) -> String? {
        let settingsURL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/settings.json")
            .resolvingSymlinksInPath()
        let fileManager = FileManager.default

        var original = ""
        if fileManager.fileExists(atPath: settingsURL.path) {
            do {
                original = try String(contentsOf: settingsURL, encoding: .utf8)
            } catch {
                return "Could not read \(settingsURL.path): \(error.localizedDescription)"
            }
        } else if !install {
            return nil
        }

        guard let context = JSContext() else { return "JavaScriptCore is unavailable" }
        var failure: String?
        context.exceptionHandler = { _, exception in
            failure = exception?.toString() ?? "Unknown error"
        }
        context.evaluateScript(mergeScript)
        let result = context.objectForKeyedSubscript("update")?.call(withArguments: [
            original, install, "http://127.0.0.1:\(port)", token,
        ])
        if let failure { return "Could not update settings.json: \(failure)" }
        guard let updated = result?.toString(), result?.isString == true else {
            return "Could not update settings.json"
        }
        guard updated != original else { return nil }

        do {
            if original.isEmpty {
                try fileManager.createDirectory(
                    at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            } else {
                // Keep the file as it was before Twanotch first touched it; later writes only add or remove our hooks.
                let backupURL = settingsURL.appendingPathExtension("twanotch-backup")
                if !fileManager.fileExists(atPath: backupURL.path) {
                    try original.write(to: backupURL, atomically: true, encoding: .utf8)
                }
            }
            try updated.write(to: settingsURL, atomically: true, encoding: .utf8)
            return nil
        } catch {
            return "Could not write \(settingsURL.path): \(error.localizedDescription)"
        }
    }

    /// Removes every hook whose URL points at Twanotch, then adds the current ones when installing.
    /// Returns the text unchanged when there is nothing to do.
    private static let mergeScript = """
        function update(text, install, base, token) {
          const settings = text.trim() ? JSON.parse(text) : {};
          if (settings === null || typeof settings !== 'object' || Array.isArray(settings)) {
            throw new Error('settings.json is not a JSON object');
          }
          const hadHooks = Object.prototype.hasOwnProperty.call(settings, 'hooks');
          const hooks = hadHooks && settings.hooks && typeof settings.hooks === 'object' ? settings.hooks : {};
          const isOurs = (hook) => hook && typeof hook.url === 'string' && hook.url.indexOf('/twanotch/') !== -1;
          let removed = false;
          for (const event of Object.keys(hooks)) {
            if (!Array.isArray(hooks[event])) continue;
            hooks[event] = hooks[event].filter((group) => {
              if (!group || !Array.isArray(group.hooks) || !group.hooks.some(isOurs)) return true;
              removed = true;
              group.hooks = group.hooks.filter((hook) => !isOurs(hook));
              return group.hooks.length > 0;
            });
            if (hooks[event].length === 0) delete hooks[event];
          }
          if (!install && !removed) return text;
          if (install) {
            const hook = (path, timeout) => ({
              type: 'http', url: base + path, headers: { 'X-Twanotch-Token': token }, timeout: timeout,
            });
            (hooks.PermissionRequest = hooks.PermissionRequest || []).push(
              { matcher: '*', hooks: [hook('/twanotch/permission', 300)] });
            (hooks.PreToolUse = hooks.PreToolUse || []).push(
              { matcher: 'AskUserQuestion', hooks: [hook('/twanotch/question', 60)] });
            // Activity only, answered at once: when Claude starts, keeps working, and stops.
            for (const event of ['UserPromptSubmit', 'PreToolUse', 'Stop', 'StopFailure', 'SessionEnd']) {
              const group = { hooks: [hook('/twanotch/event', 5)] };
              if (event === 'PreToolUse') group.matcher = '*';
              (hooks[event] = hooks[event] || []).push(group);
            }
          }
          if (Object.keys(hooks).length > 0 || hadHooks) settings.hooks = hooks;
          const newline = text === '' || text.endsWith('\\n') ? '\\n' : '';
          return JSON.stringify(settings, null, 2) + newline;
        }
        """
}
