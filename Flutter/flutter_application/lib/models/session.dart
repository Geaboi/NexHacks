/// Represents a recording session with metadata
class Session {
  final int? id;
  final int timestampUtc; // UTC milliseconds when recording started (single source of truth)
  final String? originalVideoPath;
  final String? processedVideoPath;
  final int? durationMs;
  final int? fps;
  final int? totalFrames;
  final int? numAngles;

  const Session({
    this.id,
    required this.timestampUtc,
    this.originalVideoPath,
    this.processedVideoPath,
    this.durationMs,
    this.fps,
    this.totalFrames,
    this.numAngles,
  });

  /// Create from database row
  factory Session.fromMap(Map<String, dynamic> map) {
    return Session(
      id: map['id'] as int?,
      timestampUtc: map['timestamp_utc'] as int,
      originalVideoPath: map['original_video_path'] as String?,
      processedVideoPath: map['processed_video_path'] as String?,
      durationMs: map['duration_ms'] as int?,
      fps: map['fps'] as int?,
      totalFrames: map['total_frames'] as int?,
      numAngles: map['num_angles'] as int?,
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
    };
  }

  /// Get createdAt as DateTime (derived from timestampUtc)
  DateTime get createdAt => DateTime.fromMillisecondsSinceEpoch(timestampUtc, isUtc: true);

  /// Get session date formatted for display (converts UTC to local)
  String get formattedDate {
    final local = createdAt.toLocal();
    return '${local.day}/${local.month}/${local.year}';
  }

  /// Get session time formatted for display (converts UTC to local)
  String get formattedTime {
    final local = createdAt.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }

  /// Get ISO8601 string for display purposes
  String get createdAtIso => createdAt.toIso8601String();

  @override
  String toString() {
    return 'Session(id: $id, timestampUtc: $timestampUtc, totalFrames: $totalFrames)';
  }
}
