//
//  WebcamManager.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 19/08/24.
//
import AVFoundation
import SwiftUI

class WebcamManager: NSObject, ObservableObject {
    static let shared = WebcamManager()
    
    @Published var previewLayer: AVCaptureVideoPreviewLayer? {
        didSet {
            objectWillChange.send()
        }
    }
    
    private var captureSession: AVCaptureSession?
    @Published var isSessionRunning: Bool = false {
        didSet {
            objectWillChange.send()
        }
    }
    
    @Published var authorizationStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video) {
        didSet {
            objectWillChange.send()
        }
    }
    
    @Published var cameraAvailable: Bool = false {
        didSet {
            objectWillChange.send()
        }
    }

    private let sessionQueue = DispatchQueue(label: "BoringNotch.WebcamManager.SessionQueue", qos: .userInitiated)
    
    private var isCleaningUp: Bool = false

    private static let sessionStateNotifications: [Notification.Name] = [
        AVCaptureSession.runtimeErrorNotification,
        AVCaptureSession.wasInterruptedNotification,
        AVCaptureSession.didStopRunningNotification,
        AVCaptureSession.didStartRunningNotification,
    ]
    /// Whether the session should be running. Read and written only on `sessionQueue`.
    private var wantsSessionRunning = false
    
    // MARK: - Constants
    
    enum WebcamError: Error, LocalizedError {
        case deviceUnavailable
        case accessDenied
        case configurationFailed(String)
        
        var errorDescription: String? {
            switch self {
            case .deviceUnavailable:
                return "No camera devices available"
            case .accessDenied:
                return "Camera access denied"
            case .configurationFailed(let message):
                return "Camera configuration failed: \(message)"
            }
        }
    }
    
    // MARK: - Properties
    
    private override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(deviceWasDisconnected), name: .AVCaptureDeviceWasDisconnected, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(deviceWasConnected), name: .AVCaptureDeviceWasConnected, object: nil)
        checkCameraAvailability()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        
        if let session = captureSession {
            if session.isRunning {
                session.stopRunning()
            }
        }
        captureSession = nil
            
        previewLayer = nil
    }

    // MARK: - Camera Management
    
    /// Checks current authorization status and requests access if needed
    func checkAndRequestVideoAuthorization() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        DispatchQueue.main.async {
            self.authorizationStatus = status
        }
        
        switch status {
        case .authorized:
            checkCameraAvailability() // Check availability if authorized
        case .notDetermined:
            requestVideoAccess()
        case .denied, .restricted:
            NSLog("Camera access denied or restricted")
        @unknown default:
            NSLog("Unknown authorization status")
        }
    }
    
    /// Requests access to the camera
    private func requestVideoAccess() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                self?.authorizationStatus = granted ? .authorized : .denied
                if granted {
                    self?.checkCameraAvailability() // Check availability if access granted
                }
            }
        }
    }
    
    /// Whether at least one connected camera is present, regardless of permission or session state.
    static var hasConnectedCamera: Bool {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external, .builtInWideAngleCamera],
            mediaType: .video,
            position: .unspecified
        ).devices.contains { $0.isConnected }
    }

    /// Checks if any camera devices are available and sets up capture session if needed
    func checkCameraAvailability() {
        let hasAvailableDevices = Self.hasConnectedCamera
        
        DispatchQueue.main.async {
            self.cameraAvailable = hasAvailableDevices
        }
    }
    
    /// Sets up the capture session. Must be called on `sessionQueue`; returns whether setup succeeded.
    private func setupCaptureSession() -> Bool {
        // Clean up any existing session before creating a new one
        cleanupExistingSession()
        
        let session = AVCaptureSession()
        
        do {
                // Get available devices and prefer external camera if available
                let discoverySession = AVCaptureDevice.DiscoverySession(
                    deviceTypes: [.external, .builtInWideAngleCamera],
                    mediaType: .video,
                    position: .unspecified
                )
                
                guard let videoDevice = discoverySession.devices.first else {
                    NSLog("No video devices available")
                    DispatchQueue.main.async {
                        self.isSessionRunning = false
                        self.cameraAvailable = false
                    }
                    return false
                }
                
                NSLog("Using camera: \(videoDevice.localizedName)")
                
                // Lock device for configuration
                try videoDevice.lockForConfiguration()
                defer { videoDevice.unlockForConfiguration() }
                
                let videoInput = try AVCaptureDeviceInput(device: videoDevice)
                guard session.canAddInput(videoInput) else {
                    throw NSError(domain: "BoringNotch.WebcamManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cannot add video input"])
                }
                
                session.beginConfiguration()
                session.sessionPreset = .high
                session.addInput(videoInput)
                
                let videoOutput = AVCaptureVideoDataOutput()
                videoOutput.setSampleBufferDelegate(nil, queue: nil)
                if session.canAddOutput(videoOutput) {
                    session.addOutput(videoOutput)
                }
                session.commitConfiguration()
                
                self.captureSession = session
                for name in Self.sessionStateNotifications {
                    NotificationCenter.default.addObserver(self, selector: #selector(captureSessionStateChanged), name: name, object: session)
                }
                
                // Create and set up preview layer on main thread
                DispatchQueue.main.async {
                    self.cameraAvailable = true
                    let previewLayer = AVCaptureVideoPreviewLayer(session: session)
                    previewLayer.videoGravity = .resizeAspectFill
                    self.previewLayer = previewLayer
                }
                
                NSLog("Capture session setup completed successfully")
                return true
            } catch {
                NSLog("Failed to setup capture session: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.isSessionRunning = false
                    self.cameraAvailable = false
                    self.previewLayer = nil
                }
                return false
            }
    }
    
    /// Cleans up an existing capture session, removing all inputs and outputs
    private func cleanupExistingSession() {
        if let existingSession = self.captureSession {
            // First stop the session if running
            if existingSession.isRunning {
                existingSession.stopRunning()
            }
            
            for name in Self.sessionStateNotifications {
                NotificationCenter.default.removeObserver(self, name: name, object: existingSession)
            }
            
            // Then perform configuration cleanup
            existingSession.beginConfiguration()
            
            // Remove all inputs and outputs
            for input in existingSession.inputs {
                existingSession.removeInput(input)
            }
            for output in existingSession.outputs {
                existingSession.removeOutput(output)
            }
            
            existingSession.commitConfiguration()
            self.captureSession = nil
            
            // Clear preview layer on main thread
            DispatchQueue.main.async {
                self.previewLayer = nil
            }
        }
    }

    @objc private func deviceWasDisconnected(notification: Notification) {
        // The notification also fires for microphones and other capture devices.
        guard let device = notification.object as? AVCaptureDevice, device.hasMediaType(.video) else { return }
        NSLog("Camera device was disconnected")
        let disconnectedID = device.uniqueID
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            // Other cameras going away must not interrupt a session that is using a different one.
            let usesDisconnectedDevice = self.captureSession?.inputs.contains {
                ($0 as? AVCaptureDeviceInput)?.device.uniqueID == disconnectedID
            } ?? false
            if usesDisconnectedDevice {
                self.stopSession()
            }
            self.checkCameraAvailability()
        }
    }

    /// Runtime errors, interruptions and system-initiated stops leave the session not running while
    /// the preview layer freezes, so mirror the real session state into `isSessionRunning`.
    @objc private func captureSessionStateChanged(notification: Notification) {
        guard let session = notification.object as? AVCaptureSession else { return }
        let name = notification.name
        let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError
        sessionQueue.async { [weak self] in
            guard let self = self, session === self.captureSession else { return }
            switch name {
            case AVCaptureSession.runtimeErrorNotification:
                NSLog("Capture session runtime error: \(error?.localizedDescription ?? "unknown")")
            case AVCaptureSession.wasInterruptedNotification:
                NSLog("Capture session was interrupted")
                DispatchQueue.main.async {
                    self.isSessionRunning = false
                }
                return
            default:
                break
            }
            self.updateSessionState()
        }
    }

    @objc private func deviceWasConnected(notification: Notification) {
        NSLog("Camera device was connected")
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.checkCameraAvailability()
        }
    }

    private func updateSessionState() {
        let isRunning = self.captureSession?.isRunning ?? false
        DispatchQueue.main.async {
            self.isSessionRunning = isRunning
        }
    }
    
    func startSession() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.wantsSessionRunning = true
            
            // If no session exists, create new session; setup runs inline so a later stop cannot interleave
            if self.captureSession == nil, !self.setupCaptureSession() {
                return
            }
            self.startRunningCaptureSession()
        }
    }
    
    /// Must be called on `sessionQueue`.
    private func startRunningCaptureSession() {
        guard wantsSessionRunning, let session = captureSession, !session.isRunning else {
            return
        }
        
        session.startRunning()
        
        // Update state on main thread
        updateSessionState()
        
        NSLog("Capture session started successfully")
    }
    
    func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.wantsSessionRunning = false
            
            // Update state to indicate we're stopping
            DispatchQueue.main.async {
                self.isSessionRunning = false
            }
            
            self.cleanupExistingSession()
            
            NSLog("Capture session stopped and cleaned up")
        }
    }
}
