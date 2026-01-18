import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
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
  CameraController? _cameraController;
  bool _isCameraInitialized = false;
  bool _isCameraAvailable = false;
  bool _isRecording = false;
  String? _tempVideoPath;
  Timer? _recordingTimer;
  int _recordingSeconds = 0;
  int _selectedCameraIndex = 0;
  List<CameraDescription> _cameras = [];
  
  // ==================== FRAME SAMPLING CONFIGURATION ====================
  // Adjust this value to change how many frames per second are captured
  // 1.0 = 1 frame per second, 0.5 = 1 frame every 2 seconds, 2.0 = 2 frames per second
  static const double _frameSamplingFps = 1.0;
  // ======================================================================
  
  // Frame sampling for hybrid approach
  Timer? _frameSamplingTimer;
  bool _isCapturingFrame = false;
  int _framesCaptured = 0;
  
  // Frame streaming
  final FrameStreamingService _frameStreamingService = FrameStreamingService();
  bool _isStreamingFrames = false;
  bool _isWaitingForResults = false;
  bool _isAnalysisAvailable = false; // Track if WebSocket/analysis is working
  StreamSubscription<InferenceResult>? _resultsSubscription;
  StreamSubscription<void>? _allResultsSubscription;
  StreamSubscription<bool>? _connectionSubscription;
  String? _latestInferenceResult;
  int? _videoStartTimeUtc; // UTC timestamp when MP4 recording started
  
  // Timeout constants
  static const int _wsReadyTimeoutMs = 5000; // 5 seconds to wait for WS ready
  static const int _waitingForResultsTimeoutMs = 10000; // 10 seconds max wait for results

  @override
  void initState() {
    super.initState();
    _initializeCamera();
    _setupFrameStreamingListeners();
  }

  void _setupFrameStreamingListeners() {
    // Set up listeners for WebSocket events (without connecting yet)
    
    // Listen for inference results from the server (sparse storage - only store these)
    _resultsSubscription = _frameStreamingService.resultsStream.listen((result) {
      // Add frame with result directly (sparse storage)
      ref.read(frameAnalysisProvider.notifier).addFrameWithResult(
        result.timestampUtc,
        result.result,
      );
      setState(() {
        _latestInferenceResult = result.result;
      });
    });
    
    // Listen for connection state changes
    _connectionSubscription = _frameStreamingService.connectionStream.listen((connected) {
      if (!connected && _isRecording && _isAnalysisAvailable) {
        // Connection lost during recording
        print('[RecordingPage] ⚠️ WebSocket connection lost during recording');
        setState(() {
          _isAnalysisAvailable = false;
          _isStreamingFrames = false;
        });
        _stopFrameSampling();
        _showErrorSnackBar('Analysis connection lost. Recording continues without real-time analysis.');
      }
    });
    
    // Listen for all results received
    _allResultsSubscription = _frameStreamingService.allResultsReceivedStream.listen((_) {
      // Mark session complete and navigate
      ref.read(frameAnalysisProvider.notifier).markSessionComplete();
      setState(() {
        _isWaitingForResults = false;
      });
      _navigateToReview();
    });
  }

  Future<void> _initializeCamera() async {
    // Request camera permission
    final cameraStatus = await Permission.camera.request();
    final micStatus = await Permission.microphone.request();

    if (cameraStatus.isDenied || micStatus.isDenied) {
      setState(() {
        _isCameraAvailable = false;
        _isCameraInitialized = true;
      });
      return;
    }

    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        setState(() {
          _isCameraAvailable = false;
          _isCameraInitialized = true;
        });
        return;
      }

      await _setupCamera(_selectedCameraIndex);
    } catch (e) {
      setState(() {
        _isCameraAvailable = false;
        _isCameraInitialized = true;
      });
    }
  }

  Future<void> _setupCamera(int cameraIndex) async {
    if (_cameras.isEmpty) return;

    // Dispose existing controller
    await _cameraController?.dispose();

    _cameraController = CameraController(
      _cameras[cameraIndex],
      ResolutionPreset.high,
      enableAudio: true,
    );

    try {
      await _cameraController!.initialize();
      setState(() {
        _isCameraAvailable = true;
        _isCameraInitialized = true;
        _selectedCameraIndex = cameraIndex;
      });
    } catch (e) {
      setState(() {
        _isCameraAvailable = false;
        _isCameraInitialized = true;
      });
    }
  }

  void _flipCamera() {
    if (_cameras.length < 2) return;
    final newIndex = (_selectedCameraIndex + 1) % _cameras.length;
    _setupCamera(newIndex);
  }

  Future<void> _startRecording() async {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return;
    }

    try {
      // Start BLE sensor recording (sends "Start" command and calculates RTT)
      final sensorNotifier = ref.read(sensorProvider.notifier);

      // Connect to WebSocket server NOW (when recording starts)
      const config = StreamConfig(
        prompt: 'Analyze the physical therapy exercise form',
        model: 'gemini-2.0-flash',
        backend: 'gemini',
        samplingRatio: 1.0,
        fps: 30,
        clipLengthSeconds: 3.0,
        delaySeconds: 3.0,
        width: 640,
        height: 480,
      );
      
      // Attempt to connect to WebSocket - may fail, that's OK
      bool wsConnected = false;
      try {
        wsConnected = await _frameStreamingService.connect(
          wsUrl: 'wss://api.mateotaylortest.org/api/overshoot/ws/stream',
          config: config,
        );
        
        // Wait for WebSocket to become ready (receive 'ready' message from server)
        if (wsConnected) {
          wsConnected = await _waitForWebSocketReady();
        }
      } catch (e) {
        print('[RecordingPage] ⚠️ WebSocket connection failed: $e');
        wsConnected = false;
      }
      
      // Set analysis availability based on connection success
      setState(() {
        _isAnalysisAvailable = wsConnected;
      });
      
      // Notify user if analysis is not available (but don't block recording)
      if (!wsConnected) {
        _showWarningSnackBar(
          'Real-time analysis unavailable. Recording will continue without frame analysis.',
        );
      }
      
      // Capture the video start timestamp BEFORE starting the recording
      _videoStartTimeUtc = DateTime.now().toUtc().millisecondsSinceEpoch;
      
      // Start a new analysis session in the provider with the video start timestamp
      ref.read(frameAnalysisProvider.notifier).startSession(_videoStartTimeUtc!);
      
      // Start video recording (saves to file)
      await _cameraController!.startVideoRecording();
      if (ref.read(sensorProvider).isConnected) {
        sensorNotifier.startRecording();
      }
      
      // Only start frame streaming if analysis is available
      if (_isAnalysisAvailable) {
        print('[RecordingPage] 🎬 Starting frame streaming service...');
        _frameStreamingService.startStreaming(cameraFps: 30);
        
        // Start hybrid frame sampling (takes pictures at configured FPS)
        _startFrameSampling();
      }
      
      setState(() {
        _isRecording = true;
        _isStreamingFrames = _isAnalysisAvailable;
        _recordingSeconds = 0;
        _framesCaptured = 0;
      });

      // Start timer
      _recordingTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        setState(() {
          _recordingSeconds++;
        });
      });
    } catch (e) {
      print('[RecordingPage] ❌ Recording failed: $e');
      _showErrorSnackBar('Failed to start recording: $e');
    }
  }

  /// Wait for WebSocket to receive 'ready' message from server
  /// Returns true if ready within timeout, false otherwise
  Future<bool> _waitForWebSocketReady() async {
    if (_frameStreamingService.isReady) return true;
    
    final completer = Completer<bool>();
    Timer? timeoutTimer;
    
    // Set up timeout
    timeoutTimer = Timer(Duration(milliseconds: _wsReadyTimeoutMs), () {
      if (!completer.isCompleted) {
        print('[RecordingPage] ⚠️ WebSocket ready timeout after ${_wsReadyTimeoutMs}ms');
        completer.complete(false);
      }
    });
    
    // Check if already ready
    if (_frameStreamingService.isReady) {
      timeoutTimer.cancel();
      return true;
    }
    
    // Poll for ready state (simpler than adding a ready stream)
    final pollTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
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

  /// Show a warning message to the user (orange, non-blocking)
  void _showWarningSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.warning_amber_rounded, color: Colors.white),
            const SizedBox(width: 8),
            Expanded(child: Text(message)),
          ],
        ),
        backgroundColor: AppColors.warning,
        duration: const Duration(seconds: 4),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// Start periodic frame sampling using takePicture()
  /// This runs in parallel with video recording
  void _startFrameSampling() {
    print('[RecordingPage] 📸 Starting frame sampling at $_frameSamplingFps fps...');
    
    // Calculate interval in milliseconds from FPS
    final intervalMs = (1000 / _frameSamplingFps).round();
    
    _frameSamplingTimer = Timer.periodic(
      Duration(milliseconds: intervalMs),
      (_) => _captureAndSendFrame(),
    );
    
    // Also capture first frame immediately
    _captureAndSendFrame();
  }
  
  /// Capture a single frame and send it to the WebSocket
  Future<void> _captureAndSendFrame() async {
    // Prevent overlapping captures
    if (_isCapturingFrame || !_isRecording || _cameraController == null) return;
    
    _isCapturingFrame = true;
    
    try {
      // Get timestamp BEFORE taking picture for accuracy
      final timestampUtc = DateTime.now().toUtc().millisecondsSinceEpoch;
      
      // Take a picture (this works even during video recording)
      final XFile imageFile = await _cameraController!.takePicture();
      
      // Read the JPEG bytes
      final Uint8List jpegBytes = await File(imageFile.path).readAsBytes();
      
      // Convert JPEG to RGB24 in an isolate to avoid blocking UI
      final rgb24Bytes = await _decodeJpegToRgb24(
        jpegBytes,
        _frameStreamingService.configWidth,
        _frameStreamingService.configHeight,
      );
      
      // Send to WebSocket with the captured timestamp
      _frameStreamingService.sendRawFrameWithTimestamp(rgb24Bytes, timestampUtc);
      
      // Clean up the temporary image file
      await File(imageFile.path).delete();
      
      setState(() {
        _framesCaptured++;
      });
      
      print('[RecordingPage] 📸 Frame $_framesCaptured captured and sent');
      
    } catch (e) {
      print('[RecordingPage] ⚠️ Frame capture failed: $e');
    } finally {
      _isCapturingFrame = false;
    }
  }
  
  /// Decode JPEG bytes to RGB24 format
  /// Runs in isolate to avoid blocking the UI thread
  Future<Uint8List> _decodeJpegToRgb24(
    Uint8List jpegBytes,
    int targetWidth,
    int targetHeight,
  ) async {
    return await Isolate.run(() {
      // Decode JPEG
      final image = img.decodeJpg(jpegBytes);
      if (image == null) {
        return Uint8List(targetWidth * targetHeight * 3);
      }
      
      // Resize to target dimensions
      final resized = img.copyResize(
        image,
        width: targetWidth,
        height: targetHeight,
        interpolation: img.Interpolation.linear,
      );
      
      // Convert to RGB24 bytes
      final rgb24 = Uint8List(targetWidth * targetHeight * 3);
      int index = 0;
      
      for (int y = 0; y < targetHeight; y++) {
        for (int x = 0; x < targetWidth; x++) {
          final pixel = resized.getPixel(x, y);
          rgb24[index++] = pixel.r.toInt();
          rgb24[index++] = pixel.g.toInt();
          rgb24[index++] = pixel.b.toInt();
        }
      }
      
      return rgb24;
    });
  }
  
  /// Stop frame sampling
  void _stopFrameSampling() {
    _frameSamplingTimer?.cancel();
    _frameSamplingTimer = null;
    print('[RecordingPage] 📸 Frame sampling stopped. Total frames captured: $_framesCaptured');
  }

  Future<void> _stopRecording() async {
    if (_cameraController == null || !_cameraController!.value.isRecordingVideo) {
      return;
    }

    _recordingTimer?.cancel();
    
    // Stop frame sampling first (only if it was running)
    if (_isAnalysisAvailable) {
      _stopFrameSampling();
    }
    
    // Stop BLE sensor recording
    final sensorNotifier = ref.read(sensorProvider.notifier);
    if (ref.read(sensorProvider).isConnected) {
      await sensorNotifier.stopRecording();
      // Get sensor data as JSON for later use
      final sensorData = sensorNotifier.getSamplesAsMap();
      debugPrint('Collected ${sensorData['total_samples']} IMU samples');
    }
    
    // Stop frame streaming - mark session as stopped in provider
    ref.read(frameAnalysisProvider.notifier).stopRecording();
    
    // Only stop streaming if it was active
    if (_isAnalysisAvailable) {
      _frameStreamingService.stopStreaming();
    }

    try {
      final XFile videoFile = await _cameraController!.stopVideoRecording();
      
      // Get temp directory and copy the video
      final tempDir = await getTemporaryDirectory();
      _tempVideoPath = '${tempDir.path}/temp_record.mp4';
      
      // Copy recorded video to temp path
      await File(videoFile.path).copy(_tempVideoPath!);

      setState(() {
        _isRecording = false;
        _isStreamingFrames = false;
      });

      // Check if we need to wait for remaining results (only if analysis was available)
      final pendingCount = _frameStreamingService.pendingFrameCount;
      if (_isAnalysisAvailable && pendingCount > 0) {
        print('[RecordingPage] ⏳ Waiting for $pendingCount pending results...');
        setState(() {
          _isWaitingForResults = true;
        });
        
        // Start a timeout timer - don't wait forever for results
        Timer(Duration(milliseconds: _waitingForResultsTimeoutMs), () {
          if (_isWaitingForResults && mounted) {
            print('[RecordingPage] ⚠️ Timeout waiting for results, proceeding to review');
            _showErrorSnackBar('Some analysis results were not received.');
            setState(() {
              _isWaitingForResults = false;
            });
            ref.read(frameAnalysisProvider.notifier).markSessionComplete();
            _navigateToReview();
          }
        });
        
        // Navigation will happen when allResultsReceivedStream fires (or timeout)
      } else {
        // No pending frames or analysis wasn't available, navigate immediately
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
      // Still try to navigate to review if we have a video path
      if (_tempVideoPath != null) {
        ref.read(frameAnalysisProvider.notifier).markSessionComplete();
        _navigateToReview();
      }
    }
  }

  Future<void> _toggleRecording() async {
    if (_isCameraAvailable && _cameraController != null) {
      if (_isRecording) {
        await _stopRecording();
      } else {
        await _startRecording();
      }
    } else {
      // No camera available - simulate recording with fallback
      if (_isRecording) {
        _recordingTimer?.cancel();
        setState(() {
          _isRecording = false;
        });
        await _useFallbackVideo();
      } else {
        setState(() {
          _isRecording = true;
          _recordingSeconds = 0;
        });
        _recordingTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
          setState(() {
            _recordingSeconds++;
          });
        });
      }
    }
  }

  Future<void> _finishRecording() async {
    if (_isCameraAvailable && _cameraController != null && _isRecording) {
      await _stopRecording();
    } else {
      _recordingTimer?.cancel();
      setState(() {
        _isRecording = false;
      });
      await _useFallbackVideo();
    }
  }

  Future<void> _useFallbackVideo() async {
    try {
      final tempDir = await getTemporaryDirectory();
      _tempVideoPath = '${tempDir.path}/temp_record.mp4';

      final byteData = await rootBundle.load('static/walking.mp4');
      final file = File(_tempVideoPath!);
      await file.writeAsBytes(byteData.buffer.asUint8List());

      _navigateToReview();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Error loading video')),
        );
      }
    }
  }

  void _navigateToReview() {
    if (mounted && _tempVideoPath != null) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ReviewPage(videoPath: _tempVideoPath!),
        ),
      );
    }
  }

  String _formatDuration(int seconds) {
    final minutes = seconds ~/ 60;
    final secs = seconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
  }

  /// Show an error/warning message to the user
  void _showErrorSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: AppColors.warning,
        duration: const Duration(seconds: 4),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  void dispose() {
    _recordingTimer?.cancel();
    _frameSamplingTimer?.cancel();
    _resultsSubscription?.cancel();
    _allResultsSubscription?.cancel();
    _connectionSubscription?.cancel();
    _frameStreamingService.dispose();
    _cameraController?.dispose();
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
            // Camera Preview or Placeholder
            _buildCameraPreview(),
            
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
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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
            if (!_isRecording)
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
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 8),

                  // Camera status indicator
                  if (!_isCameraAvailable && _isCameraInitialized)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.warning.withOpacity(0.9),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Text(
                        'Using demo video',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  const SizedBox(height: 16),

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
                        onTap: _isCameraInitialized ? _toggleRecording : null,
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

                      // Flip Camera Button
                      IconButton(
                        onPressed: _isCameraAvailable && _cameras.length > 1
                            ? _flipCamera
                            : null,
                        icon: const Icon(Icons.flip_camera_ios),
                        color: _isCameraAvailable && _cameras.length > 1
                            ? Colors.white
                            : Colors.grey,
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

  Widget _buildCameraPreview() {
    if (!_isCameraInitialized) {
      return Container(
        color: AppColors.primaryDark,
        child: const Center(
          child: CircularProgressIndicator(color: AppColors.accent),
        ),
      );
    }

    if (_isCameraAvailable && _cameraController != null && _cameraController!.value.isInitialized) {
      return Center(
        child: CameraPreview(_cameraController!),
      );
    }

    // Fallback placeholder when camera is not available
    return Container(
      width: double.infinity,
      height: double.infinity,
      color: AppColors.primary,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.videocam_off_outlined,
            size: 80,
            color: AppColors.primaryLight.withOpacity(0.6),
          ),
          const SizedBox(height: 16),
          Text(
            'Camera Unavailable',
            style: TextStyle(
              color: AppColors.primaryLight.withOpacity(0.8),
              fontSize: 18,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Demo video will be used',
            style: TextStyle(
              color: AppColors.primaryLight.withOpacity(0.6),
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }
}
