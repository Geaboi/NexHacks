import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';

/// Configuration for the frame streaming service
/// Maps to Overshoot API's processing and inference config
class StreamConfig {
  // Inference config
  final String prompt;
  final String model;
  final String backend;
  final String? outputSchemaJson;

  // Processing config
  final double samplingRatio;
  final int fps;
  final double clipLengthSeconds;
  final double delaySeconds;

  // Frame dimensions (for RGB24 conversion)
  final int width;
  final int height;

  const StreamConfig({
    this.prompt = 'Describe what you see',
    this.model = 'gemini-2.0-flash',
    this.backend = 'gemini',
    this.outputSchemaJson,
    this.samplingRatio = 1.0,
    this.fps = 10,
    this.clipLengthSeconds = 1.0,
    this.delaySeconds = 1.0,
    this.width = 640,
    this.height = 480,
  });

  Map<String, dynamic> toJson() => {
    'type': 'config',
    'inference': {
      'prompt': prompt,
      'model': model,
      'backend': backend,
      if (outputSchemaJson != null) 'output_schema_json': outputSchemaJson,
    },
    'processing': {
      'sampling_ratio': samplingRatio,
      'fps': fps,
      'clip_length_seconds': clipLengthSeconds,
      'delay_seconds': delaySeconds,
    },
    'width': width,
    'height': height,
  };
}

/// Service for streaming camera frames to a WebSocket server
class FrameStreamingService {
  // WebSocket Configuration - Update these for your backend
  static const String _defaultWsUrl = 'wss://api.mateotaylortest.org/api/overshoot/ws/stream';

  IOWebSocketChannel? _wsChannel;
  StreamSubscription? _wsSubscription;
  bool _isConnected = false;
  bool _isStreaming = false;
  bool _isReady = false;
  String? _streamId;
  StreamConfig _config = const StreamConfig();

  // Frame processing settings
  int _frameSkipCount = 0;
  int _frameSkipRate = 1; // Calculated based on camera fps vs desired fps
  bool _isProcessingFrame = false; // Prevent frame pile-up during async compression

  // Track pending frames by timestamp (frames sent but awaiting response)
  final Set<int> _pendingFrameTimestamps = {};

  // Callback for when a frame is captured from camera (ALL frames)
  final StreamController<int> _frameCapturedController = StreamController<int>.broadcast();

  // Callback for when a frame is sent to WebSocket (subset of captured frames)
  final StreamController<int> _frameSentController = StreamController<int>.broadcast();

  // Callback for receiving inference results from server (timestamp, result)
  final StreamController<InferenceResult> _resultsController = StreamController<InferenceResult>.broadcast();

  // Callback for connection state changes
  final StreamController<bool> _connectionController = StreamController<bool>.broadcast();

  // Callback for when all pending results are received
  final StreamController<void> _allResultsReceivedController = StreamController<void>.broadcast();

  Stream<int> get frameCapturedStream => _frameCapturedController.stream;
  Stream<int> get frameSentStream => _frameSentController.stream;
  Stream<InferenceResult> get resultsStream => _resultsController.stream;
  Stream<bool> get connectionStream => _connectionController.stream;
  Stream<void> get allResultsReceivedStream => _allResultsReceivedController.stream;
  int get pendingFrameCount => _pendingFrameTimestamps.length;
  bool get isConnected => _isConnected;
  bool get isStreaming => _isStreaming;
  bool get isReady => _isReady;
  String? get streamId => _streamId;

  /// Connect to the WebSocket server and send config
  Future<bool> connect({String? wsUrl, StreamConfig? config}) async {
    if (_isConnected) return true;

    _config = config ?? const StreamConfig();

    try {
      final url = wsUrl ?? _defaultWsUrl;
      print('[FrameStreaming] 🔌 Connecting to: $url');

      _wsChannel = IOWebSocketChannel.connect(Uri.parse(url), pingInterval: const Duration(seconds: 10));

      _wsSubscription = _wsChannel!.stream.listen(
        (message) {
          print('[FrameStreaming] 🔔 Stream.listen triggered');
          _handleMessage(message);
        },
        onError: (error, stackTrace) {
          print('[FrameStreaming] 🔔 Stream.listen onError: $error');
          _handleError(error);
        },
        onDone: () {
          print('[FrameStreaming] 🔔 Stream.listen onDone - connection closed');
          _handleDone();
        },
      );

      _isConnected = true;
      _connectionController.add(true);

      // Send config message
      _sendConfig();

      print('[FrameStreaming] ✅ WebSocket connected successfully');
      return true;
    } catch (e) {
      print('[FrameStreaming] ❌ WebSocket connection failed: $e');
      _isConnected = false;
      _connectionController.add(false);
      return false;
    }
  }

