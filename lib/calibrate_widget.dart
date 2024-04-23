/**
 * The calibration data is stored on the device and in the
 * preferences values 'lastCalibration' for the data of the last
 * time the calibration was run and 'penultimateCalibration' for the
 * previous calibration.
 */
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:rvmeter_client/rvmeter_home_page.dart';
import 'package:rvmeter_client/snackbar.dart';
import 'package:tuple/tuple.dart';
import 'package:shared_preferences/shared_preferences.dart';

class CalibrateWidget extends StatefulWidget {
  const CalibrateWidget({
    super.key,
    required this.calibrationData,
    required this.touchCharacteristic,
    required this.touchCalibrationCharacteristic,
    required this.refreshRateCharacteristic,
  });

  final List<Tuple2<int, int>> calibrationData;
  final BluetoothCharacteristic touchCalibrationCharacteristic;
  final BluetoothCharacteristic touchCharacteristic;
  final BluetoothCharacteristic refreshRateCharacteristic;

  @override
  State<CalibrateWidget> createState() => _CalibrateWidgetState();
}

class _CalibrateWidgetState extends State<CalibrateWidget> {
  final Future<SharedPreferences> _prefs = SharedPreferences.getInstance();
  String _errorMessage = "";
  int _touchValue = 0;
  final List<Tuple2<int, int>> _inProgressCalibration = [];
  static const int calibrationRefreshRate = 1; // seconds
  static const int normalRefreshRate = 60;
  static const int tolerance = 5; // max tolerance for measuring capacitance
  static const int maxRetries = 10; // maximum number of retries
  static const List<int> percentages = [0, 12, 25, 38, 50, 63, 75, 88, 100];
  static const List<String> percentLabels = [
    "Empty",
    "1/8 full",
    "1/4 full",
    "3/8 full",
    "1/2 full",
    "5/8 full",
    "3/4 full",
    "7/8 full",
    "full"
  ];
  bool _measuring = false;

  @override
  void initState() {
    super.initState();
    _inProgressCalibration.clear();
    _setRefreshRate(calibrationRefreshRate);
  }

  Future<void> _measureValue() async {
    if (mounted) {
      setState(() {
        _measuring = true;
      });
    }
    int lastTouchValue = 0;
    int retries = 0;
    int currentTouchValue = await _readTouchValue();
    while ((currentTouchValue - lastTouchValue).abs() > tolerance &&
        retries++ < maxRetries) {
      lastTouchValue = currentTouchValue;
      sleep(const Duration(seconds: 5));
      currentTouchValue = await _readTouchValue();
    }
    if (retries >= maxRetries) {
      _errorMessage =
          "Unable to get a stable calibration reading.  Consider restarting.";
      return;
    }
    int currentPercentage = percentages[_inProgressCalibration.length];
    if (_inProgressCalibration.isNotEmpty) {
      if (currentTouchValue >= _inProgressCalibration.last.item1) {
        String currentLabel = percentLabels[_inProgressCalibration.length];
        _errorMessage =
            "Value for $currentLabel is greater than the previous value.  Calibration failed";
      }
    }
    _inProgressCalibration.add(Tuple2(currentTouchValue, currentPercentage));
    if (mounted) {
      setState(() {
        _measuring = false;
      });
    }
  }

  Future<int> _readTouchValue() async {
    List<int> touchValues = await widget.touchCharacteristic.read();
    if (touchValues.length != 4) {
      Snackbar.show(ABC.c, "Invalid water level reading", success: false);
      return -1;
    } else {
      _touchValue = bytesToInt(touchValues);
      setState(() {});
      return _touchValue;
    }
  }

  Future<void> _setRefreshRate(int seconds) {
    if (seconds > 256) {
      seconds = 256;
    }
    List<int> value = [seconds, 0, 0, 0];
    return widget.refreshRateCharacteristic.write(value);
  }

  String tableToString(List<Tuple2<int, int>> table) {
    if (table.isEmpty) {
      return "";
    }
    StringBuffer sb = StringBuffer();
    sb.write(table.first.item1);
    sb.write(':');
    sb.write(table.first.item2);
    for (int i = 1; i < table.length; i++) {
      sb.write(',');
      sb.write(table[i].item1);
      sb.write(':');
      sb.write(table[i].item2);
    }
    return sb.toString();
  }

