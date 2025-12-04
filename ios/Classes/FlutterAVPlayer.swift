//
//  FlutterAVPlayer.swift
//  flutter_to_airplay
//
//  Created by Junaid Rehmat on 22/08/2020.
//

import Foundation
import AVKit
import AVFoundation
import MediaPlayer
import Flutter
import UIKit

// Shared manager to keep players alive across widget disposal
class PlayerManager {
    static let shared = PlayerManager()
    private var activePlayers: [String: FlutterAVPlayer] = [:]
    private let lockQueue = DispatchQueue(label: "com.flutter_to_airplay.playerManager")
    
    func registerPlayer(_ player: FlutterAVPlayer, forKey key: String) {
        lockQueue.async {
            self.activePlayers[key] = player
        }
    }
    
    func unregisterPlayer(forKey key: String) {
        lockQueue.async {
            self.activePlayers.removeValue(forKey: key)
        }
    }
    
    private init() {}
}

// MARK: - FlutterAVPlayer

class FlutterAVPlayer: NSObject, FlutterPlatformView {
    private var _flutterAVPlayerViewController: AVPlayerViewController
    
    private var looper: AVPlayerLooper?
    private var playerItem: AVPlayerItem?
    private var audioPlayerItem: AVPlayerItem?
    private var timeObserver: Any?
    private var audioSyncObserver: Any?
    private var maxDuration: Double?
    private var autoLoop: Bool = false
    private var player: AVPlayer?
    private var audioPlayer: AVPlayer?
    private var playerKey: String?
    private var methodChannel: FlutterMethodChannel?

    // PiP
    private var pipController: AVPictureInPictureController?
    
    // Custom controls
    private var controlsOverlay: CustomPlaybackControlsView?
    private var controlsHideTimer: Timer?
    private var hasNotifiedMaxDuration = false
    private var showPictureInPicture: Bool = false

    init(frame: CGRect,
          viewIdentifier: CLongLong,
          arguments: Dictionary<String, Any>,
          binaryMessenger: FlutterBinaryMessenger) {
        
        autoLoop = arguments["autoLoop"] as? Bool ?? false
        maxDuration = arguments["maxDuration"] as? Double
        showPictureInPicture = arguments["showPictureInPicture"] as? Bool ?? false
        
        // Create a unique key for this player instance
        playerKey = "player_\(viewIdentifier)"

        // Initialize the view controller first
        _flutterAVPlayerViewController = AVPlayerViewController()
        
        // Call super.init() after all stored properties are initialized
        super.init()
        
        // Register this player to keep it alive
        if let key = playerKey {
            PlayerManager.shared.registerPlayer(self, forKey: key)
        }
        
        // Setup method channel for communication with Flutter
        let channelName = "flutter_avplayer_view#\(viewIdentifier)"
        methodChannel = FlutterMethodChannel(name: channelName, binaryMessenger: binaryMessenger)
        methodChannel?.setMethodCallHandler { [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
            self?.handleMethodCall(call: call, result: result)
        }
        
        // Configure audio session for PiP
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Failed to configure audio session: \(error)")
        }

        _flutterAVPlayerViewController.allowsPictureInPicturePlayback = showPictureInPicture
        _flutterAVPlayerViewController.showsPlaybackControls = false
        
        // Enable PiP to start automatically from inline if available (iOS 15+)
        if #available(iOS 15.0, *) {
            _flutterAVPlayerViewController.canStartPictureInPictureAutomaticallyFromInline = true
        }
        
        // Observe PiP state changes to keep player alive during PiP
        setupPiPObserver()
        
        _flutterAVPlayerViewController.viewDidLoad()
        
        let queuePlayer = AVQueuePlayer()

        if let urlString = arguments["url"] as? String {
            let url = URL(string: urlString)!
            playerItem = AVPlayerItem(url: url)
        } else if let filePath = arguments["file"] as? String {
            let fileUrl = URL(fileURLWithPath: filePath)
            playerItem = AVPlayerItem(url: fileUrl)
        } else if let filePath = arguments["asset"] as? String {
            let appDelegate = UIApplication.shared.delegate as! FlutterAppDelegate
            let vc = appDelegate.window?.rootViewController as! FlutterViewController
            let lookUpKey = vc.lookupKey(forAsset: filePath)
            
            if let path = Bundle.main.path(forResource: lookUpKey, ofType: nil) {
                playerItem = AVPlayerItem(url: URL(fileURLWithPath: path))
            } else {
                playerItem = AVPlayerItem(url: URL(fileURLWithPath: filePath))
            }
        }
        
