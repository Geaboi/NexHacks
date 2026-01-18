import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/navigation_provider.dart';
import '../providers/frame_analysis_provider.dart';
import '../providers/sensor_provider.dart';
import '../providers/session_history_provider.dart';
import '../models/frame_angle.dart';
import '../services/analytics_service.dart';
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
        modelId: 'default_model',
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

    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: const Text('Analysis Results'),
        backgroundColor: Colors.teal,
        foregroundColor: Colors.white,
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
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Success Header - different based on analysis availability
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: hasAnalysisData
                        ? [Colors.teal, Colors.teal.shade700]
                        : [Colors.orange.shade600, Colors.orange.shade800],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  children: [
                    Icon(
                      hasAnalysisData ? Icons.check_circle_outline : Icons.videocam_outlined,
                      color: Colors.white,
                      size: 48,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      hasAnalysisData ? 'Recording Complete!' : 'Recording Saved',
                      style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    Text(projectName, style: const TextStyle(color: Colors.white70, fontSize: 16)),
                    if (!hasAnalysisData) ...[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.info_outline, color: Colors.white, size: 16),
                            SizedBox(width: 6),
                            Text(
                              'Real-time analysis was unavailable',
                              style: TextStyle(color: Colors.white, fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                    ],
                    if (hasAnalysisData) ...[
                      const SizedBox(height: 8),
                      Text(
                        '${frameAnalysis.pointCount} analysis points captured',
                        style: const TextStyle(color: Colors.white70, fontSize: 14),
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
              const Text('Most Recent Recording', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                height: 200,
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 10, offset: const Offset(0, 2)),
                  ],
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.play_circle_outline, size: 48, color: Colors.grey[400]),
                    const SizedBox(height: 12),
                    Text('Video Preview', style: TextStyle(color: Colors.grey[500], fontSize: 16)),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // Flexion Metrics
              Row(
                children: [
                  const Text('Flexion Analysis', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                  const Spacer(),
                  if (_isSavingToDb)
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else if (_sessionStats != null)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.green.shade50,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.save, size: 14, color: Colors.green.shade700),
                          const SizedBox(width: 4),
                          Text(
                            'Saved',
                            style: TextStyle(fontSize: 12, color: Colors.green.shade700, fontWeight: FontWeight.w500),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _MetricCard(
                      icon: Icons.straighten,
                      title: 'Left Knee Flexion',
                      value: _getAngleValue('left_knee_flexion'),
                      subtitle: _getAngleRange('left_knee_flexion'),
                      color: Colors.blue,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _MetricCard(
                      icon: Icons.straighten,
                      title: 'Right Knee Flexion',
                      value: _getAngleValue('right_knee_flexion'),
                      subtitle: _getAngleRange('right_knee_flexion'),
                      color: Colors.blue,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _MetricCard(
                      icon: Icons.straighten,
                      title: 'Left Hip Flexion',
                      value: _getAngleValue('left_hip_flexion'),
                      subtitle: _getAngleRange('left_hip_flexion'),
                      color: Colors.purple,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _MetricCard(
                      icon: Icons.straighten,
                      title: 'Right Hip Flexion',
                      value: _getAngleValue('right_hip_flexion'),
                      subtitle: _getAngleRange('right_hip_flexion'),
                      color: Colors.purple,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _MetricCard(
                      icon: Icons.straighten,
                      title: 'Left Ankle Flexion',
                      value: _getAngleValue('left_ankle_flexion'),
                      subtitle: _getAngleRange('left_ankle_flexion'),
                      color: Colors.orange,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _MetricCard(
                      icon: Icons.straighten,
                      title: 'Right Ankle Flexion',
                      value: _getAngleValue('right_ankle_flexion'),
                      subtitle: _getAngleRange('right_ankle_flexion'),
                      color: Colors.orange,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),

              // Chart Placeholder
              const Text('Progress Over Time', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                height: 200,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10, offset: const Offset(0, 2)),
                  ],
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.show_chart, size: 48, color: Colors.grey[400]),
                    const SizedBox(height: 12),
                    Text('Chart Placeholder', style: TextStyle(color: Colors.grey[500], fontSize: 16)),
                    const SizedBox(height: 4),
                    Text('Progress visualization coming soon', style: TextStyle(color: Colors.grey[400], fontSize: 14)),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // Feedback Section - Tips from Overshoot
              const Text('Recommendations', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              ..._buildTipsFromOvershoot(frameAnalysis),
              const SizedBox(height: 32),

              // Action Buttons
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () {
                        ScaffoldMessenger.of(
                          context,
                        ).showSnackBar(const SnackBar(content: Text('Share feature - coming soon!')));
                      },
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.teal,
                        side: const BorderSide(color: Colors.teal),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
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
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.teal,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
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
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10, offset: const Offset(0, 2))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                _isSubmitting
                    ? Icons.cloud_upload_outlined
                    : _errorMessage != null
                    ? Icons.error_outline
                    : Icons.cloud_done_outlined,
                color: _isSubmitting
                    ? Colors.blue
                    : _errorMessage != null
                    ? Colors.red
                    : Colors.green,
                size: 24,
              ),
              const SizedBox(width: 12),
              Text(
                'Backend Analysis',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.grey[800]),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Status message
          if (_isSubmitting) ...[
            Row(
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.blue),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Uploading video and data for analysis...',
                    style: TextStyle(color: Colors.grey[600], fontSize: 14),
                  ),
                ),
              ],
            ),
          ] else if (_errorMessage != null) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: Colors.red.shade50, borderRadius: BorderRadius.circular(8)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Analysis failed',
                    style: TextStyle(color: Colors.red.shade700, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(_errorMessage!, style: TextStyle(color: Colors.red.shade600, fontSize: 12)),
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: _submitAnalysis,
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('Retry'),
                    style: TextButton.styleFrom(foregroundColor: Colors.red.shade700, padding: EdgeInsets.zero),
                  ),
                ],
              ),
            ),
          ] else if (_hasSubmitted && _response != null) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: Colors.green.shade50, borderRadius: BorderRadius.circular(8)),
              child: Row(
                children: [
                  Icon(Icons.check_circle, color: Colors.green.shade600, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Analysis submitted successfully',
                      style: TextStyle(color: Colors.green.shade700, fontWeight: FontWeight.w500),
                    ),
                  ),
                ],
              ),
            ),
          ],

          const SizedBox(height: 12),

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
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: isAvailable ? Colors.teal.shade50 : Colors.grey.shade100,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: isAvailable ? Colors.teal.shade200 : Colors.grey.shade300),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: isAvailable ? Colors.teal.shade700 : Colors.grey.shade500),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: isAvailable ? Colors.teal.shade700 : Colors.grey.shade500,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(width: 4),
          Icon(
            isAvailable ? Icons.check_circle : Icons.cancel,
            size: 12,
            color: isAvailable ? Colors.teal.shade600 : Colors.grey.shade400,
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
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10, offset: const Offset(0, 2))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 28),
          const SizedBox(height: 12),
          Text(value, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(title, style: TextStyle(fontSize: 14, color: Colors.grey[600])),
          if (subtitle != null && subtitle!.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(subtitle!, style: TextStyle(fontSize: 11, color: Colors.grey[500])),
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
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: color.withOpacity(0.1), borderRadius: BorderRadius.circular(8)),
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(text, style: TextStyle(color: Colors.grey[700], fontSize: 14)),
          ),
        ],
      ),
    );
  }
}
