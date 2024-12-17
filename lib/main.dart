import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:dchs_motion_sensors/dchs_motion_sensors.dart'; // dchs_motion_sensorsを使用
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart'; // 追加

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: SensorRecorderPage(),
      theme: ThemeData(
        primarySwatch: Colors.indigo,
        appBarTheme: AppBarTheme(
          backgroundColor: Colors.indigoAccent,
          centerTitle: true,
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.indigo,
            foregroundColor: Colors.white,
            textStyle: TextStyle(fontWeight: FontWeight.bold),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
      ),
    );
  }
}

class SensorRecorderPage extends StatefulWidget {
  @override
  _SensorRecorderPageState createState() => _SensorRecorderPageState();
}

class _SensorRecorderPageState extends State<SensorRecorderPage> {
  bool _isRecording = false;
  bool _isLongPressing = false;
  bool _uploading = false;

  List<List<dynamic>> _locationDataRows = [];
  List<List<dynamic>> _accelDataRows = [];

  Timer? _locationTimer;
  StreamSubscription<AccelerometerEvent>? _accelSub;
  DateTime? _recordStartTime;

  final String lambdaUrl =
      "https://49icw5dap1.execute-api.ap-northeast-1.amazonaws.com/upload";

  String? _userName;

  @override
  void initState() {
    super.initState();
    _requestPermissions();
    _checkUserName();
    // 加速度センサー取得頻度を設定（例：100Hz相当）
    // 1秒=1,000,000マイクロ秒, 100Hz→1秒/100=0.01秒=10ms=10000マイクロ秒
    motionSensors.accelerometerUpdateInterval =
        Duration.microsecondsPerSecond ~/ 100;
  }

  Future<void> _requestPermissions() async {
    await Geolocator.requestPermission();
    await Permission.sensors.request();
    await Permission.storage.request();
  }

