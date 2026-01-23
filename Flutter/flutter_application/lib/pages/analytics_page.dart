import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:video_player/video_player.dart';
import '../providers/navigation_provider.dart';
import '../providers/frame_analysis_provider.dart';
import '../providers/sensor_provider.dart';
import '../providers/session_history_provider.dart';
import '../models/frame_angle.dart';
import '../services/analytics_service.dart';
import '../main.dart';
import 'home_page.dart';

class AnalyticsPage extends ConsumerStatefulWidget {
  final String videoPath;
  final int videoDurationMs;
  final int fps;

  const AnalyticsPage({super.key, required this.videoPath, required this.videoDurationMs, this.fps = 30});

  @override
  ConsumerState<AnalyticsPage> createState() => _AnalyticsPageState();
}

class _AnalyticsPageState extends ConsumerState<AnalyticsPage> {
  final AnalyticsService _analyticsService = AnalyticsService();

  bool _isSubmitting = false;
  bool _hasSubmitted = false;
  bool _isSavingToDb = false;
  AnalyticsResponse? _response;
  String? _errorMessage;
  List<AngleStats>? _sessionStats;
  List<FrameAngle>? _sessionAngles;
  List<int> _anomalousFrameIds = [];
  List<List<dynamic>>? _rawAngles;
  int? _usedJointIndex;
  
  int? _savedSessionId;
  DateTime? _sessionTimestamp;

  // Video player state
  VideoPlayerController? _videoController;
  bool _isVideoInitialized = false;
  bool _isVideoPlaying = false;

