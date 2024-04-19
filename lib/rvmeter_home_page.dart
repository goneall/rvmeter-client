// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:gauge_indicator/gauge_indicator.dart';
import 'package:rvmeter_client/ble_utils_extras.dart';
import 'package:rvmeter_client/scan_screen.dart';
import 'package:rvmeter_client/snackbar.dart';

Guid RV_METER_SERVICE_GUID = Guid("68f9860f-4946-4031-8107-9327cd9f92ca");
Guid TOUCH_CHARACTERISTIC_UUID = Guid("bcdd0001-b67f-46c7-b2b8-e8a385ac70fc");
Guid VOLTAGE_CHARACTERISTIC_UUID = Guid("bcdd0002-b67f-46c7-b2b8-e8a385ac70fc");

class RvMeterHomePage extends StatefulWidget {
  const RvMeterHomePage({super.key, required this.device});

  final String title = 'RV Meter Client';
  final BluetoothDevice device;

  @override
  State<RvMeterHomePage> createState() => _RvMeterHomePageState();
}

class _RvMeterHomePageState extends State<RvMeterHomePage> {
  double _batteryPercentage = 0.0;
  double _waterPercentage = 0.0;

  BluetoothConnectionState _connectionState =
      BluetoothConnectionState.disconnected;
  bool _isConnecting = false;
  bool _isDisconnecting = false;
  BluetoothService? _rvMeterService;
  BluetoothCharacteristic? _touchCharacteristic;
  BluetoothCharacteristic? _voltageCharacteristic;

  late StreamSubscription<BluetoothConnectionState>
      _connectionStateSubscription;
  late StreamSubscription<bool> _isConnectingSubscription;
  late StreamSubscription<bool> _isDisconnectingSubscription;

  @override
  void initState() {
    super.initState();

    _connectionStateSubscription =
        widget.device.connectionState.listen((state) async {
      _connectionState = state;
      if (state == BluetoothConnectionState.connected) {
        _findRvMeterService(); // must rediscover services
      }
      if (mounted) {
        setState(() {});
      }
    });

    _isConnectingSubscription = widget.device.isConnecting.listen((value) {
      _isConnecting = value;
      if (mounted) {
        setState(() {});
      }
    });

    _isDisconnectingSubscription =
        widget.device.isDisconnecting.listen((value) {
      _isDisconnecting = value;
      if (mounted) {
        setState(() {});
      }
    });
  }

  Future _findRvMeterService() async {
    try {
      _rvMeterService = null;
      List<BluetoothService> services = await widget.device.discoverServices();
      for (BluetoothService service in services) {
        if (service.serviceUuid == RV_METER_SERVICE_GUID) {
          _rvMeterService = service;
        }
      }
      if (_rvMeterService != null) {
        for (BluetoothCharacteristic characteristic
            in _rvMeterService!.characteristics) {
          if (characteristic.characteristicUuid == TOUCH_CHARACTERISTIC_UUID) {
            _touchCharacteristic = characteristic;
          } else if (characteristic.characteristicUuid ==
              VOLTAGE_CHARACTERISTIC_UUID) {
            _voltageCharacteristic = characteristic;
          }
        }
        if (_touchCharacteristic == null) {
          Snackbar.show(
              ABC.c, "No data found for water level - meter will read 0",
              success: false);
        }
        if (_voltageCharacteristic == null) {
          Snackbar.show(
              ABC.c, "No data found for battery level - meter will read 0",
              success: false);
        }
        return _refreshRvData();
      } else {
        Snackbar.show(ABC.c,
            "No RV Meter service found on device - try a different device",
            success: false);
        await widget.device.disconnectAndUpdateStream();
        MaterialPageRoute route = MaterialPageRoute(
            builder: (context) => const ScanScreen(), settings: const RouteSettings(name: '/Scan'));
        if (mounted) {
          Navigator.pushReplacement(context, route);
        }
      }
    } catch (e) {
      Snackbar.show(ABC.c, prettyException("Discover Services Error:", e),
          success: false);
    }
  }

  @override
  void dispose() {
    _connectionStateSubscription.cancel();
    _isConnectingSubscription.cancel();
    _isDisconnectingSubscription.cancel();
    super.dispose();
  }

  bool get isConnected {
    return _connectionState == BluetoothConnectionState.connected;
  }

