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

  List<List<dynamic>> _dataRows = [];
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
  }

  void _startRecording() {
    setState(() {
      _isRecording = true;
      _recordStartTime = DateTime.now();
      _dataRows = [];
      _dataRows.add([
        "timestamp(ms)",
        "latitude",
        "longitude",
        "accelX",
        "accelY",
        "accelZ"
      ]);
    });

    _locationTimer = Timer.periodic(Duration(seconds: 1), (timer) async {
      Position pos = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high);
      _recordData(position: pos);
    });

    _accelSub = accelerometerEvents.listen((event) {
      _recordData(accelX: event.x, accelY: event.y, accelZ: event.z);
    });
  }

  Future<void> _stopRecording() async {
    _locationTimer?.cancel();
    _accelSub?.cancel();

    setState(() {
      _isRecording = false;
    });

    // データをCSVに変換
    String csvData = const ListToCsvConverter().convert(_dataRows);

    // ローカルへ一旦保存(必要であれば)
    final directory = await getApplicationDocumentsDirectory();
    final filePath =
        "${directory.path}/sensor_data_${DateTime.now().millisecondsSinceEpoch}.csv";
    final file = File(filePath);
    await file.writeAsString(csvData);

    // S3へアップロード (Lambda経由)
    setState(() {
      _uploading = true;
    });
    try {
      final csvBase64 = base64Encode(csvData.codeUnits);
      final response = await http.post(Uri.parse(lambdaUrl),
          headers: {"Content-Type": "application/json"},
          body: jsonEncode({
            "filename": "data_${DateTime.now().millisecondsSinceEpoch}.csv",
            "filedata_base64": csvBase64
          }));

      if (response.statusCode == 200) {
        print("Upload success");
      } else {
        print("Upload failed: ${response.statusCode}, ${response.body}");
      }
    } catch (e) {
      print("Upload error: $e");
    }

    setState(() {
      _uploading = false;
    });
  }

  void _recordData(
      {Position? position, double? accelX, double? accelY, double? accelZ}) {
    final now = DateTime.now();
    final elapsedMs = _recordStartTime == null
        ? 0
        : now.millisecondsSinceEpoch - _recordStartTime!.millisecondsSinceEpoch;
    double lat = position?.latitude ?? double.nan;
    double lon = position?.longitude ?? double.nan;
    double ax = accelX ?? double.nan;
    double ay = accelY ?? double.nan;
    double az = accelZ ?? double.nan;
    _dataRows.add([elapsedMs, lat, lon, ax, ay, az]);
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
