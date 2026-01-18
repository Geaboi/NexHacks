import 'dart:convert';

/// Represents a recording session with metadata
class Session {
  final int? id;
  final int timestampUtc; // UTC milliseconds when recording started
  final String? originalVideoPath;
  final String? processedVideoPath;
  final int? durationMs;
  final int? fps;
  final int? totalFrames;
  final int? numAngles;
  final List<int> anomalousFrameIds; // Frame indices flagged as anomalous by backend
  final DateTime createdAt;

  const Session({
    this.id,
    required this.timestampUtc,
    this.originalVideoPath,
    this.processedVideoPath,
    this.durationMs,
    this.fps,
    this.totalFrames,
    this.numAngles,
    this.anomalousFrameIds = const [],
    required this.createdAt,
  });

  /// Create from database row
  factory Session.fromMap(Map<String, dynamic> map) {
    // Parse anomalous_frame_ids from JSON string
    List<int> anomalousIds = [];
    if (map['anomalous_frame_ids'] != null) {
      final jsonStr = map['anomalous_frame_ids'] as String;
      if (jsonStr.isNotEmpty) {
        final decoded = jsonDecode(jsonStr) as List<dynamic>;
        anomalousIds = decoded.map((e) => e as int).toList();
      }
    }
    
    return Session(
      id: map['id'] as int?,
      timestampUtc: map['timestamp_utc'] as int,
      originalVideoPath: map['original_video_path'] as String?,
      processedVideoPath: map['processed_video_path'] as String?,
      durationMs: map['duration_ms'] as int?,
      fps: map['fps'] as int?,
      totalFrames: map['total_frames'] as int?,
      numAngles: map['num_angles'] as int?,
      anomalousFrameIds: anomalousIds,
      createdAt: DateTime.parse(map['created_at'] as String),
    );
  }

  /// Convert to database map for insertion
  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'timestamp_utc': timestampUtc,
      'original_video_path': originalVideoPath,
      'processed_video_path': processedVideoPath,
      'duration_ms': durationMs,
      'fps': fps,
      'total_frames': totalFrames,
      'num_angles': numAngles,
      'anomalous_frame_ids': jsonEncode(anomalousFrameIds),
      'created_at': createdAt.toIso8601String(),
    };
  }

  /// Get session date formatted for display
  String get formattedDate {
    return '${createdAt.day}/${createdAt.month}/${createdAt.year}';
  }

  /// Get session time formatted for display
  String get formattedTime {
    return '${createdAt.hour.toString().padLeft(2, '0')}:${createdAt.minute.toString().padLeft(2, '0')}';
  }

  /// Check if a frame index is marked as anomalous and should be ignored
  bool isFrameAnomalous(int frameIndex) {
    return anomalousFrameIds.contains(frameIndex);
  }

  /// Get the count of anomalous frames
  int get anomalousFrameCount => anomalousFrameIds.length;

  @override
  String toString() {
    return 'Session(id: $id, timestampUtc: $timestampUtc, totalFrames: $totalFrames)';
  }
}