        if let playerItem = playerItem {
            if autoLoop {
                looper = AVPlayerLooper(player: queuePlayer, templateItem: playerItem)
                _flutterAVPlayerViewController.player = queuePlayer
                player = queuePlayer
            } else {
                let avPlayer = AVPlayer(playerItem: playerItem)
                _flutterAVPlayerViewController.player = avPlayer
                player = avPlayer
            }
            
            // Setup PiP controller
            if let player = player, AVPictureInPictureController.isPictureInPictureSupported() {
                let playerLayer = AVPlayerLayer(player: player)
                pipController = AVPictureInPictureController(playerLayer: playerLayer)
                pipController?.delegate = self
            }
            
            // Setup duration limiting if maxDuration is specified
            // Note: Duration limiting doesn't work well with autoLoop, so we skip it in that case
            if let maxDuration = maxDuration, let currentPlayer = player, !autoLoop {
                self.setupDurationLimit(player: currentPlayer, maxDuration: maxDuration)
            } else {
                // Setup time observer for controls even when there's no maxDuration
                setupTimeObserverForControls()
            }
            
            // Setup extra audio player if audio URL is provided
            setupAudioPlayer(arguments: arguments)
            
            // Sync audio player with video player (only if audio player exists)
            if audioPlayer != nil {
                setupAudioPlayerSync()
            }
            
            // Setup custom controls
            setupCustomControls()
            
            player?.play()
            audioPlayer?.play()
        }
    }
    
    private func setupCustomControls() {
        guard let player = player else { return }
        
        // Create custom controls overlay
        let controlsView = CustomPlaybackControlsView(player: player, maxDuration: maxDuration)
        controlsView.delegate = self
        controlsOverlay = controlsView
        
        // Add controls overlay to the player view
        let containerView = _flutterAVPlayerViewController.view!
        containerView.addSubview(controlsView)
        controlsView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            controlsView.topAnchor.constraint(equalTo: containerView.topAnchor),
            controlsView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            controlsView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            controlsView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
        ])
        
        // Add tap gesture to show/hide controls
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(toggleControls))
        containerView.addGestureRecognizer(tapGesture)
        
        // Observe player item duration
        if let playerItem = playerItem {
            playerItem.addObserver(self, forKeyPath: "status", options: [.new], context: nil)
        }
    }
    
    @objc private func toggleControls() {
        guard let controls = controlsOverlay else { return }
        controls.isHidden.toggle()
        
        if !controls.isHidden {
            resetControlsHideTimer()
        } else {
            controlsHideTimer?.invalidate()
        }
    }
    
    private func resetControlsHideTimer() {
        controlsHideTimer?.invalidate()
        controlsHideTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            self?.controlsOverlay?.isHidden = true
        }
    }
    
    private func setupTimeObserverForControls() {
        guard let player = player else { return }
        let interval = CMTime(seconds: 0.1, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: DispatchQueue.main) { [weak self] time in
            self?.controlsOverlay?.updateTime(currentTime: time)
        }
    }
    
    private func setupDurationLimit(player: AVPlayer, maxDuration: Double) {
        hasNotifiedMaxDuration = false // Reset flag
        let interval = CMTime(seconds: 0.1, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: DispatchQueue.main) { [weak self] time in
            guard let self = self else { return }
            let currentTime = CMTimeGetSeconds(time)
            
            // Update custom controls
            self.controlsOverlay?.updateTime(currentTime: time)
            
            if currentTime >= maxDuration && !self.hasNotifiedMaxDuration {
                self.hasNotifiedMaxDuration = true
                player.pause()
                self.audioPlayer?.pause()
                // Seek to the max duration position
                let seekTime = CMTime(seconds: maxDuration, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
                player.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)
                self.audioPlayer?.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)
                // Notify Flutter that maxDuration was reached
                self.notifyPlayerClosed()
            }
        }
    }
    
    private func setupAudioPlayer(arguments: Dictionary<String, Any>) {
        // Check for audio URL, file, or asset
        if let audioUrlString = arguments["audioUrl"] as? String {
            let url = URL(string: audioUrlString)!
            audioPlayerItem = AVPlayerItem(url: url)
        } else if let audioFilePath = arguments["audioFile"] as? String {
            let fileUrl = URL(fileURLWithPath: audioFilePath)
            audioPlayerItem = AVPlayerItem(url: fileUrl)
        } else if let audioAssetPath = arguments["audioAsset"] as? String {
            let appDelegate = UIApplication.shared.delegate as! FlutterAppDelegate
            let vc = appDelegate.window?.rootViewController as! FlutterViewController
            let lookUpKey = vc.lookupKey(forAsset: audioAssetPath)
            
            if let path = Bundle.main.path(forResource: lookUpKey, ofType: nil) {
                audioPlayerItem = AVPlayerItem(url: URL(fileURLWithPath: path))
            } else {
                audioPlayerItem = AVPlayerItem(url: URL(fileURLWithPath: audioAssetPath))
            }
        }
        
        // Create audio player if audio item exists
        if let audioPlayerItem = audioPlayerItem {
            audioPlayer = AVPlayer(playerItem: audioPlayerItem)
            // Set initial volume balance (50/50 by default)
            player?.volume = 0.5
            audioPlayer?.volume = 0.5
        }
    }
    
    private func setupAudioPlayerSync() {
        guard let player = player, let audioPlayer = audioPlayer else { return }
        
        // Observe video player time control status to sync play/pause
        player.addObserver(self, forKeyPath: "timeControlStatus", options: [.new, .old], context: nil)
        
        // Observe when video finishes to stop audio
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(videoDidFinishPlaying),
            name: NSNotification.Name.AVPlayerItemDidPlayToEndTime,
            object: player.currentItem
        )
        
        // Add periodic observer to keep audio player in sync with video player
        // This ensures audio stays synchronized when user seeks through video controls
        let interval = CMTime(seconds: 0.1, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        audioSyncObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: DispatchQueue.main) { [weak self] time in
            guard let self = self, let audioPlayer = self.audioPlayer else { return }
            
            // Only sync if audio player is playing and time difference is significant (> 0.5 seconds)
            if audioPlayer.rate > 0 {
                let audioTime = audioPlayer.currentTime()
                let timeDiff = abs(CMTimeGetSeconds(time) - CMTimeGetSeconds(audioTime))
                
                // If time difference is more than 0.5 seconds, sync the audio player
                if timeDiff > 0.5 {
                    audioPlayer.seek(
                        to: time,
                        toleranceBefore: CMTime(seconds: 0.1, preferredTimescale: CMTimeScale(NSEC_PER_SEC)),
                        toleranceAfter: CMTime(seconds: 0.1, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
                    )
                }
            }
        }
    }
    
    @objc private func videoDidFinishPlaying() {
        audioPlayer?.pause()
        // Notify Flutter that video ended (only if not looping)
        if !autoLoop {
            notifyPlayerClosed()
        }
    }
    
    override func observeValue(forKeyPath keyPath: String?,
                               of object: Any?,
                               change: [NSKeyValueChangeKey : Any]?,
                               context: UnsafeMutableRawPointer?) {
        if keyPath == "timeControlStatus", let player = object as? AVPlayer {
            guard let change = change,
                  let newValue = change[NSKeyValueChangeKey.newKey] as? Int,
                  let oldValue = change[NSKeyValueChangeKey.oldKey] as? Int else { return }
            
            let oldStatus = AVPlayer.TimeControlStatus(rawValue: oldValue)
            let newStatus = AVPlayer.TimeControlStatus(rawValue: newValue)
            
            if newStatus != oldStatus {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, let audioPlayer = self.audioPlayer else { return }
                    
                    switch newStatus {
                    case .playing:
                        // Sync audio player time with video player
                        let currentTime = player.currentTime()
                            audioPlayer.seek(to: currentTime, toleranceBefore: .zero, toleranceAfter: .zero)
                        audioPlayer.play()
                        // Update play button state
                        self.controlsOverlay?.updatePlayButton(isPlaying: true)
                    case .paused:
                        audioPlayer.pause()
                        // Update play button state
                        self.controlsOverlay?.updatePlayButton(isPlaying: false)
                    case .waitingToPlayAtSpecifiedRate:
                        // Keep audio paused while video is buffering
                        break
                    @unknown default:
                        break
                    }
                }
            }
        } else if keyPath == "status", let playerItem = object as? AVPlayerItem {
            if playerItem.status == .readyToPlay {
                DispatchQueue.main.async { [weak self] in
                    self?.controlsOverlay?.updateDuration()
                }
            }
        } else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }
    }
    
    private func setupPiPObserver() {
        // Observe when PiP starts/stops to manage player lifecycle
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pipDidStart),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
    }
    
    @objc private func pipDidStart() {
        // Keep player alive when entering background (PiP might be active)
        // The player will continue playing in PiP mode
    }
    
    func cleanup() {
        // Check if player is currently playing - if so, might be in PiP mode
        // Don't cleanup aggressively to allow PiP to continue
        if let currentPlayer = player, currentPlayer.rate > 0 {
            // Player is playing - might be in PiP, so don't cleanup
            return
        }
        
        forceCleanup()
    }
    
    func forceCleanup() {
        // Force cleanup - stop all players regardless of state
        // This is called when widget is disposed
        
        // Cleanup resources
        if let timeObserver = timeObserver, let player = player {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        
        // Remove audio sync observer
        if let audioSyncObserver = audioSyncObserver, let player = player {
            player.removeTimeObserver(audioSyncObserver)
            self.audioSyncObserver = nil
        }
        
        // Remove observer for time control status (only if audio player was set up)
        if audioPlayer != nil {
            player?.removeObserver(self, forKeyPath: "timeControlStatus")
        }
        
        // Remove observer for player item status
        playerItem?.removeObserver(self, forKeyPath: "status")
        
        // Cleanup custom controls
        controlsOverlay?.removeFromSuperview()
        controlsOverlay = nil
        controlsHideTimer?.invalidate()
        controlsHideTimer = nil
        
        // Stop and release players
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        audioPlayer?.pause()
        audioPlayer?.replaceCurrentItem(with: nil)
        
        // Release player items
        playerItem = nil
        audioPlayerItem = nil
        
        // Clear player references
        player = nil
        audioPlayer = nil
        looper = nil
        
        // PiP controller
        pipController?.stopPictureInPicture()
        pipController = nil
        
        // Unregister from manager
        if let key = playerKey {
            PlayerManager.shared.unregisterPlayer(forKey: key)
        }
        
        // Clear method channel
        methodChannel?.setMethodCallHandler(nil)
        methodChannel = nil
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        forceCleanup()
    }

    func view() -> UIView {
        return _flutterAVPlayerViewController.view
    }
    
    private func handleMethodCall(call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "setVolumeBalance":
            if let args = call.arguments as? Dictionary<String, Any>,
               let balance = args["balance"] as? Double {
                setVolumeBalance(balance: balance)
                result(nil)
            } else {
                result(FlutterError(code: "INVALID_ARGUMENT",
                                    message: "Balance must be a double between 0.0 and 1.0",
                                    details: nil))
            }
        case "dispose":
            // Force cleanup when widget is disposed
            forceCleanup()
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    private func setVolumeBalance(balance: Double) {
        // Clamp balance between 0.0 and 1.0
        let clampedBalance = max(0.0, min(1.0, balance))
        
        // Set video player volume (inverse of balance)
        // When balance is 0.0, video volume is 1.0 (full)
        // When balance is 1.0, video volume is 0.0 (muted)
        player?.volume = Float(1.0 - clampedBalance)
        
        // Set audio player volume (direct balance)
        // When balance is 0.0, audio volume is 0.0 (muted)
        // When balance is 1.0, audio volume is 1.0 (full)
        audioPlayer?.volume = Float(clampedBalance)
    }
}

// MARK: - CustomPlaybackControlsDelegate

protocol CustomPlaybackControlsDelegate: AnyObject {
    func didTapPlayPause()
    func didSeek(to time: CMTime)
    func didTapForward10Seconds()
    func didTapReplay10Seconds()
    func didTapPictureInPicture()
    func didTapClose()
}

// MARK: - FlutterAVPlayer + CustomPlaybackControlsDelegate

extension FlutterAVPlayer: CustomPlaybackControlsDelegate {
    func didTapPlayPause() {
        guard let player = player else { return }
        if player.rate > 0 {
            player.pause()
            audioPlayer?.pause()
        } else {
            player.play()
            audioPlayer?.play()
        }
    }
    
    func didSeek(to time: CMTime) {
        player?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        audioPlayer?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }
    
    func didTapForward10Seconds() {
        guard let player = player else { return }
        let currentTime = player.currentTime()
        let newTime = CMTimeAdd(currentTime, CMTime(seconds: 10, preferredTimescale: CMTimeScale(NSEC_PER_SEC)))
        
        // Check if maxDuration is set and clamp to it
        if let maxDuration = maxDuration {
            let maxDurationTime = CMTime(seconds: maxDuration, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
            let clampedTime = CMTimeCompare(newTime, maxDurationTime) > 0 ? maxDurationTime : newTime
            player.seek(to: clampedTime, toleranceBefore: .zero, toleranceAfter: .zero)
            audioPlayer?.seek(to: clampedTime, toleranceBefore: .zero, toleranceAfter: .zero)
        } else {
            // Check against video duration
            if let duration = player.currentItem?.duration {
                let clampedTime = CMTimeCompare(newTime, duration) > 0 ? duration : newTime
                player.seek(to: clampedTime, toleranceBefore: .zero, toleranceAfter: .zero)
                audioPlayer?.seek(to: clampedTime, toleranceBefore: .zero, toleranceAfter: .zero)
            } else {
                player.seek(to: newTime, toleranceBefore: .zero, toleranceAfter: .zero)
                audioPlayer?.seek(to: newTime, toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }
    }
    
    func didTapReplay10Seconds() {
        guard let player = player else { return }
        let currentTime = player.currentTime()
        let newTime = CMTimeSubtract(currentTime, CMTime(seconds: 10, preferredTimescale: CMTimeScale(NSEC_PER_SEC)))
        
        // Clamp to zero (can't go before start)
        let zeroTime = CMTime.zero
        let clampedTime = CMTimeCompare(newTime, zeroTime) < 0 ? zeroTime : newTime
        
        player.seek(to: clampedTime, toleranceBefore: .zero, toleranceAfter: .zero)
        audioPlayer?.seek(to: clampedTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }
    
    func didTapPictureInPicture() {
       guard let pip = pipController else { return }
        DispatchQueue.main.async {
            if pip.isPictureInPictureActive {
                pip.stopPictureInPicture()
            } else {
                pip.startPictureInPicture()
            }
        }
    }
    
    func didTapClose() {
        // Notify Flutter that player was closed
        notifyPlayerClosed()
        
        // Cleanup player after notifying Flutter
        forceCleanup()
    }
    
    private func notifyPlayerClosed() {
        // Store method channel reference before cleanup (cleanup sets it to nil)
        guard let channel = methodChannel else {
            print("FlutterAVPlayer: methodChannel is nil, cannot notify Flutter")
            return
        }
        
        // Notify Flutter that player was closed (must be done before cleanup)
        // Ensure we're on the main thread
        let notifyFlutter = {
            channel.invokeMethod("onPlayerClosed", arguments: nil) { (result: Any?) in
                if let error = result as? FlutterError {
                    print("FlutterAVPlayer: Error invoking onPlayerClosed: \(error)")
                } else if FlutterMethodNotImplemented.isEqual(result) {
                    print("FlutterAVPlayer: onPlayerClosed method not implemented in Flutter")
                }
            }
        }
        
        if Thread.isMainThread {
            notifyFlutter()
        } else {
            DispatchQueue.main.sync {
                notifyFlutter()
            }
        }
    }
}

// MARK: - CustomPlaybackControlsView

class CustomPlaybackControlsView: UIView {
    weak var delegate: CustomPlaybackControlsDelegate?
    private weak var player: AVPlayer?
    private var maxDuration: Double?
    
    private let backgroundLayer = UIView()
    private let containerView = UIView()
    private let playPauseButton = UIButton(type: .system)
    private let forward10Button = UIButton(type: .system)
    private let replay10Button = UIButton(type: .system)
    private let progressSlider = UISlider()
    private let currentTimeLabel = UILabel()
    private let remainingTimeLabel = UILabel()
    private let controlsStackView = UIStackView()
    private let centerButtonsStackView = UIStackView()
    
    private let closeButton = UIButton(type: .system)
    private let pipButton = UIButton(type: .system)
    private let airplayPickerView = AVRoutePickerView()
    
    private var isDraggingSlider = false
    
    init(player: AVPlayer, maxDuration: Double?) {
        self.player = player
        self.maxDuration = maxDuration
        super.init(frame: .zero)
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupUI() {
        backgroundColor = .clear
        
        // Background layer with black color and 0.3 opacity (below all controls)
        backgroundLayer.backgroundColor = UIColor.black.withAlphaComponent(0.3)
        addSubview(backgroundLayer)
        backgroundLayer.translatesAutoresizingMaskIntoConstraints = false
        
        // Container view (bottom bar)
        containerView.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        addSubview(containerView)
        containerView.translatesAutoresizingMaskIntoConstraints = false
        
        // Replay 10 seconds button
        replay10Button.setImage(UIImage(systemName: "gobackward.10"), for: .normal)
        replay10Button.tintColor = .white
        replay10Button.addTarget(self, action: #selector(replay10Tapped), for: .touchUpInside)
        replay10Button.translatesAutoresizingMaskIntoConstraints = false
        
        // Play/Pause button
        playPauseButton.setImage(UIImage(systemName: "play.fill"), for: .normal)
        playPauseButton.tintColor = .white
        playPauseButton.addTarget(self, action: #selector(playPauseTapped), for: .touchUpInside)
        playPauseButton.translatesAutoresizingMaskIntoConstraints = false
        
        // Forward 10 seconds button
        forward10Button.setImage(UIImage(systemName: "goforward.10"), for: .normal)
        forward10Button.tintColor = .white
        forward10Button.addTarget(self, action: #selector(forward10Tapped), for: .touchUpInside)
        forward10Button.translatesAutoresizingMaskIntoConstraints = false
        
        // Bigger SF Symbol size for center buttons
        let largeSymbolConfig = UIImage.SymbolConfiguration(pointSize: 48, weight: .bold)
        replay10Button.setPreferredSymbolConfiguration(largeSymbolConfig, forImageIn: .normal)
        playPauseButton.setPreferredSymbolConfiguration(largeSymbolConfig, forImageIn: .normal)
        forward10Button.setPreferredSymbolConfiguration(largeSymbolConfig, forImageIn: .normal)
        
        // Close button (top-left, left of PiP button)
        closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeButton.tintColor = .white
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)
        
        // PiP button (top-left, right of close button)
        if #available(iOS 15.0, *) {
            pipButton.setImage(UIImage(systemName: "pip.enter"), for: .normal)
        } else {
            pipButton.setImage(UIImage(systemName: "rectangle.arrowtriangle.2.inward"), for: .normal)
        }
        pipButton.tintColor = .white
        pipButton.addTarget(self, action: #selector(pipTapped), for: .touchUpInside)
        pipButton.translatesAutoresizingMaskIntoConstraints = false
        pipButton.isHidden = true // Show/hide based on flag
        addSubview(pipButton)
        
        // AirPlay picker (top-right)
        airplayPickerView.translatesAutoresizingMaskIntoConstraints = false
        airplayPickerView.tintColor = .white
        if #available(iOS 13.0, *) {
            airplayPickerView.activeTintColor = .systemBlue
        }
        addSubview(airplayPickerView)
        
        // Center buttons stack view (replay, play/pause, forward)
        centerButtonsStackView.axis = .horizontal
        centerButtonsStackView.spacing = 20
        centerButtonsStackView.alignment = .center
        centerButtonsStackView.distribution = .equalSpacing
        centerButtonsStackView.translatesAutoresizingMaskIntoConstraints = false
        
        centerButtonsStackView.addArrangedSubview(replay10Button)
        centerButtonsStackView.addArrangedSubview(playPauseButton)
        centerButtonsStackView.addArrangedSubview(forward10Button)
        addSubview(centerButtonsStackView)
        
        // Progress slider
        progressSlider.minimumTrackTintColor = .systemBlue
        progressSlider.maximumTrackTintColor = .lightGray
        progressSlider.addTarget(self, action: #selector(sliderValueChanged), for: .valueChanged)
        progressSlider.addTarget(self, action: #selector(sliderTouchDown), for: .touchDown)
        progressSlider.addTarget(self, action: #selector(sliderTouchUp), for: [.touchUpInside, .touchUpOutside])
        progressSlider.translatesAutoresizingMaskIntoConstraints = false
        
        // Time labels
        currentTimeLabel.text = "0:00"
        currentTimeLabel.textColor = .white
        currentTimeLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        currentTimeLabel.textAlignment = .left
        
        remainingTimeLabel.text = "-0:00"
        remainingTimeLabel.textColor = .white
        remainingTimeLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        remainingTimeLabel.textAlignment = .right
        
        // Stack view for time labels and slider
        controlsStackView.axis = .horizontal
        controlsStackView.spacing = 12
        controlsStackView.alignment = .center
        controlsStackView.distribution = .fill
        controlsStackView.translatesAutoresizingMaskIntoConstraints = false
        
        controlsStackView.addArrangedSubview(currentTimeLabel)
        controlsStackView.addArrangedSubview(progressSlider)
        controlsStackView.addArrangedSubview(remainingTimeLabel)
        
        containerView.addSubview(controlsStackView)
        
        // Layout constraints
        NSLayoutConstraint.activate([
            // Background layer (covers entire view, below all controls)
            backgroundLayer.topAnchor.constraint(equalTo: topAnchor),
            backgroundLayer.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundLayer.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundLayer.bottomAnchor.constraint(equalTo: bottomAnchor),
            
            // Center buttons stack view (middle of the view)
            centerButtonsStackView.centerXAnchor.constraint(equalTo: centerXAnchor),
            centerButtonsStackView.centerYAnchor.constraint(equalTo: centerYAnchor),
            
            // Button sizes
            replay10Button.widthAnchor.constraint(equalToConstant: 90),
            replay10Button.heightAnchor.constraint(equalToConstant: 90),
            playPauseButton.widthAnchor.constraint(equalToConstant: 90),
            playPauseButton.heightAnchor.constraint(equalToConstant: 90),
            forward10Button.widthAnchor.constraint(equalToConstant: 90),
            forward10Button.heightAnchor.constraint(equalToConstant: 90),
            
            // Container view (bottom bar)
            containerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            containerView.bottomAnchor.constraint(equalTo: bottomAnchor),
            containerView.heightAnchor.constraint(equalToConstant: 100),
            
            // Controls stack (time labels + slider)
            controlsStackView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            controlsStackView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),
            controlsStackView.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
            
            // Time labels width
            currentTimeLabel.widthAnchor.constraint(equalToConstant: 60),
            remainingTimeLabel.widthAnchor.constraint(equalToConstant: 60),
            
            // Close button top-left
            closeButton.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 12),
            closeButton.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 12),
            closeButton.widthAnchor.constraint(equalToConstant: 32),
            closeButton.heightAnchor.constraint(equalToConstant: 32),
            
            // PiP button top-left (right of close button) - hidden
            pipButton.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 12),
            pipButton.leadingAnchor.constraint(equalTo: closeButton.trailingAnchor, constant: 12),
            pipButton.widthAnchor.constraint(equalToConstant: 32),
            pipButton.heightAnchor.constraint(equalToConstant: 32),
            
            // AirPlay picker top-right (aligned with close button)
            airplayPickerView.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            airplayPickerView.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -12),
            airplayPickerView.widthAnchor.constraint(equalToConstant: 32),
            airplayPickerView.heightAnchor.constraint(equalToConstant: 32)
        ])
        
        isHidden = true
    }
    
    @objc private func playPauseTapped() {
        delegate?.didTapPlayPause()
    }
    
    @objc private func forward10Tapped() {
        delegate?.didTapForward10Seconds()
    }
    
    @objc private func replay10Tapped() {
        delegate?.didTapReplay10Seconds()
    }
    
    @objc private func pipTapped() {
        delegate?.didTapPictureInPicture()
    }
    
    @objc private func closeTapped() {
        delegate?.didTapClose()
    }
    
    @objc private func sliderTouchDown() {
        isDraggingSlider = true
    }
    
    @objc private func sliderTouchUp() {
        isDraggingSlider = false
        guard let player = player else { return }
        
        let effectiveDuration: Double
        if let maxDuration = maxDuration {
            effectiveDuration = maxDuration
        } else if let duration = player.currentItem?.duration {
            effectiveDuration = CMTimeGetSeconds(duration)
        } else {
            return
        }
        
        let time = CMTime(
            seconds: Double(progressSlider.value) * effectiveDuration,
            preferredTimescale: CMTimeScale(NSEC_PER_SEC)
        )
        delegate?.didSeek(to: time)
    }
    
    @objc private func sliderValueChanged() {
        guard let player = player else { return }
        
        let effectiveDuration: Double
        if let maxDuration = maxDuration {
            effectiveDuration = maxDuration
        } else if let duration = player.currentItem?.duration {
            effectiveDuration = CMTimeGetSeconds(duration)
        } else {
            return
        }
        
        let currentSeconds = Double(progressSlider.value) * effectiveDuration
        updateTimeLabels(current: currentSeconds, effectiveDuration: effectiveDuration)
    }
    
    func updatePlayButton(isPlaying: Bool) {
        let imageName = isPlaying ? "pause.fill" : "play.fill"
        playPauseButton.setImage(UIImage(systemName: imageName), for: .normal)
    }
    
    func updatePictureInPicture(isActive: Bool) {
        if #available(iOS 15.0, *) {
            let name = isActive ? "pip.exit" : "pip.enter"
            pipButton.setImage(UIImage(systemName: name), for: .normal)
        }
    }
    
    func updateTime(currentTime: CMTime) {
        guard !isDraggingSlider, let player = player else { return }
        
        let currentSeconds = CMTimeGetSeconds(currentTime)
        
        let effectiveDuration: Double
        if let maxDuration = maxDuration {
            effectiveDuration = maxDuration
        } else if let duration = player.currentItem?.duration {
            effectiveDuration = CMTimeGetSeconds(duration)
        } else {
            return
        }
        
        if effectiveDuration > 0 {
            let clampedCurrent = min(currentSeconds, effectiveDuration)
            progressSlider.value = Float(clampedCurrent / effectiveDuration)
        }
        
        updateTimeLabels(current: currentSeconds, effectiveDuration: effectiveDuration)
    }
    
    func updateDuration() {
        guard let player = player else { return }
        
        let currentSeconds = CMTimeGetSeconds(player.currentTime())
        
        let effectiveDuration: Double
        if let maxDuration = maxDuration {
            effectiveDuration = maxDuration
        } else if let duration = player.currentItem?.duration {
            effectiveDuration = CMTimeGetSeconds(duration)
        } else {
            return
        }
        
        updateTimeLabels(current: currentSeconds, effectiveDuration: effectiveDuration)
    }
    
    private func updateTimeLabels(current: Double, effectiveDuration: Double) {
        currentTimeLabel.text = formatTime(current)
        
        let clampedCurrent = min(current, effectiveDuration)
        let remaining = effectiveDuration - clampedCurrent
        remainingTimeLabel.text = "-\(formatTime(remaining))"
    }
    
    private func formatTime(_ seconds: Double) -> String {
        guard !seconds.isNaN && !seconds.isInfinite else { return "0:00" }
        
        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%d:%02d", minutes, secs)
        }
    }
}

// MARK: - AVPictureInPictureControllerDelegate

extension FlutterAVPlayer: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        controlsOverlay?.updatePictureInPicture(isActive: true)
    }
    
    func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        controlsOverlay?.updatePictureInPicture(isActive: false)
    }
    
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) { }
    
    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) { }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        print("PiP failed to start: \(error)")
    }
}
