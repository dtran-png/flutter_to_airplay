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

class FlutterAVPlayer: NSObject, FlutterPlatformView {
    private var _flutterAVPlayerViewController : AVPlayerViewController;
    
    private var looper : AVPlayerLooper?
    private var playerItem: AVPlayerItem?
    private var audioPlayerItem: AVPlayerItem?
    private var timeObserver: Any?
    private var audioSyncObserver: Any?
    private var maxDuration: Double?
    private var player: AVPlayer?
    private var audioPlayer: AVPlayer?
    private var playerKey: String?
    private var pipObserver: NSObjectProtocol?
    private var methodChannel: FlutterMethodChannel?
    
    // Custom controls
    private var controlsOverlay: CustomPlaybackControlsView?
    private var controlsHideTimer: Timer?

    init(frame:CGRect,
          viewIdentifier: CLongLong,
          arguments: Dictionary<String, Any>,
          binaryMessenger: FlutterBinaryMessenger) {
        let autoLoop = arguments["autoLoop"] as? Bool ?? false
        maxDuration = arguments["maxDuration"] as? Double
        
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

        _flutterAVPlayerViewController.allowsPictureInPicturePlayback = true
        _flutterAVPlayerViewController.showsPlaybackControls = false
        
        // Enable PiP to start automatically from inline if available (iOS 15+)
        if #available(iOS 15.0, *) {
            _flutterAVPlayerViewController.canStartPictureInPictureAutomaticallyFromInline = true
        }
        
        // Observe PiP state changes to keep player alive during PiP
        setupPiPObserver()
        
        _flutterAVPlayerViewController.viewDidLoad()
        
        let queuePlayer = AVQueuePlayer()

        if let urlString = arguments["url"] {
            let url = URL(string: urlString as! String)!
            playerItem = AVPlayerItem(url: url)
        } else if let filePath = arguments["file"] {
            let fileUrl = URL(fileURLWithPath: filePath as! String)
            playerItem = AVPlayerItem(url: fileUrl)
        } 
        else if let filePath = arguments["asset"] {
            let appDelegate = UIApplication.shared.delegate as! FlutterAppDelegate
            let vc = appDelegate.window?.rootViewController as! FlutterViewController
            let lookUpKey = vc.lookupKey(forAsset: filePath as! String)
            
            if let path = Bundle.main.path(forResource: lookUpKey, ofType: nil) {
                playerItem = AVPlayerItem(url: URL(fileURLWithPath: path))
            } else {
                playerItem = AVPlayerItem(url: URL(fileURLWithPath: filePath as! String))
            }
        }
        
        if let playerItem = playerItem {
            if (autoLoop){
                looper = AVPlayerLooper(player: queuePlayer, templateItem: playerItem)
                _flutterAVPlayerViewController.player = queuePlayer
                player = queuePlayer
            } else {
                let avPlayer = AVPlayer(playerItem: playerItem)
                _flutterAVPlayerViewController.player = avPlayer
                player = avPlayer
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
            
            // Sync audio player with video player
            setupAudioPlayerSync()
            
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
        _flutterAVPlayerViewController.view.addSubview(controlsView)
        controlsView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            controlsView.topAnchor.constraint(equalTo: _flutterAVPlayerViewController.view.topAnchor),
            controlsView.leadingAnchor.constraint(equalTo: _flutterAVPlayerViewController.view.leadingAnchor),
            controlsView.trailingAnchor.constraint(equalTo: _flutterAVPlayerViewController.view.trailingAnchor),
            controlsView.bottomAnchor.constraint(equalTo: _flutterAVPlayerViewController.view.bottomAnchor)
        ])
        
        // Add tap gesture to show/hide controls
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(toggleControls))
        _flutterAVPlayerViewController.view.addGestureRecognizer(tapGesture)
        
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
        let interval = CMTime(seconds: 0.1, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: DispatchQueue.main) { [weak self] time in
            guard let self = self else { return }
            let currentTime = CMTimeGetSeconds(time)
            
            // Update custom controls
            self.controlsOverlay?.updateTime(currentTime: time)
            
            if currentTime >= maxDuration {
                player.pause()
                self.audioPlayer?.pause()
                // Seek to the max duration position
                let seekTime = CMTime(seconds: maxDuration, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
                player.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)
                self.audioPlayer?.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)
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
                    audioPlayer.seek(to: time, toleranceBefore: CMTime(seconds: 0.1, preferredTimescale: CMTimeScale(NSEC_PER_SEC)), toleranceAfter: CMTime(seconds: 0.1, preferredTimescale: CMTimeScale(NSEC_PER_SEC)))
                }
            }
        }
    }
    
    @objc private func videoDidFinishPlaying() {
        audioPlayer?.pause()
    }
    
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
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
                        if let currentTime = player.currentTime() as CMTime? {
                            audioPlayer.seek(to: currentTime, toleranceBefore: .zero, toleranceAfter: .zero)
                        }
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
            // Call super for any unhandled key paths
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
        
        // Remove observer for time control status
        do {
            try player?.removeObserver(self, forKeyPath: "timeControlStatus")
        } catch {
            // Observer might not be registered, ignore error
        }
        
        // Remove observer for player item status
        do {
            try playerItem?.removeObserver(self, forKeyPath: "status")
        } catch {
            // Observer might not be registered, ignore error
        }
        
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
        
        // Unregister from manager
        if let key = playerKey {
            PlayerManager.shared.unregisterPlayer(forKey: key)
        }
        
        // Clear method channel
        methodChannel?.setMethodCallHandler(nil)
        methodChannel = nil
    }
    
    deinit {
        // Remove observer
        NotificationCenter.default.removeObserver(self)
        
        // Always force cleanup when deallocating
        // This ensures all resources are released
        forceCleanup()
    }

    func view() -> UIView {
        return _flutterAVPlayerViewController.view;
    }
    
    private func handleMethodCall(call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "setVolumeBalance":
            if let args = call.arguments as? Dictionary<String, Any>,
               let balance = args["balance"] as? Double {
                setVolumeBalance(balance: balance)
                result(nil)
            } else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "Balance must be a double between 0.0 and 1.0", details: nil))
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
}