  /// Send the initial config message
  void _sendConfig() {
    if (!_isConnected || _wsChannel == null) return;

    final configMap = _config.toJson();
    final configJson = jsonEncode(configMap);
    print('[FrameStreaming] 📤 Sending config:');
    print('[FrameStreaming]   $configJson');
    _wsChannel!.sink.add(configJson);
  }

  /// Update the inference prompt
  void updatePrompt(String newPrompt) {
    if (!_isConnected || _wsChannel == null) return;

    final message = jsonEncode({'type': 'update_prompt', 'prompt': newPrompt});
    _wsChannel!.sink.add(message);
  }

  /// Send stop message to server
  void sendStop() {
    if (!_isConnected || _wsChannel == null) return;

    final message = jsonEncode({'type': 'stop'});
    _wsChannel!.sink.add(message);
  }

  /// Disconnect from the WebSocket server
  void disconnect() {
    if (_isConnected) {
      sendStop();
    }

    _isStreaming = false;
    _isConnected = false;
    _isReady = false;
    _streamId = null;
    _wsSubscription?.cancel();
    _wsChannel?.sink.close();
    _wsChannel = null;
    _connectionController.add(false);
  }

  /// Start streaming frames
  void startStreaming({int cameraFps = 30}) {
    if (!_isReady) {
      print('[FrameStreaming] ⚠️ Cannot start streaming - not ready');
      return;
    }

    _isStreaming = true;
    _frameSkipCount = 0;

    // Calculate frame skip rate to match desired fps
    _frameSkipRate = (cameraFps / _config.fps).ceil();
    if (_frameSkipRate < 1) _frameSkipRate = 1;

    print('[FrameStreaming] 🎬 Streaming started (skip rate: $_frameSkipRate)');
  }

  /// Stop streaming frames
  void stopStreaming() {
    _isStreaming = false;
    sendStop();

    // If no pending frames, signal completion immediately
    if (_pendingFrameTimestamps.isEmpty) {
      _allResultsReceivedController.add(null);
    }
  }

  /// Check if still waiting for results
  bool get isWaitingForResults => !_isStreaming && _pendingFrameTimestamps.isNotEmpty;

  /// Send JPEG bytes to the WebSocket server
  /// Call this method with pre-encoded JPEG data (e.g., from camerawesome's AnalysisImage.toJpeg())
  /// Returns true if the frame was sent, false if skipped or not ready
  bool sendJpegFrame(Uint8List jpegBytes, {int? timestampUtc}) {
    // Get UTC timestamp for this frame
    final frameTimestamp = timestampUtc ?? DateTime.now().toUtc().millisecondsSinceEpoch;

    // Notify listeners that a frame was captured
    _frameCapturedController.add(frameTimestamp);

    // Check if we should send this frame to WebSocket
    if (!_isConnected || !_isStreaming || !_isReady || _wsChannel == null) {
      // Debug: log why frame was skipped (only occasionally to avoid spam)
      if (frameTimestamp % 1000 < 100) {
        print('[FrameStreaming] ⏭️ Frame skipped - connected: $_isConnected, streaming: $_isStreaming, ready: $_isReady, channel: ${_wsChannel != null}');
      }
      return false;
    }

    // Prevent frame pile-up
    if (_isProcessingFrame) return false;
    _isProcessingFrame = true;

    try {
      // Create frame with timestamp header + JPEG data
      final frameWithTimestamp = _createFrameWithTimestamp(frameTimestamp, jpegBytes);

      // Track this frame as pending (awaiting server response)
      _pendingFrameTimestamps.add(frameTimestamp);

      // Send as binary data
      _wsChannel!.sink.add(frameWithTimestamp);

      // Debug: Print frame sent info
      print(
        '[FrameStreaming] 📤 Frame sent - timestamp: $frameTimestamp, size: ${jpegBytes.length} bytes, pending: ${_pendingFrameTimestamps.length}',
      );

      // Notify listeners that a frame was sent to WebSocket
      _frameSentController.add(frameTimestamp);

      return true;
    } catch (e) {
      print('[FrameStreaming] ❌ Frame send failed: $e');
      return false;
    } finally {
      _isProcessingFrame = false;
    }
  }

  /// Legacy method for backward compatibility - now just notifies listeners
  /// Use sendJpegFrame instead for sending pre-encoded JPEG frames
  @Deprecated('Use sendJpegFrame with pre-encoded JPEG bytes instead')
  void processFrameNotification() {
    final timestampUtc = DateTime.now().toUtc().millisecondsSinceEpoch;
    _frameCapturedController.add(timestampUtc);
  }

