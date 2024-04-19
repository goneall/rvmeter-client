// SPDX-License-Identifier: Apache-2.0 AND BSD-3-Clause license

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:rvmeter_client/scan_screen.dart';

import 'bluetooth_off_screen.dart';

void main() {
  FlutterBluePlus.setLogLevel(LogLevel.info, color: true);
  runApp(const RvMeterClientApp());
}

class RvMeterClientApp extends StatefulWidget {
  const RvMeterClientApp({Key? key}) : super(key: key);

  @override
  State<RvMeterClientApp> createState() => _RvMeterClientAppState();
}

class _RvMeterClientAppState extends State<RvMeterClientApp> {
  // Based on https://github.com/boskokg/flutter_blue_plus/blob/master/example/lib/main.dart
  // which uses the BSD-3-Clause license

  BluetoothAdapterState _adapterState = BluetoothAdapterState.unknown;

  late StreamSubscription<BluetoothAdapterState> _adapterStateStateSubscription;

  @override
  void initState() {
    super.initState();
    _adapterStateStateSubscription =
        FlutterBluePlus.adapterState.listen((state) {
      _adapterState = state;
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _adapterStateStateSubscription.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    String title = 'RV Meter Client';
    Widget screen = _adapterState == BluetoothAdapterState.on
        ? const ScanScreen()
    : BluetoothOffScreen(adapterState: _adapterState);
    return MaterialApp(
      title: title,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.green),
        useMaterial3: true,
      ),
      home: screen,
      navigatorObservers: [BluetoothAdapterStateObserver()],
    );
  }
}

//
// This observer listens for Bluetooth Off and dismisses the DeviceScreen
//
class BluetoothAdapterStateObserver extends NavigatorObserver {
  StreamSubscription<BluetoothAdapterState>? _adapterStateSubscription;

  @override
  void didPush(Route route, Route? previousRoute) {
    super.didPush(route, previousRoute);
    if (route.settings.name == '/RvMeterHomePage') {
      // Start listening to Bluetooth state changes when a new route is pushed
      _adapterStateSubscription ??=
          FlutterBluePlus.adapterState.listen((state) {
        if (state != BluetoothAdapterState.on) {
          // Pop the current route if Bluetooth is off
          navigator?.pop();
        }
      });
    }
  }

  @override
  void didPop(Route route, Route? previousRoute) {
    super.didPop(route, previousRoute);
    // Cancel the subscription when the route is popped
    _adapterStateSubscription?.cancel();
    _adapterStateSubscription = null;
  }
}
