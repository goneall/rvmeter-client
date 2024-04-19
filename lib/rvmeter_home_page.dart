// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:ffi';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:gauge_indicator/gauge_indicator.dart';
import 'package:rvmeter_client/ble_utils_extras.dart';
import 'package:rvmeter_client/scan_screen.dart';
import 'package:rvmeter_client/snackbar.dart';
import 'package:tuple/tuple.dart';

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

  // map of milli-volts to percent battery capacity left
  static const List<Tuple2<int, int>> batteryTable = [
    Tuple2(1264, 100),
    Tuple2(1253, 90),
    Tuple2(1241, 80),
    Tuple2(1229, 70),
    Tuple2(1218, 60),
    Tuple2(1207, 50),
    Tuple2(1197, 40),
    Tuple2(1187, 30),
    Tuple2(1176, 20),
    Tuple2(1163, 10),
    Tuple2(1159, 0),
  ];

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
        CharacteristicProperties properties = _touchCharacteristic!.properties;
        List<int> touchValues = await _touchCharacteristic!.read();
        if (touchValues.length != 4) {
          Snackbar.show(ABC.c, "Invalid water level reading",
              success: false);
        } else {
          touchValue = _bytesToInt(touchValues);
        }
      } catch (e) {
        Snackbar.show(ABC.c, prettyException("Error getting water level:", e),
            success: false);
      }
    }
    if (_voltageCharacteristic != null) {
      try {
        List<int> milliVoltValues = await _voltageCharacteristic!.read();
        if (milliVoltValues.length != 4) {
          Snackbar.show(ABC.c, "Invalid battery level reading",
              success: false);
        } else {
          milliVoltValue = _bytesToInt(milliVoltValues);
        }
      } catch (e) {
        Snackbar.show(ABC.c, prettyException("Error getting water level:", e),
            success: false);
      }
    }
    if (mounted) {
      setState(() {
        _batteryPercentage = _calculateBatteryPercentage(milliVoltValue);
        _waterPercentage = _calculateWaterPercentage(touchValue);
      });
    }
  }

  int _bytesToInt(List<int> bytes) {
    int retval = 0;
    for (int i = 0; i < bytes.length; i++) {
      retval = retval + bytes[i] * (pow(256, i)).round();
    }
    return retval;
  }

  double _mapValueToPercent(value, List<Tuple2<int, int>> table) {
    if (table.length < 2) {
      return 0.0;
    }
    if (value >= table[0].item1) {
      return table[0].item2.toDouble();
    }
    if (value <= table.last.item1) {
      return table.last.item2.toDouble();
    }
    int i = 1;
    while (i < table.length && value < table[i].item1) {
      i++;
    }
    double percentBetween = (table[i-1].item1 - value) / (table[i-1].item1 - table[i].item1);
    return table[i-1].item2.toDouble() - percentBetween * (table[i-1].item2 - table[i].item2);
  }

  double _calculateBatteryPercentage(int milliVoltValue) {
    return _mapValueToPercent(milliVoltValue, batteryTable);
  }

  double _calculateWaterPercentage(int touchValue) {
    return _waterPercentage + 5;
  }

  Widget buildConnecting(BuildContext context) {
    return Column(
      children: [
        const Padding(
          padding: EdgeInsets.all(14.0),
          child: AspectRatio(
            aspectRatio: 1.0,
            child: CircularProgressIndicator(
              backgroundColor: Colors.black12,
              color: Colors.black26,
            ),
          ),
        ),
        Center(child: Text('(re)Connecting...',
          style: Theme.of(context).textTheme.headlineMedium,)),
      ]
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
            child: isConnected ? buildConnected(context) : buildConnecting(context),
          ),
          floatingActionButton: FloatingActionButton(
            onPressed: _refreshRvData,
            tooltip: 'Refresh',
            child: const Icon(Icons.refresh),
          ),
        ));
  }
}
