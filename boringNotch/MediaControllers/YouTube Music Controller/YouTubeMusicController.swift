//
//  YouTubeMusicController.swift
//  boringNotch
//
//  Created By Alexander on 2025-03-30.
//  Modified by Pranav on 2025-06-16.
//

import Foundation
import Combine
import SwiftUI

final class YouTubeMusicController: MediaControllerProtocol {
    // MARK: - Published Properties
    @Published var playbackState = PlaybackState(
        bundleIdentifier: YouTubeMusicConfiguration.default.bundleIdentifier
    )

    private var artworkFetchTask: Task<Void, Never>?
    /// imageSrc of the artwork currently fetched or being fetched; only touched on the main actor.
    private var currentArtworkSrc: String?

    var playbackStatePublisher: AnyPublisher<PlaybackState, Never> {
        $playbackState.eraseToAnyPublisher()
    }

    var supportsVolumeControl: Bool {
        return true
    }

    var supportsFavorite: Bool { true }

    func setFavorite(_ favorite: Bool) async {
        do {
            let token = try await authManager.authenticate()
            let isFavorite = await MainActor.run { playbackState.isFavorite }
            if favorite && !isFavorite {
                _ = try await httpClient.toggleLike(token: token)
            } else if !favorite && isFavorite {
                _ = try await httpClient.toggleLike(token: token)
            }
            try? await Task.sleep(for: .milliseconds(150))
            await updatePlaybackInfo()
        } catch {
            print("[YouTubeMusicController] Failed to set favorite: \(error)")
        }
    }

    // MARK: - Private Properties
    private let configuration: YouTubeMusicConfiguration
    private let httpClient: YouTubeMusicHTTPClient
    private let authManager: YouTubeMusicAuthManager
    private var webSocketClient: YouTubeMusicWebSocketClient?
    /// Identifies the current WebSocket client so callbacks from replaced clients can be ignored.
    private var webSocketToken: UUID?
    
    private var updateTask: Task<Void, Never>?
    private var appStateObserver: Task<Void, Never>?
    private var reconnectDelay: TimeInterval = 1.0
    
    // MARK: - Initialization
    init(configuration: YouTubeMusicConfiguration = .default) {
        self.configuration = configuration
        self.httpClient = YouTubeMusicHTTPClient(baseURL: configuration.baseURL)
        self.authManager = YouTubeMusicAuthManager(httpClient: httpClient)
        
        setupAppStateObserver()
        
        Task {
            await initializeIfAppActive()
        }
    }

    deinit {
        appStateObserver?.cancel()
        updateTask?.cancel()
    }
    
    // MARK: - MediaControllerProtocol Implementation
    func play() async { await sendCommand(endpoint: "/play", method: "POST") }
    
    func pause() async { await sendCommand(endpoint: "/pause", method: "POST") }
    
    func togglePlay() async {
        if !isActive() { launchApp() }
        await sendCommand(endpoint: "/toggle-play", method: "POST")
    }
    
    func nextTrack() async { await sendCommand(endpoint: "/next", method: "POST") }

    func previousTrack() async { await sendCommand(endpoint: "/previous", method: "POST") }
    
    func seek(to time: Double) async {
        let payload = ["seconds": time]
        await sendCommand(endpoint: "/seek-to", method: "POST", body: payload)
    }

    func setVolume(_ level: Double) async {
        let clampedLevel = max(0.0, min(1.0, level))
        let volumePercentage = Int(clampedLevel * 100)
        let payload = ["volume": volumePercentage]
        await sendCommand(endpoint: "/volume", method: "POST", body: payload)
    }
    func fetchShuffleState() async { await sendCommand(endpoint: "/shuffle", method: "GET", refresh: false) }
    func fetchRepeatMode() async { await sendCommand(endpoint: "/repeat-mode", method: "GET", refresh: false) }
    
