import 'package:flutter/material.dart';
import 'package:flutter_to_airplay/flutter_to_airplay.dart';

/// Example showing how to use the audio balance slider with FlutterAVPlayerView
class AudioBalanceExample extends StatefulWidget {
  @override
  _AudioBalanceExampleState createState() => _AudioBalanceExampleState();
}

class _AudioBalanceExampleState extends State<AudioBalanceExample> {
  AudioBalanceController? _audioController;
  String _statusMessage = 'Ready';
  bool _isBuffering = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Audio Balance Example'),
      ),
      body: Column(
        children: [
          // Status display
          Container(
            padding: EdgeInsets.all(16.0),
            color: Colors.grey[200],
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Status: $_statusMessage',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                if (_isBuffering)
                  Padding(
                    padding: EdgeInsets.only(top: 8.0),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        SizedBox(width: 8),
                        Text('Buffering...'),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          // Video player with extra audio
          Expanded(
            child: FlutterAVPlayerView(
              showPictureInPicture: true,
              onPlayerClosed: () {
                Navigator.of(context).pop();
              },
              maxDuration: 120,
              audioUrl: 'https://staging-media.glo.com/music/10217/4a5c95bd5c40cc74751bbaf1414510cf-preview.m4a?Expires=1765079261&Policy=eyJTdGF0ZW1lbnQiOlt7IlJlc291cmNlIjoiaHR0cHM6Ly9zdGFnaW5nLW1lZGlhLmdsby5jb20vbXVzaWMvMTAyMTcvNGE1Yzk1YmQ1YzQwY2M3NDc1MWJiYWYxNDE0NTEwY2YtcHJldmlldy5tNGEiLCJDb25kaXRpb24iOnsiRGF0ZUxlc3NUaGFuIjp7IkFXUzpFcG9jaFRpbWUiOjE3NjUwNzkyNjF9fX1dfQ__&Signature=S4I7dd-J6mues~NhIojb3bCl-1Fy-PqCZWZLSkbEgyG1bAh2srVDcOPPUIwre-a~0NvymIzNvO~i07~f38dXYqDTbHJIu616W4RNW9iHASJqcnDBbOFS41f-ja3Kjrua6Bnve8jrmJ8kG87mhoGSivZISd2sK~vGeR9ogJW805fksMMrZNRTHEGNuXcN7ItVSvZydriNnmjuRQ7BE2lsJRrh3~1sKOMvjyx8qQea1iWqzxJo968wuJUhBUyp30hJGm4lq28IaQW~EJ2Qtr9UrTdDVfw92WwsFHhXIfNtQZhdtCFMHtOOIpPJjciWa4WirqkarkrQPcLYsOmalyxcTA__&Key-Pair-Id=APKAI5ZIYQVCDU4IM5GA',
              urlString:
                  'https://staging-media.glo.com/video/hls/10217/b10ddc3f7baafd7fe095360c97652fdd.m3u8',
              onControllerReady: (controller) {
                setState(() {
                  _audioController = controller;
                });
              },
              // Event listeners
              onStart: () {
                setState(() {
                  _statusMessage = 'Playing';
                  _isBuffering = false;
                });
                print('Video playback started');
              },
              onEnd: () {
                setState(() {
                  _statusMessage = 'Playback ended';
                });
                print('Video playback ended');
              },
              onError: (errorMessage) {
                setState(() {
                  _statusMessage = 'Error: $errorMessage';
                });
                print('Video player error: $errorMessage');
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Error: $errorMessage'),
                    backgroundColor: Colors.red,
                  ),
                );
              },
              onBuffering: (isBuffering) {
                setState(() {
                  _isBuffering = isBuffering;
                  if (isBuffering) {
                    _statusMessage = 'Buffering...';
                  } else {
                    _statusMessage = 'Playing';
                  }
                });
                print('Buffering: $isBuffering');
              },
              onSeek: (second) {
                setState(() {
                  _statusMessage = 'Seeking to ${second.toStringAsFixed(1)}s';
                });
                print('Seeked to: ${second.toStringAsFixed(2)} seconds');
              },
              onPause: () {
                setState(() {
                  _statusMessage = 'Paused';
                });
                print('Video playback paused');
              },
              onAirPlayTrigger: (target) {
                setState(() {
                  _statusMessage = 'AirPlay: $target';
                });
                print('AirPlay target changed to: $target');
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('AirPlay: $target'),
                    duration: Duration(seconds: 2),
                  ),
                );
              },
            ),
          ),
          // Audio balance slider
          if (_audioController != null)
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: AudioBalanceSlider(
                controller: _audioController!,
                onChanged: (balance) {
                  print('Balance changed: $balance');
                  // balance: 0.0 = only video audio
                  // balance: 1.0 = only extra audio
                  // balance: 0.5 = equal balance
                },
              ),
            ),
        ],
      ),
    );
  }
}