  @override
  void initState() {
    super.initState();
    // Submit analysis when page loads
    _submitAnalysis();

    // Show a brief snackbar if analysis wasn't available
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final frameAnalysis = ref.read(frameAnalysisProvider);
      if (frameAnalysis.inferencePoints.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Row(
              children: [
                Icon(Icons.info_outline, color: Colors.white, size: 18),
                SizedBox(width: 8),
                Text('Model saved! Analysis will be available soon.'),
              ],
            ),
            backgroundColor: Colors.orange.shade700,
            duration: const Duration(seconds: 3),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
        );
      }
    });
  }

  @override
  void dispose() {
    _videoController?.removeListener(_videoListener);
    _videoController?.dispose();
    super.dispose();
  }

  void _videoListener() {
    final isPlaying = _videoController?.value.isPlaying ?? false;
    if (isPlaying != _isVideoPlaying) {
      setState(() {
        _isVideoPlaying = isPlaying;
      });
    }
  }

  Future<void> _initializeVideo(String videoPath) async {
    // Dispose old controller if exists
    _videoController?.removeListener(_videoListener);
    _videoController?.dispose();

    final file = File(videoPath);
    if (await file.exists()) {
      _videoController = VideoPlayerController.file(file);
      await _videoController!.initialize();
      _videoController!.addListener(_videoListener);
      setState(() {
        _isVideoInitialized = true;
      });
      print('[AnalyticsPage] 🎬 Video initialized: $videoPath');
    } else {
      print('[AnalyticsPage] ⚠️ Video file not found: $videoPath');
    }
  }

  void _togglePlayPause() {
    if (_videoController == null) return;
    if (_videoController!.value.isPlaying) {
      _videoController!.pause();
    } else {
      _videoController!.play();
    }
  }

  Future<void> _submitAnalysis() async {
    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
      _sessionTimestamp = DateTime.now();
    });

    try {
      final frameAnalysis = ref.read(frameAnalysisProvider);
      final sensorState = ref.read(sensorProvider);

      // Get video start time from frame analysis state
      final videoStartTimeUtc = frameAnalysis.videoStartTimeUtc ?? DateTime.now().toUtc().millisecondsSinceEpoch;

      // Convert inference points to JSON format
      final inferencePointsJson = frameAnalysis.inferencePoints.map((p) => p.toJson()).toList();

      // Get sensor data if samples were collected
      // Check if sensor buffer has any samples - this indicates sensors were used
      List<Map<String, dynamic>>? sensorSamples;
      if (sensorState.sampleBuffer.isNotEmpty) {
        sensorSamples = ref.read(sensorProvider.notifier).getSamplesForBackend();
        print('[AnalyticsPage] 📡 Sensor data available: ${sensorSamples.length} samples');
      } else {
        print('[AnalyticsPage] 📡 No sensor data available (sensor not used during recording)');
      }

      print('[AnalyticsPage] 🚀 Submitting analysis...');
      print('[AnalyticsPage] 📹 Video: ${widget.videoPath}');
      print('[AnalyticsPage] 📊 Inference points: ${inferencePointsJson.length}');
      print('[AnalyticsPage] ⏱️ Video duration: ${widget.videoDurationMs}ms, FPS: ${widget.fps}');

      // Hardcode joint index to 0 (Left Knee) for now as per requirement
      // This will be moved to user selection later
      const jointIndex = 0;

      final response = await _analyticsService.submitAnalysis(
        videoPath: widget.videoPath,
        inferencePoints: inferencePointsJson,
        videoStartTimeUtc: videoStartTimeUtc,
        fps: widget.fps,
        videoDurationMs: widget.videoDurationMs,
        sensorSamples: sensorSamples,
        datasetName: 'flutter_recording_${DateTime.now().millisecondsSinceEpoch}',
        modelId: '1OZUO0uahYoua8SklFmr',
        jointIndex: jointIndex,
      );

      setState(() {
        _isSubmitting = false;
        _hasSubmitted = true;
        _response = response;
        if (!response.success) {
          _errorMessage = response.errorMessage;
        } else {
          // Store raw angles and joint index
          _rawAngles = response.rawAngles;
          _usedJointIndex = response.jointIndex;
        }
      });

      if (response.success) {
        print('[AnalyticsPage] ✅ Analysis submitted successfully');

        // Save to local database
        await _saveToDatabase(response, videoStartTimeUtc);
      } else {
        print('[AnalyticsPage] ❌ Analysis failed: ${response.errorMessage}');
      }
    } catch (e) {
      print('[AnalyticsPage] ❌ Error submitting analysis: $e');
      setState(() {
        _isSubmitting = false;
        _hasSubmitted = true;
        _errorMessage = e.toString();
      });
    }
  }

  /// Save the analysis results to local SQLite database
  Future<void> _saveToDatabase(AnalyticsResponse response, int videoStartTimeUtc) async {
    setState(() {
      _isSavingToDb = true;
    });

    try {
      final angles = response.analyticsData['angles'] as List<dynamic>?;
      if (angles == null || angles.isEmpty) {
        print('[AnalyticsPage] ⚠️ No angles data to save');
        setState(() {
          _isSavingToDb = false;
        });
        return;
      }

      // Convert to List<List<dynamic>> for the provider
      final anglesList = angles.map((e) => e as List<dynamic>).toList();

      // Save session using the provider (including anomalous frame IDs)
      final sessionId = await ref
          .read(sessionHistoryProvider.notifier)
          .saveSession(
            timestampUtc: videoStartTimeUtc,
            angles: anglesList,
            originalVideoPath: widget.videoPath,
            processedVideoPath: response.processedVideoPath,
            durationMs: widget.videoDurationMs,
            fps: widget.fps,
            anomalousFrameIds: response.anomalousIds,
          );

      if (sessionId != null) {
        // Load the stats for display
        await ref.read(sessionHistoryProvider.notifier).selectSession(sessionId);
        final historyState = ref.read(sessionHistoryProvider);

        setState(() {
          _savedSessionId = sessionId;
          _sessionStats = historyState.selectedSessionStats;
          _sessionAngles = historyState.selectedSessionAngles;
          _anomalousFrameIds = response.anomalousIds;
          _isSavingToDb = false;
        });

        // Initialize video player with processed video if available
        if (response.processedVideoPath != null) {
          await _initializeVideo(response.processedVideoPath!);
        }

        print(
          '[AnalyticsPage] 💾 Session saved with ID: $sessionId, ${_sessionAngles?.length ?? 0} frames, ${_anomalousFrameIds.length} anomalous',
        );
      } else {
        setState(() {
          _isSavingToDb = false;
        });
      }
    } catch (e) {
      print('[AnalyticsPage] ❌ Error saving to database: $e');
      setState(() {
        _isSavingToDb = false;
      });
    }
  }

  /// Get the max angle value for display
  String _getAngleValue(String angleType) {
    if (_sessionStats == null) return '--°';

    final stat = _sessionStats!.where((s) => s.angleName == angleType).firstOrNull;
    if (stat == null) return '--°';

    return '${stat.max?.toStringAsFixed(1) ?? '--'}°';
  }

  /// Get the min-avg range for subtitle
  String _getAngleRange(String angleType) {
    if (_sessionStats == null) return '';

    final stat = _sessionStats!.where((s) => s.angleName == angleType).firstOrNull;
    if (stat == null) return '';

    return 'Min: ${stat.min?.toStringAsFixed(1) ?? '--'}° • Avg: ${stat.avg?.toStringAsFixed(1) ?? '--'}°';
  }

  /// Get chart data points for a specific angle type, filtering out anomalous frames
  List<FlSpot> _getChartData(String angleColumn) {
    if (_sessionAngles == null || _sessionAngles!.isEmpty) {
      return [];
    }

    final spots = <FlSpot>[];
    for (final angle in _sessionAngles!) {
      // Skip anomalous frames
      if (_anomalousFrameIds.contains(angle.frameIndex)) {
        continue;
      }

      double? value;
      switch (angleColumn) {
        case 'left_knee_flexion':
          value = angle.leftKneeFlexion;
          break;
        case 'right_knee_flexion':
          value = angle.rightKneeFlexion;
          break;
        case 'left_hip_flexion':
          value = angle.leftHipFlexion;
          break;
        case 'right_hip_flexion':
          value = angle.rightHipFlexion;
          break;
        case 'left_ankle_flexion':
          value = angle.leftAnkleFlexion;
          break;
        case 'right_ankle_flexion':
          value = angle.rightAnkleFlexion;
          break;
      }

      if (value != null) {
        spots.add(FlSpot(angle.frameIndex.toDouble(), value));
      }
    }

    return spots;
  }

  /// Get Y-axis bounds for a specific angle type
  (double min, double max) _getAngleBounds(String angleType) {
    if (_sessionStats == null) return (0, 180);

    final stat = _sessionStats!.where((s) => s.angleName == angleType).firstOrNull;
    if (stat == null || stat.min == null || stat.max == null) return (0, 180);

    // Add some padding to the bounds
    final padding = (stat.max! - stat.min!) * 0.1;
    return ((stat.min! - padding).clamp(0, 180), (stat.max! + padding).clamp(0, 180));
  }

  /// Build tips list from overshoot inference results
  List<Widget> _buildTipsFromOvershoot(FrameAnalysisState frameAnalysis) {
    final inferencePoints = frameAnalysis.sortedPoints;

    // If no inference results, show placeholder
    if (inferencePoints.isEmpty) {
      return [
        _FeedbackItem(icon: Icons.info_outline, text: 'No real-time analysis data available', color: Colors.grey),
        const SizedBox(height: 8),
        _FeedbackItem(
          icon: Icons.lightbulb_outline,
          text: 'Record with a stable connection for AI tips',
          color: Colors.amber,
        ),
      ];
    }

    // Extract unique tips from inference results
    final uniqueTips = <String>{};
    for (final point in inferencePoints) {
      final result = point.inferenceResult.trim();
      if (result.isNotEmpty && !result.startsWith('Error:')) {
        uniqueTips.add(result);
      }
    }

    // If no valid tips after filtering
    if (uniqueTips.isEmpty) {
      return [
        _FeedbackItem(
          icon: Icons.check_circle_outline,
          text: 'Analysis complete - no issues detected',
          color: Colors.green,
        ),
      ];
    }

    // Build tip widgets (limit to 5 most recent unique tips)
    final tipsList = uniqueTips.toList();
    final displayTips = tipsList.length > 5 ? tipsList.sublist(tipsList.length - 5) : tipsList;

    final widgets = <Widget>[];
    for (int i = 0; i < displayTips.length; i++) {
      widgets.add(_FeedbackItem(icon: Icons.lightbulb_outline, text: displayTips[i], color: Colors.amber));
      if (i < displayTips.length - 1) {
        widgets.add(const SizedBox(height: 8));
      }
    }

    // Add summary at the top if multiple tips
    if (uniqueTips.length > 1) {
      widgets.insert(
        0,
        _FeedbackItem(icon: Icons.auto_awesome, text: '${uniqueTips.length} tips from AI analysis', color: Colors.teal),
      );
      widgets.insert(1, const SizedBox(height: 8));
    }

    return widgets;
  }

  /// Build video preview widget with actual video player or placeholder
  Widget _buildVideoPreview() {
    // Show loading state while submitting
    if (_isSubmitting) {
      return Container(
        width: double.infinity,
        height: 200,
        decoration: BoxDecoration(
          color: AppColors.primaryDark,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 10, offset: const Offset(0, 4))],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(color: Colors.white),
            const SizedBox(height: 16),
            Text('Processing video...', style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 14)),
          ],
        ),
      );
    }

    // Show video player if initialized
    if (_isVideoInitialized && _videoController != null) {
      return Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: AppColors.primaryDark,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 10, offset: const Offset(0, 4))],
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            // Video player
            AspectRatio(aspectRatio: _videoController!.value.aspectRatio, child: VideoPlayer(_videoController!)),
            // Controls
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              color: AppColors.primaryDark,
              child: Row(
                children: [
                  // Play/Pause button
                  IconButton(
                    onPressed: _togglePlayPause,
                    icon: Icon(
                      _isVideoPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled,
                      color: Colors.white,
                      size: 36,
                    ),
                  ),
                  const SizedBox(width: 12),
                  // Progress indicator
                  Expanded(
                    child: VideoProgressIndicator(
                      _videoController!,
                      allowScrubbing: true,
                      colors: VideoProgressColors(
                        playedColor: AppColors.accent,
                        bufferedColor: Colors.white.withOpacity(0.3),
                        backgroundColor: Colors.white.withOpacity(0.1),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  // Duration
                  Text(
                    _formatDuration(_videoController!.value.duration),
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    // Show placeholder if no video
    return Container(
      width: double.infinity,
      height: 200,
      decoration: BoxDecoration(
        color: AppColors.primaryDark,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 10, offset: const Offset(0, 4))],
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            _hasSubmitted && _response?.success == true ? Icons.videocam_off : Icons.play_circle_outline,
            size: 56,
            color: Colors.white.withOpacity(0.4),
          ),
          const SizedBox(height: 12),
          Text(
            _hasSubmitted && _response?.success == true ? 'Processed video not available' : 'Video will appear here',
            style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 16),
          ),
        ],
      ),
    );
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final navState = ref.watch(navigationProvider);
    final projectName = navState.selectedProject?.name ?? 'Exercise';
    final frameAnalysis = ref.watch(frameAnalysisProvider);
    final sensorState = ref.watch(sensorProvider);
    final hasAnalysisData = frameAnalysis.inferencePoints.isNotEmpty;
    final hasSensorData = sensorState.sampleBuffer.isNotEmpty;
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Analysis Results'),
        actions: [
          // Developer Info Button
          if (_hasSubmitted && _response?.success == true)
            IconButton(
              icon: const Icon(Icons.developer_mode),
              tooltip: 'Developer Info',
              onPressed: () => _showDeveloperInfoDialog(context),
            ),
        ],
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () {
            // Navigate back to home and clear the stack
            Navigator.pushAndRemoveUntil(
              context,
              MaterialPageRoute(builder: (_) => const HomePage()),
              (route) => false,
            );
          },
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Session Header
              if (_sessionTimestamp != null) ...[
                Text(
                  'Your results from ${_sessionTimestamp!.day}/${_sessionTimestamp!.month}/${_sessionTimestamp!.year} at ${_sessionTimestamp!.hour.toString().padLeft(2, '0')}:${_sessionTimestamp!.minute.toString().padLeft(2, '0')}',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: AppColors.textSecondary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (_savedSessionId != null)
                  Text(
                    'Session #$_savedSessionId',
                    style: theme.textTheme.bodySmall?.copyWith(color: AppColors.textLight),
                  ),
                const SizedBox(height: 16),
              ],

              // Backend Submission Status
              _buildSubmissionStatus(hasSensorData),
              const SizedBox(height: 24),

              // Processed Video Preview
              Text('Processed Recording', style: theme.textTheme.headlineSmall),
              const SizedBox(height: 12),
              _buildVideoPreview(),
              const SizedBox(height: 28),

              // Flexion Metrics
              Row(
                children: [
                  Text('Flexion Analysis', style: theme.textTheme.headlineSmall),
                  const Spacer(),
                  if (_isSavingToDb)
                    const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary),
                    )
                  else if (_sessionStats != null)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: AppColors.success.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.check_circle, size: 14, color: AppColors.success),
                          SizedBox(width: 4),
                          Text(
                            'Saved',
                            style: TextStyle(fontSize: 12, color: AppColors.success, fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              // Left Knee Chart
              _AngleChartCard(
                icon: Icons.accessibility_new,
                title: 'Left Knee Flexion',
                value: _getAngleValue('left_knee_flexion'),
                subtitle: _getAngleRange('left_knee_flexion'),
                color: AppColors.kneeColor,
                chartData: _getChartData('left_knee_flexion'),
                yBounds: _getAngleBounds('left_knee_flexion'),
              ),
              const SizedBox(height: 12),
              // Right Knee Chart
              _AngleChartCard(
                icon: Icons.accessibility_new,
                title: 'Right Knee Flexion',
                value: _getAngleValue('right_knee_flexion'),
                subtitle: _getAngleRange('right_knee_flexion'),
                color: AppColors.kneeColor,
                chartData: _getChartData('right_knee_flexion'),
                yBounds: _getAngleBounds('right_knee_flexion'),
              ),
              const SizedBox(height: 12),
              // Left Hip Chart
              _AngleChartCard(
                icon: Icons.airline_seat_legroom_normal,
                title: 'Left Hip Flexion',
                value: _getAngleValue('left_hip_flexion'),
                subtitle: _getAngleRange('left_hip_flexion'),
                color: AppColors.hipColor,
                chartData: _getChartData('left_hip_flexion'),
                yBounds: _getAngleBounds('left_hip_flexion'),
              ),
              const SizedBox(height: 12),
              // Right Hip Chart
              _AngleChartCard(
                icon: Icons.airline_seat_legroom_normal,
                title: 'Right Hip Flexion',
                value: _getAngleValue('right_hip_flexion'),
                subtitle: _getAngleRange('right_hip_flexion'),
                color: AppColors.hipColor,
                chartData: _getChartData('right_hip_flexion'),
                yBounds: _getAngleBounds('right_hip_flexion'),
              ),
              const SizedBox(height: 12),
              // Left Ankle Chart
              _AngleChartCard(
                icon: Icons.directions_walk,
                title: 'Left Ankle Flexion',
                value: _getAngleValue('left_ankle_flexion'),
                subtitle: _getAngleRange('left_ankle_flexion'),
                color: AppColors.ankleColor,
                chartData: _getChartData('left_ankle_flexion'),
                yBounds: _getAngleBounds('left_ankle_flexion'),
              ),
              const SizedBox(height: 12),
              // Right Ankle Chart
              _AngleChartCard(
                icon: Icons.directions_walk,
                title: 'Right Ankle Flexion',
                value: _getAngleValue('right_ankle_flexion'),
                subtitle: _getAngleRange('right_ankle_flexion'),
                color: AppColors.ankleColor,
                chartData: _getChartData('right_ankle_flexion'),
                yBounds: _getAngleBounds('right_ankle_flexion'),
              ),
              const SizedBox(height: 28),

              // Chart Placeholder
              Text('Progress Over Time', style: theme.textTheme.headlineSmall),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                height: 200,
                decoration: BoxDecoration(
                  color: AppColors.cardBackground,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(color: AppColors.primary.withOpacity(0.06), blurRadius: 16, offset: const Offset(0, 4)),
                  ],
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.show_chart, size: 48, color: AppColors.textLight),
                    const SizedBox(height: 12),
                    Text('Chart Placeholder', style: theme.textTheme.bodyMedium),
                    const SizedBox(height: 4),
                    Text('Progress visualization coming soon', style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
              const SizedBox(height: 28),

              // Feedback Section
              Text('Recommendations', style: theme.textTheme.headlineSmall),
              const SizedBox(height: 12),
              _FeedbackItem(icon: Icons.info_outline, text: 'AI feedback will appear here', color: AppColors.info),
              const SizedBox(height: 8),
              _FeedbackItem(
                icon: Icons.lightbulb_outline,
                text: 'Tips for improvement coming soon',
                color: AppColors.warning,
              ),
              const SizedBox(height: 32),

              // Action Buttons
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: const Text('Share feature - coming soon!'),
                            backgroundColor: AppColors.primary,
                            behavior: SnackBarBehavior.floating,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                        );
                      },
                      icon: const Icon(Icons.share),
                      label: const Text('Share'),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () {
                        Navigator.pushAndRemoveUntil(
                          context,
                          MaterialPageRoute(builder: (_) => const HomePage()),
                          (route) => false,
                        );
                      },
                      icon: const Icon(Icons.home),
                      label: const Text('Home'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSubmissionStatus(bool hasSensorData) {
    final theme = Theme.of(context);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.cardBackground,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: AppColors.primary.withOpacity(0.06), blurRadius: 16, offset: const Offset(0, 4))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: _isSubmitting
                      ? AppColors.info.withOpacity(0.1)
                      : _errorMessage != null
                      ? AppColors.error.withOpacity(0.1)
                      : AppColors.success.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  _isSubmitting
                      ? Icons.cloud_upload_outlined
                      : _errorMessage != null
                      ? Icons.error_outline
                      : Icons.cloud_done_outlined,
                  color: _isSubmitting
                      ? AppColors.info
                      : _errorMessage != null
                      ? AppColors.error
                      : AppColors.success,
                  size: 24,
                ),
              ),
              const SizedBox(width: 12),
              Text('Backend Analysis', style: theme.textTheme.titleLarge),
            ],
          ),
          const SizedBox(height: 16),

          // Status message
          if (_isSubmitting) ...[
            Row(
              children: [
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(AppColors.info),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(child: Text('Uploading video and data for analysis...', style: theme.textTheme.bodyMedium)),
              ],
            ),
          ] else if (_errorMessage != null) ...[
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.error.withOpacity(0.08),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.error.withOpacity(0.2)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Analysis failed',
                    style: theme.textTheme.titleMedium?.copyWith(color: AppColors.error, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(_errorMessage!, style: theme.textTheme.bodySmall?.copyWith(color: AppColors.error)),
                  const SizedBox(height: 10),
                  TextButton.icon(
                    onPressed: _submitAnalysis,
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('Retry'),
                    style: TextButton.styleFrom(foregroundColor: AppColors.error, padding: EdgeInsets.zero),
                  ),
                ],
              ),
            ),
          ] else if (_hasSubmitted && _response != null) ...[
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.success.withOpacity(0.08),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.success.withOpacity(0.2)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.check_circle, color: AppColors.success, size: 22),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Analysis submitted successfully',
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: AppColors.success,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],

          const SizedBox(height: 16),

          // Data summary
          Row(
            children: [
              _DataChip(icon: Icons.videocam, label: 'Video', isAvailable: true),
              const SizedBox(width: 8),
              _DataChip(
                icon: Icons.auto_fix_high,
                label: 'Overshoot',
                isAvailable: ref.read(frameAnalysisProvider).inferencePoints.isNotEmpty,
              ),
              const SizedBox(width: 8),
              _DataChip(icon: Icons.sensors, label: 'IMU', isAvailable: hasSensorData),
            ],
          ),
        ],
      ),
    );
  }
}

