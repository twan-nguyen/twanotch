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
            // Ask the server: the local flag may still describe the previous track.
            let isFavorite: Bool
            if let likeResp = try? await httpClient.getLikeState(token: token) {
                isFavorite = likeResp.state?.uppercased() == "LIKE"
            } else {
                isFavorite = await MainActor.run { playbackState.isFavorite }
            }
            if favorite != isFavorite {
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
    /// Single reconnect loop; only touched on the main actor.
    private var reconnectTask: Task<Void, Never>?
    /// Set when a reconnect is requested while the loop is already running, e.g. the socket drops right after connecting.
    private var reconnectRequested = false
    private var reconnectDelay: TimeInterval = 1.0

    /// Set once by stop(); every async entry point checks it so a torn-down controller never reconnects.
    private let stopLock = NSLock()
    private var stopped = false
    private var isStopped: Bool { stopLock.withLock { stopped } }
    
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
        reconnectTask?.cancel()
        artworkFetchTask?.cancel()
        // stop() normally ran already; this only covers a controller released without it.
        if let client = webSocketClient {
            Task { await client.disconnect() }
        }
    }

    /// Closes the WebSocket and cancels polling, reconnects and artwork work. Safe to call more than once.
    func stop() {
        stopLock.withLock { stopped = true }
        appStateObserver?.cancel()
        Task { @MainActor in
            reconnectTask?.cancel()
            reconnectTask = nil
            stopPeriodicUpdates()
            artworkFetchTask?.cancel()
            artworkFetchTask = nil
            await tearDownWebSocket()
        }
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
            await fetchLikeState(token: token)
        } catch YouTubeMusicError.authenticationRequired {
            await authManager.invalidateToken()
        } catch {
            print("[YouTubeMusicController] Failed to update playback info: \(error)")
        }
    }
    
    // MARK: - Private Methods
    private func fetchLikeState(token: String) async {
        do {
            let likeResp = try await httpClient.getLikeState(token: token)
            // A missing state or a DISLIKE (no separate dislike UI yet) both count as not favorited.
            let isFavorite = likeResp.state?.uppercased() == "LIKE"
            await MainActor.run { playbackState.isFavorite = isFavorite }
        } catch {
            // Don't treat it as an error if the like endpoint doesn't exist — just skip
        }
    }

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
        if await !attemptInitialize() {
            await scheduleReconnect()
        }
    }
    
    /// Returns false when the attempt failed and should be retried.
    private func attemptInitialize() async -> Bool {
        guard !isStopped, isActive() else { return true }
        
        do {
            let token = try await authManager.authenticate()
            guard !isStopped else { return true }
            let connected = await setupWebSocketIfPossible(token: token)
            await startPeriodicUpdates()
            await updatePlaybackInfo()
            return connected
        } catch {
            print("[YouTubeMusicController] Failed to initialize: \(error)")
            return false
        }
    }
    
    /// Returns false when the connection failed and should be retried.
    @MainActor
    private func setupWebSocketIfPossible(token: String) async -> Bool {
        guard !isStopped else { return true }
        guard let wsURL = WebSocketURLBuilder.buildURL(from: configuration.baseURL) else {
            print("[YouTubeMusicController] Failed to build WebSocket URL")
            return true
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
            if isStopped {
                // stop() may have run while connecting, before this client was torn down.
                await tearDownWebSocket()
                return true
            }
            stopPeriodicUpdates() // WebSocket will provide real-time updates
            return true
        } catch {
            if webSocketToken == clientToken {
                webSocketClient = nil
                webSocketToken = nil
            }
            print("[YouTubeMusicController] WebSocket connection failed: \(error)")
            return false
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
        scheduleReconnect()
    }
    
    /// Starts the retry loop unless one is already running. The loop only holds self while an attempt runs,
    /// so a released controller is not kept alive by its backoff sleep.
    @MainActor
    private func scheduleReconnect() {
        guard !isStopped else { return }
        guard reconnectTask == nil else {
            reconnectRequested = true
            return
        }
        reconnectTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let delay = await self?.nextReconnectDelay() else { return }
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self else { return }
                let succeeded = await self.attemptInitialize()
                let requested = await self.consumeReconnectRequest()
                if succeeded && !requested { break }
            }
            await self?.finishReconnect()
        }
    }
    
    @MainActor
    private func nextReconnectDelay() -> TimeInterval {
        let delay = reconnectDelay
        reconnectDelay = min(delay * 2, configuration.reconnectDelay.upperBound)
        return delay
    }
    
    @MainActor
    private func consumeReconnectRequest() -> Bool {
        defer { reconnectRequested = false }
        return reconnectRequested
    }
    
    @MainActor
    private func finishReconnect() {
        reconnectTask = nil
    }
    
    @MainActor
    private func startPeriodicUpdates() async {
        guard !isStopped, isActive() && webSocketClient == nil else { return }
        
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
        let previousTitle = newState.title
        let previousArtist = newState.artist
        
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

        // The like flag belongs to the previous track until the new state is fetched.
        let trackChanged = newState.title != previousTitle || newState.artist != previousArtist
        if trackChanged {
            newState.isFavorite = false
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

        if trackChanged && !isStopped {
            Task { [weak self] in
                guard let self, let token = try? await self.authManager.authenticate() else { return }
                await self.fetchLikeState(token: token)
            }
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
