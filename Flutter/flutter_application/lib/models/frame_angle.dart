/// Represents the 6 joint angles for a single video frame
/// 
/// Angle order matches backend:
/// - left_knee_flexion
/// - right_knee_flexion
/// - left_hip_flexion
/// - right_hip_flexion
/// - left_ankle_flexion
/// - right_ankle_flexion
class FrameAngle {
  final int? id;
  final int sessionId;
  final int frameIndex;
  final int? timestampOffsetMs; // Offset from session start
  final double? leftKneeFlexion;
  final double? rightKneeFlexion;
  final double? leftHipFlexion;
  final double? rightHipFlexion;
  final double? leftAnkleFlexion;
  final double? rightAnkleFlexion;

  const FrameAngle({
    this.id,
    required this.sessionId,
    required this.frameIndex,
    this.timestampOffsetMs,
    this.leftKneeFlexion,
    this.rightKneeFlexion,
    this.leftHipFlexion,
    this.rightHipFlexion,
    this.leftAnkleFlexion,
    this.rightAnkleFlexion,
  });

  /// Create from database row
  factory FrameAngle.fromMap(Map<String, dynamic> map) {
    return FrameAngle(
      id: map['id'] as int?,
      sessionId: map['session_id'] as int,
      frameIndex: map['frame_index'] as int,
      timestampOffsetMs: map['timestamp_offset_ms'] as int?,
      leftKneeFlexion: map['left_knee_flexion'] as double?,
      rightKneeFlexion: map['right_knee_flexion'] as double?,
      leftHipFlexion: map['left_hip_flexion'] as double?,
      rightHipFlexion: map['right_hip_flexion'] as double?,
      leftAnkleFlexion: map['left_ankle_flexion'] as double?,
      rightAnkleFlexion: map['right_ankle_flexion'] as double?,
    );
  }

  /// Create from backend angles list
  /// Backend format: angles[frameIndex] = [left_knee, right_knee, left_hip, right_hip, left_ankle, right_ankle]
  factory FrameAngle.fromBackendList({
    required int sessionId,
    required int frameIndex,
    required List<dynamic> angles,
    int? fps,
  }) {
    return FrameAngle(
      sessionId: sessionId,
      frameIndex: frameIndex,
      timestampOffsetMs: fps != null ? (frameIndex * 1000 ~/ fps) : null,
      leftKneeFlexion: angles.length > 0 ? (angles[0] as num?)?.toDouble() : null,
      rightKneeFlexion: angles.length > 1 ? (angles[1] as num?)?.toDouble() : null,
      leftHipFlexion: angles.length > 2 ? (angles[2] as num?)?.toDouble() : null,
      rightHipFlexion: angles.length > 3 ? (angles[3] as num?)?.toDouble() : null,
      leftAnkleFlexion: angles.length > 4 ? (angles[4] as num?)?.toDouble() : null,
      rightAnkleFlexion: angles.length > 5 ? (angles[5] as num?)?.toDouble() : null,
    );
  }

  /// Convert to database map for insertion
  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'session_id': sessionId,
      'frame_index': frameIndex,
      'timestamp_offset_ms': timestampOffsetMs,
      'left_knee_flexion': leftKneeFlexion,
      'right_knee_flexion': rightKneeFlexion,
      'left_hip_flexion': leftHipFlexion,
      'right_hip_flexion': rightHipFlexion,
      'left_ankle_flexion': leftAnkleFlexion,
      'right_ankle_flexion': rightAnkleFlexion,
    };
  }

  /// Get all angles as a list (same order as backend)
  List<double?> get anglesList => [
        leftKneeFlexion,
        rightKneeFlexion,
        leftHipFlexion,
        rightHipFlexion,
        leftAnkleFlexion,
        rightAnkleFlexion,
      ];

  /// Angle column names for display
  static const List<String> angleNames = [
    'Left Knee Flexion',
    'Right Knee Flexion',
    'Left Hip Flexion',
    'Right Hip Flexion',
    'Left Ankle Flexion',
    'Right Ankle Flexion',
  ];

  /// Database column names
  static const List<String> angleColumns = [
    'left_knee_flexion',
    'right_knee_flexion',
    'left_hip_flexion',
    'right_hip_flexion',
    'left_ankle_flexion',
    'right_ankle_flexion',
  ];

  @override
  String toString() {
    return 'FrameAngle(sessionId: $sessionId, frame: $frameIndex, '
        'knee: L${leftKneeFlexion?.toStringAsFixed(1)}° R${rightKneeFlexion?.toStringAsFixed(1)}°)';
  }
}

/// Statistics for a single angle type across a session or multiple sessions
class AngleStats {
  final String angleName;
  final double? min;
  final double? max;
  final double? avg;
  final int sampleCount;

  const AngleStats({
    required this.angleName,
    this.min,
    this.max,
    this.avg,
    this.sampleCount = 0,
  });

  /// Format value for display (e.g., "45.2°")
  String formatValue(double? value) {
    if (value == null) return '--°';
    return '${value.toStringAsFixed(1)}°';
  }

  String get minFormatted => formatValue(min);
  String get maxFormatted => formatValue(max);
  String get avgFormatted => formatValue(avg);

  @override
  String toString() {
    return 'AngleStats($angleName: min=$minFormatted, max=$maxFormatted, avg=$avgFormatted, n=$sampleCount)';
  }
}
