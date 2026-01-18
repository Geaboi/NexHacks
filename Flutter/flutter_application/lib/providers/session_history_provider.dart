import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/session.dart';
import '../models/frame_angle.dart';
import '../services/database_service.dart';

/// State for session history
class SessionHistoryState {
  final List<Session> sessions;
  final bool isLoading;
  final String? errorMessage;
  final Session? selectedSession;
  final List<FrameAngle>? selectedSessionAngles;
  final List<AngleStats>? selectedSessionStats;

  const SessionHistoryState({
    this.sessions = const [],
    this.isLoading = false,
    this.errorMessage,
    this.selectedSession,
    this.selectedSessionAngles,
    this.selectedSessionStats,
  });

  SessionHistoryState copyWith({
    List<Session>? sessions,
    bool? isLoading,
    String? errorMessage,
    Session? selectedSession,
    List<FrameAngle>? selectedSessionAngles,
    List<AngleStats>? selectedSessionStats,
  }) {
    return SessionHistoryState(
      sessions: sessions ?? this.sessions,
      isLoading: isLoading ?? this.isLoading,
      errorMessage: errorMessage,
      selectedSession: selectedSession ?? this.selectedSession,
      selectedSessionAngles: selectedSessionAngles ?? this.selectedSessionAngles,
      selectedSessionStats: selectedSessionStats ?? this.selectedSessionStats,
    );
  }

  /// Get the most recent session
  Session? get latestSession => sessions.isNotEmpty ? sessions.first : null;

  /// Check if there's any session data
  bool get hasData => sessions.isNotEmpty;
}

/// Notifier for managing session history state
class SessionHistoryNotifier extends Notifier<SessionHistoryState> {
  final DatabaseService _db = DatabaseService();

  @override
  SessionHistoryState build() {
    // Load sessions on initialization
    _loadSessions();
    return const SessionHistoryState(isLoading: true);
  }

  /// Load all sessions from database
  Future<void> _loadSessions() async {
    try {
      final sessions = await _db.getAllSessions();
      state = state.copyWith(
        sessions: sessions,
        isLoading: false,
      );
      print('[SessionHistory] 📚 Loaded ${sessions.length} sessions');
    } catch (e) {
      print('[SessionHistory] ❌ Error loading sessions: $e');
      state = state.copyWith(
        isLoading: false,
        errorMessage: e.toString(),
      );
    }
  }

  /// Refresh sessions from database
  Future<void> refresh() async {
    state = state.copyWith(isLoading: true);
    await _loadSessions();
  }

  /// Save a new session with its frame angles
  /// Called after receiving backend response in AnalyticsService
  Future<int?> saveSession({
    required int timestampUtc,
    required List<List<dynamic>> angles,
    String? originalVideoPath,
    String? processedVideoPath,
    int? durationMs,
    int? fps,
    List<int> anomalousFrameIds = const [],
  }) async {
    try {
      print('[SessionHistory] 💾 Saving session with ${angles.length} frames, ${anomalousFrameIds.length} anomalous...');

      // Create session
      final session = Session(
        timestampUtc: timestampUtc,
        originalVideoPath: originalVideoPath,
        processedVideoPath: processedVideoPath,
        durationMs: durationMs,
        fps: fps,
        totalFrames: angles.length,
        numAngles: 6,
        anomalousFrameIds: anomalousFrameIds,
        createdAt: DateTime.now().toUtc(),
      );

      // Insert session and get ID
      final sessionId = await _db.insertSession(session);

      // Convert backend angles to FrameAngle objects
      final frameAngles = <FrameAngle>[];
      for (int i = 0; i < angles.length; i++) {
        if (angles[i] is List) {
          frameAngles.add(FrameAngle.fromBackendList(
            sessionId: sessionId,
            frameIndex: i,
            angles: angles[i],
            fps: fps,
          ));
        }
      }

      // Batch insert frame angles
      await _db.insertFrameAngles(frameAngles);

      print('[SessionHistory] ✅ Saved session $sessionId with ${frameAngles.length} frames');

      // Refresh session list
      await _loadSessions();

      return sessionId;
    } catch (e) {
      print('[SessionHistory] ❌ Error saving session: $e');
      state = state.copyWith(errorMessage: e.toString());
      return null;
    }
  }

  /// Select a session and load its details
  Future<void> selectSession(int sessionId) async {
    try {
      final session = await _db.getSession(sessionId);
      if (session == null) return;

      final angles = await _db.getSessionAngles(sessionId);
      final stats = await _db.getSessionAngleStats(sessionId);

      state = state.copyWith(
        selectedSession: session,
        selectedSessionAngles: angles,
        selectedSessionStats: stats,
      );

      print('[SessionHistory] 📊 Selected session $sessionId with ${angles.length} frames');
    } catch (e) {
      print('[SessionHistory] ❌ Error selecting session: $e');
      state = state.copyWith(errorMessage: e.toString());
    }
  }

  /// Clear the selected session
  void clearSelection() {
    state = SessionHistoryState(sessions: state.sessions);
  }

  /// Delete a session
  Future<void> deleteSession(int sessionId) async {
    try {
      await _db.deleteSession(sessionId);
      await _loadSessions();
      
      // Clear selection if deleted session was selected
      if (state.selectedSession?.id == sessionId) {
        clearSelection();
      }
    } catch (e) {
      print('[SessionHistory] ❌ Error deleting session: $e');
      state = state.copyWith(errorMessage: e.toString());
    }
  }

  /// Get angle statistics for the most recent session
  Future<List<AngleStats>> getLatestSessionStats() async {
    final latest = state.latestSession;
    if (latest?.id == null) return [];
    return await _db.getSessionAngleStats(latest!.id!);
  }

  /// Get all-time max angles for progress tracking
  Future<List<AngleStats>> getAllTimeStats() async {
    return await _db.getAllTimeMaxAngles();
  }

  /// Get angle trend data for charting
  Future<List<Map<String, dynamic>>> getAngleTrend(String angleColumn) async {
    return await _db.getAngleTrendBySession(angleColumn);
  }
}

/// Provider for session history
final sessionHistoryProvider =
    NotifierProvider<SessionHistoryNotifier, SessionHistoryState>(
  SessionHistoryNotifier.new,
);

/// Provider for the most recent session's stats
final latestSessionStatsProvider = FutureProvider<List<AngleStats>>((ref) async {
  final notifier = ref.watch(sessionHistoryProvider.notifier);
  return notifier.getLatestSessionStats();
});

/// Provider for all-time stats
final allTimeStatsProvider = FutureProvider<List<AngleStats>>((ref) async {
  final notifier = ref.watch(sessionHistoryProvider.notifier);
  return notifier.getAllTimeStats();
});
