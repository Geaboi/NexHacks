// lib/providers/sensor_provider.dart
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// Single IMU sample matching the embedded imu_sample_t struct
/// With converted floating-point values in physical units
class ImuSample {
  final int timeOffset; // ms from session start (after RTT adjustment)

  // Raw int16 values (kept for debugging)
  final List<int> rawAccA;
  final List<int> rawGyroA;
  final List<int> rawAccB;
  final List<int> rawGyroB;

  // Converted floating-point values in physical units
  final List<double> accA; // [x, y, z] in g (Earth gravity units)
  final List<double> gyroA; // [x, y, z] in degrees/second
  final List<double> accB; // [x, y, z] in g
  final List<double> gyroB; // [x, y, z] in degrees/second

  ImuSample({
    required this.timeOffset,
    required this.rawAccA,
    required this.rawGyroA,
    required this.rawAccB,
    required this.rawGyroB,
    required this.accA,
    required this.gyroA,
    required this.accB,
    required this.gyroB,
  });

  /// Convert to JSON format expected by backend sensor fusion
  /// Backend expects: dict with keys xA, yA, zA, xB, yB, zB (gyro values in °/s)
  Map<String, dynamic> toJson() => {
    'time_offset': timeOffset,
    // Gyroscope values for sensor fusion (in degrees/second)
    'xA': gyroA[0],
    'yA': gyroA[1],
    'zA': gyroA[2],
    'xB': gyroB[0],
    'yB': gyroB[1],
    'zB': gyroB[2],
    // Accelerometer values (in g)
    'acc_A': accA,
    'acc_B': accB,
    // Include gyro arrays for convenience
    'gyro_A': gyroA,
    'gyro_B': gyroB,
  };

  /// Full JSON with raw values for debugging
  Map<String, dynamic> toFullJson() => {
    'time_offset': timeOffset,
    'raw_acc_A': rawAccA,
    'raw_gyro_A': rawGyroA,
    'raw_acc_B': rawAccB,
    'raw_gyro_B': rawGyroB,
    'acc_A': accA,
    'gyro_A': gyroA,
    'acc_B': accB,
    'gyro_B': gyroB,
  };
}

/// BLE packet matching ble_packet_t struct (seq_id + 3 samples)
class BlePacket {
  final int seqId;
  final List<ImuSample> samples;

  BlePacket({required this.seqId, required this.samples});
}

/// State for the sensor provider
class SensorState {
  final bool isScanning;
  final bool isConnected;
  final bool isRecording;
  final BluetoothDevice? device;
  final String statusMessage;
  final int? rttOffsetMs; // RTT/2 offset for time synchronization
  final List<ImuSample> sampleBuffer;
  final int lastSeqId;
  final int droppedPackets;

  const SensorState({
    this.isScanning = false,
    this.isConnected = false,
    this.isRecording = false,
    this.device,
    this.statusMessage = 'Not connected',
    this.rttOffsetMs,
    this.sampleBuffer = const [],
    this.lastSeqId = -1,
    this.droppedPackets = 0,
  });

  SensorState copyWith({
    bool? isScanning,
    bool? isConnected,
    bool? isRecording,
    BluetoothDevice? device,
    String? statusMessage,
    int? rttOffsetMs,
    List<ImuSample>? sampleBuffer,
    int? lastSeqId,
    int? droppedPackets,
  }) {
    return SensorState(
      isScanning: isScanning ?? this.isScanning,
      isConnected: isConnected ?? this.isConnected,
      isRecording: isRecording ?? this.isRecording,
      device: device ?? this.device,
      statusMessage: statusMessage ?? this.statusMessage,
      rttOffsetMs: rttOffsetMs ?? this.rttOffsetMs,
      sampleBuffer: sampleBuffer ?? this.sampleBuffer,
      lastSeqId: lastSeqId ?? this.lastSeqId,
      droppedPackets: droppedPackets ?? this.droppedPackets,
    );
  }
}

/// Notifier for managing BLE sensor connection and data
class SensorNotifier extends Notifier<SensorState> {
  // BLE UUIDs matching embedded code
  static const String serviceUuid = '181c';
  static const String statusCharUuid = '0000';
  static const String ackCharUuid = '0001';
  static const String dataCharUuid = '0002';
  static const String deviceName = 'SmartPT_Device';

