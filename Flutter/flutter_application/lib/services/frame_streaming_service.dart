import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';

/// Configuration for the frame streaming service
class StreamConfig {
  final String prompt;
  final String model;
  final String backend;
  final int fps;
  final int width;
  final int height;

  const StreamConfig({
    this.prompt = 'Describe what you see',
    this.model = 'gemini-2.0-flash',
    this.backend = 'gemini',
    this.fps = 30,
    this.width = 640,
    this.height = 480,
  });

  Map<String, dynamic> toJson() => {
    'type': 'config',
    'prompt': prompt,
    'model': model,
    'backend': backend,
    'fps': fps,
    'width': width,
    'height': height,
  };
}

/// Service for streaming camera frames to a WebSocket server
class FrameStreamingService {
  // WebSocket Configuration - Update these for your backend
  static const String _defaultWsUrl = 'ws://localhost:8080/frames';
  
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
  
  // Callback for receiving inference results from server
  final StreamController<String> _resultsController = 
      StreamController<String>.broadcast();
  
  // Callback for connection state changes
  final StreamController<bool> _connectionController = 
      StreamController<bool>.broadcast();
  
  Stream<String> get resultsStream => _resultsController.stream;
  Stream<bool> get connectionStream => _connectionController.stream;
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
      _wsChannel = IOWebSocketChannel.connect(Uri.parse(url));
      
      _wsSubscription = _wsChannel!.stream.listen(
        _handleMessage,
        onError: _handleError,
        onDone: _handleDone,
      );
      
      _isConnected = true;
      _connectionController.add(true);
      
      // Send config message
      _sendConfig();
      
