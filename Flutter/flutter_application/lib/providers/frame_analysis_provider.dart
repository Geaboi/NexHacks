import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Represents a single frame's analysis result
class FrameAnalysis {
  final int timestampUtc; // UTC milliseconds since epoch - primary key
  final String? inferenceResult;
  final bool isPending; // True if still waiting for server response

  const FrameAnalysis({
    required this.timestampUtc,
    this.inferenceResult,
    this.isPending = true,
  });

  FrameAnalysis copyWith({
    String? inferenceResult,
    bool? isPending,
  }) {
    return FrameAnalysis(
      timestampUtc: timestampUtc,
      inferenceResult: inferenceResult ?? this.inferenceResult,
      isPending: isPending ?? this.isPending,
    );
  }

  Map<String, dynamic> toJson() => {
    'timestampUtc': timestampUtc,
    'inferenceResult': inferenceResult,
    'isPending': isPending,
  };

  factory FrameAnalysis.fromJson(Map<String, dynamic> json) => FrameAnalysis(
    timestampUtc: json['timestampUtc'] as int,
    inferenceResult: json['inferenceResult'] as String?,
    isPending: json['isPending'] as bool? ?? false,
  );
}

/// State for the frame analysis session
class FrameAnalysisState {
  final Map<int, FrameAnalysis> frames; // keyed by timestampUtc
  final bool isRecording;
  final bool isWaitingForResults;
  final DateTime? sessionStartTime;
  final DateTime? sessionEndTime;

  const FrameAnalysisState({
    this.frames = const {},
    this.isRecording = false,
    this.isWaitingForResults = false,
    this.sessionStartTime,
    this.sessionEndTime,
  });

  /// Get frames sorted by timestamp
  List<FrameAnalysis> get sortedFrames {
    final sorted = frames.values.toList()
      ..sort((a, b) => a.timestampUtc.compareTo(b.timestampUtc));
    return sorted;
  }

  /// Get completed frames with inference results
  List<FrameAnalysis> get completedFrames {
    return sortedFrames.where((f) => !f.isPending && f.inferenceResult != null).toList();
  }

  /// Get count of pending frames
  int get pendingCount => frames.values.where((f) => f.isPending).length;

  /// Check if all frames have received results
  bool get allResultsReceived => frames.isNotEmpty && pendingCount == 0;

  FrameAnalysisState copyWith({
    Map<int, FrameAnalysis>? frames,
    bool? isRecording,
    bool? isWaitingForResults,
    DateTime? sessionStartTime,
    DateTime? sessionEndTime,
  }) {
    return FrameAnalysisState(
      frames: frames ?? this.frames,
      isRecording: isRecording ?? this.isRecording,
      isWaitingForResults: isWaitingForResults ?? this.isWaitingForResults,
      sessionStartTime: sessionStartTime ?? this.sessionStartTime,
      sessionEndTime: sessionEndTime ?? this.sessionEndTime,
    );
  }
}

/// Notifier for managing frame analysis state
class FrameAnalysisNotifier extends Notifier<FrameAnalysisState> {
  @override
  FrameAnalysisState build() {
    return const FrameAnalysisState();
  }

  /// Start a new recording session
  void startSession() {
    state = FrameAnalysisState(
      isRecording: true,
      sessionStartTime: DateTime.now().toUtc(),
    );
  }

  /// Register a frame that was sent to the server
  void addFrame(int timestampUtc) {
    final newFrames = Map<int, FrameAnalysis>.from(state.frames);
    newFrames[timestampUtc] = FrameAnalysis(
      timestampUtc: timestampUtc,
      isPending: true,
    );
    state = state.copyWith(frames: newFrames);
  }

  /// Update a frame with its inference result
  void updateFrameResult(int timestampUtc, String result) {
    final newFrames = Map<int, FrameAnalysis>.from(state.frames);
    
    if (newFrames.containsKey(timestampUtc)) {
      newFrames[timestampUtc] = newFrames[timestampUtc]!.copyWith(
        inferenceResult: result,
        isPending: false,
      );
    } else {
      // Frame not found by exact timestamp - might be a slight mismatch
      // Find the closest pending frame
      final pendingFrames = newFrames.entries
          .where((e) => e.value.isPending)
          .toList()
        ..sort((a, b) => 
            (a.key - timestampUtc).abs().compareTo((b.key - timestampUtc).abs()));
      
      if (pendingFrames.isNotEmpty) {
        final closestKey = pendingFrames.first.key;
        newFrames[closestKey] = newFrames[closestKey]!.copyWith(
          inferenceResult: result,
          isPending: false,
        );
      }
    }
    
    state = state.copyWith(frames: newFrames);
  }

  /// Mark oldest pending frame as complete with result
  void addResultToOldestPending(String result) {
    final pendingFrames = state.frames.entries
        .where((e) => e.value.isPending)
        .toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    
    if (pendingFrames.isNotEmpty) {
      final oldestKey = pendingFrames.first.key;
      final newFrames = Map<int, FrameAnalysis>.from(state.frames);
      newFrames[oldestKey] = newFrames[oldestKey]!.copyWith(
        inferenceResult: result,
        isPending: false,
      );
      state = state.copyWith(frames: newFrames);
    }
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

  /// Get the analysis summary
  Map<String, dynamic> getSessionSummary() {
    return {
      'sessionStart': state.sessionStartTime?.toIso8601String(),
      'sessionEnd': state.sessionEndTime?.toIso8601String(),
      'totalFrames': state.frames.length,
      'completedFrames': state.completedFrames.length,
      'pendingFrames': state.pendingCount,
      'frames': state.sortedFrames.map((f) => f.toJson()).toList(),
    };
  }
}

/// Provider for the most recent frame analysis session
final frameAnalysisProvider = NotifierProvider<FrameAnalysisNotifier, FrameAnalysisState>(
  FrameAnalysisNotifier.new,
);
