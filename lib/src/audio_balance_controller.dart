import 'package:flutter/services.dart';

/// Controller for managing audio balance between video audio and extra audio
class AudioBalanceController {
  final MethodChannel _methodChannel;

  AudioBalanceController(this._methodChannel);

  /// Sets the volume balance between video audio and extra audio.
  /// [balance] should be between 0.0 and 1.0:
  /// - 0.0 = only video audio (extra audio muted)
  /// - 1.0 = only extra audio (video audio muted)
  /// - 0.5 = equal balance (default)
  Future<void> setVolumeBalance(double balance) async {
    if (balance >= 0.0 && balance <= 1.0) {
      try {
        await _methodChannel.invokeMethod('setVolumeBalance', {'balance': balance});
      } catch (e) {
        print('Error setting volume balance: $e');
      }
    }
  }
}