  // MPU6050 Conversion Constants
  // Default Full Scale Range (FSR) settings when not explicitly configured:
  // - Accelerometer: ±2g  → Sensitivity = 16384 LSB/g
  // - Gyroscope: ±250°/s  → Sensitivity = 131.0 LSB/(°/s)
  //
  // To convert raw int16 to physical units:
  //   accel_g = raw_value / ACCEL_SENSITIVITY
  //   gyro_dps = raw_value / GYRO_SENSITIVITY
  static const double accelSensitivity = 16384.0; // LSB/g for ±2g range
  static const double gyroSensitivity = 131.0; // LSB/(°/s) for ±250°/s range

  BluetoothCharacteristic? _statusChar;
  BluetoothCharacteristic? _ackChar;
  BluetoothCharacteristic? _dataChar;

  StreamSubscription<List<ScanResult>>? _scanSubscription;
  StreamSubscription<BluetoothConnectionState>? _connectionSubscription;
  StreamSubscription<List<int>>? _ackSubscription;
  StreamSubscription<List<int>>? _dataSubscription;

  DateTime? _startCommandTime;
  Completer<void>? _ackCompleter;

  @override
  SensorState build() {
    ref.onDispose(() {
      _cleanup();
    });
    return const SensorState();
  }

  void _cleanup() {
    _scanSubscription?.cancel();
    _connectionSubscription?.cancel();
    _ackSubscription?.cancel();
    _dataSubscription?.cancel();
    state.device?.disconnect();
  }

  /// Scan for and connect to the SmartPT device
  Future<void> scanAndConnect() async {
    if (state.isScanning || state.isConnected) return;

    state = state.copyWith(
      isScanning: true,
      statusMessage: 'Scanning for $deviceName...',
    );

    try {
      // Check if Bluetooth is on
      if (await FlutterBluePlus.adapterState.first !=
          BluetoothAdapterState.on) {
        state = state.copyWith(
          isScanning: false,
          statusMessage: 'Bluetooth is off',
        );
        return;
      }

      // Start scanning
      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 10),
        withServices: [Guid(serviceUuid)],
      );

      _scanSubscription = FlutterBluePlus.scanResults.listen((results) async {
        for (ScanResult result in results) {
          if (result.device.platformName == deviceName) {
            await FlutterBluePlus.stopScan();
            await _connectToDevice(result.device);
            return;
          }
        }
      });

