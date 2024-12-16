import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: SensorRecorderPage(),
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

  // 位置情報と加速度センサのデータを別々に保持
  List<List<dynamic>> _locationDataRows = [];
  List<List<dynamic>> _accelDataRows = [];

  Timer? _locationTimer;
  StreamSubscription<AccelerometerEvent>? _accelSub;
  DateTime? _recordStartTime;

  // LambdaエンドポイントURLをハードコーディング
  final String lambdaUrl =
      "https://49icw5dap1.execute-api.ap-northeast-1.amazonaws.com/upload";

  @override
  void initState() {
    super.initState();
    _requestPermissions();
  }

  Future<void> _requestPermissions() async {
    await Geolocator.requestPermission();
    await Permission.sensors.request();
    await Permission.storage.request(); // ファイル保存のためのストレージ権限も追加
  }

  void _startRecording() {
    setState(() {
      _isRecording = true;
      _recordStartTime = DateTime.now();
      _locationDataRows = [];
      _accelDataRows = [];

      // 位置情報用のヘッダー
      _locationDataRows.add(["timestamp(ms)", "latitude", "longitude"]);

      // 加速度センサ用のヘッダー
      _accelDataRows.add(["timestamp(ms)", "accelX", "accelY", "accelZ"]);
    });

    // 位置情報を1Hzで取得
    _locationTimer = Timer.periodic(Duration(seconds: 1), (timer) async {
      Position pos = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high);
      _recordLocationData(position: pos);
    });

    // 加速度センサを60Hz（約16ms間隔）で取得
    _accelSub = accelerometerEvents.listen((event) {
      _recordAccelData(accelX: event.x, accelY: event.y, accelZ: event.z);
    });
  }

  Future<void> _stopRecording() async {
    _locationTimer?.cancel();
    _accelSub?.cancel();

    setState(() {
      _isRecording = false;
    });

    // 位置情報をCSVに変換
    String locationCsv = const ListToCsvConverter().convert(_locationDataRows);

    // 加速度センサデータをCSVに変換
    String accelCsv = const ListToCsvConverter().convert(_accelDataRows);

    // ローカルへ保存
    final directory = await getApplicationDocumentsDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final locationFilePath = "${directory.path}/location_data_$timestamp.csv";
    final accelFilePath = "${directory.path}/accel_data_$timestamp.csv";

    final locationFile = File(locationFilePath);
    final accelFile = File(accelFilePath);

    await locationFile.writeAsString(locationCsv);
    await accelFile.writeAsString(accelCsv);

    // S3へアップロード (Lambda経由)
    setState(() {
      _uploading = true;
    });
    try {
      // 位置情報ファイルのアップロード
      final locationCsvBase64 = base64Encode(locationCsv.codeUnits);
      final locationResponse = await http.post(Uri.parse(lambdaUrl),
          headers: {"Content-Type": "application/json"},
          body: jsonEncode({
            "filename": "location_data_$timestamp.csv",
            "filedata_base64": locationCsvBase64
          }));

      if (locationResponse.statusCode == 200) {
        print("Location data upload success");
      } else {
        print(
            "Location data upload failed: ${locationResponse.statusCode}, ${locationResponse.body}");
      }

      // 加速度センサファイルのアップロード
      final accelCsvBase64 = base64Encode(accelCsv.codeUnits);
      final accelResponse = await http.post(Uri.parse(lambdaUrl),
          headers: {"Content-Type": "application/json"},
          body: jsonEncode({
            "filename": "accel_data_$timestamp.csv",
            "filedata_base64": accelCsvBase64
          }));

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
    final elapsedMs = _recordStartTime == null
        ? 0
        : now.millisecondsSinceEpoch - _recordStartTime!.millisecondsSinceEpoch;
    double lat = position?.latitude ?? double.nan;
    double lon = position?.longitude ?? double.nan;
    _locationDataRows.add([elapsedMs, lat, lon]);
  }

  void _recordAccelData({double? accelX, double? accelY, double? accelZ}) {
    final now = DateTime.now();
    final elapsedMs = _recordStartTime == null
        ? 0
        : now.millisecondsSinceEpoch - _recordStartTime!.millisecondsSinceEpoch;
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("Sensor Recorder"),
      ),
      body: Center(
          child: _uploading
              ? CircularProgressIndicator()
              : _isRecording
                  ? GestureDetector(
                      onLongPressStart: _onLongPressStart,
                      onLongPressEnd: _onLongPressEnd,
                      child: Container(
                        color: Colors.red,
                        padding: EdgeInsets.all(20),
                        child: Text("END (長押し3秒)"),
                      ),
                    )
                  : ElevatedButton(
                      onPressed: _startRecording, child: Text("START"))),
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
