//
//  HardwareCapabilities.swift
//  Twanotch
//

import AVFoundation
import Combine
import Defaults
import IOKit.ps
import SwiftUI

/// Detects which hardware-backed features this Mac can actually drive. Desktop Macs such as the
/// Mac mini have no internal battery, no keyboard backlight and often no built-in camera, and
/// external displays usually do not expose brightness control. When `hideUnsupportedFeatures` is on,
/// the UI hides those features instead of showing controls that cannot work.
final class HardwareCapabilities: ObservableObject {
    static let shared = HardwareCapabilities()

    @Published private(set) var hasBattery: Bool
    // Brightness starts as supported and only flips once the helper answers, so a slow or
    // unreachable helper never hides the HUD on Macs that do have these controls.
    @Published private(set) var hasScreenBrightness = true
    @Published private(set) var hasKeyboardBacklight = true
    @Published private(set) var hasCamera: Bool
    @Published private(set) var hideUnsupported: Bool

    private var cancellables = Set<AnyCancellable>()
    private var brightnessRefreshTask: Task<Void, Never>?

    private init() {
        hasBattery = Self.detectInternalBattery()
        hasCamera = WebcamManager.hasConnectedCamera
        hideUnsupported = Defaults[.hideUnsupportedFeatures]

        Defaults.publisher(.hideUnsupportedFeatures, options: [])
            .receive(on: RunLoop.main)
            .sink { [weak self] change in self?.hideUnsupported = change.newValue }
            .store(in: &cancellables)

        // Track camera hardware directly; WebcamManager.cameraAvailable also turns false on
        // permission or session errors, which says nothing about whether a camera exists.
        Publishers.Merge(
            NotificationCenter.default.publisher(for: .AVCaptureDeviceWasConnected),
            NotificationCenter.default.publisher(for: .AVCaptureDeviceWasDisconnected)
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in self?.hasCamera = WebcamManager.hasConnectedCamera }
        .store(in: &cancellables)

        // Brightness support depends on which display is main (e.g. an Apple display on a Mac mini).
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.refreshBrightnessSupport() }
            .store(in: &cancellables)

        refreshBrightnessSupport()
    }

    /// Battery indicator, power notifications and the Battery settings tab.
    var showsBattery: Bool { !hideUnsupported || hasBattery }
    /// Display brightness HUD; brightness keys go to macOS when hidden.
    var showsScreenBrightness: Bool { !hideUnsupported || hasScreenBrightness }
    /// Keyboard backlight HUD; backlight keys go to macOS when hidden.
    var showsKeyboardBacklight: Bool { !hideUnsupported || hasKeyboardBacklight }
    /// Mirror (camera preview) button and its settings.
    var showsMirror: Bool { !hideUnsupported || hasCamera }

    /// Names of the features detected as unsupported on this Mac, for display in Settings.
    var unsupportedFeatureNames: [String] {
        var names: [String] = []
        if !hasBattery { names.append(String(localized: "Battery")) }
        if !hasScreenBrightness { names.append(String(localized: "Display brightness")) }
        if !hasKeyboardBacklight { names.append(String(localized: "Keyboard backlight")) }
        if !hasCamera { names.append(String(localized: "Mirror")) }
        return names
    }

    /// Asks the helper which brightness controls exist. A newer refresh cancels an older one, and
    /// unanswered queries keep the previous value and are retried a few times.
    func refreshBrightnessSupport() {
        brightnessRefreshTask?.cancel()
        brightnessRefreshTask = Task { @MainActor [weak self] in
            for attempt in 0..<3 {
                if attempt > 0 {
                    try? await Task.sleep(for: .seconds(2))
                }
                guard !Task.isCancelled else { return }
                let screen = await XPCHelperClient.shared.isScreenBrightnessAvailable()
                let keyboard = await XPCHelperClient.shared.isKeyboardBrightnessAvailable()
                guard !Task.isCancelled, let self else { return }
                if let screen { self.hasScreenBrightness = screen }
                if let keyboard { self.hasKeyboardBacklight = keyboard }
                if screen != nil && keyboard != nil { return }
            }
        }
    }

    private static func detectInternalBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return false }

        return sources.contains { source in
            guard let description = IOPSGetPowerSourceDescription(info, source)?
                .takeUnretainedValue() as? [String: Any]
            else { return false }
            return description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
    }
}
