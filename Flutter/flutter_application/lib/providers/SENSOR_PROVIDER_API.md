# Sensor Provider API Documentation

This document describes the public methods and state available through `sensorProvider` for interfacing with the SmartPT BLE IMU device.

---

## Provider Access

```dart
// Watch state reactively in widgets
final sensorState = ref.watch(sensorProvider);

// Access notifier for method calls
final sensorNotifier = ref.read(sensorProvider.notifier);
```

---

## State Properties

| Property | Type | Description |
|----------|------|-------------|
| `isScanning` | `bool` | True while scanning for BLE devices |
| `isConnected` | `bool` | True when connected to SmartPT device |
| `isRecording` | `bool` | True when actively recording IMU data |
| `device` | `BluetoothDevice?` | Connected device reference |
| `statusMessage` | `String` | Human-readable status for UI display |
| `rttOffsetMs` | `int?` | RTT/2 offset in ms for time sync |
| `sampleBuffer` | `List<ImuSample>` | Collected IMU samples |
| `lastSeqId` | `int` | Last received packet sequence ID |
| `droppedPackets` | `int` | Count of detected dropped packets |

---

## Methods

### `scanAndConnect()`

**Signature:** `Future<void> scanAndConnect()`

**When to call:** On app startup or when user taps "Connect" button. Call before any recording can begin.

**Parameters:** None

**Description:** Scans for the SmartPT BLE device and automatically connects when found. Discovers services and subscribes to data/ACK notifications.

**Example:**
```dart
await ref.read(sensorProvider.notifier).scanAndConnect();
```

---

### `startRecording()`

**Signature:** `Future<bool> startRecording()`

**When to call:** When video recording starts. Must be connected first.

**Parameters:** None

**Returns:** `true` if recording started successfully, `false` on failure.

**Description:** 
1. Clears the sample buffer
2. Sends "Start" command to embedded device
3. Waits for ACK notification
4. Calculates RTT/2 offset for time synchronization
5. Begins buffering incoming IMU data

**Example:**
```dart
if (ref.read(sensorProvider).isConnected) {
  final success = await ref.read(sensorProvider.notifier).startRecording();
  if (success) {
    // Start video recording
  }
}
```

---

### `stopRecording()`

**Signature:** `Future<void> stopRecording()`

**When to call:** When video recording stops.

**Parameters:** None

**Description:** Sends "Stop" command to embedded device. IMU data remains in buffer for retrieval.

**Example:**
```dart
await ref.read(sensorProvider.notifier).stopRecording();
final samples = ref.read(sensorProvider.notifier).getSamplesAsMap();
```

---

### `getSamplesAsJson()`

**Signature:** `String getSamplesAsJson()`

**When to call:** After stopping recording, when you need JSON string for HTTP request body.

**Parameters:** None

**Returns:** JSON string with all collected samples.

**Output Format:**
```json
{
  "samples": [
    {
      "time_offset": 150,
      "xA": -0.76, "yA": 0.38, "zA": 0.19,
      "xB": -0.73, "yB": 0.37, "zB": 0.21,
      "acc_A": [0.0625, -0.0312, 1.0],
      "acc_B": [0.0610, -0.0305, 0.9766],
      "gyro_A": [-0.76, 0.38, 0.19],
      "gyro_B": [-0.73, 0.37, 0.21]
    }
  ]
}
```

---

### `getSamplesAsMap()`

**Signature:** `Map<String, dynamic> getSamplesAsMap()`

**When to call:** After stopping recording, when you need a Dart map for further processing or JSON encoding with metadata.

**Parameters:** None

**Returns:** Map containing samples and metadata.

**Output Format:**
```dart
{
  'samples': [...],           // List of sample maps
  'total_samples': 300,       // Total sample count
  'dropped_packets': 0,       // Detected packet drops
  'rtt_offset_ms': 15,        // RTT/2 offset used
}
```

---

### `getSamplesForBackend()`

**Signature:** `List<Map<String, dynamic>> getSamplesForBackend()`

**When to call:** When preparing data for the Python backend's Kalman filter / sensor fusion.

**Parameters:** None

**Returns:** List of maps in format expected by `rtmpose3d_handler.py`.

**Output Format:**
```dart
[
  {
    'data': {
      'xA': -0.76, 'yA': 0.38, 'zA': 0.19,  // Gyro A (°/s)
      'xB': -0.73, 'yB': 0.37, 'zB': 0.21,  // Gyro B (°/s)
    },
    'timestamp_ms': 150,
  },
  ...
]
```

**Backend Usage:**
```python
# In Python backend
w_rel = sample['data']['yB'] - sample['data']['yA']  # Relative angular velocity
```

---

### `clearBuffer()`

**Signature:** `void clearBuffer()`

**When to call:** When starting a new session without full reconnect, or to free memory.

**Parameters:** None

**Description:** Clears all collected IMU samples from buffer.

---

### `disconnect()`

**Signature:** `Future<void> disconnect()`

**When to call:** When leaving the recording screen or app cleanup.

**Parameters:** None

**Description:** Stops recording if active, then disconnects from BLE device.

---

## Data Units

| Measurement | Unit | Conversion |
|-------------|------|------------|
| Accelerometer | g (Earth gravity) | `raw / 16384.0` |
| Gyroscope | °/s (degrees/second) | `raw / 131.0` |
| Time offset | milliseconds | Adjusted by RTT/2 |

**Note:** These conversions assume default MPU6050 FSR settings (±2g accel, ±250°/s gyro).

---

## Typical Usage Flow

```dart
// 1. Connect on screen init
@override
void initState() {
  super.initState();
  ref.read(sensorProvider.notifier).scanAndConnect();
}

// 2. Start recording with video
Future<void> _startRecording() async {
  final sensor = ref.read(sensorProvider.notifier);
  
  if (ref.read(sensorProvider).isConnected) {
    await sensor.startRecording();
  }
  
  await _cameraController.startVideoRecording();
}

// 3. Stop and retrieve data
Future<void> _stopRecording() async {
  await _cameraController.stopVideoRecording();
  
  final sensor = ref.read(sensorProvider.notifier);
  await sensor.stopRecording();
  
  // Get data for backend
  final sensorData = sensor.getSamplesAsMap();
  print('Collected ${sensorData['total_samples']} IMU samples');
}

// 4. Cleanup
@override
void dispose() {
  ref.read(sensorProvider.notifier).disconnect();
  super.dispose();
}
```
