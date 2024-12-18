import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:dchs_motion_sensors/dchs_motion_sensors.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart'; // BLE用

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
  StreamSubscription? _accelSub;
  DateTime? _recordStartTime;

  final String lambdaUrl =
      "https://49icw5dap1.execute-api.ap-northeast-1.amazonaws.com/upload";

  String? _userName;

  // BLE関連
  BluetoothDevice? _connectedDevice;
  BluetoothCharacteristic? _heartRateCharacteristic;
  int? _currentHeartRate; // 最後に取得した心拍数
  bool _bleConnected = false;
  StreamSubscription<List<ScanResult>>? _scanSubscription;
  List<ScanResult> _scanResultsList = [];

  @override
  void initState() {
    super.initState();
    _requestPermissions();
    _checkUserName();
    // 加速度センサー取得頻度を100Hz程度
    motionSensors.accelerometerUpdateInterval =
        Duration.microsecondsPerSecond ~/ 100;
  }

  Future<void> _requestPermissions() async {
    // 必要なパーミッション要求
    await Geolocator.requestPermission();
    await Permission.sensors.request();
    await Permission.storage.request();
    await Permission.location.request();
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

  Future<void> _startRecording() async {
    if (_userName == null || _userName!.isEmpty) {
      _showNameInputDialog();
      return;
    }

    if (!_bleConnected) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text("デバイス未接続のため録画開始できません")));
      return;
    }

    setState(() {
      _isRecording = true;
      _recordStartTime = DateTime.now();
      _locationDataRows = [];
      _accelDataRows = [];

      // CSVにheartRateカラムを追加
      _locationDataRows
          .add(["timestamp(ms)", "latitude", "longitude", "heartRate"]);
      _accelDataRows.add(["timestamp(ms)", "accelX", "accelY", "accelZ"]);
    });

    // 位置情報を1Hzで取得
    _locationTimer = Timer.periodic(Duration(seconds: 1), (timer) async {
      Position pos = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high);
      _recordLocationData(position: pos);
    });

    // 加速度データ取得
    _accelSub = motionSensors.accelerometer.listen((event) {
      _recordAccelData(accelX: event.x, accelY: event.y, accelZ: event.z);
    });
  }

  // デバイス検索・接続処理
  Future<void> _reloadAndConnectDevice() async {
    // スキャン開始前にリストを初期化
    _scanResultsList.clear();
    await FlutterBluePlus.startScan(timeout: Duration(seconds: 5));
    _scanSubscription?.cancel();
    _scanSubscription = FlutterBluePlus.scanResults.listen((results) async {
      setState(() {
        _scanResultsList = results;
      });
    });

    await Future.delayed(Duration(seconds: 5));
    await FlutterBluePlus.stopScan();

    // スキャンが完了したら、ユーザーにデバイスを選ばせる
    if (_scanResultsList.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text("デバイスが見つかりませんでした")));
      return;
    }

    _showDeviceSelectionDialog();
  }

  void _showDeviceSelectionDialog() {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text("接続するデバイスを選択"),
          content: Container(
            width: double.maxFinite,
            height: 200,
            child: ListView.builder(
              itemCount: _scanResultsList.length,
              itemBuilder: (context, index) {
                final device = _scanResultsList[index].device;
                final name = device.name.isNotEmpty ? device.name : "(No name)";
                return ListTile(
                  title: Text(name),
                  subtitle: Text(device.id.toString()),
                  onTap: () {
                    Navigator.of(context).pop();
                    _connectToSelectedDevice(device);
                  },
                );
              },
            ),
          ),
        );
      },
    );
  }

  Future<void> _connectToSelectedDevice(BluetoothDevice device) async {
    setState(() {
      _bleConnected = false;
      _connectedDevice = null;
      _heartRateCharacteristic = null;
      _currentHeartRate = null;
    });

    try {
      await device.connect();
    } catch (e) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text("接続に失敗しました: $e")));
      return;
    }
    _connectedDevice = device;

    List<BluetoothService> services = await device.discoverServices();

    // Heart Rate Service探索
    final heartRateServiceList = services
        .where((s) => s.uuid.toString().toLowerCase().contains("180d"))
        .toList();
    BluetoothService? heartRateService =
        heartRateServiceList.isNotEmpty ? heartRateServiceList.first : null;

    if (heartRateService == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text("心拍センサーサービスが見つかりませんでした")));
      await device.disconnect();
      return;
    }

    // Heart Rate Measurement Char探索
    final hrCharList = heartRateService.characteristics
        .where((c) => c.uuid.toString().toLowerCase().contains("2a37"))
        .toList();
    BluetoothCharacteristic? hrChar =
        hrCharList.isNotEmpty ? hrCharList.first : null;

    if (hrChar == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text("心拍数計測キャラクタリスティックが見つかりませんでした")));
      await device.disconnect();
      return;
    }

    _heartRateCharacteristic = hrChar;
    await hrChar.setNotifyValue(true);
    hrChar.value.listen((value) {
      if (value.isNotEmpty) {
        int hr = value[1];
        setState(() {
          _currentHeartRate = hr;
        });
      }
    });

    setState(() {
      _bleConnected = true;
    });
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text("デバイス '${device.name}' に接続しました")));
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
    double hr = _currentHeartRate?.toDouble() ?? double.nan;
    _locationDataRows.add([elapsedMs, lat, lon, hr]);
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
    // BLE接続状態とデバイス名表示用ウィジェット
    Widget connectionIndicator = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: _bleConnected ? Colors.green : Colors.red,
            shape: BoxShape.circle,
          ),
        ),
        SizedBox(width: 5),
        Text(_connectedDevice?.name.isNotEmpty == true
            ? _connectedDevice!.name
            : "No Device")
      ],
    );

    return Scaffold(
      appBar: AppBar(
        title: Text("Sensor Recorder"),
        leading: IconButton(
          icon: Icon(Icons.person),
          onPressed: _resetUserName,
          tooltip: "氏名変更",
        ),
        actions: [
          // リロードボタン: デバイスを再スキャンし、ユーザーに選択させる
          IconButton(
            icon: Icon(Icons.refresh),
            onPressed: () {
              _reloadAndConnectDevice();
            },
            tooltip: "リロード",
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: connectionIndicator,
          )
        ],
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient:
              LinearGradient(colors: [Colors.white, Colors.indigo.shade50]),
        ),
        child: Center(
          child: _uploading
              ? CircularProgressIndicator()
              : Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // START後に心拍数表示
                    if (_isRecording)
                      Text(
                        _currentHeartRate != null
                            ? "Heart Rate: $_currentHeartRate bpm"
                            : "Heart Rate: ---",
                        style: TextStyle(
                            fontSize: 24, fontWeight: FontWeight.bold),
                      ),
                    SizedBox(height: 20),
                    _isRecording
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
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold),
                              ),
                            ),
                          )
                        : ElevatedButton(
                            onPressed: _bleConnected ? _startRecording : null,
                            // 接続前はnullで無効化
                            child: Text("START"),
                          ),
                  ],
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
