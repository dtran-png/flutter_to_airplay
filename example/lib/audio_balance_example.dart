import 'package:flutter/material.dart';
import 'package:flutter_to_airplay/flutter_to_airplay.dart';

/// Example showing how to use the audio balance slider with FlutterAVPlayerView
class AudioBalanceExample extends StatefulWidget {
  @override
  _AudioBalanceExampleState createState() => _AudioBalanceExampleState();
}

class _AudioBalanceExampleState extends State<AudioBalanceExample> {
  AudioBalanceController? _audioController;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Audio Balance Example'),
      ),
      body: Column(
        children: [
          // Video player with extra audio
          Expanded(
            child: FlutterAVPlayerView(
              maxDuration: 4*60,
              onPlayerClosed: (){
                Navigator.of(context).pop();
              },
              audioUrl: 'https://staging-media.glo.com/music/10217/4a5c95bd5c40cc74751bbaf1414510cf-preview.m4a?Expires=1764769410&Policy=eyJTdGF0ZW1lbnQiOlt7IlJlc291cmNlIjoiaHR0cHM6Ly9zdGFnaW5nLW1lZGlhLmdsby5jb20vbXVzaWMvMTAyMTcvNGE1Yzk1YmQ1YzQwY2M3NDc1MWJiYWYxNDE0NTEwY2YtcHJldmlldy5tNGEiLCJDb25kaXRpb24iOnsiRGF0ZUxlc3NUaGFuIjp7IkFXUzpFcG9jaFRpbWUiOjE3NjQ3Njk0MTB9fX1dfQ__&Signature=hRcbb-Nuyv4xoADxy-4wQ3imWcRePKEqgBcREQSOhbWR2x31lsaJQmPBoi6y3tuyUtOEg~GX5e0pZPwfcud~cuLouBzUVYZXHGCP1-h-W6hNyPrElYQ-kakrDPgmMmQgvKWVftEGvcn2DUunnlit~~egK5o~S9ZY7pmiZLLtxuiTVNGY-6UjtenGy~DS0tSL6z9vH-VAML4PpkaNbkyKexBCup9RqziZGwJmEeX6zFJ5XIPqjRZeL-Ek~X5-C82oEViiDJ8hMquDLDolNsjxU7To2xXlE6wzr8ffvc2hECrxe6D8Nzilxn2cyjEOH0PQBfSKF25iqCh3wqNMzMbjBA__&Key-Pair-Id=APKAI5ZIYQVCDU4IM5GA',
              urlString:
              'https://staging-media.glo.com/video/hls/10217/b10ddc3f7baafd7fe095360c97652fdd.m3u8',
              onControllerReady: (controller) {
                setState(() {
                  _audioController = controller;
                });
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

