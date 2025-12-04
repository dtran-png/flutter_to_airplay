import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'audio_balance_controller.dart';

/// This widget returns a UIView from swift with an AVPlayer inside,
/// it can be added as it is, or inside a Container to limit
/// and control its width and height.

class FlutterAVPlayerView extends StatefulWidget {
  const FlutterAVPlayerView({
    Key? key,
    this.urlString,
    this.filePath,
    this.assetPath,
    this.autoLoop = false,
    this.maxDuration,
    this.audioUrl,
    this.audioFilePath,
    this.audioAssetPath,
    this.onControllerReady,
    this.onPlayerClosed,
    this.showPictureInPicture = false,
  }) : assert(urlString != null || filePath != null || assetPath != null);

  /// URL string for the video file, if the file is to be played from the network.
  final String? urlString;

  /// Asset name/path for the video file that needs to be played.
  final String? assetPath;

  /// File name/path for the video file that needs to be played from the Temporary or Document directory.
  final String? filePath;

  /// Boolean to enable/disable autoLoop
  final bool autoLoop;

  /// Maximum duration in seconds to play the video. If null, the full video will play.
  /// The video will stop automatically when this duration is reached.
  final double? maxDuration;

  /// URL string for an extra audio file to play alongside the video.
  /// This audio will be synchronized with the video playback.
  final String? audioUrl;

  /// File path for an extra audio file from the Temporary or Document directory.
  final String? audioFilePath;

  /// Asset name/path for an extra audio file to play alongside the video.
  final String? audioAssetPath;

  /// Callback that provides the AudioBalanceController when the player is ready.
  /// Use this to get the controller for controlling volume balance.
  final ValueChanged<AudioBalanceController>? onControllerReady;

  /// Callback that is called when the player is closed by the user (via close button).
  final VoidCallback? onPlayerClosed;

  /// Whether to show the Picture-in-Picture button. Defaults to false.
  final bool showPictureInPicture;

  @override
  State<FlutterAVPlayerView> createState() => _FlutterAVPlayerViewState();
}

class _FlutterAVPlayerViewState extends State<FlutterAVPlayerView> {
  MethodChannel? _methodChannel;
  AudioBalanceController? _controller;

  @override
  void dispose() {
    // Stop the player when widget is disposed
    if (_methodChannel != null) {
      _methodChannel!.invokeMethod('dispose').catchError((error) {
        // Ignore errors - player might already be disposed
        print('Error disposing player: $error');
      });
    }
    _methodChannel?.setMethodCallHandler(null);
    _methodChannel = null;
    _controller = null;
    super.dispose();
  }

  void _onPlatformViewCreated(int id) {
    final name = 'flutter_avplayer_view#$id';

    if (_methodChannel?.name != name) {
      _methodChannel?.setMethodCallHandler(null);
    }

    _methodChannel = MethodChannel(name);
    _controller = AudioBalanceController(_methodChannel!);

    // Set up method call handler to receive messages from native code
    _methodChannel!.setMethodCallHandler(_handleMethodCall);

    // Notify widget if there's a controller callback
    if (widget.onControllerReady != null) {
      widget.onControllerReady!(_controller!);
    }
  }

  Future<dynamic> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'onPlayerClosed':
        // Player was closed by user (via close button)
        print('FlutterAVPlayerView: Received onPlayerClosed from native');
        if (widget.onPlayerClosed != null) {
          widget.onPlayerClosed!();
        } else {
          print('FlutterAVPlayerView: onPlayerClosed callback is null');
        }
        break;
      default:
        print('FlutterAVPlayerView: Unknown method call: ${call.method}');
        break;
    }
  }

  /// This function packs the available parameters to be sent to native code.
  /// It will check for the URL first, if it is available, then it will be used,
  /// otherwise filePath will be used.
  /// It is preferred that only one of urlString or filePath is used at a time,
  /// if both are provided, application will prioritise urlString.
  Map<String, dynamic> getCreateParams() {
    Map<String, dynamic> params = {
      'class': 'FlutterAVPlayerView',
    };

    if (widget.urlString != null) {
      params['url'] = widget.urlString;
    } else if (widget.filePath != null) {
      params['file'] = widget.filePath;
    } else if (widget.assetPath != null) {
      params['asset'] = widget.assetPath;
    }

    // Add audio parameters
    if (widget.audioUrl != null) {
      params['audioUrl'] = widget.audioUrl;
    } else if (widget.audioFilePath != null) {
      params['audioFile'] = widget.audioFilePath;
    } else if (widget.audioAssetPath != null) {
      params['audioAsset'] = widget.audioAssetPath;
    }

    params['autoLoop'] = widget.autoLoop;

    if (widget.maxDuration != null) {
      params['maxDuration'] = widget.maxDuration;
    }

    params['showPictureInPicture'] = widget.showPictureInPicture;

    return params;
  }

  @override
  Widget build(BuildContext context) {
    return UiKitView(
      viewType:
          'flutter_avplayer_view', // This is the identifier that helps distinguish different views in the native code.
      creationParams: getCreateParams(), // parameters to load the video in native code.
      creationParamsCodec: StandardMessageCodec(), // messenger to decode message between flutter and native.
      onPlatformViewCreated: _onPlatformViewCreated,
    );
  }
}
