import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/detected_action.dart';
import '../services/database_service.dart';

/// State for detected actions (action segments from Overshoot inference)
class DetectedActionsState {
  /// Actions for the current/selected session
  final List<DetectedAction> actions;
  
  /// Whether actions are being loaded
  final bool isLoading;
  
  /// Error message if loading failed
  final String? errorMessage;
  
  /// Session ID these actions belong to
  final int? sessionId;

  const DetectedActionsState({
    this.actions = const [],
    this.isLoading = false,
    this.errorMessage,
    this.sessionId,
  });

  DetectedActionsState copyWith({
    List<DetectedAction>? actions,
    bool? isLoading,
    String? errorMessage,
    int? sessionId,
  }) {
    return DetectedActionsState(
      actions: actions ?? this.actions,
      isLoading: isLoading ?? this.isLoading,
      errorMessage: errorMessage,
      sessionId: sessionId ?? this.sessionId,
    );
  }

  /// Check if there are any actions
  bool get hasActions => actions.isNotEmpty;

  /// Get unique action types
  List<String> get actionTypes => actions.map((a) => a.action).toSet().toList();

  /// Get actions sorted by frame number
  List<DetectedAction> get sortedActions {
    final sorted = List<DetectedAction>.from(actions)
      ..sort((a, b) => a.frameNumber.compareTo(b.frameNumber));
    return sorted;
  }

  /// Get actions filtered by action type
  List<DetectedAction> actionsOfType(String actionType) {
    return actions.where((a) => a.action == actionType).toList();
  }

  /// Get the action at a specific frame (or null if no action covers that frame)
  DetectedAction? getActionAtFrame(int frameIndex) {
    for (final action in actions) {
      final endFrame = action.frameNumberEnd ?? action.frameNumber;
      if (frameIndex >= action.frameNumber && frameIndex <= endFrame) {
        return action;
      }
    }
    return null;
  }

  /// Get frame intervals for chart segment labels
  /// Returns list of (startFrame, endFrame, actionLabel) tuples
  List<({int start, int end, String label})> get frameIntervals {
    final sorted = sortedActions;
    if (sorted.isEmpty) return [];

    final intervals = <({int start, int end, String label})>[];
    for (int i = 0; i < sorted.length; i++) {
      final action = sorted[i];
      final startFrame = action.frameNumber;
      final endFrame = action.frameNumberEnd ?? 
          (i + 1 < sorted.length ? sorted[i + 1].frameNumber - 1 : startFrame);
      intervals.add((start: startFrame, end: endFrame, label: action.action));
    }
    return intervals;
  }
}

/// Notifier for managing detected actions state
class DetectedActionsNotifier extends Notifier<DetectedActionsState> {
  final DatabaseService _db = DatabaseService();

  @override
  DetectedActionsState build() {
    return const DetectedActionsState();
  }

  /// Load actions for a specific session
  Future<void> loadSessionActions(int sessionId) async {
    state = state.copyWith(isLoading: true, sessionId: sessionId);

    try {
      final actions = await _db.getSessionDetectedActions(sessionId);
      state = state.copyWith(
        actions: actions,
        isLoading: false,
        sessionId: sessionId,
      );
      print('[DetectedActions] 📊 Loaded ${actions.length} actions for session $sessionId');
    } catch (e) {
      print('[DetectedActions] ❌ Error loading actions: $e');
      state = state.copyWith(
        isLoading: false,
        errorMessage: e.toString(),
      );
    }
  }

  /// Save actions for a session from backend response
  /// Takes raw JSON maps from AnalyticsResponse.detectedActions
  Future<void> saveActions({
    required int sessionId,
    required List<Map<String, dynamic>> actionsJson,
  }) async {
    if (actionsJson.isEmpty) {
      print('[DetectedActions] ℹ️ No actions to save');
      return;
    }

    try {
      // Convert JSON to DetectedAction objects
      final actions = actionsJson
          .map((json) => DetectedAction.fromBackendJson(json, sessionId))
          .toList();

      // Insert into database
      await _db.insertDetectedActions(actions);

      // Update state with the saved actions
      state = state.copyWith(
        actions: actions,
        sessionId: sessionId,
      );

      print('[DetectedActions] 💾 Saved ${actions.length} actions for session $sessionId');
    } catch (e) {
      print('[DetectedActions] ❌ Error saving actions: $e');
      state = state.copyWith(errorMessage: e.toString());
    }
  }

  /// Set actions directly (without saving to database)
  /// Use for temporary display before database save
  void setActions(List<DetectedAction> actions, {int? sessionId}) {
    state = state.copyWith(
      actions: actions,
      sessionId: sessionId,
    );
  }

  /// Clear current actions
  void clear() {
    state = const DetectedActionsState();
  }

  /// Delete all actions for a session
  Future<void> deleteSessionActions(int sessionId) async {
    try {
      await _db.deleteSessionDetectedActions(sessionId);
      if (state.sessionId == sessionId) {
        state = state.copyWith(actions: []);
      }
      print('[DetectedActions] 🗑️ Deleted actions for session $sessionId');
    } catch (e) {
      print('[DetectedActions] ❌ Error deleting actions: $e');
      state = state.copyWith(errorMessage: e.toString());
    }
  }
}

/// Provider for detected actions
final detectedActionsProvider = NotifierProvider<DetectedActionsNotifier, DetectedActionsState>(
  DetectedActionsNotifier.new,
);

/// Provider family to get actions for a specific session
/// Usage: ref.watch(sessionActionsProvider(sessionId))
final sessionActionsProvider = FutureProvider.family<List<DetectedAction>, int>((ref, sessionId) async {
  final db = DatabaseService();
  return db.getSessionDetectedActions(sessionId);
});

/// Provider to get unique action types for a session
/// Usage: ref.watch(sessionActionTypesProvider(sessionId))
final sessionActionTypesProvider = FutureProvider.family<List<String>, int>((ref, sessionId) async {
  final db = DatabaseService();
  return db.getSessionActionTypes(sessionId);
});