class _DataChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isAvailable;

  const _DataChip({required this.icon, required this.label, required this.isAvailable});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: isAvailable ? AppColors.primary.withOpacity(0.08) : AppColors.textLight.withOpacity(0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isAvailable ? AppColors.primary.withOpacity(0.2) : AppColors.textLight.withOpacity(0.3),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: isAvailable ? AppColors.primary : AppColors.textLight),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: isAvailable ? AppColors.primary : AppColors.textLight,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(width: 4),
          Icon(
            isAvailable ? Icons.check_circle : Icons.cancel,
            size: 12,
            color: isAvailable ? AppColors.success : AppColors.textLight,
          ),
        ],
      ),
    );
  }
}

class _MetricCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String value;
  final String? subtitle;
  final Color color;

  const _MetricCard({required this.icon, required this.title, required this.value, required this.color, this.subtitle});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.cardBackground,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: color.withOpacity(0.1), blurRadius: 16, offset: const Offset(0, 4))],
        border: Border.all(color: color.withOpacity(0.15)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: color.withOpacity(0.1), borderRadius: BorderRadius.circular(10)),
            child: Icon(icon, color: color, size: 24),
          ),
          const SizedBox(height: 14),
          Text(
            value,
            style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold, color: AppColors.textPrimary),
          ),
          const SizedBox(height: 4),
          Text(title, style: theme.textTheme.bodyMedium),
          if (subtitle != null && subtitle!.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(subtitle!, style: theme.textTheme.bodySmall),
          ],
        ],
      ),
    );
  }
}

