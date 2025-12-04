import 'package:flutter/material.dart';
import 'audio_balance_controller.dart';

/// A slider widget for controlling the balance between video audio and extra audio.
/// 
/// This widget provides a horizontal slider with labels "MUSIC" (extra audio) on the left
/// and "VOICE" (video audio) on the right. Moving the slider adjusts the volume balance.
class AudioBalanceSlider extends StatefulWidget {
  const AudioBalanceSlider({
    Key? key,
    required this.controller,
    this.onChanged,
    this.musicLabel = 'MUSIC',
    this.voiceLabel = 'VOICE',
    this.height = 48.0,
    this.backgroundColor,
    this.sliderActiveColor,
    this.sliderInactiveColor,
    this.textColor,
  }) : super(key: key);

  /// The controller for managing audio balance
  final AudioBalanceController controller;

  /// Callback called when the balance value changes
  final ValueChanged<double>? onChanged;

  /// Label for the extra audio side (left side)
  final String musicLabel;

  /// Label for the video audio side (right side)
  final String voiceLabel;

  /// Height of the slider widget
  final double height;

  /// Background color of the container
  final Color? backgroundColor;

  /// Active color of the slider track
  final Color? sliderActiveColor;

  /// Inactive color of the slider track
  final Color? sliderInactiveColor;

  /// Color of the text labels
  final Color? textColor;

  @override
  State<AudioBalanceSlider> createState() => _AudioBalanceSliderState();
}

class _AudioBalanceSliderState extends State<AudioBalanceSlider> {
  double _balance = 0.5; // Default balance (50/50)

  @override
  Widget build(BuildContext context) {
    final backgroundColor = widget.backgroundColor ?? 
        Colors.black.withOpacity(0.27);
    final textColor = widget.textColor ?? Colors.white;
    final sliderActiveColor = widget.sliderActiveColor ?? 
        Colors.white.withOpacity(0.8);
    final sliderInactiveColor = widget.sliderInactiveColor ?? 
        Colors.white.withOpacity(0.3);

    return Container(
      height: widget.height,
      padding: const EdgeInsets.symmetric(horizontal: 4.0),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(5.0),
      ),
      child: Row(
        children: [
          // MUSIC label (left side - extra audio)
          Text(
            widget.musicLabel,
            style: TextStyle(
              color: textColor,
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(width: 8),
          // Slider
          Expanded(
            child: SliderTheme(
              data: SliderThemeData(
                trackHeight: 2.0,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6.0),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 12.0),
                activeTrackColor: sliderActiveColor,
                inactiveTrackColor: sliderInactiveColor,
                thumbColor: Colors.white,
                overlayColor: Colors.white.withOpacity(0.1),
              ),
              child: Slider(
                value: _balance,
                min: 0.0,
                max: 1.0,
                onChanged: (value) {
                  setState(() {
                    _balance = value;
                  });
                  widget.controller.setVolumeBalance(value);
                  widget.onChanged?.call(value);
                },
              ),
            ),
          ),
          const SizedBox(width: 8),
          // VOICE label (right side - video audio)
          Text(
            widget.voiceLabel,
            style: TextStyle(
              color: textColor,
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

