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
        _flutterAVPlayerViewController.showsPlaybackControls = true
        
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
            }
            
            // Setup extra audio player if audio URL is provided
            setupAudioPlayer(arguments: arguments)
            
            // Sync audio player with video player
            setupAudioPlayerSync()
            
            player?.play()
            audioPlayer?.play()
        }
    }
    
    private func setupDurationLimit(player: AVPlayer, maxDuration: Double) {
        let interval = CMTime(seconds: 0.1, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: DispatchQueue.main) { [weak self] time in
            guard self != nil else { return }
            let currentTime = CMTimeGetSeconds(time)
            if currentTime >= maxDuration {
                player.pause()
                self?.audioPlayer?.pause()
                // Seek to the max duration position
                let seekTime = CMTime(seconds: maxDuration, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
                player.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)
                self?.audioPlayer?.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)
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
                    case .paused:
                        audioPlayer.pause()
                    case .waitingToPlayAtSpecifiedRate:
                        // Keep audio paused while video is buffering
                        break
                    @unknown default:
                        break
                    }
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