  Future _refreshRvData() async {
    int touchValue = 0;
    int milliVoltValue = 0;
    if (_touchCharacteristic != null) {
      try {
        List<int> touchValues = await _touchCharacteristic!.read();
        if (touchValues.length != 1) {
          Snackbar.show(ABC.c, "Invalid water level reading",
              success: false);
        } else {
          touchValue = touchValues[0];
        }
      } catch (e) {
        Snackbar.show(ABC.c, prettyException("Error getting water level:", e),
            success: false);
      }
    }
    if (_voltageCharacteristic != null) {
      try {
        List<int> milliVoltValues = await _touchCharacteristic!.read();
        if (milliVoltValues.length != 1) {
          Snackbar.show(ABC.c, "Invalid battery level reading",
              success: false);
        } else {
          milliVoltValue = milliVoltValues[0];
        }
      } catch (e) {
        Snackbar.show(ABC.c, prettyException("Error getting water level:", e),
            success: false);
      }
    }
    if (mounted) {
      setState(() {
        _batteryPercentage = _calculateBatteryPercentage(touchValue);
        _waterPercentage = _calculateWaterPercentage(milliVoltValue);
      });
    }
  }

  double _calculateBatteryPercentage(int touchValue) {
    debugPrint("Touch: $touchValue");
    return _batteryPercentage + 5;
  }

  double _calculateWaterPercentage(int milliVoltValue) {
    debugPrint("Milli-volts: $milliVoltValue");
    return _waterPercentage + 5;
  }

  Widget buildSpinner(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.all(14.0),
      child: AspectRatio(
        aspectRatio: 1.0,
        child: CircularProgressIndicator(
          backgroundColor: Colors.black12,
          color: Colors.black26,
        ),
      ),
    );
  }

  Widget buildConnected(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: <Widget>[
        Column(children: <Widget>[
          AnimatedRadialGauge(
            duration: const Duration(seconds: 1),
            curve: Curves.elasticOut,
            radius: 100,
            value: _waterPercentage,
            axis: const GaugeAxis(
                min: 0,
                max: 100,
                degrees: 270,
                style: GaugeAxisStyle(
                  thickness: 20,
                  background: Colors.lightBlue,
                  segmentSpacing: 0,
                ),
                progressBar: GaugeProgressBar.basic(
                  color: Colors.blue,
                ),
                pointer: GaugePointer.needle(
                  width: 30.0,
                  height: 90.0,
                  color: Colors.blue,
                ),
                segments: [
                  GaugeSegment(
                    from: 0,
                    to: 25.0,
                    color: Colors.red,
                    cornerRadius: Radius.zero,
                  ),
                  GaugeSegment(
                    from: 25.0,
                    to: 50.0,
                    color: Colors.yellow,
                    cornerRadius: Radius.zero,
                  ),
                  GaugeSegment(
                    from: 50.0,
                    to: 75.0,
                    color: Colors.lightGreen,
                    cornerRadius: Radius.zero,
                  ),
                  GaugeSegment(
                    from: 75.0,
                    to: 100.0,
                    color: Colors.green,
                    cornerRadius: Radius.zero,
                  ),
                ]),
          ),
          const SizedBox(height: 10),
          Text(
            'Water Level',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
        ]),
        Column(children: <Widget>[
          AnimatedRadialGauge(
            duration: const Duration(seconds: 1),
            curve: Curves.elasticOut,
            radius: 100,
            value: _batteryPercentage,
            axis: const GaugeAxis(
                min: 0,
                max: 100,
                degrees: 270,
                style: GaugeAxisStyle(
                  thickness: 20,
                  background: Colors.lightGreen,
                  segmentSpacing: 0,
                ),
                progressBar: GaugeProgressBar.basic(
                  color: Colors.teal,
                ),
                pointer: GaugePointer.needle(
                  width: 30.0,
                  height: 90.0,
                  color: Colors.teal,
                ),
                segments: [
                  GaugeSegment(
                    from: 0,
                    to: 25.0,
                    color: Colors.red,
                    cornerRadius: Radius.zero,
                  ),
                  GaugeSegment(
                    from: 25.0,
                    to: 50.0,
                    color: Colors.yellow,
                    cornerRadius: Radius.zero,
                  ),
                  GaugeSegment(
                    from: 50.0,
                    to: 75.0,
                    color: Colors.lightGreen,
                    cornerRadius: Radius.zero,
                  ),
                  GaugeSegment(
                    from: 75.0,
                    to: 100.0,
                    color: Colors.green,
                    cornerRadius: Radius.zero,
                  ),
                ]),
          ),
          const SizedBox(height: 10),
          Text(
            'Battery Level',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
        ]),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return ScaffoldMessenger(
        key: Snackbar.snackBarKeyC,
        child: Scaffold(
          appBar: AppBar(
            backgroundColor: Theme.of(context).colorScheme.inversePrimary,
            title: Text(widget.title),
          ),
          body: Center(
            child: isConnected ? buildConnected(context) : buildSpinner(context),
          ),
          floatingActionButton: FloatingActionButton(
            onPressed: _refreshRvData,
            tooltip: 'Refresh',
            child: const Icon(Icons.refresh),
          ),
        ));
  }
}
