import 'dart:async';
import 'package:camerawesome/camerawesome_plugin.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
  // ==================== VIDEO RECORDING TOGGLE ====================
  // Set to false to disable video recording and only stream images
  static const bool _enableVideoRecording = false;
  // ================================================================

  // Frame streaming service
  final FrameStreamingService _frameStreamingService = FrameStreamingService();

  // Recording state
  bool _isRecording = false;
  bool _isStreamingFrames = false;
  int _recordingSeconds = 0;
  Timer? _recordingTimer;
  String? _tempVideoPath;
  int? _videoStartTimeUtc;
  bool _isWaitingForResults = false;
  bool _isAnalysisAvailable = false;
  bool _isCameraReady = false;

  // Frame capture stats
  int _framesReceived = 0; // Total frames received from camerawesome
  int _framesSent = 0; // Frames actually sent to WebSocket
  bool _isProcessingFrame = false;

  // CamerAwesome state reference
  CameraState? _cameraState;

  // Stream subscriptions
  StreamSubscription<InferenceResult>? _resultsSubscription;
  StreamSubscription<void>? _allResultsSubscription;
  StreamSubscription<bool>? _connectionSubscription;
  String? _latestInferenceResult;

  // Timeout constants
  static const int _wsReadyTimeoutMs = 5000;
  static const int _waitingForResultsTimeoutMs = 10000;

  @override
  void initState() {
    super.initState();
    _setupFrameStreamingListeners();
    _checkDeviceCapabilities();
  }

  /// Check if device supports video recording + image analysis simultaneously
  Future<void> _checkDeviceCapabilities() async {
    try {
      final supported =
          await CameraCharacteristics.isVideoRecordingAndImageAnalysisSupported(
            SensorPosition.back,
          );
      print('[RecordingPage] 📱 Device supports video+analysis: $supported');
      if (!supported && _enableVideoRecording) {
        print(
          '[RecordingPage] ⚠️ WARNING: This device does NOT support video recording + image analysis at the same time!',
        );
        print(
          '[RecordingPage] ⚠️ Image analysis will be DISABLED during video recording.',
        );
      }
    } catch (e) {
      print('[RecordingPage] ⚠️ Could not check device capabilities: $e');
    }
  }

  void _setupFrameStreamingListeners() {
    // Listen for inference results from the server
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

    // Listen for connection state changes
    _connectionSubscription = _frameStreamingService.connectionStream.listen((
      connected,
    ) {
      if (!connected && _isRecording && _isAnalysisAvailable) {
        print('[RecordingPage] ⚠️ WebSocket connection lost during recording');
        setState(() {
          _isAnalysisAvailable = false;
          _isStreamingFrames = false;
        });
      }
    });

    // Listen for all results received
    _allResultsSubscription = _frameStreamingService.allResultsReceivedStream
        .listen((_) {
          ref.read(frameAnalysisProvider.notifier).markSessionComplete();
          setState(() {
            _isWaitingForResults = false;
          });
          _navigateToReview();
        });
  }

  /// Handle analysis image from camerawesome - convert to JPEG and send
  Future<void> _onImageForAnalysis(AnalysisImage image) async {
    // UNCONDITIONAL log - if this never prints, camerawesome isn't calling us
    _framesReceived++;
    if (_framesReceived == 1 || _framesReceived % 30 == 0) {
      print(
        '[RecordingPage] 📷 onImageForAnalysis #$_framesReceived - streaming: $_isStreamingFrames, processing: $_isProcessingFrame, format: ${image.format}',
      );
    }

    // Skip if not streaming or already processing
    if (!_isStreamingFrames || _isProcessingFrame) return;

    _isProcessingFrame = true;

    try {
      // Convert analysis image to JPEG based on format
      // Using 60% quality for lower bandwidth
      JpegImage? jpegImage;

      if (image is Nv21Image) {
        jpegImage = await image.toJpeg(quality: 60);
      } else if (image is Bgra8888Image) {
        jpegImage = await image.toJpeg(quality: 60);
      } else if (image is Yuv420Image) {
        jpegImage = await image.toJpeg(quality: 60);
      } else if (image is JpegImage) {
        jpegImage = image;
      }

      if (jpegImage != null) {
        // Send JPEG bytes to WebSocket
        final sent = _frameStreamingService.sendJpegFrame(jpegImage.bytes);

        _framesSent++;
        if (_framesSent % 10 == 0) {
          print(
            '[RecordingPage] 📹 Sent $_framesSent frames (last: ${jpegImage.bytes.length} bytes, sent: $sent)',
          );
        }
      }
    } catch (e) {
      if (_framesReceived % 30 == 0) {
        print('[RecordingPage] ⚠️ Frame processing error: $e');
      }
    } finally {
      _isProcessingFrame = false;
    }
  }

  Future<void> _startRecording() async {
    if (_cameraState == null) return;

    try {
      // Start BLE sensor recording
      final sensorNotifier = ref.read(sensorProvider.notifier);

      // Connect to WebSocket server NOW (when recording starts)
      // IMPORTANT: fps must match _frameSamplingFps to ensure consistent inference timing
      final config = StreamConfig(
        prompt: 'Analyze the physical therapy exercise form',
        model: 'gemini-2.0-flash',
        backend: 'gemini',
        samplingRatio: 1.0,
        fps: 10, // Must match camerawesome maxFramesPerSecond
        clipLengthSeconds: 0.5,
        delaySeconds: 0.3,
        width: 640,
        height: 480,
      );

      bool wsConnected = false;
      try {
        wsConnected = await _frameStreamingService.connect(
          wsUrl: 'wss://api.mateotaylortest.org/api/overshoot/ws/stream',
          config: config,
        );

        if (wsConnected) {
          wsConnected = await _waitForWebSocketReady();
        }
      } catch (e) {
        print('[RecordingPage] ⚠️ WebSocket connection failed: $e');
        wsConnected = false;
      }

      setState(() {
        _isAnalysisAvailable = wsConnected;
      });

      // Capture the video start timestamp
      _videoStartTimeUtc = DateTime.now().toUtc().millisecondsSinceEpoch;

      // Start a new analysis session
      ref
          .read(frameAnalysisProvider.notifier)
          .startSession(_videoStartTimeUtc!);

      // Start video recording if enabled
      if (_enableVideoRecording) {
        _cameraState?.when(
          onVideoMode: (videoState) {
            videoState.startRecording();
            print('[RecordingPage] 🎥 Video recording started');
          },
          onVideoRecordingMode: (recordingState) {
            // Already recording
            print('[RecordingPage] 🎥 Already recording');
          },
        );
      } else {
        print(
          '[RecordingPage] 🎥 Video recording DISABLED - only image stream will run',
        );
      }

      if (ref.read(sensorProvider).isConnected) {
        sensorNotifier.startRecording();
      }

      // Start frame streaming if analysis is available
      if (_isAnalysisAvailable) {
        print('[RecordingPage] 🎬 Starting frame streaming service...');
        _frameStreamingService.startStreaming(cameraFps: 10);
        // Image analysis is handled by camerawesome's onImageForAnalysis callback
      } else {
        print(
          '[RecordingPage] ⚠️ Analysis NOT available - WebSocket not connected',
        );
      }

      setState(() {
        _isRecording = true;
        _isStreamingFrames = _isAnalysisAvailable;
        _recordingSeconds = 0;
        _framesSent = 0;
      });

      print(
        '[RecordingPage] ✅ Recording started - isStreamingFrames: $_isStreamingFrames, isAnalysisAvailable: $_isAnalysisAvailable, framesReceived so far: $_framesReceived',
      );

      // Start timer
      _recordingTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        setState(() {
          _recordingSeconds++;
        });
      });
    } catch (e) {
      print('[RecordingPage] ❌ Recording failed: $e');
    }
  }

  Future<bool> _waitForWebSocketReady() async {
    if (_frameStreamingService.isReady) return true;

    final completer = Completer<bool>();
    Timer? timeoutTimer;

    timeoutTimer = Timer(Duration(milliseconds: _wsReadyTimeoutMs), () {
      if (!completer.isCompleted) {
        print(
          '[RecordingPage] ⚠️ WebSocket ready timeout after ${_wsReadyTimeoutMs}ms',
        );
        completer.complete(false);
      }
    });

    if (_frameStreamingService.isReady) {
      timeoutTimer.cancel();
      return true;
    }

    final pollTimer = Timer.periodic(const Duration(milliseconds: 100), (
      timer,
    ) {
      if (_frameStreamingService.isReady) {
        timer.cancel();
        timeoutTimer?.cancel();
        if (!completer.isCompleted) {
          completer.complete(true);
        }
      }
    });

    final result = await completer.future;
    pollTimer.cancel();
    return result;
  }

  Future<void> _stopRecording() async {
    if (!_isRecording) return;

    _recordingTimer?.cancel();

    // Stop BLE sensor recording
    final sensorNotifier = ref.read(sensorProvider.notifier);
    if (ref.read(sensorProvider).isConnected) {
      await sensorNotifier.stopRecording();
      final sensorData = sensorNotifier.getSamplesAsMap();
      print('Collected ${sensorData['total_samples']} IMU samples');
    }

    // Stop frame streaming
    ref.read(frameAnalysisProvider.notifier).stopRecording();

    if (_isAnalysisAvailable) {
      _frameStreamingService.stopStreaming();
    }

    try {
      // Stop video recording if enabled
      if (_enableVideoRecording && _cameraState != null) {
        final completer = Completer<void>();

        _cameraState!.when(
          onVideoRecordingMode: (recordingState) {
            recordingState.stopRecording(
              onVideo: (captureRequest) {
                // Get the video file path from the capture request
                if (captureRequest is SingleCaptureRequest) {
                  _tempVideoPath = captureRequest.file?.path;
                  print('[RecordingPage] 🎥 Video saved: $_tempVideoPath');
                }
                if (!completer.isCompleted) completer.complete();
              },
              onVideoFailed: (exception) {
                print('[RecordingPage] ⚠️ Video recording failed: $exception');
                if (!completer.isCompleted) completer.complete();
              },
            );
          },
        );

        // Wait for video to be saved (with timeout)
        await completer.future.timeout(
          const Duration(seconds: 5),
          onTimeout: () {
            print('[RecordingPage] ⚠️ Timeout waiting for video save');
          },
        );
      } else {
        _tempVideoPath = null;
        print('[RecordingPage] 🎥 Recording stopped (no video - disabled)');
      }

      setState(() {
        _isRecording = false;
        _isStreamingFrames = false;
      });

      // Check if we need to wait for remaining results
      final pendingCount = _frameStreamingService.pendingFrameCount;
      if (_isAnalysisAvailable && pendingCount > 0) {
        print('[RecordingPage] ⏳ Waiting for $pendingCount pending results...');
        setState(() {
          _isWaitingForResults = true;
        });

        Timer(Duration(milliseconds: _waitingForResultsTimeoutMs), () {
          if (_isWaitingForResults && mounted) {
            print(
              '[RecordingPage] ⚠️ Timeout waiting for results, proceeding to review',
            );
            setState(() {
              _isWaitingForResults = false;
            });
            ref.read(frameAnalysisProvider.notifier).markSessionComplete();
            _navigateToReview();
          }
        });
      } else {
        ref.read(frameAnalysisProvider.notifier).markSessionComplete();
        _navigateToReview();
      }
    } catch (e) {
      print('[RecordingPage] ⚠️ Error stopping recording: $e');
      setState(() {
        _isRecording = false;
        _isStreamingFrames = false;
        _isWaitingForResults = false;
      });
      if (_tempVideoPath != null) {
        ref.read(frameAnalysisProvider.notifier).markSessionComplete();
        _navigateToReview();
      }
    }
  }

  Future<void> _toggleRecording() async {
    if (_isRecording) {
      await _stopRecording();
    } else {
      await _startRecording();
    }
  }

  Future<void> _finishRecording() async {
    if (_isRecording) {
      await _stopRecording();
    }
  }

  void _navigateToReview() {
    if (!mounted) return;

    if (_tempVideoPath != null) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ReviewPage(videoPath: _tempVideoPath!),
        ),
      );
    } else if (!_enableVideoRecording) {
      print(
        '[RecordingPage] ℹ️ No video to review (video recording was disabled)',
      );
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Image stream test complete. No video recorded.'),
          duration: Duration(seconds: 3),
        ),
      );
    }
  }

  String _formatDuration(int seconds) {
    final minutes = seconds ~/ 60;
    final secs = seconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
  }

  void _showErrorSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.error_outline, color: Colors.white),
            const SizedBox(width: 8),
            Expanded(child: Text(message)),
          ],
        ),
        backgroundColor: AppColors.error,
        duration: const Duration(seconds: 4),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  void dispose() {
    _recordingTimer?.cancel();
    _resultsSubscription?.cancel();
    _allResultsSubscription?.cancel();
    _connectionSubscription?.cancel();
    _frameStreamingService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final navState = ref.watch(navigationProvider);
    final projectName = navState.selectedProject?.name ?? 'Exercise';
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: AppColors.primaryDark,
      appBar: AppBar(
        title: Text('Recording: $projectName'),
        backgroundColor: AppColors.primaryDark,
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          if (_isRecording)
            TextButton(
              onPressed: _finishRecording,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_isStreamingFrames)
                    Container(
                      width: 8,
                      height: 8,
                      margin: const EdgeInsets.only(right: 6),
                      decoration: const BoxDecoration(
                        color: AppColors.success,
                        shape: BoxShape.circle,
                      ),
                    ),
                  const Text(
                    'Done',
                    style: TextStyle(
                      color: AppColors.accent,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
      body: SafeArea(
        child: Stack(
          children: [
            // CamerAwesome Camera Preview
            RotatedBox(
              quarterTurns: 1,
              child: _buildCameraAwesome(),
            ),

            // Waiting for Results Overlay
            if (_isWaitingForResults)
              Container(
                color: AppColors.primaryDark.withOpacity(0.9),
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const CircularProgressIndicator(color: AppColors.accent),
                      const SizedBox(height: 24),
                      Text(
                        'Processing frames...',
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '${_frameStreamingService.pendingFrameCount} frames remaining',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: Colors.white70,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

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
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 12,
                          height: 12,
                          decoration: const BoxDecoration(
                            color: Colors.white,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'REC ${_formatDuration(_recordingSeconds)}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

            // Pose Guide Overlay (only when not recording)
            if (!_isRecording && _isCameraReady)
              Positioned(
                top: 80,
                left: 40,
                right: 40,
                bottom: 200,
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: Colors.white.withOpacity(0.3),
                      width: 2,
                    ),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.accessibility_new,
                          size: 100,
                          color: Colors.white.withOpacity(0.2),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Position yourself here',
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.5),
                            fontSize: 16,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

            // Bottom Controls
            Positioned(
              bottom: 40,
              left: 0,
              right: 0,
              child: Column(
                children: [
                  // Instructions
                  Text(
                    _isRecording
                        ? 'Perform your exercise'
                        : 'Tap to start recording',
                    style: const TextStyle(color: Colors.white70, fontSize: 16),
                  ),
                  const SizedBox(height: 24),

                  // Record Button Row
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // Cancel Button
                      IconButton(
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close),
                        color: Colors.white,
                        iconSize: 32,
                      ),
                      const SizedBox(width: 40),

                      // Main Record Button
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
                      const SizedBox(width: 40),

                      // Flip Camera Button (handled by camerawesome internally)
                      IconButton(
                        onPressed: () {
                          _cameraState?.switchCameraSensor();
                        },
                        icon: const Icon(Icons.flip_camera_ios),
                        color: Colors.white,
                        iconSize: 32,
                      ),
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

  Widget _buildCameraAwesome() {
    return CameraAwesomeBuilder.custom(
      // Use video mode for recording capability
      saveConfig: _enableVideoRecording
          ? SaveConfig.video()
          : SaveConfig.photo(),
      // Image analysis config - 10 FPS for streaming
      onImageForAnalysis: _onImageForAnalysis,
      imageAnalysisConfig: AnalysisConfig(
        // Android: use nv21 format (recommended by MLKit), constrained to 640px width
        androidOptions: const AndroidAnalysisOptions.nv21(width: 640),
        // iOS: use bgra8888 format
        cupertinoOptions: const CupertinoAnalysisOptions.bgra8888(),
        // Auto-start analysis when camera is ready
        autoStart: true,
        // Limit to 10 FPS to match our streaming config
        maxFramesPerSecond: 10,
      ),
      // Sensor config - use 4:3 aspect ratio for 640x480 analysis frames
      sensorConfig: SensorConfig.single(
        sensor: Sensor.position(SensorPosition.back),
        flashMode: FlashMode.none,
        aspectRatio: CameraAspectRatios.ratio_4_3,
      ),
      // Custom UI builder (2 parameters: state, preview)
      builder: (state, preview) {
        // Store camera state reference for recording control
        _cameraState = state;

        // Mark camera as ready when in photo or video mode
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!_isCameraReady) {
            state.when(
              onPhotoMode: (_) {
                if (mounted) setState(() => _isCameraReady = true);
              },
              onVideoMode: (_) {
                if (mounted) setState(() => _isCameraReady = true);
              },
              onVideoRecordingMode: (_) {
                if (mounted) setState(() => _isCameraReady = true);
              },
            );
          }
        });

        // Return transparent container - our UI is in Stack overlay
        return const SizedBox.shrink();
      },
      // Handle preparation state
      previewFit: CameraPreviewFit.cover,
    );
  }
}
