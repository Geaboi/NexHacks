import 'dart:convert';

/// Represents a detected action/segment from the Overshoot inference
/// Used to divide video sessions into labeled segments
class DetectedAction {
  final int? id;
  final int sessionId;
  final String action;
  final double timestamp; // Timestamp in seconds from video start
  final double confidence;
  final int frameNumber;
  final int? frameNumberEnd; // End frame for interval (optional)
  final Map<String, dynamic>? metadata;

  const DetectedAction({
    this.id,
    required this.sessionId,
    required this.action,
    required this.timestamp,
    required this.confidence,
    required this.frameNumber,
    this.frameNumberEnd,
    this.metadata,
  });

  /// Create from database row
  factory DetectedAction.fromMap(Map<String, dynamic> map) {
    Map<String, dynamic>? parsedMetadata;
    if (map['metadata'] != null && map['metadata'] is String) {
      try {
        parsedMetadata = Map<String, dynamic>.from(
          (map['metadata'] as String).isNotEmpty
              ? jsonDecode(map['metadata'] as String) as Map<String, dynamic>
              : {},
        );
      } catch (_) {
        parsedMetadata = null;
      }
    }

    return DetectedAction(
      id: map['id'] as int?,
      sessionId: map['session_id'] as int,
      action: map['action'] as String,
      timestamp: (map['timestamp'] as num).toDouble(),
      confidence: (map['confidence'] as num).toDouble(),
      frameNumber: map['frame_number'] as int,
      frameNumberEnd: map['frame_number_end'] as int?,
      metadata: parsedMetadata,
    );
  }

  /// Create from backend JSON response
  factory DetectedAction.fromBackendJson(Map<String, dynamic> json, int sessionId) {
    return DetectedAction(
      sessionId: sessionId,
      action: json['action'] as String? ?? 'unknown',
      timestamp: (json['timestamp'] as num?)?.toDouble() ?? 0.0,
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0.0,
      frameNumber: json['frame_number'] as int? ?? 0,
      frameNumberEnd: json['frame_number_end'] as int?,
      metadata: json['metadata'] as Map<String, dynamic>?,
    );
  }

  /// Convert to database map for insertion
  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'session_id': sessionId,
      'action': action,
      'timestamp': timestamp,
      'confidence': confidence,
      'frame_number': frameNumber,
      'frame_number_end': frameNumberEnd,
      'metadata': metadata != null ? jsonEncode(metadata!) : null,
    };
  }

  /// Convert to JSON for serialization
  Map<String, dynamic> toJson() => {
    'action': action,
    'timestamp': timestamp,
    'confidence': confidence,
    'frame_number': frameNumber,
    'frame_number_end': frameNumberEnd,
    'metadata': metadata,
  };

  /// Get the frame interval as a human-readable string
  String get frameIntervalString {
    if (frameNumberEnd != null && frameNumberEnd! > frameNumber) {
      return 'Frames $frameNumber-$frameNumberEnd';
    }
    return 'Frame $frameNumber';
  }

  /// Get timestamp formatted as mm:ss
  String get formattedTimestamp {
    final totalSeconds = timestamp.toInt();
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  String toString() {
    return 'DetectedAction(action: $action, timestamp: $timestamp, confidence: $confidence, frame: $frameNumber)';
  }

  /// Copy with new values
  DetectedAction copyWith({
    int? id,
    int? sessionId,
    String? action,
    double? timestamp,
    double? confidence,
    int? frameNumber,
    int? frameNumberEnd,
    Map<String, dynamic>? metadata,
  }) {
    return DetectedAction(
      id: id ?? this.id,
      sessionId: sessionId ?? this.sessionId,
      action: action ?? this.action,
      timestamp: timestamp ?? this.timestamp,
      confidence: confidence ?? this.confidence,
      frameNumber: frameNumber ?? this.frameNumber,
      frameNumberEnd: frameNumberEnd ?? this.frameNumberEnd,
      metadata: metadata ?? this.metadata,
    );
  }
}
