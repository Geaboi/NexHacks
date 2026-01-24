import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web_socket_channel/io.dart';
import 'package:flutter/foundation.dart';

/// Configuration for the frame streaming service
class StreamConfig {
  final String prompt;
  final String model;
  final String backend;
  final String? outputSchemaJson;
  final double samplingRatio;
  final int fps;
  final double clipLengthSeconds;
  final double delaySeconds;
  final int width;
  final int height;

  const StreamConfig({
    this.prompt = 'Describe what you see',
    this.model = 'gemini-2.0-flash',
    this.backend = 'gemini',
    this.outputSchemaJson,
    this.samplingRatio = 0.3,
    this.fps = 10,
    this.clipLengthSeconds = 10.0,
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

class InferenceResult {
  final int timestampUtc;
  final String result;
  const InferenceResult({required this.timestampUtc, required this.result});
}

/// Service for streaming camera frames via WebRTC (H.264)
class FrameStreamingService {
  // WebSocket Configuration
  static const String _defaultWsUrl =
      'wss://api.mateotaylortest.org/api/overshoot/ws/stream';

  IOWebSocketChannel? _wsChannel;
  StreamSubscription? _wsSubscription;
  bool _isConnected = false;
  bool _isStreaming = false;
  bool _isReady = false;
  String? _streamId;
  StreamConfig _config = const StreamConfig();

  // WebRTC
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  List<RTCIceCandidate> _candidateQueue = [];

  // Callbacks
  final StreamController<InferenceResult> _resultsController =
      StreamController<InferenceResult>.broadcast();
  final StreamController<bool> _connectionController =
      StreamController<bool>.broadcast();
  final StreamController<void> _allResultsReceivedController =
      StreamController<void>.broadcast();

  Stream<InferenceResult> get resultsStream => _resultsController.stream;
  Stream<bool> get connectionStream => _connectionController.stream;
  Stream<void> get allResultsReceivedStream =>
      _allResultsReceivedController.stream;

  // Pending frames is less relevant in WebRTC as it's continuous
  int get pendingFrameCount => 0;

  bool get isConnected => _isConnected;
  bool get isStreaming => _isStreaming;
  bool get isReady => _isReady;
  String? get streamId => _streamId;
  MediaStream? get localStream => _localStream;

  /// Initialize Camera and return MediaStream for preview
  Future<MediaStream?> initializeCamera() async {
    // Note: H.264 is preferred, usually handled by OS + negotiation.
    // We request standard VGA/30fps.
    final Map<String, dynamic> mediaConstraints = {
      'audio': false,
      'video': {
        'mandatory': {
          'minWidth': '640',
          'minHeight': '480',
          'minFrameRate': '30',
        },
        'facingMode': 'environment',
        'optional': [],
      },
    };

    try {
      _localStream = await navigator.mediaDevices.getUserMedia(
        mediaConstraints,
      );
      print('[FrameStreaming] 📸 Camera initialized');
      return _localStream;
    } catch (e) {
      print('[FrameStreaming] ❌ Camera initialization failed: $e');
      return null;
    }
  }

  /// Connect signaling WebSocket
  Future<bool> connect({String? wsUrl, StreamConfig? config}) async {
    if (_isConnected) return true;
    _config = config ?? const StreamConfig();

    try {
      final url = wsUrl ?? _defaultWsUrl;
      print('[FrameStreaming] 🔌 Connecting signaling to: $url');
      _wsChannel = IOWebSocketChannel.connect(Uri.parse(url));

      _wsSubscription = _wsChannel!.stream.listen(
        (message) => _handleMessage(message),
        onError: (e) {
          print('[FrameStreaming] ❌ Signaling error: $e');
          _handleError(e);
        },
        onDone: _handleDone,
      );

      _isConnected = true;
      _connectionController.add(true);
      _sendConfig();
      return true;
    } catch (e) {
      print('[FrameStreaming] ❌ Connection failed: $e');
      return false;
    }
  }

  void _sendConfig() {
    if (!_isConnected || _wsChannel == null) return;
    _wsChannel!.sink.add(jsonEncode(_config.toJson()));
  }

  /// Start WebRTC Streaming
  Future<void> startStreaming({int cameraFps = 30}) async {
    if (!_isReady || _localStream == null) {
      print(
        '[FrameStreaming] ⚠️ Cannot start streaming: Ready=$_isReady, Stream=${_localStream != null}',
      );
      return;
    }

    _isStreaming = true;
    print('[FrameStreaming] 🎬 Starting WebRTC negotiation...');

    try {
      _peerConnection = await createPeerConnection({
        'iceServers': [
          {'urls': 'stun:stun.l.google.com:19302'},
        ],
      });

      _peerConnection!.onIceCandidate = (candidate) {
        if (_isConnected && _wsChannel != null) {
          _wsChannel!.sink.add(
            jsonEncode({
              'type': 'candidate',
              'candidate': candidate.candidate,
              'sdpMid': candidate.sdpMid,
              'sdpMLineIndex': candidate.sdpMLineIndex,
            }),
          );
        }
      };

      _peerConnection!.onConnectionState = (state) {
        print('[FrameStreaming] 🔗 Connection state: $state');
      };

      // Add local stream tracks
      _localStream!.getTracks().forEach((track) {
        _peerConnection!.addTrack(track, _localStream!);
      });

      // Create Offer
      RTCSessionDescription offer = await _peerConnection!.createOffer();
      await _peerConnection!.setLocalDescription(offer);

      if (_isConnected && _wsChannel != null) {
        _wsChannel!.sink.add(jsonEncode({'type': 'offer', 'sdp': offer.sdp}));
      }
    } catch (e) {
      print('[FrameStreaming] ❌ WebRTC Setup failed: $e');
      _isStreaming = false;
    }
  }

  void stopStreaming() {
    _isStreaming = false;
    if (_peerConnection != null) {
      _peerConnection!.close();
      _peerConnection = null;
    }
    if (_isConnected && _wsChannel != null) {
      _wsChannel!.sink.add(jsonEncode({'type': 'stop'}));
    }
    // Notify completion
    _allResultsReceivedController.add(null);
  }

  void _handleMessage(dynamic message) async {
    try {
      final data = jsonDecode(message);
      final type = data['type'];

      switch (type) {
        case 'ready':
          _isReady = true;
          _streamId = data['stream_id'];
          print('[FrameStreaming] ✅ Ready. Stream ID: $_streamId');
          break;

        case 'answer':
          print('[FrameStreaming] 📩 Received Answer');
          if (_peerConnection != null) {
            await _peerConnection!.setRemoteDescription(
              RTCSessionDescription(data['sdp'], 'answer'),
            );
            // Flush queued candidates
            for (var c in _candidateQueue) {
              await _peerConnection!.addCandidate(c);
            }
            _candidateQueue.clear();
          }
          break;

        case 'candidate':
          print('[FrameStreaming] 🧊 Received ICE Candidate');
          final candidate = RTCIceCandidate(
            data['candidate'],
            data['sdpMid'],
            data['sdpMLineIndex'],
          );
          if (_peerConnection != null &&
              await _peerConnection!.getRemoteDescription() != null) {
            await _peerConnection!.addCandidate(candidate);
          } else {
            _candidateQueue.add(candidate);
          }
          break;

        case 'inference':
          _handleInferenceResult(data);
          break;

        case 'error':
          print('[FrameStreaming] ❌ Server Error: ${data['error']}');
          _resultsController.add(
            InferenceResult(
              timestampUtc: DateTime.now().millisecondsSinceEpoch,
              result: "Error: ${data['error']}",
            ),
          );
          break;
      }
    } catch (e) {
      print('[FrameStreaming] ❌ Msg handle error: $e');
    }
  }

  void _handleInferenceResult(Map<String, dynamic> data) {
    final resultStr = data['result'] as String?;
    int timestampMs = 0;
    if (data['timestamp'] is num) {
      timestampMs = (data['timestamp'] * 1000).toInt();
    }

    if (resultStr != null) {
      _resultsController.add(
        InferenceResult(
          timestampUtc: timestampMs > 0
              ? timestampMs
              : DateTime.now().millisecondsSinceEpoch,
          result: resultStr,
        ),
      );
    }
  }

  void _handleError(dynamic error) {
    _isConnected = false;
    _connectionController.add(false);
  }

  void _handleDone() {
    _isConnected = false;
    _connectionController.add(false);
  }

  void dispose() {
    stopStreaming();
    _localStream?.dispose();
    _resultsController.close();
    _connectionController.close();
    _allResultsReceivedController.close();
    _wsSubscription?.cancel();
    _wsChannel?.sink.close();
  }

  // Deprecated/Stub methods for compatibility with RecordingPage until updated
  void updatePrompt(String p) {
    if (_isConnected && _wsChannel != null) {
      _wsChannel!.sink.add(jsonEncode({'type': 'update_prompt', 'prompt': p}));
    }
  }

  bool sendJpegFrame(Uint8List bytes, {int? timestampUtc}) {
    return false;
  }
}