/// Chart card widget that displays angle data over frames
class _AngleChartCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String value;
  final String? subtitle;
  final Color color;
  final List<FlSpot> chartData;
  final (double min, double max) yBounds;

  const _AngleChartCard({
    required this.icon,
    required this.title,
    required this.value,
    this.subtitle,
    required this.color,
    required this.chartData,
    required this.yBounds,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasData = chartData.isNotEmpty;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.cardBackground,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: color.withOpacity(0.1), blurRadius: 16, offset: const Offset(0, 4))],
        border: Border.all(color: color.withOpacity(0.15)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row with icon and stats
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: color.withOpacity(0.1), borderRadius: BorderRadius.circular(10)),
                child: Icon(icon, color: color, size: 24),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                    if (subtitle != null && subtitle!.isNotEmpty)
                      Text(subtitle!, style: theme.textTheme.bodySmall?.copyWith(color: AppColors.textSecondary)),
                  ],
                ),
              ),
              Text(
                value,
                style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold, color: color),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // Chart
          SizedBox(
            height: 120,
            child: hasData
                ? LineChart(
                    LineChartData(
                      gridData: FlGridData(
                        show: true,
                        drawVerticalLine: false,
                        horizontalInterval: (yBounds.$2 - yBounds.$1) / 4,
                        getDrawingHorizontalLine: (value) =>
                            FlLine(color: AppColors.textLight.withOpacity(0.2), strokeWidth: 1),
                      ),
                      titlesData: FlTitlesData(
                        leftTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 40,
                            interval: (yBounds.$2 - yBounds.$1) / 4,
                            getTitlesWidget: (value, meta) {
                              return Text(
                                '${value.toInt()}°',
                                style: TextStyle(color: AppColors.textLight, fontSize: 10),
                              );
                            },
                          ),
                        ),
                        bottomTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 22,
                            interval: chartData.length > 10 ? (chartData.last.x / 5).roundToDouble() : null,
                            getTitlesWidget: (value, meta) {
                              return Text(
                                '${value.toInt()}',
                                style: TextStyle(color: AppColors.textLight, fontSize: 10),
                              );
                            },
                          ),
                        ),
                        topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                        rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                      ),
                      borderData: FlBorderData(show: false),
                      minY: yBounds.$1,
                      maxY: yBounds.$2,
                      lineBarsData: [
                        LineChartBarData(
                          spots: chartData,
                          isCurved: true,
                          curveSmoothness: 0.3,
                          color: color,
                          barWidth: 2,
                          isStrokeCapRound: true,
                          dotData: const FlDotData(show: false),
                          belowBarData: BarAreaData(show: true, color: color.withOpacity(0.1)),
                        ),
                      ],
                      lineTouchData: LineTouchData(
                        touchTooltipData: LineTouchTooltipData(
                          getTooltipItems: (touchedSpots) {
                            return touchedSpots.map((spot) {
                              return LineTooltipItem(
                                'Frame ${spot.x.toInt()}\n${spot.y.toStringAsFixed(1)}°',
                                TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 12),
                              );
                            }).toList();
                          },
                        ),
                      ),
                    ),
                  )
                : Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.show_chart, color: AppColors.textLight, size: 32),
                        const SizedBox(height: 8),
                        Text(
                          'No data available',
                          style: theme.textTheme.bodySmall?.copyWith(color: AppColors.textLight),
                        ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
    void _showDeveloperInfoDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Developer Info'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Comparison: Raw CV vs Fused (CV+IMU)',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  height: 300,
                  child: _buildComparisonChart(),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Legend:',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    _LegendItem(color: Colors.blue, label: 'Freq Filtered (Final)'),
                    const SizedBox(width: 16),
                    _LegendItem(color: Colors.red.withOpacity(0.5), label: 'Raw CV'),
                    const SizedBox(width: 16),
                    _LegendItem(color: Colors.green.withOpacity(0.5), label: 'Raw IMU'),
                  ],
                ),
                if (_usedJointIndex != null) ...[
                  const SizedBox(height: 16),
                  Text('Joint Index Used: $_usedJointIndex'),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _buildComparisonChart() {
    if (_sessionAngles == null || _sessionAngles!.isEmpty) {
      return const Center(child: Text('No data available'));
    }

    final rawSpots = <FlSpot>[];
    final fusedSpots = <FlSpot>[];
    final imuSpots = <FlSpot>[];

    // Determine which field to use based on joint index (default to left knee if null)
    // 0: leftKnee, 1: rightKnee, etc.
    // Sync with rtmpose3d_handler.py
    final jointIndex = _usedJointIndex ?? 0;

    for (int i = 0; i < _sessionAngles!.length; i++) {
      final angle = _sessionAngles![i];
      
      // Get fused value
      double? fusedVal;
      switch (jointIndex) {
        case 0: fusedVal = angle.leftKneeFlexion; break;
        case 1: fusedVal = angle.rightKneeFlexion; break;
        // Add others if needed
        default: fusedVal = angle.leftKneeFlexion;
      }

      if (fusedVal != null) {
        fusedSpots.add(FlSpot(i.toDouble(), fusedVal));
      }

      // Get raw value if available
      if (_rawAngles != null && i < _rawAngles!.length) {
        final rawFrame = _rawAngles![i];
        if (rawFrame.length > jointIndex) {
          final rawVal = rawFrame[jointIndex] as num?;
          if (rawVal != null) {
            rawSpots.add(FlSpot(i.toDouble(), rawVal.toDouble()));
          }
        }
      }

      // Get IMU value if available
      if (_imuAngles != null && i < _imuAngles!.length) {
        final imuFrame = _imuAngles![i];
        if (imuFrame.length > jointIndex) {
          final imuVal = imuFrame[jointIndex] as num?;
          if (imuVal != null) {
            imuSpots.add(FlSpot(i.toDouble(), imuVal.toDouble()));
          }
        }
      }
    }

    return LineChart(
      LineChartData(
        gridData: FlGridData(
          show: true,
          drawVerticalLine: true,
          getDrawingHorizontalLine: (value) => FlLine(color: Colors.grey.withOpacity(0.2), strokeWidth: 1),
          getDrawingVerticalLine: (value) => FlLine(color: Colors.grey.withOpacity(0.2), strokeWidth: 1),
        ),
        titlesData: FlTitlesData(
          show: true,
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 22,
              getTitlesWidget: (value, meta) {
                if (value % 30 == 0) return Text(value.toInt().toString(), style: const TextStyle(fontSize: 10));
                return const SizedBox();
              },
            ),
          ),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 30,
              getTitlesWidget: (value, meta) {
                return Text(value.toInt().toString(), style: const TextStyle(fontSize: 10));
              },
            ),
          ),
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
        borderData: FlBorderData(show: true, border: Border.all(color: const Color(0xff37434d), width: 1)),
        minX: 0,
        maxX: _sessionAngles!.length.toDouble(),
        minY: 0,
        maxY: 180,
        lineBarsData: [
          // Raw CV Data (Red, slightly transparent)
          LineChartBarData(
            spots: rawSpots,
            isCurved: false,
            color: Colors.red.withOpacity(0.5),
            barWidth: 2,
            isStrokeCapRound: true,
            dotData: const FlDotData(show: false),
          ),
          // Raw IMU Data (Green, slightly transparent)
          LineChartBarData(
            spots: imuSpots,
            isCurved: false,
            color: Colors.green.withOpacity(0.5),
            barWidth: 2,
            isStrokeCapRound: true,
            dotData: const FlDotData(show: false),
          ),
          // Fused Data (Blue, main)
          LineChartBarData(
            spots: fusedSpots,
            isCurved: false,
            color: Colors.blue,
            barWidth: 2,
            isStrokeCapRound: true,
            dotData: const FlDotData(show: false),
          ),
        ],
      ),
    );
  }

class _FeedbackItem extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color color;

  const _FeedbackItem({required this.icon, required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.2)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(width: 14),
          Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}

class _LegendItem extends StatelessWidget {
  final Color color;
  final String label;

  const _LegendItem({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 12),
        ),
      ],
    );
  }
}
