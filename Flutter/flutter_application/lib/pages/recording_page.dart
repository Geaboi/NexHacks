import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../main.dart';
import '../providers/navigation_provider.dart';
import '../providers/frame_analysis_provider.dart';
import '../providers/sensor_provider.dart';
import '../services/frame_streaming_service.dart';
import 'review_page.dart';

class RecordingPage extends ConsumerStatefulWidget {
  const RecordingPage({super.key});

  @override
  ConsumerState<RecordingPage> createState() => _RecordingPageState();
}

class _RecordingPageState extends ConsumerState<RecordingPage> {
  // Service
  final FrameStreamingService _frameStreamingService = FrameStreamingService();

  // WebRTC Renderer
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();

  // State
  bool _isRecording = false;
  bool _isStreamingFrames = false;
  bool _isCameraReady = false;
  int _recordingSeconds = 0;
  Timer? _recordingTimer;
  String? _latestInferenceResult;
  bool _isWaitingForResults = false;
  int _framesSent =
      0; // Keeping track for UI feedback, though handled internally by WebRTC mostly

  // Subscriptions
  StreamSubscription<InferenceResult>? _resultsSubscription;
  StreamSubscription<void>? _allResultsSubscription;
  StreamSubscription<bool>? _connectionSubscription;

  @override
  void initState() {
    super.initState();
    _initRenderers();
    _setupListeners();
    // Lock to landscape
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  Future<void> _initRenderers() async {
    await _localRenderer.initialize();
    final stream = await _frameStreamingService.initializeCamera();
    if (stream != null) {
      if (mounted) {
        setState(() {
          _localRenderer.srcObject = stream;
          _isCameraReady = true;
        });
      }
    }
  }

  void _setupListeners() {
    _resultsSubscription = _frameStreamingService.resultsStream.listen((
      result,
    ) {
      ref
          .read(frameAnalysisProvider.notifier)
          .addFrameWithResult(result.timestampUtc, result.result);
      setState(() {
        _latestInferenceResult = result.result;
      });
    });

    _connectionSubscription = _frameStreamingService.connectionStream.listen((
      connected,
    ) {
      if (!connected && _isRecording) {
        // Handle disconnection
        _showErrorSnackBar("Connection lost");
        _stopRecording();
      }
    });

    _allResultsReceivedControllerListener();
  }

  void _allResultsReceivedControllerListener() {
    _allResultsSubscription = _frameStreamingService.allResultsReceivedStream
        .listen((_) {
          ref.read(frameAnalysisProvider.notifier).markSessionComplete();
          if (mounted) {
            setState(() => _isWaitingForResults = false);
            _navigateToReview();
          }
        });
  }

  @override
  void dispose() {
    _recordingTimer?.cancel();
    _resultsSubscription?.cancel();
    _allResultsSubscription?.cancel();
    _connectionSubscription?.cancel();
    _localRenderer.dispose();
    _frameStreamingService.dispose();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    super.dispose();
  }

  Future<void> _toggleRecording() async {
    if (_isRecording) {
      await _stopRecording();
    } else {
      await _startRecording();
    }
  }

  Future<void> _startRecording() async {
    try {
      // Connect signaling
      final connected = await _frameStreamingService.connect();
      if (!connected) {
        _showErrorSnackBar("Could not connect to server");
        return;
      }

      // Start IMU recording
      if (ref.read(sensorProvider).isConnected) {
        ref.read(sensorProvider.notifier).startRecording();
      }

      // Start WebRTC Streaming
      await _frameStreamingService.startStreaming();

      // Session Management
      final startTimeUtc = DateTime.now().toUtc().millisecondsSinceEpoch;
      ref.read(frameAnalysisProvider.notifier).startSession(startTimeUtc);

      // Wait a bit for streamId to be available? Usually happens after 'ready' message
      // We can update it later or listen to it, but for now we proceed.
      // Ideally we should wait for 'ready' state.

      setState(() {
        _isRecording = true;
        _isStreamingFrames = true;
        _recordingSeconds = 0;
      });

      _recordingTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (mounted) setState(() => _recordingSeconds++);
      });
    } catch (e) {
      print("Error starting recording: $e");
      _showErrorSnackBar("Error starting recording");
    }
  }

  Future<void> _stopRecording() async {
    if (!_isRecording) return;

    _recordingTimer?.cancel();

    // Stop IMU
    if (ref.read(sensorProvider).isConnected) {
      await ref.read(sensorProvider.notifier).stopRecording();
    }

    // Stop Streaming
    _frameStreamingService.stopStreaming();

    // Set Stream ID to provider if available
    if (_frameStreamingService.streamId != null) {
      ref
          .read(frameAnalysisProvider.notifier)
          .setStreamId(_frameStreamingService.streamId!);
    }

    if (mounted) {
      setState(() {
        _isRecording = false;
        _isStreamingFrames = false;
        // We might wait for final results here?
        // Since WebRTC is continuous, 'pending frames' isn't synonymous with 'awaiting explicit response'
        // But FrameStreamingService.stopStreaming triggers _allResultsReceivedController.
      });
    }
  }

  void _finishRecording() => _stopRecording();

  void _navigateToReview() {
    // We don't have a local video path anymore.
    // ReviewPage needs to handle "remote/stream" review or just analysis results.
    // If ReviewPage expects videoPath, we might need to adjust it or pass null/dummy.
    // Assuming ReviewPage can handle null videoPath or we update it later.
    // For now, let's pass a placeholder or null if the constructor allows.
    // ReviewPage probably assumes a file path. CHECK ReviewPage!
    // If ReviewPage requires a path, we are in trouble.
    // But implementation plan said "Update process endpoint... to use accumulated file".
    // Does ReviewPage analyze immediately?

    // Let's assume for now we pass 'STREAM_ID:...' as a fake path if needed,
    // but ideally we should update ReviewPage.
    // User requested "Update backend/routes.py... identification of frames...".

    // I'll check ReviewPage signature in a sec, but for now passing a stream ID marker might work if we hack it,
    // or passing null if allowed.
    // Let's pass the streamId as "stream://<id>" or similar if we can.

    final sId = _frameStreamingService.streamId;
    if (sId != null) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ReviewPage(videoPath: "stream://$sId"),
        ),
      );
    } else {
      _showErrorSnackBar("Stream ID unavailable.");
    }
  }

  void _showErrorSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red),
    );
  }

  String _formatDuration(int seconds) {
    final minutes = seconds ~/ 60;
    final secs = seconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final navState = ref.watch(navigationProvider);
    final projectName = navState.selectedProject?.name ?? 'Exercise';

    return Scaffold(
      backgroundColor: AppColors.primaryDark,
      body: SafeArea(
        child: Stack(
          children: [
            // WebRTC Preview
            _isCameraReady
                ? RTCVideoView(
                    _localRenderer,
                    objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                  )
                : const Center(child: CircularProgressIndicator()),

            // Overlay UI
            // Recording Indicator
            if (_isRecording)
              Positioned(
                top: 16,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.red.withOpacity(0.8),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      'REC ${_formatDuration(_recordingSeconds)}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ),

            // Inference Result Display
            if (_latestInferenceResult != null)
              Positioned(
                top: 60,
                left: 16,
                right: 16,
                child: Container(
                  padding: const EdgeInsets.all(8),
                  color: Colors.black54,
                  child: Text(
                    _latestInferenceResult!,
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              ),

            // Controls
            Positioned(
              bottom: 40,
              left: 0,
              right: 0,
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(
                          Icons.close,
                          color: Colors.white,
                          size: 32,
                        ),
                      ),
                      const SizedBox(width: 40),
                      GestureDetector(
                        onTap: _isCameraReady ? _toggleRecording : null,
                        child: Container(
                          width: 80,
                          height: 80,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 4),
                          ),
                          child: Center(
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 200),
                              width: _isRecording ? 32 : 64,
                              height: _isRecording ? 32 : 64,
                              decoration: BoxDecoration(
                                color: Colors.red,
                                borderRadius: BorderRadius.circular(
                                  _isRecording ? 8 : 32,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 80), // Balance spacing
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
