// lib/providers/overshoot_provider.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../services/overshoot_service.dart';


// 1. The State Object (Immutable)
class OvershootState {
  final RTCVideoRenderer renderer;
  final String aiResult;
  final bool isStreaming;
  final bool isCameraReady;

  OvershootState({
    required this.renderer,
    this.aiResult = "Ready to start",
    this.isStreaming = false,
    this.isCameraReady = false,
  });

  OvershootState copyWith({
    String? aiResult,
    bool? isStreaming,
    bool? isCameraReady,
  }) {
    return OvershootState(
      renderer: renderer,
      aiResult: aiResult ?? this.aiResult,
      isStreaming: isStreaming ?? this.isStreaming,
      isCameraReady: isCameraReady ?? this.isCameraReady,
    );
  }
}

// 2. The Notifier (The Brains)
class OvershootNotifier extends Notifier<OvershootState> {
  late final OvershootService _service;
  MediaStream? _localStream;

  @override
  OvershootState build() {
    _service = OvershootService();
    ref.onDispose(() {
      _service.stop();
      _localStream?.dispose();
      state.renderer.dispose();
    });
    return OvershootState(renderer: RTCVideoRenderer());
  }

  // Initialize Camera (Call this on screen load)
  Future<void> initialize() async {
    await state.renderer.initialize();
    try {
      _localStream = await _service.getCameraStream();
      state.renderer.srcObject = _localStream;
      state = state.copyWith(isCameraReady: true);
    } catch (e) {
      state = state.copyWith(aiResult: "Camera Error: $e");
    }
  }

  // Start/Stop AI
  Future<void> toggleStream() async {
    if (state.isStreaming) {
      _service.stop();
      state = state.copyWith(isStreaming: false, aiResult: "Stopped.");
    } else {
      if (_localStream == null) return;
      
      state = state.copyWith(isStreaming: true, aiResult: "Connecting...");
      
      try {
        final stream = await _service.startConnection(
          _localStream!, 
          "Describe what is happening in detail."
        );
        
        stream.listen((text) {
          state = state.copyWith(aiResult: text);
        });
        
      } catch (e) {
        state = state.copyWith(isStreaming: false, aiResult: "Connection Failed: $e");
      }
    }
  }

}

// 3. The Provider Definition (What the UI watches)
final overshootProvider = NotifierProvider.autoDispose<OvershootNotifier, OvershootState>(
  OvershootNotifier.new,
);