import 'package:flutter/material.dart';
import 'package:flutter_to_airplay/flutter_to_airplay.dart';

AppBar createAppBar(void Function()? onPressed) {
  return AppBar(
    title: Text(
      'Flutter 2 Airplay',
      style: TextStyle(
        color: Colors.blueGrey.shade400,
        fontWeight: FontWeight.bold,
      ),
    ),
    leading: IconButton(
      alignment: Alignment.centerLeft,
      onPressed: onPressed,
      icon: Icon(
        Icons.arrow_back,
        color: Colors.blueGrey.shade400,
      ),
    ),
    actions: [
      AirPlayRoutePickerView(
        tintColor: Colors.blueGrey.shade400,
        activeTintColor: Colors.blueGrey.shade400,
        backgroundColor: Colors.transparent,
      ),
    ],
  );
}
