//  BrightnessManager.swift
//  boringNotch
//
//  Created by JeanLouis on 08/22/24.

import AppKit

final class BrightnessManager: ObservableObject {
	static let shared = BrightnessManager()

	@Published private(set) var rawBrightness: Float = 0
	@Published private(set) var animatedBrightness: Float = 0
	@Published private(set) var lastChangeAt: Date = .distantPast

	private let visibleDuration: TimeInterval = 1.2
	private let client = XPCHelperClient.shared
	private var pendingDelta: Float = 0
	private var isApplying = false

	private init() { refresh() }

	var shouldShowOverlay: Bool { Date().timeIntervalSince(lastChangeAt) < visibleDuration }

	func refresh() {
		Task { @MainActor in
			if let current = await client.currentScreenBrightness() {
				publish(brightness: current, touchDate: false)
			}
		}
	}

	@MainActor func setRelative(delta: Float) {
		// Key repeats accumulate here and are applied one batch at a time, so steps are never lost.
		pendingDelta += delta
		guard !isApplying else { return }
		isApplying = true
		Task { @MainActor in
			defer { isApplying = false }
			while pendingDelta != 0 {
				let step = pendingDelta
				pendingDelta = 0
				let starting = await client.currentScreenBrightness() ?? rawBrightness
				let target = max(0, min(1, starting + step))
				let ok = await client.setScreenBrightness(target)
				if ok {
					publish(brightness: target, touchDate: true)
				} else {
					refresh()
				}
				BoringViewCoordinator.shared.toggleSneakPeek(status: true, type: .brightness, value: CGFloat(target))
			}
		}
	}

	func setAbsolute(value: Float) {
		let clamped = max(0, min(1, value))
		Task { @MainActor in
			let ok = await client.setScreenBrightness(clamped)
			if ok {
				publish(brightness: clamped, touchDate: true)
			} else {
				refresh()
			}
		}
	}

	private func publish(brightness: Float, touchDate: Bool) {
		DispatchQueue.main.async {
			if self.rawBrightness != brightness || touchDate {
				if touchDate { self.lastChangeAt = Date() }
				self.rawBrightness = brightness
				self.animatedBrightness = brightness
			}
		}
	}
}

// (DisplayServices helpers moved into XPC helper)

// MARK: - Keyboard Backlight Controller
final class KeyboardBacklightManager: ObservableObject {
	static let shared = KeyboardBacklightManager()

	@Published private(set) var rawBrightness: Float = 0
	@Published private(set) var lastChangeAt: Date = .distantPast

	private let visibleDuration: TimeInterval = 1.2
	private let client = XPCHelperClient.shared
	private var pendingDelta: Float = 0
	private var isApplying = false

	private init() { refresh() }

	var shouldShowOverlay: Bool { Date().timeIntervalSince(lastChangeAt) < visibleDuration }

	func refresh() {
		Task { @MainActor in
			if let current = await client.currentKeyboardBrightness() {
				publish(brightness: current, touchDate: false)
			}
		}
	}

	@MainActor func setRelative(delta: Float) {
		// Key repeats accumulate here and are applied one batch at a time, so steps are never lost.
		pendingDelta += delta
		guard !isApplying else { return }
		isApplying = true
		Task { @MainActor in
			defer { isApplying = false }
			while pendingDelta != 0 {
				let step = pendingDelta
				pendingDelta = 0
				let starting = await client.currentKeyboardBrightness() ?? rawBrightness
				let target = max(0, min(1, starting + step))
				let ok = await client.setKeyboardBrightness(target)
				if ok {
					publish(brightness: target, touchDate: true)
				} else {
					refresh()
				}
				BoringViewCoordinator.shared.toggleSneakPeek(
					status: true,
					type: .backlight,
					value: CGFloat(target)
				)
			}
		}
	}

	func setAbsolute(value: Float) {
		let clamped = max(0, min(1, value))
		Task { @MainActor in
			let ok = await client.setKeyboardBrightness(clamped)
			if ok {
				publish(brightness: clamped, touchDate: true)
			} else {
				refresh()
			}
		}
	}

	private func publish(brightness: Float, touchDate: Bool) {
		DispatchQueue.main.async {
			if self.rawBrightness != brightness || touchDate {
				if touchDate { self.lastChangeAt = Date() }
				self.rawBrightness = brightness
			}
		}
	}
}