// MARK: - CustomPlaybackControlsView
protocol CustomPlaybackControlsDelegate: AnyObject {
    func didTapPlayPause()
    func didSeek(to time: CMTime)
}

class CustomPlaybackControlsView: UIView {
    weak var delegate: CustomPlaybackControlsDelegate?
    private weak var player: AVPlayer?
    private var maxDuration: Double?
    
    private let containerView = UIView()
    private let playPauseButton = UIButton(type: .system)
    private let progressSlider = UISlider()
    private let currentTimeLabel = UILabel()
    private let remainingTimeLabel = UILabel()
    private let controlsStackView = UIStackView()
    
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
        
        // Container view with gradient background
        containerView.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        addSubview(containerView)
        containerView.translatesAutoresizingMaskIntoConstraints = false
        
        // Play/Pause button
        playPauseButton.setImage(UIImage(systemName: "play.fill"), for: .normal)
        playPauseButton.tintColor = .white
        playPauseButton.addTarget(self, action: #selector(playPauseTapped), for: .touchUpInside)
        playPauseButton.translatesAutoresizingMaskIntoConstraints = false
        
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
        
        // Add all views to container
        containerView.addSubview(playPauseButton)
        containerView.addSubview(controlsStackView)
        
        // Layout constraints
        NSLayoutConstraint.activate([
            // Container view
            containerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            containerView.bottomAnchor.constraint(equalTo: bottomAnchor),
            containerView.heightAnchor.constraint(equalToConstant: 100),
            
            // Play/Pause button
            playPauseButton.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            playPauseButton.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
            playPauseButton.widthAnchor.constraint(equalToConstant: 44),
            playPauseButton.heightAnchor.constraint(equalToConstant: 44),
            
            // Controls stack view
            controlsStackView.leadingAnchor.constraint(equalTo: playPauseButton.trailingAnchor, constant: 16),
            controlsStackView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),
            controlsStackView.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
            
            // Time labels width
            currentTimeLabel.widthAnchor.constraint(equalToConstant: 60),
            remainingTimeLabel.widthAnchor.constraint(equalToConstant: 60)
        ])
        
        // Initially hidden
        isHidden = true
    }
    
    @objc private func playPauseTapped() {
        delegate?.didTapPlayPause()
    }
    
    @objc private func sliderTouchDown() {
        isDraggingSlider = true
    }
    
    @objc private func sliderTouchUp() {
        isDraggingSlider = false
        guard let player = player else { return }
        
        // Use maxDuration if set, otherwise use video duration
        let effectiveDuration: Double
        if let maxDuration = maxDuration {
            effectiveDuration = maxDuration
        } else if let duration = player.currentItem?.duration {
            effectiveDuration = CMTimeGetSeconds(duration)
        } else {
            return
        }
        
        let time = CMTime(seconds: Double(progressSlider.value) * effectiveDuration, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        delegate?.didSeek(to: time)
    }
    
    @objc private func sliderValueChanged() {
        // Update time labels while dragging
        guard let player = player else { return }
        
        // Use maxDuration if set, otherwise use video duration
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
    
    func updateTime(currentTime: CMTime) {
        guard !isDraggingSlider, let player = player else { return }
        
        let currentSeconds = CMTimeGetSeconds(currentTime)
        
        // Use maxDuration if set, otherwise use video duration
        let effectiveDuration: Double
        if let maxDuration = maxDuration {
            effectiveDuration = maxDuration
        } else if let duration = player.currentItem?.duration {
            effectiveDuration = CMTimeGetSeconds(duration)
        } else {
            return
        }
        
        // Update slider - use effective duration for slider calculation
        if effectiveDuration > 0 {
            // Clamp current time to effective duration
            let clampedCurrent = min(currentSeconds, effectiveDuration)
            progressSlider.value = Float(clampedCurrent / effectiveDuration)
        }
        
        // Update labels
        updateTimeLabels(current: currentSeconds, effectiveDuration: effectiveDuration)
    }
    
    func updateDuration() {
        guard let player = player else { return }
        
        let currentSeconds = CMTimeGetSeconds(player.currentTime())
        
        // Use maxDuration if set, otherwise use video duration
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
        // Update current time
        currentTimeLabel.text = formatTime(current)
        
        // Calculate remaining time based on effective duration (maxDuration or original duration)
        // Clamp current time to effective duration to avoid negative remaining time
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

