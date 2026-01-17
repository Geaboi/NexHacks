// lib/main.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import 'providers/overshoot_provider.dart';

void main() {
  // 1. Wrap app in ProviderScope
  runApp(const ProviderScope(child: MaterialApp(home: OvershootScreen())));
}

class OvershootScreen extends ConsumerStatefulWidget {
  const OvershootScreen({super.key});

  @override
  ConsumerState<OvershootScreen> createState() => _OvershootScreenState();
}

class _OvershootScreenState extends ConsumerState<OvershootScreen> {
  
  @override
  void initState() {
    super.initState();
    _requestPermissions();
  }

  Future<void> _requestPermissions() async {
    await [Permission.camera, Permission.microphone].request();
    // Initialize the provider automatically when permissions granted
    if (mounted) {
      ref.read(overshootProvider.notifier).initialize();
    }
  }

  @override
  Widget build(BuildContext context) {
    // 2. Watch the State
    final overshootState = ref.watch(overshootProvider);
    final notifier = ref.read(overshootProvider.notifier);

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(title: const Text("Overshoot + Riverpod")),
      body: Stack(
        children: [
          // A. Camera Layer
          overshootState.isCameraReady
              ? RTCVideoView(
                  overshootState.renderer,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                )
              : const Center(child: CircularProgressIndicator()),

          // B. AI Overlay Layer
          Positioned(
            bottom: 40,
            left: 20,
            right: 20,
            child: Column(
              children: [
                // Result Box
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.7),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.white24)
                  ),
                  child: Text(
                    overshootState.aiResult,
                    style: const TextStyle(color: Colors.white, fontSize: 18),
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(height: 20),
                
                // Control Button
                FloatingActionButton.extended(
                  onPressed: notifier.toggleStream,
                  backgroundColor: overshootState.isStreaming ? Colors.red : Colors.green,
                  icon: Icon(overshootState.isStreaming ? Icons.stop : Icons.videocam),
                  label: Text(overshootState.isStreaming ? "STOP AI" : "START AI"),
                )
              ],
            ),
          )
        ],
      ),
    );
  }
}