import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';
import '../main.dart';
import '../providers/navigation_provider.dart';
import '../providers/sensor_provider.dart';
import 'analytics_page.dart';

class ReviewPage extends ConsumerStatefulWidget {
  final String videoPath;

  const ReviewPage({super.key, required this.videoPath});

  @override
  ConsumerState<ReviewPage> createState() => _ReviewPageState();
}

class _ReviewPageState extends ConsumerState<ReviewPage> {
  VideoPlayerController? _controller;
  bool _isInitialized = false;
  bool _isPlaying = false;

  @override
  void initState() {
    super.initState();
    _initializeVideo();
  }

  Future<void> _initializeVideo() async {
    VideoPlayerController controller;
    if (widget.videoPath.startsWith('stream://')) {
      final streamId = widget.videoPath.replaceFirst('stream://', '');
      // Construct the URL for the backend endpoint we just added
      // Base URL matches the one used in FrameStreamingService (converted to https)
      final url =
          'https://api.mateotaylortest.org/api/pose/streams/$streamId/video';
      print('[ReviewPage] Initializing video from stream URL: $url');
      controller = VideoPlayerController.networkUrl(Uri.parse(url));
    } else {
      final file = File(widget.videoPath);
      if (!await file.exists()) {
        print('[ReviewPage] Local file not found: ${widget.videoPath}');
        return;
      }
      controller = VideoPlayerController.file(file);
    }

    try {
      _controller = controller;
      await _controller!.initialize();
      _controller!.addListener(_videoListener);
      setState(() {
        _isInitialized = true;
      });
    } catch (e) {
      print('[ReviewPage] Error initializing video: $e');
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to load video: $e')));
    }
  }

  void _videoListener() {
    final isPlaying = _controller?.value.isPlaying ?? false;
    if (isPlaying != _isPlaying) {
      setState(() {
        _isPlaying = isPlaying;
      });
    }
  }

  @override
  void dispose() {
    _controller?.removeListener(_videoListener);
    _controller?.dispose();
    super.dispose();
  }

  void _togglePlayPause() {
    if (_controller == null) return;
    if (_controller!.value.isPlaying) {
      _controller!.pause();
    } else {
      _controller!.play();
    }
  }

  void _replayVideo() {
    _controller?.seekTo(Duration.zero);
    _controller?.play();
  }