    func toggleShuffle() async { await sendCommand(endpoint: "/shuffle", method: "POST") }
    func toggleRepeat() async { await sendCommand(endpoint: "/switch-repeat", method: "POST") }

    nonisolated func isActive() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == configuration.bundleIdentifier
        }
    }
    
    func updatePlaybackInfo() async {
        guard isActive() else {
            await resetPlaybackState()
            return
        }
        
        do {
            let token = try await authManager.authenticate()
            let response = try await httpClient.getPlaybackInfo(token: token)
            await updatePlaybackState(with: response)
            // Fetch like state if supported
            do {
                let likeResp = try await httpClient.getLikeState(token: token)
                // A missing state or a DISLIKE (no separate dislike UI yet) both count as not favorited.
                let isFavorite = likeResp.state?.uppercased() == "LIKE"
                await MainActor.run { playbackState.isFavorite = isFavorite }
            } catch {
                // Don't treat it as an error if the like endpoint doesn't exist — just skip
            }
        } catch YouTubeMusicError.authenticationRequired {
            await authManager.invalidateToken()
        } catch {
            print("[YouTubeMusicController] Failed to update playback info: \(error)")
        }
    }
    
    // MARK: - Private Methods
    private func setupAppStateObserver() {
        appStateObserver = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    let launchNotifications = NSWorkspace.shared.notificationCenter.notifications(
                        named: NSWorkspace.didLaunchApplicationNotification
                    )
                    
                    for await notification in launchNotifications {
                        await self?.handleAppLaunched(notification)
                    }
                }
                
                group.addTask {
                    let terminateNotifications = NSWorkspace.shared.notificationCenter.notifications(
                        named: NSWorkspace.didTerminateApplicationNotification
                    )
                    
                    for await notification in terminateNotifications {
                        await self?.handleAppTerminated(notification)
                    }
                }
            }
        }
    }
    
    private func handleAppLaunched(_ notification: Notification) async {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == configuration.bundleIdentifier else {
            return
        }
        
        await initializeIfAppActive()
    }
    
    private func handleAppTerminated(_ notification: Notification) async {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == configuration.bundleIdentifier else {
            return
        }
        
        Task { @MainActor in
            stopPeriodicUpdates()
        }
        
        await tearDownWebSocket()
        
        await resetPlaybackState()
    }
    
    private func initializeIfAppActive() async {
        guard isActive() else { return }
        
        do {
            let token = try await authManager.authenticate()
            await setupWebSocketIfPossible(token: token)
            await startPeriodicUpdates()
            await updatePlaybackInfo()
        } catch {
            print("[YouTubeMusicController] Failed to initialize: \(error)")
            await scheduleReconnect()
        }
    }
    
    @MainActor
    private func setupWebSocketIfPossible(token: String) async {
        guard let wsURL = WebSocketURLBuilder.buildURL(from: configuration.baseURL) else {
            print("[YouTubeMusicController] Failed to build WebSocket URL")
            return
        }
        
        let clientToken = UUID()
        let client = YouTubeMusicWebSocketClient(
            onMessage: { [weak self] data in
                await self?.handleWebSocketMessage(data, clientToken: clientToken)
            },
            onDisconnect: { [weak self] in
                await self?.handleWebSocketDisconnect(clientToken: clientToken)
            }
        )
        
        // Replace the previous client first. Its onDisconnect is ignored because the token no longer matches.
        let previousClient = webSocketClient
        webSocketClient = client
        webSocketToken = clientToken
        await previousClient?.disconnect()
        
        do {
            try await client.connect(to: wsURL, with: token)
            stopPeriodicUpdates() // WebSocket will provide real-time updates
        } catch {
            if webSocketToken == clientToken {
                webSocketClient = nil
                webSocketToken = nil
            }
            print("[YouTubeMusicController] WebSocket connection failed: \(error)")
            await scheduleReconnect()
        }
    }
    
    @MainActor
    private func tearDownWebSocket() async {
        let client = webSocketClient
        webSocketClient = nil
        webSocketToken = nil
        await client?.disconnect()
    }
    
    @MainActor
    private func handleWebSocketMessage(_ data: Data, clientToken: UUID) async {
        guard clientToken == webSocketToken else { return }
        // The connection is only considered healthy once the server actually sends something.
        reconnectDelay = configuration.reconnectDelay.lowerBound
        
        guard let message = WebSocketMessage(from: data) else {
            if let response = try? JSONDecoder().decode(PlaybackResponse.self, from: data) {
                await updatePlaybackState(with: response)
            }
            return
        }
        switch message.type {
        case .playerInfo, .videoChanged, .playerStateChanged:
            if let data = message.extractData(),
               let response = PlaybackResponse.from(websocketData: data) {
                await updatePlaybackState(with: response)
            }

        case .positionChanged:
            guard let data = message.extractData() else { return }

            var position: Double? = nil
            if let pos = data["position"] as? Double {
                position = pos
            } else if let elapsed = data["elapsedSeconds"] as? Double {
                position = elapsed
            }
            guard let newPosition = position else { return }

            var copied = playbackState
            copied.currentTime = newPosition
            copied.lastUpdated = Date()
            if copied != playbackState { playbackState = copied }

        case .repeatChanged:
            guard let data = message.extractData() else { return }
            var copy = playbackState

            if let repeatStr = data["repeat"] as? String {
                switch repeatStr.uppercased() {
                case "NONE": copy.repeatMode = .off
                case "ALL": copy.repeatMode = .all
                case "ONE": copy.repeatMode = .one
                default: break
                }
            }
            copy.lastUpdated = Date()
            if copy != playbackState { playbackState = copy }

        case .shuffleChanged:
            guard let data = message.extractData() else { return }
            var copy = playbackState
            if let shuffle = data["shuffle"] as? Bool { copy.isShuffled = shuffle }
            else if let shuffle = data["isShuffled"] as? Bool { copy.isShuffled = shuffle }
            copy.lastUpdated = Date()
            if copy != playbackState { playbackState = copy }

        case .volumeChanged:
            guard let data = message.extractData() else { return }
            var copy = playbackState
            if let volume = data["volume"] as? Double {
                copy.volume = volume / 100.0
            } else if let volume = data["volume"] as? Int {
                copy.volume = Double(volume) / 100.0
            }
            copy.lastUpdated = Date()
            if copy != playbackState { playbackState = copy }
        }
    }
    
    @MainActor
    private func handleWebSocketDisconnect(clientToken: UUID) async {
        // A replaced or torn-down client must not wipe the current one.
        guard clientToken == webSocketToken else { return }
        webSocketClient = nil
        webSocketToken = nil
        await startPeriodicUpdates() // Fallback to polling
        await scheduleReconnect()
    }
    
    @MainActor
    private func scheduleReconnect() async {
        let delay = reconnectDelay
        try? await Task.sleep(for: .seconds(delay))
        reconnectDelay = min(delay * 2, configuration.reconnectDelay.upperBound)
        
        if isActive() {
            await initializeIfAppActive()
        }
    }
    
    @MainActor
    private func startPeriodicUpdates() async {
        guard isActive() && webSocketClient == nil else { return }
        
        stopPeriodicUpdates()
        
        let interval = configuration.updateInterval
        updateTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                await self?.updatePlaybackInfo()
            }
        }
    }
    
    @MainActor
    private func stopPeriodicUpdates() {
        updateTask?.cancel()
        updateTask = nil
    }

    func pollPlaybackState() async {
        if !isActive() {
            return
        }
        
        await fetchRepeatMode()
        await fetchShuffleState()
        await updatePlaybackInfo()
    }
    
    private func sendCommand(
        endpoint: String,
        method: String = "POST",
        body: (any Codable & Sendable)? = nil,
        refresh: Bool = true
    ) async {
        do {
            let token = try await authManager.authenticate()
            
            let data = try await httpClient.sendCommand(
                endpoint: endpoint,
                method: method,
                body: body,
                token: token
            )
            // Lightweight endpoint-specific parsing
            if endpoint == "/shuffle" {
                let reportedState = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["state"] as? Bool
                await MainActor.run {
                    if let reportedState {
                        playbackState.isShuffled = reportedState
                    } else if method != "GET" {
                        // Only a toggle request may flip the flag; a read never does.
                        playbackState.isShuffled.toggle()
                    }
                }
            } else if endpoint == "/repeat-mode" {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let mode = json["mode"] as? String { await updateRepeatMode(mode) }
                }
            }  else if endpoint == "/switch-repeat" {
                await MainActor.run {
                    // Find next repeat mode
                    let nextMode: RepeatMode
                    switch playbackState.repeatMode {
                    case .off: nextMode = .all
                    case .all: nextMode = .one
                    case .one: nextMode = .off
                    }
                    playbackState.repeatMode = nextMode
                }
            } else if refresh {
                let hasWebSocket = await MainActor.run { webSocketClient != nil }
                if !hasWebSocket {
                    try? await Task.sleep(for: .milliseconds(100))
                    await updatePlaybackInfo()
                }
            }
        } catch YouTubeMusicError.authenticationRequired {
            await authManager.invalidateToken()
        } catch {
            print("[YouTubeMusicController] Command failed: \(error)")
        }
    }
    
    @MainActor
    private func updatePlaybackState(with response: PlaybackResponse) async {
        var newState = playbackState
        
        newState.isPlaying = !response.isPaused

        if let title = response.title {
            newState.title = title
        }

        if let artist = response.artist {
            newState.artist = artist
        }

        if let album = response.album {
            newState.album = album
        }

        if let elapsed = response.elapsedSeconds {
            newState.currentTime = elapsed
        }

        if let duration = response.songDuration {
            newState.duration = duration
        }

        newState.lastUpdated = Date()
        
        if let shuffled = response.isShuffled {
            newState.isShuffled = shuffled
        }
        
        if let mode = response.repeatMode {
            switch mode {
            case 0: newState.repeatMode = .off
            case 1: newState.repeatMode = .all
            case 2: newState.repeatMode = .one
            default: break
            }
        }

        if let volume = response.volume {
            newState.volume = volume / 100.0
        }

        if newState != playbackState {
            playbackState = newState
        }

        if let artworkURL = response.imageSrc, artworkURL != currentArtworkSrc {
            artworkFetchTask?.cancel()
            artworkFetchTask = nil
            currentArtworkSrc = artworkURL

            if let url = URL(string: artworkURL) {
                artworkFetchTask = Task {
                    do {
                        let data = try await ImageService.shared.fetchImageData(from: url)
                        await MainActor.run { [weak self] in
                            guard let self, !Task.isCancelled, self.currentArtworkSrc == artworkURL else { return }
                            self.playbackState.artwork = data
                        }
                    } catch {
                        // Allow a retry on the next update unless a newer artwork superseded this one.
                        await MainActor.run { [weak self] in
                            guard let self, self.currentArtworkSrc == artworkURL else { return }
                            self.currentArtworkSrc = nil
                        }
                    }
                }
            }
        }
    }

    @MainActor
    private func resetPlaybackState() {
        artworkFetchTask?.cancel()
        artworkFetchTask = nil
        currentArtworkSrc = nil
        playbackState = PlaybackState(
            bundleIdentifier: configuration.bundleIdentifier,
            isPlaying: false
        )
    }
    
    private func launchApp() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: configuration.bundleIdentifier) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    @MainActor
    private func updateRepeatMode(_ mode: String) {
        var target: RepeatMode? = nil
        switch mode {
            case "NONE": target = .off
            case "ALL": target = .all
            case "ONE": target = .one
            default: break
        }
        if let target, target != playbackState.repeatMode { playbackState.repeatMode = target }
    }
    
}
