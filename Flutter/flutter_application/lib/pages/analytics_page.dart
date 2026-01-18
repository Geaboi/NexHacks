import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
  int? _savedSessionId;

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

  Future<void> _submitAnalysis() async {
    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
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
      Map<String, dynamic>? sensorData;
      if (sensorState.sampleBuffer.isNotEmpty) {
        sensorData = ref.read(sensorProvider.notifier).getSamplesAsMap();
        print('[AnalyticsPage] 📡 Sensor data available: ${sensorData['total_samples']} samples');
      } else {
        print('[AnalyticsPage] 📡 No sensor data available (sensor not used during recording)');
      }

      print('[AnalyticsPage] 🚀 Submitting analysis...');
      print('[AnalyticsPage] 📹 Video: ${widget.videoPath}');
      print('[AnalyticsPage] 📊 Inference points: ${inferencePointsJson.length}');
      print('[AnalyticsPage] ⏱️ Video duration: ${widget.videoDurationMs}ms, FPS: ${widget.fps}');

      
      final response = await _analyticsService.submitAnalysis(
        videoPath: widget.videoPath,
        inferencePoints: inferencePointsJson,
        videoStartTimeUtc: videoStartTimeUtc,
        fps: widget.fps,
        videoDurationMs: widget.videoDurationMs,
        sensorData: sensorData,
        datasetName: 'flutter_recording_${DateTime.now().millisecondsSinceEpoch}',
        modelId: '1OZUO0uahYoua8SklFmr',
      );

      setState(() {
        _isSubmitting = false;
        _hasSubmitted = true;
        _response = response;
        if (!response.success) {
          _errorMessage = response.errorMessage;
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

      // Save session using the provider
      final sessionId = await ref.read(sessionHistoryProvider.notifier).saveSession(
        timestampUtc: videoStartTimeUtc,
        angles: anglesList,
        originalVideoPath: widget.videoPath,
        processedVideoPath: response.processedVideoPath,
        durationMs: widget.videoDurationMs,
        fps: widget.fps,
      );

      if (sessionId != null) {
        // Load the stats for display
        await ref.read(sessionHistoryProvider.notifier).selectSession(sessionId);
        final historyState = ref.read(sessionHistoryProvider);
        
        setState(() {
          _savedSessionId = sessionId;
          _sessionStats = historyState.selectedSessionStats;
          _isSavingToDb = false;
        });
        
        print('[AnalyticsPage] 💾 Session saved with ID: $sessionId');
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

  /// Build tips list from overshoot inference results
  List<Widget> _buildTipsFromOvershoot(FrameAnalysisState frameAnalysis) {
    final inferencePoints = frameAnalysis.sortedPoints;

    // If no inference results, show placeholder
    if (inferencePoints.isEmpty) {
      return [
        _FeedbackItem(
          icon: Icons.info_outline,
          text: 'No real-time analysis data available',
          color: Colors.grey,
        ),
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
      widgets.add(
        _FeedbackItem(
          icon: Icons.lightbulb_outline,
          text: displayTips[i],
          color: Colors.amber,
        ),
      );
      if (i < displayTips.length - 1) {
        widgets.add(const SizedBox(height: 8));
      }
    }

    // Add summary at the top if multiple tips
    if (uniqueTips.length > 1) {
      widgets.insert(
        0,
        _FeedbackItem(
          icon: Icons.auto_awesome,
          text: '${uniqueTips.length} tips from AI analysis',
          color: Colors.teal,
        ),
      );
      widgets.insert(1, const SizedBox(height: 8));
    }

    return widgets;
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
              // Success Header
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(28),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [AppColors.primary, AppColors.primaryLight],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.primary.withOpacity(0.3),
                      blurRadius: 20,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.2),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.check_circle_outline,
                        color: Colors.white,
                        size: 48,
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Recording Complete!',
                      style: TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    Text(projectName, style: TextStyle(color: Colors.white.withOpacity(0.8), fontSize: 16)),
                    if (hasAnalysisData) ...[
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          '${frameAnalysis.pointCount} analysis points captured',
                          style: TextStyle(color: Colors.white.withOpacity(0.9), fontSize: 14),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // Backend Submission Status
              _buildSubmissionStatus(hasSensorData),
              const SizedBox(height: 24),

              // Most Recent Recording Placeholder
              Text('Most Recent Recording', style: theme.textTheme.headlineSmall),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                height: 200,
                decoration: BoxDecoration(
                  color: AppColors.primaryDark,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 10, offset: const Offset(0, 4)),
                  ],
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.play_circle_outline, size: 56, color: Colors.white.withOpacity(0.4)),
                    const SizedBox(height: 12),
                    Text('Video Preview', style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 16)),
                  ],
                ),
              ),
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
              Row(
                children: [
                  Expanded(
                    child: _MetricCard(
                      icon: Icons.accessibility_new,
                      title: 'Left Knee',
                      value: _getAngleValue('left_knee_flexion'),
                      subtitle: _getAngleRange('left_knee_flexion'),
                      color: AppColors.kneeColor,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _MetricCard(
                      icon: Icons.accessibility_new,
                      title: 'Right Knee',
                      value: _getAngleValue('right_knee_flexion'),
                      subtitle: _getAngleRange('right_knee_flexion'),
                      color: AppColors.kneeColor,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _MetricCard(
                      icon: Icons.airline_seat_legroom_normal,
                      title: 'Left Hip',
                      value: _getAngleValue('left_hip_flexion'),
                      subtitle: _getAngleRange('left_hip_flexion'),
                      color: AppColors.hipColor,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _MetricCard(
                      icon: Icons.airline_seat_legroom_normal,
                      title: 'Right Hip',
                      value: _getAngleValue('right_hip_flexion'),
                      subtitle: _getAngleRange('right_hip_flexion'),
                      color: AppColors.hipColor,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _MetricCard(
                      icon: Icons.directions_walk,
                      title: 'Left Ankle',
                      value: _getAngleValue('left_ankle_flexion'),
                      subtitle: _getAngleRange('left_ankle_flexion'),
                      color: AppColors.ankleColor,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _MetricCard(
                      icon: Icons.directions_walk,
                      title: 'Right Ankle',
                      value: _getAngleValue('right_ankle_flexion'),
                      subtitle: _getAngleRange('right_ankle_flexion'),
                      color: AppColors.ankleColor,
                    ),
                  ),
                ],
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
              Text(
                'Backend Analysis',
                style: theme.textTheme.titleLarge,
              ),
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
                Expanded(
                  child: Text(
                    'Uploading video and data for analysis...',
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
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
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: AppColors.error,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _errorMessage!,
                    style: theme.textTheme.bodySmall?.copyWith(color: AppColors.error),
                  ),
                  const SizedBox(height: 10),
                  TextButton.icon(
                    onPressed: _submitAnalysis,
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('Retry'),
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.error,
                      padding: EdgeInsets.zero,
                    ),
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
          Icon(
            icon,
            size: 14,
            color: isAvailable ? AppColors.primary : AppColors.textLight,
          ),
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

  const _MetricCard({required this.icon, required this.title, required this.value, this.subtitle, required this.color});

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
            decoration: BoxDecoration(
              color: color.withOpacity(0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: color, size: 24),
          ),
          const SizedBox(height: 14),
          Text(
            value,
            style: theme.textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.bold,
              color: AppColors.textPrimary,
            ),
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
          Expanded(
            child: Text(text, style: theme.textTheme.bodyMedium),
          ),
        ],
      ),
    );
  }
}
