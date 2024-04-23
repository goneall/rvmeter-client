// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:ffi';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:gauge_indicator/gauge_indicator.dart';
import 'package:rvmeter_client/ble_utils_extras.dart';
import 'package:rvmeter_client/snackbar.dart';
import 'package:tuple/tuple.dart';

import 'calibrate_widget.dart';

Guid RV_METER_SERVICE_GUID = Guid("68f9860f-4946-4031-8107-9327cd9f92ca");
Guid TOUCH_CHARACTERISTIC_UUID = Guid("bcdd0001-b67f-46c7-b2b8-e8a385ac70fc");
Guid VOLTAGE_CHARACTERISTIC_UUID = Guid("bcdd0002-b67f-46c7-b2b8-e8a385ac70fc");
Guid TOUCH_CALIBRATION_CHARACTERISTIC_UUID =
    Guid("bcdd0011-b67f-46c7-b2b8-e8a385ac70fc");
Guid REFRESH_RATE_CHARACTERISTIC_UUID =
    Guid("bcdd0005-b67f-46c7-b2b8-e8a385ac70fc");

int bytesToInt(List<int> bytes) {
  int retval = 0;
  for (int i = 0; i < bytes.length; i++) {
    retval = retval + bytes[i] * (pow(256, i)).round();
  }
  return retval;
}

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
  bool _serviceConnected = false;
  BluetoothService? _rvMeterService;
  BluetoothCharacteristic? _touchCharacteristic;
  BluetoothCharacteristic? _voltageCharacteristic;
  BluetoothCharacteristic? _touchCalibrationCharacteristic;
  BluetoothCharacteristic? _refreshRateCharacteristic;

  late StreamSubscription<BluetoothConnectionState>
      _connectionStateSubscription;
  late StreamSubscription<bool> _isConnectingSubscription;
  late StreamSubscription<bool> _isDisconnectingSubscription;

  List<Tuple2<int, int>> waterCalibrationTable = [];

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
        _serviceConnected = false;
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
          } else if (characteristic.characteristicUuid ==
              TOUCH_CALIBRATION_CHARACTERISTIC_UUID) {
            _touchCalibrationCharacteristic = characteristic;
          } else if (characteristic.characteristicUuid ==
              REFRESH_RATE_CHARACTERISTIC_UUID) {
            _refreshRateCharacteristic = characteristic;
          }
        }
        StringBuffer errors = StringBuffer();
        if (_touchCharacteristic == null) {
          errors.write("Water level");
        }
        if (_voltageCharacteristic == null) {
          if (errors.isNotEmpty) {
            errors.write(" and ");
          }
          errors.write("Battery level");
        }
        if (_touchCalibrationCharacteristic == null) {
          if (errors.isNotEmpty) {
            errors.write(" and ");
          }
          errors.write("Calibration service");
        }
        if (_refreshRateCharacteristic == null) {
          if (errors.isNotEmpty) {
            errors.write(" and ");
          }
          errors.write("Refresh function");
        }
        if (errors.isNotEmpty) {
          errors.write(" not found on device.  Select another device.");
          await widget.device.disconnectAndUpdateStream();
          await _errorDialog(errors.toString());
          if (mounted) {
            Navigator.of(context).pop();
          }
        } else {
          await _refreshRvData();
          _serviceConnected = true;
        }
      } else {
        await _errorDialog(
            "No RV Meter service found on device - try a different device");
        await widget.device.disconnectAndUpdateStream();
        if (mounted) {
          Navigator.of(context).pop();
        }
      }
    } catch (e) {
      await widget.device.disconnectAndUpdateStream();
      await _errorDialog("Discover Services Error: $e");
      if (mounted) {
        Navigator.of(context).pop();
      }
    }
  }

  Future<void> _errorDialog(String msg) async {
    return showDialog(
        context: context,
        builder: (BuildContext context) => AlertDialog(
              title: const Text('Error'),
              content: Text(msg),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.pop(context, 'OK'),
                  child: const Text('OK'),
                ),
              ],
            ));
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
    if (_touchCharacteristic != null &&
        _touchCalibrationCharacteristic != null) {
      try {
        List<int> calibrationRaw =
            await _touchCalibrationCharacteristic!.read();
        _updateCalibration(calibrationRaw);
        List<int> touchValues = await _touchCharacteristic!.read();
        if (touchValues.length != 4) {
          Snackbar.show(ABC.c, "Invalid water level reading", success: false);
        } else {
          touchValue = bytesToInt(touchValues);
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
          Snackbar.show(ABC.c, "Invalid battery level reading", success: false);
        } else {
          milliVoltValue = bytesToInt(milliVoltValues);
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

  // Updates the calibration array based on the device string
  // The string is in the format value1:percentage1,value2:percentage2, ...
  // e.g. "3000:100,1500:50,12:0"
  void _updateCalibration(List<int> rawDeviceData) {
    String configStr = String.fromCharCodes(rawDeviceData);
    List<String> pairs = configStr.split(",");
    if (pairs.length < 3) {
      // Too few for config
      Snackbar.show(ABC.c, "Not enough water measurements for configuration",
          success: false);
      return;
    }
    List<Tuple2<int, int>> newConfig = [];
    int lastValue = 0;
    int lastPercent = 32767;
    for (String pair in pairs) {
      List<String> parts = pair.split(':');
      if (parts.length != 2) {
        Snackbar.show(ABC.c, "Invalid configuration pair: $pair",
            success: false);
        return;
      }
      int? value = int.tryParse(parts[0]);
      if (value == null) {
        Snackbar.show(ABC.c, "Invalid value in configuration pair: $pair",
            success: false);
        return;
      }
      if (value < lastValue) {
        Snackbar.show(ABC.c,
            "Configuration values out of order in configuration pair: $pair",
            success: false);
        return;
      }
      lastValue = value;
      int? percent = int.tryParse(parts[1]);
      if (percent == null || percent < 0 || percent > 100) {
        Snackbar.show(ABC.c, "Invalid percent in configuration pair: $pair",
            success: false);
        return;
      }
      if (percent > lastPercent) {
        Snackbar.show(ABC.c,
            "Configuration values out of order in configuration pair: $pair",
            success: false);
        return;
      }
      lastPercent = percent;
      newConfig.add(Tuple2(value, percent));
      waterCalibrationTable = newConfig;
    }
  }

  double _mapValueToPercentAscending(value, List<Tuple2<int, int>> table) {
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
    double percentBetween =
        (table[i - 1].item1 - value) / (table[i - 1].item1 - table[i].item1);
    return table[i - 1].item2.toDouble() -
        percentBetween * (table[i - 1].item2 - table[i].item2);
  }

  double _mapValueToPercentDescending(value, List<Tuple2<int, int>> table) {
    if (table.length < 2) {
      return 0.0;
    }
    if (value <= table[0].item1) {
      return table[0].item2.toDouble();
    }
    if (value >= table.last.item1) {
      return table.last.item2.toDouble();
    }
    int i = 1;
    while (i < table.length && value > table[i].item1) {
      i++;
    }
    double percentBetween =
        (table[i - 1].item1 - value) / (table[i - 1].item1 - table[i].item1);
    return table[i - 1].item2.toDouble() -
        percentBetween * (table[i - 1].item2 - table[i].item2);
  }

  double _calculateBatteryPercentage(int milliVoltValue) {
    return _mapValueToPercentAscending(milliVoltValue, batteryTable);
  }

  double _calculateWaterPercentage(int touchValue) {
    if (waterCalibrationTable.isNotEmpty) {
      return _mapValueToPercentDescending(touchValue, waterCalibrationTable);
    } else {
      return 0.0;
    }
  }

  Widget buildConnecting(BuildContext context) {
    return Column(children: [
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
      Center(
          child: Text(
        '(re)Connecting...',
        style: Theme.of(context).textTheme.headlineMedium,
      )),
    ]);
  }

  Widget buildMeters(BuildContext context) {
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
            actions: [
              IconButton(
                  icon: const Icon(Icons.scale),
                  tooltip: 'Calibrate water level',
                  onPressed: () {
                    MaterialPageRoute route = MaterialPageRoute(
                        builder: (context) => CalibrateWidget(
                              calibrationData: waterCalibrationTable,
                              touchCalibrationCharacteristic:
                                  _touchCalibrationCharacteristic!,
                              touchCharacteristic: _touchCharacteristic!,
                              refreshRateCharacteristic:
                                  _refreshRateCharacteristic!,
                            ),
                        settings: const RouteSettings(name: '/Calibrate'));
                    Navigator.of(context).push(route);
                  }),
            ],
          ),
          body: Center(
              child: isConnected && _serviceConnected ? buildMeters(context) : buildConnecting(context),
          ),
          floatingActionButton: FloatingActionButton(
            onPressed: _serviceConnected ? _refreshRvData : null,
            tooltip: 'Refresh',
            child: const Icon(Icons.refresh),
          ),
        ));
  }
}