      return true;
    } catch (e) {
      _isConnected = false;
      _connectionController.add(false);
      return false;
    }
  }

  /// Send the initial config message
  void _sendConfig() {
    if (!_isConnected || _wsChannel == null) return;
    
    final configJson = jsonEncode(_config.toJson());
    _wsChannel!.sink.add(configJson);
  }

  /// Update the inference prompt
  void updatePrompt(String newPrompt) {
    if (!_isConnected || _wsChannel == null) return;
    
    final message = jsonEncode({
      'type': 'update_prompt',
      'prompt': newPrompt,
    });
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
    if (!_isReady) return;
    
    _isStreaming = true;
    _frameSkipCount = 0;
    
    // Calculate frame skip rate to match desired fps
    _frameSkipRate = (cameraFps / _config.fps).ceil();
    if (_frameSkipRate < 1) _frameSkipRate = 1;
  }

  /// Stop streaming frames
  void stopStreaming() {
    _isStreaming = false;
    sendStop();
  }

  /// Process and send a camera frame to the WebSocket server
  /// Call this method from the camera's image stream callback
  void processFrame(CameraImage image) {
    if (!_isConnected || !_isStreaming || !_isReady || _wsChannel == null) return;
    
    // Skip frames to match desired fps
    _frameSkipCount++;
    if (_frameSkipCount % _frameSkipRate != 0) return;
    
    try {
      // Convert CameraImage to RGB24 bytes
      final rgb24Data = _convertToRgb24(image);
      
      // Send as binary data
      _wsChannel!.sink.add(rgb24Data);
    } catch (e) {
      // Frame processing failed silently
    }
  }

  /// Send raw RGB24 bytes directly
  void sendRawFrame(Uint8List rgb24Bytes) {
    if (!_isConnected || !_isStreaming || !_isReady || _wsChannel == null) return;
    
    try {
      _wsChannel!.sink.add(rgb24Bytes);
    } catch (e) {
      // Send failed silently
    }
  }

  /// Convert CameraImage to RGB24 format (height, width, 3)
  Uint8List _convertToRgb24(CameraImage image) {
    final int width = _config.width;
    final int height = _config.height;
    
    // For YUV420 format (most common on Android)
    if (image.format.group == ImageFormatGroup.yuv420) {
      return _yuv420ToRgb24(image, width, height);
    }
    
    // For BGRA8888 format (common on iOS)
    if (image.format.group == ImageFormatGroup.bgra8888) {
      return _bgra8888ToRgb24(image, width, height);
    }
    
    // Fallback: return empty frame of correct size
    return Uint8List(width * height * 3);
  }

  /// Convert YUV420 to RGB24
  Uint8List _yuv420ToRgb24(CameraImage image, int targetWidth, int targetHeight) {
    final int srcWidth = image.width;
    final int srcHeight = image.height;
    
    final yPlane = image.planes[0];
    final uPlane = image.planes[1];
    final vPlane = image.planes[2];
    
    final yBuffer = yPlane.bytes;
    final uBuffer = uPlane.bytes;
    final vBuffer = vPlane.bytes;
    
    final yRowStride = yPlane.bytesPerRow;
    final uvRowStride = uPlane.bytesPerRow;
    final uvPixelStride = uPlane.bytesPerPixel ?? 1;
    
    // Calculate scaling factors
    final double scaleX = srcWidth / targetWidth;
    final double scaleY = srcHeight / targetHeight;
    
    final rgb24 = Uint8List(targetWidth * targetHeight * 3);
    
    for (int y = 0; y < targetHeight; y++) {
      for (int x = 0; x < targetWidth; x++) {
        // Map to source coordinates
        final int srcX = (x * scaleX).floor().clamp(0, srcWidth - 1);
        final int srcY = (y * scaleY).floor().clamp(0, srcHeight - 1);
        
        final int yIndex = srcY * yRowStride + srcX;
        final int uvIndex = (srcY ~/ 2) * uvRowStride + (srcX ~/ 2) * uvPixelStride;
        
        // Get YUV values
        final int yValue = yBuffer[yIndex];
        final int uValue = uBuffer[uvIndex.clamp(0, uBuffer.length - 1)];
        final int vValue = vBuffer[uvIndex.clamp(0, vBuffer.length - 1)];
        
        // Convert YUV to RGB
        int r = (yValue + 1.370705 * (vValue - 128)).round().clamp(0, 255);
        int g = (yValue - 0.337633 * (uValue - 128) - 0.698001 * (vValue - 128)).round().clamp(0, 255);
        int b = (yValue + 1.732446 * (uValue - 128)).round().clamp(0, 255);
        
        final int rgbIndex = (y * targetWidth + x) * 3;
        rgb24[rgbIndex] = r;
        rgb24[rgbIndex + 1] = g;
        rgb24[rgbIndex + 2] = b;
      }
    }
    
    return rgb24;
  }

  /// Convert BGRA8888 to RGB24
  Uint8List _bgra8888ToRgb24(CameraImage image, int targetWidth, int targetHeight) {
    final int srcWidth = image.width;
    final int srcHeight = image.height;
    final srcBuffer = image.planes[0].bytes;
    final srcRowStride = image.planes[0].bytesPerRow;
    
    // Calculate scaling factors
    final double scaleX = srcWidth / targetWidth;
    final double scaleY = srcHeight / targetHeight;
    
    final rgb24 = Uint8List(targetWidth * targetHeight * 3);
    
    for (int y = 0; y < targetHeight; y++) {
      for (int x = 0; x < targetWidth; x++) {
        // Map to source coordinates
        final int srcX = (x * scaleX).floor().clamp(0, srcWidth - 1);
        final int srcY = (y * scaleY).floor().clamp(0, srcHeight - 1);
        
        final int srcIndex = srcY * srcRowStride + srcX * 4;
        
        // BGRA -> RGB
        final int rgbIndex = (y * targetWidth + x) * 3;
        rgb24[rgbIndex] = srcBuffer[srcIndex + 2];     // R
        rgb24[rgbIndex + 1] = srcBuffer[srcIndex + 1]; // G
        rgb24[rgbIndex + 2] = srcBuffer[srcIndex];     // B
      }
    }
    
    return rgb24;
  }

  /// Handle incoming WebSocket messages
  void _handleMessage(dynamic message) {
    try {
      if (message is String) {
        final data = jsonDecode(message);
        
        if (data is Map<String, dynamic>) {
          final type = data['type'] as String?;
          
          switch (type) {
            case 'ready':
              _isReady = true;
              _streamId = data['stream_id'] as String?;
              break;
              
            case 'inference':
              final result = data['result'] as String?;
              if (result != null) {
                _resultsController.add(result);
              }
              break;
              
            case 'error':
              final error = data['message'] as String?;
              if (error != null) {
                _resultsController.add('Error: $error');
              }
              break;
          }
        }
      }
    } catch (e) {
      // Message parsing failed
    }
  }

  /// Handle WebSocket errors
  void _handleError(dynamic error) {
    _isConnected = false;
    _isStreaming = false;
    _isReady = false;
    _connectionController.add(false);
  }

  /// Handle WebSocket connection closed
  void _handleDone() {
    _isConnected = false;
    _isStreaming = false;
    _isReady = false;
    _connectionController.add(false);
  }

  /// Clean up resources
  void dispose() {
    disconnect();
    _resultsController.close();
    _connectionController.close();
  }
}