      // Handle scan timeout
      await Future.delayed(const Duration(seconds: 10));
      if (state.isScanning && !state.isConnected) {
        await FlutterBluePlus.stopScan();
        state = state.copyWith(
          isScanning: false,
          statusMessage: 'Device not found',
        );
      }
    } catch (e) {
      state = state.copyWith(
        isScanning: false,
        statusMessage: 'Scan error: $e',
      );
    }
  }

  Future<void> _connectToDevice(BluetoothDevice device) async {
    state = state.copyWith(isScanning: false, statusMessage: 'Connecting...');

    try {
      await device.connect(timeout: const Duration(seconds: 10));

      // Listen for disconnection
      _connectionSubscription = device.connectionState.listen((
        connectionState,
      ) {
        if (connectionState == BluetoothConnectionState.disconnected) {
          _onDisconnected();
        }
      });

      // Discover services
      List<BluetoothService> services = await device.discoverServices();

      for (BluetoothService service in services) {
        if (service.uuid.toString().toLowerCase().contains(serviceUuid)) {
          for (BluetoothCharacteristic char in service.characteristics) {
            String charUuid = char.uuid.toString().toLowerCase();
            if (charUuid.contains(statusCharUuid)) {
              _statusChar = char;
            } else if (charUuid.contains(ackCharUuid)) {
              _ackChar = char;
              // Subscribe to ACK notifications
              await char.setNotifyValue(true);
              _ackSubscription = char.onValueReceived.listen(_onAckReceived);
            } else if (charUuid.contains(dataCharUuid)) {
              _dataChar = char;
              // Subscribe to data notifications
              await char.setNotifyValue(true);
              _dataSubscription = char.onValueReceived.listen(_onDataReceived);
            }
          }
        }
      }

      if (_statusChar == null || _ackChar == null || _dataChar == null) {
        throw Exception('Required characteristics not found');
      }

      state = state.copyWith(
        isConnected: true,
        device: device,
        statusMessage: 'Connected to $deviceName',
      );
    } catch (e) {
      await device.disconnect();
      state = state.copyWith(
        isConnected: false,
        statusMessage: 'Connection failed: $e',
      );
    }
  }

  void _onDisconnected() {
    _ackSubscription?.cancel();
    _dataSubscription?.cancel();
    _statusChar = null;
    _ackChar = null;
    _dataChar = null;

    state = state.copyWith(
      isConnected: false,
      isRecording: false,
      device: null,
      statusMessage: 'Disconnected',
    );
  }

  /// Start recording - sends "Start" command and calculates RTT
  Future<bool> startRecording() async {
    if (!state.isConnected || _statusChar == null) {
      state = state.copyWith(statusMessage: 'Not connected');
      return false;
    }

    try {
      // Clear buffer for new session
      state = state.copyWith(
        sampleBuffer: [],
        lastSeqId: -1,
        droppedPackets: 0,
        statusMessage: 'Starting recording...',
      );

      // Create completer for ACK
      _ackCompleter = Completer<void>();

      // Record time and send Start command
      _startCommandTime = DateTime.now();
      await _statusChar!.write(utf8.encode('Start'), withoutResponse: false);

      // Wait for ACK (with timeout)
      await _ackCompleter!.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          throw TimeoutException('ACK timeout');
        },
      );

      state = state.copyWith(
        isRecording: true,
        statusMessage: 'Recording (RTT offset: ${state.rttOffsetMs}ms)',
      );

      return true;
    } catch (e) {
      state = state.copyWith(statusMessage: 'Start failed: $e');
      return false;
    }
  }

  /// Handle ACK notification - calculate RTT
  void _onAckReceived(List<int> value) {
    String ackStr = utf8.decode(value);

    if (ackStr == 'ACK' && _startCommandTime != null && _ackCompleter != null) {
      final rtt = DateTime.now().difference(_startCommandTime!).inMilliseconds;
      final rttOffset = rtt ~/ 2;

      state = state.copyWith(rttOffsetMs: rttOffset);

      if (!_ackCompleter!.isCompleted) {
        _ackCompleter!.complete();
      }
    }
  }

  /// Handle incoming IMU data packet
  void _onDataReceived(List<int> value) {
    if (!state.isRecording) return;

    try {
      final packet = _parsePacket(Uint8List.fromList(value));

      // Check for dropped packets
      int dropped = 0;
      if (state.lastSeqId >= 0 && packet.seqId > state.lastSeqId + 1) {
        dropped = packet.seqId - state.lastSeqId - 1;
      }

      // Add samples to buffer
      final newBuffer = List<ImuSample>.from(state.sampleBuffer)
        ..addAll(packet.samples);

      state = state.copyWith(
        sampleBuffer: newBuffer,
        lastSeqId: packet.seqId,
        droppedPackets: state.droppedPackets + dropped,
      );
    } catch (e) {
      // Parsing error - skip this packet
      print('Packet parse error: $e');
    }
  }

  /// Parse raw BLE packet bytes into BlePacket
  BlePacket _parsePacket(Uint8List data) {
    // ble_packet_t: uint32_t seq_id + 3x imu_sample_t
    // imu_sample_t: uint16_t time_offset + int16_t[3] acc_A + int16_t[3] gyro_A
    //               + int16_t[3] acc_B + int16_t[3] gyro_B = 26 bytes
    // Total: 4 + 3*26 = 82 bytes
    //
    // ENDIANNESS:
    // - seq_id, time_offset: Little Endian (set by ESP32)
    // - acc_*, gyro_*: Big Endian (raw from MPU6050)

    final byteData = ByteData.sublistView(data);
    int offset = 0;

    // Parse seq_id (little-endian uint32 - from ESP32)
    final seqId = byteData.getUint32(offset, Endian.little);
    offset += 4;

    final samples = <ImuSample>[];

    for (int i = 0; i < 3; i++) {
      // time_offset (uint16, little-endian - from ESP32)
      final timeOffset = byteData.getUint16(offset, Endian.little);
      offset += 2;

      // Apply RTT offset for time synchronization
      final adjustedTime = timeOffset + (state.rttOffsetMs ?? 0);

      // acc_A[3] (int16 x 3, BIG ENDIAN - raw from MPU6050)
      final rawAccA = [
        byteData.getInt16(offset, Endian.big),
        byteData.getInt16(offset + 2, Endian.big),
        byteData.getInt16(offset + 4, Endian.big),
      ];
      offset += 6;

      // gyro_A[3] (int16 x 3, BIG ENDIAN - raw from MPU6050)
      final rawGyroA = [
        byteData.getInt16(offset, Endian.big),
        byteData.getInt16(offset + 2, Endian.big),
        byteData.getInt16(offset + 4, Endian.big),
      ];
      offset += 6;

      // acc_B[3] (int16 x 3, BIG ENDIAN - raw from MPU6050)
      final rawAccB = [
        byteData.getInt16(offset, Endian.big),
        byteData.getInt16(offset + 2, Endian.big),
        byteData.getInt16(offset + 4, Endian.big),
      ];
      offset += 6;

      // gyro_B[3] (int16 x 3, BIG ENDIAN - raw from MPU6050)
      final rawGyroB = [
        byteData.getInt16(offset, Endian.big),
        byteData.getInt16(offset + 2, Endian.big),
        byteData.getInt16(offset + 4, Endian.big),
      ];
      offset += 6;

      // Convert raw values to physical units
      // Accelerometer: raw / 16384.0 = value in g (Earth gravity)
      // Gyroscope: raw / 131.0 = value in degrees/second
      final accA = rawAccA.map((v) => v / accelSensitivity).toList();
      final gyroA = rawGyroA.map((v) => v / gyroSensitivity).toList();
      final accB = rawAccB.map((v) => v / accelSensitivity).toList();
      final gyroB = rawGyroB.map((v) => v / gyroSensitivity).toList();

      samples.add(
        ImuSample(
          timeOffset: adjustedTime,
          rawAccA: rawAccA,
          rawGyroA: rawGyroA,
          rawAccB: rawAccB,
          rawGyroB: rawGyroB,
          accA: accA,
          gyroA: gyroA,
          accB: accB,
          gyroB: gyroB,
        ),
      );
    }

    return BlePacket(seqId: seqId, samples: samples);
  }

  /// Stop recording - sends "Stop" command
  Future<void> stopRecording() async {
    if (!state.isConnected || _statusChar == null) return;

    try {
      await _statusChar!.write(utf8.encode('Stop'), withoutResponse: false);

      state = state.copyWith(
        isRecording: false,
        statusMessage:
            'Recording stopped (${state.sampleBuffer.length} samples)',
      );
    } catch (e) {
      state = state.copyWith(
        isRecording: false,
        statusMessage: 'Stop error: $e',
      );
    }
  }

  // Get all collected samples as JSON string
  // Format compatible with backend sensor fusion (rtmpose3d_handler.py):
  //  {
  //   "samples": [
  //     {
  //       "time_offset": 0,
  //       "xA": -0.76,  "yA": 0.38,  "zA": 0.19,   // Gyro A in °/s
  //       "xB": -0.73,  "yB": 0.37,  "zB": 0.21,   // Gyro B in °/s
  //       "acc_A": [0.0625, -0.0312, 1.0],         // Accel A in g
  //       "acc_B": [0.0610, -0.0305, 0.9766],      // Accel B in g
  //       "gyro_A": [-0.76, 0.38, 0.19],           // Gyro A array
  //       "gyro_B": [-0.73, 0.37, 0.21]            // Gyro B array
  //     },
  //     ...
  //   ],
  //   "total_samples": 300,
  //   "dropped_packets": 0,
  //   "rtt_offset_ms": 15
  //  }
  //
  // Conversion from raw int16 to physical units:
  //   - Accelerometer: raw / 16384.0 = g (±2g range default)
  //   - Gyroscope: raw / 131.0 = °/s (±250°/s range default)
  String getSamplesAsJson() {
    final jsonList = state.sampleBuffer.map((s) => s.toJson()).toList();
    return jsonEncode({'samples': jsonList});
  }

  /// Get samples as a JSON-encodable map
  Map<String, dynamic> getSamplesAsMap() {
    return {
      'samples': state.sampleBuffer.map((s) => s.toJson()).toList(),
      'total_samples': state.sampleBuffer.length,
      'dropped_packets': state.droppedPackets,
      'rtt_offset_ms': state.rttOffsetMs,
    };
  }

  /// Get samples in format expected by backend sensor fusion
  /// Returns list of tuples: [(dict, timestamp_ms), ...]
  /// where dict has keys: xA, yA, zA, xB, yB, zB (gyro in °/s)
  List<Map<String, dynamic>> getSamplesForBackend() {
    return state.sampleBuffer
        .map(
          (s) => {
            'data': {
              'xA': s.gyroA[0],
              'yA': s.gyroA[1],
              'zA': s.gyroA[2],
              'xB': s.gyroB[0],
              'yB': s.gyroB[1],
              'zB': s.gyroB[2],
            },
            'timestamp_ms': s.timeOffset,
          },
        )
        .toList();
  }

  /// Clear the sample buffer
  void clearBuffer() {
    state = state.copyWith(sampleBuffer: []);
  }

  /// Disconnect from device
  Future<void> disconnect() async {
    if (state.isRecording) {
      await stopRecording();
    }
    await state.device?.disconnect();
  }
}

/// Provider definition
final sensorProvider = NotifierProvider<SensorNotifier, SensorState>(
  SensorNotifier.new,
);