  /// Create a frame with timestamp header
  /// Format: [8 bytes timestamp (little-endian float64)] + [JPEG data]
  /// Backend expects: struct.unpack('<d', frame_bytes[:8]) - little-endian double
  Uint8List _createFrameWithTimestamp(int timestampUtc, Uint8List imageData) {
    final buffer = ByteData(8 + imageData.length);

    // Write timestamp as 64-bit little-endian float (double)
    // Convert milliseconds to seconds for the backend
    final timestampSeconds = timestampUtc / 1000.0;
    buffer.setFloat64(0, timestampSeconds, Endian.little);

    // Create result buffer
    final result = Uint8List(8 + imageData.length);
    result.setRange(0, 8, buffer.buffer.asUint8List());
    result.setRange(8, result.length, imageData);

    return result;
  }

  /// Send raw RGB24 bytes directly with timestamp
  void sendRawFrame(Uint8List rgb24Bytes) {
    if (!_isConnected || !_isStreaming || !_isReady || _wsChannel == null) return;

    try {
      final timestampUtc = DateTime.now().toUtc().millisecondsSinceEpoch;
      final frameWithTimestamp = _createFrameWithTimestamp(timestampUtc, rgb24Bytes);

      _pendingFrameTimestamps.add(timestampUtc);
      _wsChannel!.sink.add(frameWithTimestamp);
      _frameSentController.add(timestampUtc);
      print('[FrameStreaming] 📤 Frame sent - timestamp: $timestampUtc, pending: ${_pendingFrameTimestamps.length}');
    } catch (e) {
      // Send failed silently
    }
  }

  /// Send raw RGB24 bytes with a specific timestamp
  /// Use this when you have a pre-determined timestamp (e.g., from frame sampling)
  void sendRawFrameWithTimestamp(Uint8List rgb24Bytes, int timestampUtc) {
    if (!_isConnected || !_isStreaming || !_isReady || _wsChannel == null) {
      print(
        '[FrameStreaming] ⚠️ Cannot send frame - not ready (connected: $_isConnected, streaming: $_isStreaming, ready: $_isReady)',
      );
      return;
    }

    try {
      final frameWithTimestamp = _createFrameWithTimestamp(timestampUtc, rgb24Bytes);

      _pendingFrameTimestamps.add(timestampUtc);
      _wsChannel!.sink.add(frameWithTimestamp);
      _frameSentController.add(timestampUtc);

      final expectedSize = _config.width * _config.height * 3 + 8;
      print('[FrameStreaming] 📤 Frame sent:');
      print('[FrameStreaming]   - Timestamp (ms): $timestampUtc');
      print('[FrameStreaming]   - Timestamp (sec): ${timestampUtc / 1000.0}');
      print('[FrameStreaming]   - Frame size: ${frameWithTimestamp.length} bytes (expected: $expectedSize)');
      print('[FrameStreaming]   - RGB data size: ${rgb24Bytes.length} bytes');
      print('[FrameStreaming]   - Pending count: ${_pendingFrameTimestamps.length}');
    } catch (e) {
      print('[FrameStreaming] ❌ Failed to send frame: $e');
    }
  }

  /// Get the configured frame dimensions
  int get configWidth => _config.width;
  int get configHeight => _config.height;

  /// Handle incoming WebSocket messages
  ///
  /// Backend Message Format (from routes.py _listen_overshoot_ws):
  ///
  /// 1. Ready message - sent after config received and stream created:
  ///    {"type": "ready", "stream_id": "<string>"}
  ///
  /// 2. Inference result - forwarded from Overshoot with latest frame timestamp:
  ///    {"type": "inference", "result": "<string>", "timestamp": <int|null>}
  ///    Note: timestamp is the latest frame timestamp sent by client
  ///
  /// 3. Error message:
  ///    {"type": "error", "message": "<string>"}
  ///
  void _handleMessage(dynamic message) {
    // Always log raw message for debugging
    print('[FrameStreaming] 📥 RAW MESSAGE RECEIVED:');
    print('[FrameStreaming]   Type: ${message.runtimeType}');
    if (message is String) {
      final preview = message.length > 300 ? '${message.substring(0, 300)}...' : message;
      print('[FrameStreaming]   Content: $preview');
    } else {
      print('[FrameStreaming]   Content: $message');
    }

    try {
      Map<String, dynamic>? data;

      if (message is String) {
        data = jsonDecode(message) as Map<String, dynamic>?;
      } else if (message is Map<String, dynamic>) {
        // Some WebSocket implementations auto-parse JSON
        data = message;
      } else {
        print('[FrameStreaming] ⚠️ Unexpected message type: ${message.runtimeType}');
        return;
      }

      if (data == null) {
        print('[FrameStreaming] ⚠️ Parsed data is null');
        return;
      }

      print('[FrameStreaming] 📋 Parsed JSON keys: ${data.keys.toList()}');

      final type = data['type'] as String?;
      print('[FrameStreaming] 📌 Message type: $type');

      switch (type) {
        case 'ready':
          _isReady = true;
          _streamId = data['stream_id'] as String?;
          print('[FrameStreaming] ✅ WebSocket READY - stream_id: $_streamId');
          break;

        case 'inference':
          _handleInferenceResult(data);
          break;

        case 'error':
          final error = data['message'] as String? ?? 'Unknown error';
          print('[FrameStreaming] ❌ ERROR from server: $error');
          _resultsController.add(
            InferenceResult(timestampUtc: DateTime.now().toUtc().millisecondsSinceEpoch, result: 'Error: $error'),
          );
          break;

        default:
          print('[FrameStreaming] ⚠️ Unknown message type: $type');
          // Try to handle as inference if it has a result field
          if (data.containsKey('result')) {
            print('[FrameStreaming] 🔄 Has result field, treating as inference');
            _handleInferenceResult(data);
          }
      }
    } catch (e, stackTrace) {
      print('[FrameStreaming] ❌ Message parsing FAILED:');
      print('[FrameStreaming]   Error: $e');
      print('[FrameStreaming]   Stack: $stackTrace');
    }
  }