  Future<void> _saveCalibration() async {
    // save the next to last calibration data
    SharedPreferences prefs = await _prefs;
    await prefs.setString('penultimateCalibration', tableToString(widget.calibrationData));
    // reverse the order of the results when saving
    widget.calibrationData.clear();
    widget.calibrationData.add(_inProgressCalibration.last);
    for (int i = _inProgressCalibration.length - 2; i >= 0; i--) {
      widget.calibrationData.add(_inProgressCalibration[i]);
    }
    String deviceCalibrationData = tableToString(widget.calibrationData);
    await widget.touchCalibrationCharacteristic.write(
        deviceCalibrationData.codeUnits,
        allowLongWrite: true);
    await _resetRefresh();
    await prefs.setString('lastCalibration', deviceCalibrationData);
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  void _resetCalibration() {
    _inProgressCalibration.clear();
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _restoreCalibration() async {
    SharedPreferences prefs = await _prefs;
    String? lastCalibration = prefs.getString('lastCalibration');
    if (lastCalibration == null) {
      _errorMessage = "No previous calibration - you must calibrate by filling the tank";
    } else {
      List<String> pairs = lastCalibration.split(",");
      if (pairs.length < 3) {
        // Too few for config
        _errorMessage = "Not enough water measurements for configuration";
        return;
      }
      _inProgressCalibration.clear();
      int lastValue = 0;
      int lastPercent = 32767;
      // Note: we need to reverse the order
      for (String pair in pairs) {
        List<String> parts = pair.split(':');
        if (parts.length != 2) {
          _errorMessage = "Invalid configuration pair: $pair";
          _inProgressCalibration.clear();
          break;
        }
        int? value = int.tryParse(parts[0]);
        if (value == null) {
          _errorMessage = "Invalid value in configuration pair: $pair";
          _inProgressCalibration.clear();
          break;
        }
        if (value < lastValue) {
          _errorMessage = "Configuration values out of order in configuration pair: $pair";
          _inProgressCalibration.clear();
          break;
        }
        lastValue = value;
        int? percent = int.tryParse(parts[1]);
        if (percent == null || percent < 0 || percent > 100) {
          _errorMessage = "Invalid percent in configuration pair: $pair";
          _inProgressCalibration.clear();
          break;
        }
        if (percent > lastPercent) {
          _errorMessage = "Configuration values out of order in configuration pair: $pair";
          _inProgressCalibration.clear();
          break;
        }
        lastPercent = percent;
        _inProgressCalibration.insert(0, Tuple2(value, percent));
      }
    }
    setState(() {

    });
  }


  Widget buildStarting(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        Center(
            child: Text('Calibration',
                style: Theme.of(context).textTheme.headlineLarge)),
        Padding(
            padding: const EdgeInsets.all(10.0),
            child: Text('Either restores the previous calibration and by clicking "Restore Last" - or - completely empty the tank then click "Measure"',
                style: Theme.of(context).textTheme.headlineSmall)),
        _measuring
            ? Center(child: Text('Value Read: $_touchValue'))
            : Center(child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              ElevatedButton(
                onPressed: _restoreCalibration,
                child: const Text('Restore Last'),
              ),
              ElevatedButton(
                onPressed: _measureValue,
                child: const Text('Measure'),
              ),
        ])),
      ],
    );
  }

  Widget buildEnding(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        Center(
            child: Text('Calibration',
                style: Theme.of(context).textTheme.headlineLarge)),
        Padding(
            padding: const EdgeInsets.all(10.0),
            child: Text(
                'Done measuring - click "Confirm" to save the calibration',
                style: Theme.of(context).textTheme.headlineSmall)),
        Center(
          child:
              Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
            ElevatedButton(
              onPressed: _saveCalibration,
              child: const Text('Confirm'),
            ),
            ElevatedButton(
              onPressed: _resetCalibration,
              child: const Text('Reset'),
            )
          ]),
        )
      ],
    );
  }

  Widget buildError(BuildContext context) {
    return Column(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
      Center(
          child: Text('Calibration',
              style: Theme.of(context).textTheme.headlineLarge)),
      Padding(
          padding: const EdgeInsets.all(10.0),
          child: Text(_errorMessage,
              style: Theme.of(context).textTheme.headlineMedium)),
      ElevatedButton(
        onPressed: () => {_resetRefresh(), Navigator.of(context).pop()},
        child: const Text('Exit Calibration'),
      ),
    ]);
  }

  Widget buildFilling(BuildContext context) {
    String fillLabel = percentLabels[_inProgressCalibration.length];
    return Column(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        Center(
            child: Text('Calibration',
                style: Theme.of(context).textTheme.headlineLarge)),
        Padding(
            padding: const EdgeInsets.all(10.0),
            child: Text('Fill the tank to $fillLabel then select "Measure"',
                style: Theme.of(context).textTheme.headlineSmall)),
        _measuring
            ? Center(child: Text('Value Read: $_touchValue'))
            : ElevatedButton(
                onPressed: _measureValue,
                child: const Text('Measure'),
              ),
      ],
    );
  }

  Future<bool> _resetRefresh() async {
    await _setRefreshRate(normalRefreshRate);
    return Future.value(true);
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
        onWillPop: _resetRefresh,
        child: Scaffold(
            appBar: AppBar(
              title: const Text('Calibration'),
            ),
            body: _errorMessage.isNotEmpty
                ? buildError(context)
                : _inProgressCalibration.isEmpty
                    ? buildStarting(context)
                    : _inProgressCalibration.length == percentages.length
                        ? buildEnding(context)
                        : buildFilling(context)));
  }
}
