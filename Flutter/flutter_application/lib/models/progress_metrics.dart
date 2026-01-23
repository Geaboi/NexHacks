/// Configuration for how to measure progress for each joint type.
///
/// This model encapsulates the clinical knowledge about what "good" means
/// for each joint measurement. It's designed to be easily modifiable as
/// requirements change or as sensor/video data integration is added.
///
/// For squat/knee exercises:
/// - Knee flexion: Lower angle = deeper bend = better
/// - Hip flexion: Lower angle = deeper hinge = better
/// - Ankle flexion: Lower angle = better dorsiflexion = better
class JointProgressConfig {
  /// Database column name (e.g., 'left_knee_flexion')
  final String angleColumn;

  /// Display name (e.g., 'Left Knee Flexion')
  final String displayName;

  /// Short name for compact UI (e.g., 'L. Knee')
  final String shortName;

  /// Whether lower angle values indicate better progress.
  /// true = use 10th percentile (lower/deeper is better for squats)
  /// false = use 90th percentile (higher is better)
  final bool lowerIsBetter;

  /// Percentile to use for progress tracking (0.0 - 1.0)
  /// Default: 0.1 for lowerIsBetter=true (tracks minimum angles achieved)
  double get progressPercentile => lowerIsBetter ? 0.1 : 0.9;

  /// Normal range minimum (degrees) for reference
  final double normalRangeMin;

  /// Normal range maximum (degrees) for reference
  final double normalRangeMax;

  /// Goal description for UI
  final String goalDescription;

  const JointProgressConfig({
    required this.angleColumn,
    required this.displayName,
    required this.shortName,
    this.lowerIsBetter = true, // Default: lower angle = better (deeper movement)
    required this.normalRangeMin,
    required this.normalRangeMax,
    required this.goalDescription,
  });

  /// All joint configurations with clinical defaults.
  /// For squat/knee exercises, lower angles indicate deeper movement:
  /// - Knee flexion: Lower angle = deeper squat (e.g., 60° is better than 90°)
  /// - Hip flexion: Lower angle = deeper hip hinge
  /// - Ankle dorsiflexion: Lower angle = better ankle mobility for squats
  static const List<JointProgressConfig> allJoints = [
    JointProgressConfig(
      angleColumn: 'left_knee_flexion',
      displayName: 'Left Knee',
      shortName: 'L. Knee',
      lowerIsBetter: true, // Lower angle = deeper squat
      normalRangeMin: 60, // Deep squat
      normalRangeMax: 140, // Standing/slight bend
      goalDescription: 'Lower angle = deeper squat',
    ),
    JointProgressConfig(
      angleColumn: 'right_knee_flexion',
      displayName: 'Right Knee',
      shortName: 'R. Knee',
      lowerIsBetter: true,
      normalRangeMin: 60,
      normalRangeMax: 140,
      goalDescription: 'Lower angle = deeper squat',
    ),
    JointProgressConfig(
      angleColumn: 'left_hip_flexion',
      displayName: 'Left Hip',
      shortName: 'L. Hip',
      lowerIsBetter: true, // Lower angle = deeper hip hinge
      normalRangeMin: 40,
      normalRangeMax: 160,
      goalDescription: 'Lower angle = deeper hinge',
    ),
    JointProgressConfig(
      angleColumn: 'right_hip_flexion',
      displayName: 'Right Hip',
      shortName: 'R. Hip',
      lowerIsBetter: true,
      normalRangeMin: 40,
      normalRangeMax: 160,
      goalDescription: 'Lower angle = deeper hinge',
    ),
    JointProgressConfig(
      angleColumn: 'left_ankle_flexion',
      displayName: 'Left Ankle',
      shortName: 'L. Ankle',
      lowerIsBetter: true, // Lower angle = better dorsiflexion
      normalRangeMin: 70,
      normalRangeMax: 110,
      goalDescription: 'Lower angle = better mobility',
    ),
    JointProgressConfig(
      angleColumn: 'right_ankle_flexion',
      displayName: 'Right Ankle',
      shortName: 'R. Ankle',
      lowerIsBetter: true,
      normalRangeMin: 70,
      normalRangeMax: 110,
      goalDescription: 'Lower angle = better mobility',
    ),
  ];

  /// Get config by column name
  static JointProgressConfig? getByColumn(String angleColumn) {
    return allJoints.where((j) => j.angleColumn == angleColumn).firstOrNull;
  }

  /// Get config by index (matches FrameAngle.angleColumns order)
  static JointProgressConfig getByIndex(int index) {
    return allJoints[index.clamp(0, allJoints.length - 1)];
  }
}

/// Represents a single progress data point for charting.
/// One point per session, showing the representative value for that session.
class ProgressDataPoint {
  /// Session ID for reference
  final int sessionId;

  /// UTC timestamp of the session (milliseconds since epoch)
  final int timestampUtc;

  /// The representative angle value for this session.
  /// Calculated as the Nth percentile based on JointProgressConfig.
  final double value;

  /// Session date as DateTime (derived from timestampUtc)
  DateTime get date => DateTime.fromMillisecondsSinceEpoch(timestampUtc, isUtc: true);

  /// Formatted date for display (local time)
  String get formattedDate {
    final local = date.toLocal();
    return '${local.month}/${local.day}';
  }

  const ProgressDataPoint({required this.sessionId, required this.timestampUtc, required this.value});

  factory ProgressDataPoint.fromMap(Map<String, dynamic> map) {
    return ProgressDataPoint(
      sessionId: map['session_id'] as int,
      timestampUtc: map['timestamp_utc'] as int,
      value: (map['percentile_value'] as num).toDouble(),
    );
  }
}

/// Complete progress data for a single joint across all sessions.
class JointProgressData {
  /// Configuration for this joint
  final JointProgressConfig config;

  /// Ordered list of data points (oldest first)
  final List<ProgressDataPoint> dataPoints;

  /// Whether there's enough data to show progress
  bool get hasData => dataPoints.length >= 2;

  /// Whether progress is improving (comparing first and last sessions)
  /// For lowerIsBetter joints: improvement = latest < first (angle decreased)
  bool get isImproving {
    if (!hasData) return false;
    final first = dataPoints.first.value;
    final last = dataPoints.last.value;
    return config.lowerIsBetter ? last < first : last > first;
  }

  /// Absolute change from first to last session (in degrees)
  double get absoluteChange {
    if (!hasData) return 0;
    return dataPoints.last.value - dataPoints.first.value;
  }

  /// Percentage change from first to last session
  /// For lowerIsBetter: negative raw change means improvement, so we flip the sign
  double get percentageChange {
    if (!hasData) return 0;
    final first = dataPoints.first.value;
    final last = dataPoints.last.value;
    if (first == 0) return 0;
    final rawChange = ((last - first) / first.abs()) * 100;
    // Flip sign for lowerIsBetter so positive always means improvement
    return config.lowerIsBetter ? -rawChange : rawChange;
  }

  /// Latest value
  double? get latestValue => dataPoints.isNotEmpty ? dataPoints.last.value : null;

  /// First recorded value
  double? get firstValue => dataPoints.isNotEmpty ? dataPoints.first.value : null;

  const JointProgressData({required this.config, required this.dataPoints});
}