  Future<void> _checkUserName() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    String? storedName = prefs.getString('userName');
    if (storedName == null || storedName.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _showNameInputDialog();
      });
    } else {
      setState(() {
        _userName = storedName;
      });
    }
  }

  void _showNameInputDialog() {
    final TextEditingController _nameController = TextEditingController();
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
          title: Text("ユーザー名入力"),
          content: TextField(
            controller: _nameController,
            decoration: InputDecoration(hintText: "氏名を入力してください"),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                if (_nameController.text.isNotEmpty) {
                  SharedPreferences prefs =
                      await SharedPreferences.getInstance();
                  await prefs.setString('userName', _nameController.text);
                  setState(() {
                    _userName = _nameController.text;
                  });
                  Navigator.of(context).pop();
                }
              },
              child: Text("OK"),
            ),
          ],
        );
      },
    );
  }

  void _startRecording() {
    if (_userName == null || _userName!.isEmpty) {
      _showNameInputDialog();
      return;
    }

    setState(() {
      _isRecording = true;
      _recordStartTime = DateTime.now();
      _locationDataRows = [];
      _accelDataRows = [];

      _locationDataRows.add(["timestamp(ms)", "latitude", "longitude"]);
      _accelDataRows.add(["timestamp(ms)", "accelX", "accelY", "accelZ"]);
    });

    // 位置情報を1Hzで取得
    _locationTimer = Timer.periodic(Duration(seconds: 1), (timer) async {
      Position pos = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high);
      _recordLocationData(position: pos);
    });

    // 加速度センサデータ取得（dchs_motion_sensors）
    _accelSub = motionSensors.accelerometer.listen((event) {
      _recordAccelData(accelX: event.x, accelY: event.y, accelZ: event.z);
    });
  }

  Future<void> _stopRecording() async {
    _locationTimer?.cancel();
    _accelSub?.cancel();

    setState(() {
      _isRecording = false;
    });

    String locationCsv = const ListToCsvConverter().convert(_locationDataRows);
    String accelCsv = const ListToCsvConverter().convert(_accelDataRows);

    final directory = await getApplicationDocumentsDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final filenamePrefix = (_userName != null && _userName!.isNotEmpty)
        ? "${_userName!}_$timestamp"
        : "data_$timestamp";

    final locationFilePath =
        "${directory.path}/location_data_$filenamePrefix.csv";
    final accelFilePath = "${directory.path}/accel_data_$filenamePrefix.csv";

    final locationFile = File(locationFilePath);
    final accelFile = File(accelFilePath);

    await locationFile.writeAsString(locationCsv);
    await accelFile.writeAsString(accelCsv);

    setState(() {
      _uploading = true;
    });
    try {
      final locationCsvBase64 = base64Encode(locationCsv.codeUnits);
      final locationResponse = await http.post(
        Uri.parse(lambdaUrl),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({
          "filename": "location_data_$filenamePrefix.csv",
          "filedata_base64": locationCsvBase64
        }),
      );

      if (locationResponse.statusCode == 200) {
        print("Location data upload success");
      } else {
        print(
            "Location data upload failed: ${locationResponse.statusCode}, ${locationResponse.body}");
      }

      final accelCsvBase64 = base64Encode(accelCsv.codeUnits);
      final accelResponse = await http.post(
        Uri.parse(lambdaUrl),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({
          "filename": "accel_data_$filenamePrefix.csv",
          "filedata_base64": accelCsvBase64
        }),
      );

      if (accelResponse.statusCode == 200) {
        print("Accelerometer data upload success");
      } else {
        print(
            "Accelerometer data upload failed: ${accelResponse.statusCode}, ${accelResponse.body}");
      }
    } catch (e) {
      print("Upload error: $e");
    }

    setState(() {
      _uploading = false;
    });
  }

  void _recordLocationData({Position? position}) {
    final now = DateTime.now();
    final elapsedMs = now.millisecondsSinceEpoch;
    double lat = position?.latitude ?? double.nan;
    double lon = position?.longitude ?? double.nan;
    _locationDataRows.add([elapsedMs, lat, lon]);
  }

  void _recordAccelData({double? accelX, double? accelY, double? accelZ}) {
    final now = DateTime.now();
    final elapsedMs = now.millisecondsSinceEpoch;
    double ax = accelX ?? double.nan;
    double ay = accelY ?? double.nan;
    double az = accelZ ?? double.nan;
    _accelDataRows.add([elapsedMs, ax, ay, az]);
  }

  void _onLongPressStart(LongPressStartDetails details) {
    _isLongPressing = true;
    Future.delayed(Duration(seconds: 3)).then((_) {
      if (_isLongPressing && _isRecording) {
        _stopRecording();
      }
    });
  }

  void _onLongPressEnd(LongPressEndDetails details) {
    _isLongPressing = false;
  }

  Future<void> _resetUserName() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove('userName');
    setState(() {
      _userName = null;
    });
    _showNameInputDialog();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("Sensor Recorder"),
        leading: IconButton(
          icon: Icon(Icons.person),
          onPressed: _resetUserName,
          tooltip: "氏名変更",
        ),
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient:
              LinearGradient(colors: [Colors.white, Colors.indigo.shade50]),
        ),
        child: Center(
          child: _uploading
              ? CircularProgressIndicator()
              : _isRecording
                  ? GestureDetector(
                      onLongPressStart: _onLongPressStart,
                      onLongPressEnd: _onLongPressEnd,
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.redAccent,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        padding: EdgeInsets.all(20),
                        child: Text(
                          "END (長押し3秒)",
                          style: TextStyle(
                              color: Colors.white, fontWeight: FontWeight.bold),
                        ),
                      ),
                    )
                  : ElevatedButton(
                      onPressed: _startRecording,
                      child: Text("START"),
                    ),
        ),
      ),
    );
  }
}

/// CSV変換用
class ListToCsvConverter {
  const ListToCsvConverter();

  String convert(List<List<dynamic>> rows) {
    return rows.map((r) => r.map(_escape).join(",")).join("\n");
  }

  String _escape(dynamic field) {
    if (field == null) return '';
    String str = field.toString();
    if (str.contains(',') || str.contains('\n') || str.contains('"')) {
      str = '"' + str.replaceAll('"', '""') + '"';
    }
    return str;
  }
}
