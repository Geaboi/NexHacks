import 'dart:async';
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
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
  
  // Frame streaming
  final FrameStreamingService _frameStreamingService = FrameStreamingService();
  bool _isStreamingFrames = false;
  bool _isWaitingForResults = false;
  StreamSubscription<InferenceResult>? _resultsSubscription;
  StreamSubscription<int>? _frameSentSubscription;
  StreamSubscription<void>? _allResultsSubscription;
  String? _latestInferenceResult;

  @override
  void initState() {
    super.initState();
    _initializeCamera();
    _setupFrameStreamingListeners();
  }

  void _setupFrameStreamingListeners() {
    // Set up listeners for WebSocket events (without connecting yet)
    
    // Listen for inference results from the server
    _resultsSubscription = _frameStreamingService.resultsStream.listen((result) {
      // Update provider with the result
      ref.read(frameAnalysisProvider.notifier).updateFrameResult(
        result.timestampUtc,
        result.result,
      );
      setState(() {
        _latestInferenceResult = result.result;
      });
    });
    
    // Listen for frames being sent
    _frameSentSubscription = _frameStreamingService.frameSentStream.listen((timestamp) {
      // Register frame in provider
      ref.read(frameAnalysisProvider.notifier).addFrame(timestamp);
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
      // Start a new analysis session in the provider
      ref.read(frameAnalysisProvider.notifier).startSession();
      
      // Start BLE sensor recording (sends "Start" command and calculates RTT)
      final sensorNotifier = ref.read(sensorProvider.notifier);
      
      // Connect to WebSocket server NOW (when recording starts)
      const config = StreamConfig(
        prompt: 'Analyze the physical therapy exercise form',
        model: 'gemini-2.0-flash',
        backend: 'gemini',
        fps: 30,
        width: 640,
        height: 480,
      );
      
      await _frameStreamingService.connect(
        wsUrl: 'ws://localhost:8080/frames',
        config: config,
      );

      _cameraController!.startVideoRecording();
      if (ref.read(sensorProvider).isConnected) {
        sensorNotifier.startRecording();
      }
      
      // Start frame streaming to WebSocket (assumes ~30fps camera)
      _frameStreamingService.startStreaming(cameraFps: 30);
      await _startImageStream();
      
      setState(() {
        _isRecording = true;
        _isStreamingFrames = true;
        _recordingSeconds = 0;
      });

      // Start timer
      _recordingTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        setState(() {
          _recordingSeconds++;
        });
      });
    } catch (e) {
      // Recording failed silently
    }
  }

  Future<void> _startImageStream() async {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return;
    }
    
    // Note: startImageStream may not work simultaneously with video recording
    // on all devices. If it doesn't work, frames will be captured from the
    // recorded video in post-processing instead.
    try {
      await _cameraController!.startImageStream((CameraImage image) {
        // Send frame to WebSocket service
        _frameStreamingService.processFrame(image);
      });
    } catch (e) {
      // Image stream not available during video recording on this device
      // This is expected on some devices
    }
  }

  Future<void> _stopImageStream() async {
    if (_cameraController == null) return;
    
    try {
      await _cameraController!.stopImageStream();
    } catch (e) {
      // Image stream wasn't running
    }
  }

  Future<void> _stopRecording() async {
    if (_cameraController == null || !_cameraController!.value.isRecordingVideo) {
      return;
    }

    _recordingTimer?.cancel();
    
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
    _frameStreamingService.stopStreaming();
    await _stopImageStream();

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

      // Check if we need to wait for remaining results
      if (_frameStreamingService.pendingFrameCount > 0) {
        setState(() {
          _isWaitingForResults = true;
        });
        // Navigation will happen when allResultsReceivedStream fires
      } else {
        // No pending frames, navigate immediately
        ref.read(frameAnalysisProvider.notifier).markSessionComplete();
        _navigateToReview();
      }
    } catch (e) {
      setState(() {
        _isRecording = false;
        _isStreamingFrames = false;
        _isWaitingForResults = false;
      });
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

  @override
  void dispose() {
    _recordingTimer?.cancel();
    _resultsSubscription?.cancel();
    _frameSentSubscription?.cancel();
    _allResultsSubscription?.cancel();
    _frameStreamingService.dispose();
    _cameraController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final navState = ref.watch(navigationProvider);
    final projectName = navState.selectedProject?.name ?? 'Exercise';

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text('Recording: $projectName'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
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
                        color: Colors.green,
                        shape: BoxShape.circle,
                      ),
                    ),
                  const Text(
                    'Done',
                    style: TextStyle(
                      color: Colors.teal,
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
                color: Colors.black.withOpacity(0.8),
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const CircularProgressIndicator(color: Colors.teal),
                      const SizedBox(height: 24),
                      const Text(
                        'Processing frames...',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '${_frameStreamingService.pendingFrameCount} frames remaining',
                        style: TextStyle(
                          color: Colors.grey[400],
                          fontSize: 14,
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
                        color: Colors.orange.withOpacity(0.8),
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
        color: Colors.black,
        child: const Center(
          child: CircularProgressIndicator(color: Colors.teal),
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
      color: Colors.grey[900],
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.videocam_off_outlined,
            size: 80,
            color: Colors.grey[600],
          ),
          const SizedBox(height: 16),
          Text(
            'Camera Unavailable',
            style: TextStyle(
              color: Colors.grey[500],
              fontSize: 18,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Demo video will be used',
            style: TextStyle(
              color: Colors.grey[600],
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }
}
