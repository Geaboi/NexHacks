import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Represents a single inference result with its UTC timestamp
class InferencePoint {
  final int timestampUtc; // UTC milliseconds since epoch when frame was captured
  final String inferenceResult;

  const InferencePoint({
    required this.timestampUtc,
    required this.inferenceResult,
  });

  Map<String, dynamic> toJson() => {
    'timestampUtc': timestampUtc,
    'inferenceResult': inferenceResult,
  };

  factory InferencePoint.fromJson(Map<String, dynamic> json) => InferencePoint(
    timestampUtc: json['timestampUtc'] as int,
    inferenceResult: json['inferenceResult'] as String,
  );
}

/// State for the frame analysis session (sparse storage - only inference results)
class FrameAnalysisState {
  final List<InferencePoint> inferencePoints; // Only frames with inference results
  final int? videoStartTimeUtc; // UTC milliseconds when MP4 recording started
  final bool isRecording;
  final bool isWaitingForResults;
  final DateTime? sessionStartTime;
  final DateTime? sessionEndTime;

  const FrameAnalysisState({
    this.inferencePoints = const [],
    this.videoStartTimeUtc,
    this.isRecording = false,
    this.isWaitingForResults = false,
    this.sessionStartTime,
    this.sessionEndTime,
  });

  /// Get inference points sorted by timestamp
  List<InferencePoint> get sortedPoints {
    final sorted = List<InferencePoint>.from(inferencePoints)
      ..sort((a, b) => a.timestampUtc.compareTo(b.timestampUtc));
    return sorted;
  }

  /// Get count of inference points
  int get pointCount => inferencePoints.length;

  FrameAnalysisState copyWith({
    List<InferencePoint>? inferencePoints,
    int? videoStartTimeUtc,
    bool? isRecording,
    bool? isWaitingForResults,
    DateTime? sessionStartTime,
    DateTime? sessionEndTime,
  }) {
    return FrameAnalysisState(
      inferencePoints: inferencePoints ?? this.inferencePoints,
      videoStartTimeUtc: videoStartTimeUtc ?? this.videoStartTimeUtc,
      isRecording: isRecording ?? this.isRecording,
      isWaitingForResults: isWaitingForResults ?? this.isWaitingForResults,
      sessionStartTime: sessionStartTime ?? this.sessionStartTime,
      sessionEndTime: sessionEndTime ?? this.sessionEndTime,
    );
  }
}

/// Notifier for managing frame analysis state (sparse storage)
class FrameAnalysisNotifier extends Notifier<FrameAnalysisState> {
  @override
  FrameAnalysisState build() {
    return const FrameAnalysisState();
  }

  /// Start a new recording session with the video start timestamp
  void startSession(int videoStartTimeUtc) {
    state = FrameAnalysisState(
      videoStartTimeUtc: videoStartTimeUtc,
      isRecording: true,
      sessionStartTime: DateTime.now().toUtc(),
    );
  }

  /// Add a frame with its inference result (only called when result received)
  void addFrameWithResult(int timestampUtc, String result) {
    final newPoints = List<InferencePoint>.from(state.inferencePoints);
    newPoints.add(InferencePoint(
      timestampUtc: timestampUtc,
      inferenceResult: result,
    ));
    state = state.copyWith(inferencePoints: newPoints);
  }

  /// Stop recording and start waiting for remaining results
  void stopRecording() {
    state = state.copyWith(
      isRecording: false,
      isWaitingForResults: true,
      sessionEndTime: DateTime.now().toUtc(),
    );
  }

  /// Mark the session as complete (all results received)
  void markSessionComplete() {
    state = state.copyWith(isWaitingForResults: false);
  }

  /// Clear all data for a new session
  void clearSession() {
    state = const FrameAnalysisState();
  }

  /// Map inference points to video frame indices
  /// Returns list of [frameIndex, inferenceResult] pairs
  List<List<dynamic>> mapToVideoFrames(int fps, int videoDurationMs, {int toleranceMs = 100}) {
    final videoStart = state.videoStartTimeUtc;
    if (videoStart == null) return [];

    final result = <List<dynamic>>[];
    final totalFrames = (videoDurationMs * fps / 1000).round();

    for (final point in state.sortedPoints) {
      // Calculate offset from video start
      final offsetMs = point.timestampUtc - videoStart;
      
      // Skip if before video started or after video ended
      if (offsetMs < -toleranceMs || offsetMs > videoDurationMs + toleranceMs) {
        continue;
      }

      // Calculate frame index (clamped to valid range)
      final frameIndex = (offsetMs * fps / 1000).round().clamp(0, totalFrames - 1);
      
      result.add([frameIndex, point.inferenceResult]);
    }

    return result;
  }

  /// Get the analysis summary
  Map<String, dynamic> getSessionSummary() {
    return {
      'sessionStart': state.sessionStartTime?.toIso8601String(),
      'sessionEnd': state.sessionEndTime?.toIso8601String(),
      'videoStartTimeUtc': state.videoStartTimeUtc,
      'totalInferencePoints': state.inferencePoints.length,
      'points': state.sortedPoints.map((p) => p.toJson()).toList(),
    };
  }
}

/// Provider for the most recent frame analysis session
final frameAnalysisProvider = NotifierProvider<FrameAnalysisNotifier, FrameAnalysisState>(
  FrameAnalysisNotifier.new,
);