  void _proceedToAnalysis() {
    // Get video duration in milliseconds
    final videoDurationMs = _controller?.value.duration.inMilliseconds ?? 0;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AnalyticsPage(
          videoPath: widget.videoPath,
          videoDurationMs: videoDurationMs,
          fps: 30, // Default FPS, adjust if needed
        ),
      ),
    );
  }

  void _retakeRecording() {
    Navigator.pop(context);
  }

  void _showSensorDataDialog(BuildContext context, WidgetRef ref) {
    print('[SensorDialog] _showSensorDataDialog called');
    print('[SensorDialog] context.mounted: ${context.mounted}');

    // Capture sensor data BEFORE showing dialog to avoid rebuild issues
    if (ref.read(sensorProvider).isRecording) {
      print('[SensorDialog] Stopping recording first');
      ref.read(sensorProvider.notifier).stopRecording();
    }

    final sensorState = ref.read(sensorProvider);
    final samples = List.unmodifiable(sensorState.sampleBuffer);
    final droppedPackets = sensorState.droppedPackets;

    print(
      '[SensorDialog] Captured ${samples.length} samples, $droppedPackets dropped',
    );

    // Generate CSV content
    // Header: time_ms, gyroA_x, gyroA_y, gyroA_z, gyroB_x, gyroB_y, gyroB_z
    final csvBuffer = StringBuffer();
    csvBuffer.writeln(
      'time_ms,gyroA_x,gyroA_y,gyroA_z,gyroB_x,gyroB_y,gyroB_z',
    );

    for (final sample in samples) {
      csvBuffer.writeln(
        '${sample.timeOffset},'
        '${sample.gyroA[0].toStringAsFixed(2)},'
        '${sample.gyroA[1].toStringAsFixed(2)},'
        '${sample.gyroA[2].toStringAsFixed(2)},'
        '${sample.gyroB[0].toStringAsFixed(2)},'
        '${sample.gyroB[1].toStringAsFixed(2)},'
        '${sample.gyroB[2].toStringAsFixed(2)}',
      );
    }

    final csvContent = csvBuffer.toString();
    final sampleCount = samples.length;
    final duration = samples.isNotEmpty ? samples.last.timeOffset / 1000 : 0.0;

    print('[SensorDialog] About to call showDialog');

    // Use a local context reference to avoid issues with widget rebuilds
    final navigatorState = Navigator.of(context, rootNavigator: true);

    showDialog<void>(
      barrierDismissible:
          false, // Disable for debugging - prevents accidental dismiss
      context: context,
      useRootNavigator: true,
      builder: (dialogContext) {
        print(
          '[SensorDialog] Dialog builder called, dialogContext.mounted: ${dialogContext.mounted}',
        );
        print(
          '[SensorDialog] Navigator canPop: ${Navigator.of(dialogContext).canPop()}',
        );
        return PopScope(
          canPop: true,
          onPopInvokedWithResult: (didPop, result) {
            print(
              '[SensorDialog] PopScope onPopInvoked: didPop=$didPop, result=$result',
            );
          },
          child: AlertDialog(
            backgroundColor: AppColors.primary,
            title: Row(
              children: [
                const Icon(Icons.sensors, color: Colors.white),
                const SizedBox(width: 8),
                Text(
                  'Sensor Data ($sampleCount samples)',
                  style: const TextStyle(color: Colors.white),
                ),
              ],
            ),
            content: SizedBox(
              width: double.maxFinite,
              height: 400,
              child: sampleCount == 0
                  ? const Center(
                      child: Text(
                        'No sensor data recorded.\nConnect IMU device before recording.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white70),
                      ),
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Stats row
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: AppColors.primaryDark,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceAround,
                            children: [
                              _StatChip(
                                label: 'Samples',
                                value: '$sampleCount',
                              ),
                              const _StatChip(label: 'Rate', value: '100Hz'),
                              _StatChip(
                                label: 'Duration',
                                value: '${duration.toStringAsFixed(1)}s',
                              ),
                              _StatChip(
                                label: 'Dropped',
                                value: '$droppedPackets',
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        // CSV header
                        const Text(
                          'CSV Preview (gyro values in °/s):',
                          style: TextStyle(color: Colors.white70, fontSize: 12),
                        ),
                        const SizedBox(height: 4),
                        // CSV content in scrollable container
                        Expanded(
                          child: Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: Colors.black87,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: SingleChildScrollView(
                              child: SelectableText(
                                csvContent,
                                style: const TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 10,
                                  color: Colors.greenAccent,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
            actions: [
              if (sampleCount > 0)
                TextButton.icon(
                  onPressed: () {
                    print('[SensorDialog] Copy button pressed');
                    Clipboard.setData(ClipboardData(text: csvContent));
                    ScaffoldMessenger.of(dialogContext).showSnackBar(
                      const SnackBar(
                        content: Text('CSV copied to clipboard'),
                        duration: Duration(seconds: 2),
                      ),
                    );
                  },
                  icon: const Icon(Icons.copy, color: Colors.white70),
                  label: const Text(
                    'Copy CSV',
                    style: TextStyle(color: Colors.white70),
                  ),
                ),
              TextButton(
                onPressed: () {
                  print('[SensorDialog] Close button pressed');
                  Navigator.of(dialogContext).pop();
                },
                child: const Text(
                  'Close',
                  style: TextStyle(color: Colors.white),
                ),
              ),
            ],
          ),
        ); // closes PopScope
      },
    ).then((_) {
      print('[SensorDialog] Dialog closed (then callback)');
    });
  }

  @override
  Widget build(BuildContext context) {
    final navState = ref.watch(navigationProvider);
    final projectName = navState.selectedProject?.name ?? 'Exercise';
    // Page is always landscape-locked, so screenHeight is the short side.
    // Scale UI relative to screen height to stay compact on phones.
    final h = MediaQuery.sizeOf(context).height;

    final sectionPad = (h * 0.02).clamp(6.0, 16.0);
    final titleSize = (h * 0.032).clamp(13.0, 22.0);
    final bodySize = (h * 0.022).clamp(10.0, 16.0);
    final controlPad = (h * 0.018).clamp(4.0, 16.0);
    final playIconSize = (h * 0.07).clamp(24.0, 48.0);
    final replayIconSize = (h * 0.05).clamp(18.0, 32.0);
    final overlayIconSize = (h * 0.07).clamp(24.0, 48.0);
    final overlayPad = (h * 0.025).clamp(6.0, 16.0);
    final btnPadV = (h * 0.018).clamp(6.0, 16.0);
    final btnGap = (h * 0.02).clamp(6.0, 16.0);
    final infoGap = (h * 0.01).clamp(2.0, 8.0);

    return Scaffold(
      backgroundColor: AppColors.primaryDark,
      appBar: AppBar(
        title: const Text('Review Recording'),
        backgroundColor: AppColors.primaryDark,
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          // Developer option to view sensor data
          IconButton(
            icon: const Icon(Icons.developer_mode),
            tooltip: 'View Sensor Data (CSV)',
            onPressed: () => _showSensorDataDialog(context, ref),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Video Player Area
            Expanded(
              child: _isInitialized && _controller != null
                  ? Stack(
                      alignment: Alignment.center,
                      children: [
                        // Video Player
                        AspectRatio(
                          aspectRatio: _controller!.value.aspectRatio,
                          child: VideoPlayer(_controller!),
                        ),

                        // Play/Pause Overlay
                        GestureDetector(
                          onTap: _togglePlayPause,
                          child: Container(
                            color: Colors.transparent,
                            child: Center(
                              child: AnimatedOpacity(
                                opacity: _isPlaying ? 0.0 : 1.0,
                                duration: const Duration(milliseconds: 200),
                                child: Container(
                                  padding: EdgeInsets.all(overlayPad),
                                  decoration: BoxDecoration(
                                    color: AppColors.primaryDark.withOpacity(
                                      0.7,
                                    ),
                                    shape: BoxShape.circle,
                                  ),
                                  child: Icon(
                                    Icons.play_arrow,
                                    color: Colors.white,
                                    size: overlayIconSize,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),

                        // Progress Bar
                        Positioned(
                          bottom: 0,
                          left: 0,
                          right: 0,
                          child: VideoProgressIndicator(
                            _controller!,
                            allowScrubbing: true,
                            colors: VideoProgressColors(
                              playedColor: AppColors.accent,
                              bufferedColor: AppColors.primaryLight.withOpacity(
                                0.4,
                              ),
                              backgroundColor: AppColors.primaryLight
                                  .withOpacity(0.2),
                            ),
                          ),
                        ),
                      ],
                    )
                  : _buildPlaceholder(),
            ),

            // Info Section
            Container(
              padding: EdgeInsets.all(sectionPad),
              color: AppColors.primary,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    projectName,
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: titleSize,
                    ),
                  ),
                  SizedBox(height: infoGap),
                  Text(
                    'Review your recording before submitting for analysis.',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: bodySize,
                    ),
                  ),
                ],
              ),
            ),

            // Playback Controls
            Container(
              padding: EdgeInsets.symmetric(vertical: controlPad),
              color: AppColors.primary,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  // Replay Button
                  IconButton(
                    onPressed: _isInitialized ? _replayVideo : null,
                    icon: const Icon(Icons.replay),
                    color: Colors.white,
                    iconSize: replayIconSize,
                  ),

                  // Play/Pause Button
                  IconButton(
                    onPressed: _isInitialized ? _togglePlayPause : null,
                    icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow),
                    color: Colors.white,
                    iconSize: playIconSize,
                  ),

                  // Placeholder for symmetry
                  SizedBox(width: playIconSize),
                ],
              ),
            ),

            // Action Buttons
            Container(
              padding: EdgeInsets.all(sectionPad),
              color: AppColors.primary,
              child: Row(
                children: [
                  // Retake Button
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _retakeRecording,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: BorderSide(color: Colors.white.withOpacity(0.4)),
                        padding: EdgeInsets.symmetric(vertical: btnPadV),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(btnGap * 0.75),
                        ),
                      ),
                      icon: const Icon(Icons.refresh),
                      label: Text('Retake', style: TextStyle(fontSize: bodySize)),
                    ),
                  ),
                  SizedBox(width: btnGap),

                  // Continue Button
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _proceedToAnalysis,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.accent,
                        foregroundColor: Colors.white,
                        padding: EdgeInsets.symmetric(vertical: btnPadV),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(btnGap * 0.75),
                        ),
                      ),
                      icon: const Icon(Icons.analytics),
                      label: Text('Analyze', style: TextStyle(fontSize: bodySize)),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlaceholder() {
    final h = MediaQuery.sizeOf(context).height;
    final iconSize = (h * 0.12).clamp(40.0, 80.0);
    final headingSize = (h * 0.028).clamp(12.0, 18.0);
    final subSize = (h * 0.02).clamp(10.0, 14.0);
    final gap = (h * 0.02).clamp(6.0, 16.0);

    return Container(
      color: AppColors.primary,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.videocam_outlined,
            size: iconSize,
            color: AppColors.primaryLight.withOpacity(0.6),
          ),
          SizedBox(height: gap),
          Text(
            'Video Preview',
            style: TextStyle(
              color: AppColors.primaryLight.withOpacity(0.8),
              fontSize: headingSize,
            ),
          ),
          SizedBox(height: gap * 0.5),
          Text(
            '(Placeholder - no video recorded yet)',
            style: TextStyle(
              color: AppColors.primaryLight.withOpacity(0.6),
              fontSize: subSize,
            ),
          ),
        ],
      ),
    );
  }
}

/// Small stat chip widget for sensor data dialog
class _StatChip extends StatelessWidget {
  final String label;
  final String value;

  const _StatChip({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 14,
          ),
        ),
        Text(
          label,
          style: const TextStyle(color: Colors.white70, fontSize: 10),
        ),
      ],
    );
  }
}