  /// Handle an inference result message from the backend
  /// Expected format: {"type": "inference", "result": "<string>", "timestamp": <float|null>}
  /// Note: timestamp from backend is in seconds (float), we store as milliseconds (int)
  void _handleInferenceResult(Map<String, dynamic> data) {
    final result = data['result'] as String?;

    // Timestamp from backend is in seconds (float), convert to milliseconds
    int? timestampMs;
    final tsValue = data['timestamp'];
    if (tsValue is num) {
      // Backend returns seconds as float, convert to milliseconds
      timestampMs = (tsValue.toDouble() * 1000).round();
    }

    print('[FrameStreaming] ========== INFERENCE RESULT ==========');
    print('[FrameStreaming] Timestamp (ms): $timestampMs');
    print(
      '[FrameStreaming] Result: ${result != null ? (result.length > 200 ? '${result.substring(0, 200)}...' : result) : 'NULL'}',
    );
    print('[FrameStreaming] Pending frames before: ${_pendingFrameTimestamps.length}');
    print('[FrameStreaming] Has listeners: ${_resultsController.hasListener}');

    if (result == null) {
      print('[FrameStreaming] ⚠️ Result is NULL - skipping');
      return;
    }

    // Remove from pending if timestamp provided
    if (timestampMs != null) {
      final removed = _pendingFrameTimestamps.remove(timestampMs);
      print('[FrameStreaming] Removed timestamp $timestampMs: $removed');
    } else if (_pendingFrameTimestamps.isNotEmpty) {
      // Remove oldest pending timestamp if no timestamp in response
      final oldest = _pendingFrameTimestamps.reduce((a, b) => a < b ? a : b);
      _pendingFrameTimestamps.remove(oldest);
      print('[FrameStreaming] Removed oldest timestamp: $oldest');
    }

    print('[FrameStreaming] Pending frames after: ${_pendingFrameTimestamps.length}');
    print('[FrameStreaming] ======================================');

    // Broadcast the result to listeners
    _resultsController.add(
      InferenceResult(timestampUtc: timestampMs ?? DateTime.now().toUtc().millisecondsSinceEpoch, result: result),
    );
    print('[FrameStreaming] ✅ Result broadcasted to listeners');

    // Check if all results received after stopping
    if (!_isStreaming && _pendingFrameTimestamps.isEmpty) {
      print('[FrameStreaming] 🎉 All pending results received!');
      _allResultsReceivedController.add(null);
    }
  }

  /// Handle WebSocket errors
  void _handleError(dynamic error) {
    print('[FrameStreaming] ❌ WebSocket error: $error');
    _isConnected = false;
    _isStreaming = false;
    _isReady = false;
    _connectionController.add(false);
  }

  /// Handle WebSocket connection closed
  void _handleDone() {
    print('[FrameStreaming] 🔌 WebSocket connection closed');
    _isConnected = false;
    _isStreaming = false;
    _isReady = false;
    _connectionController.add(false);
  }

  /// Clean up resources
  void dispose() {
    disconnect();
    _frameCapturedController.close();
    _frameSentController.close();
    _resultsController.close();
    _connectionController.close();
    _allResultsReceivedController.close();
    _pendingFrameTimestamps.clear();
  }
}

/// Represents an inference result from the server
class InferenceResult {
  final int timestampUtc;
  final String result;

  const InferenceResult({required this.timestampUtc, required this.result});
}
