import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import '../models/session.dart';
import '../models/frame_angle.dart';
import '../models/detected_action.dart';

/// SQLite database service for persistent storage of angle analysis data
class DatabaseService {
  static const String _databaseName = 'smartpt_angles.db';
  static const int _databaseVersion = 4;

  static Database? _database;

  /// Get the database instance (singleton pattern)
  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  /// Initialize the database
  Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, _databaseName);

    print('[DatabaseService] 📁 Initializing database at: $path');

    return await openDatabase(path, version: _databaseVersion, onCreate: _onCreate, onUpgrade: _onUpgrade);
  }

  /// Create database tables
  Future<void> _onCreate(Database db, int version) async {
    print('[DatabaseService] 🏗️ Creating database tables...');

    // Sessions table - stores recording session metadata
    // timestamp_utc is the single source of truth for session time (UTC milliseconds)
    await db.execute('''
      CREATE TABLE sessions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        timestamp_utc INTEGER NOT NULL,
        original_video_path TEXT,
        processed_video_path TEXT,
        duration_ms INTEGER,
        fps INTEGER,
        total_frames INTEGER,
        num_angles INTEGER
      )
    ''');

    // Frame angles table - stores 6 angles per frame
    await db.execute('''
      CREATE TABLE frame_angles (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id INTEGER NOT NULL,
        frame_index INTEGER NOT NULL,
        timestamp_offset_ms INTEGER,
        left_knee_flexion REAL,
        right_knee_flexion REAL,
        left_hip_flexion REAL,
        right_hip_flexion REAL,
        left_ankle_flexion REAL,
        right_ankle_flexion REAL,
        FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE CASCADE
      )
    ''');

    // Index for efficient queries by session and frame
    await db.execute('''
      CREATE INDEX idx_frame_angles_session 
      ON frame_angles(session_id, frame_index)
    ''');

    // Index for time-based queries
    await db.execute('''
      CREATE INDEX idx_sessions_timestamp 
      ON sessions(timestamp_utc DESC)
    ''');

    // Detected actions table - stores action segments from Overshoot inference
    await db.execute('''
      CREATE TABLE detected_actions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id INTEGER NOT NULL,
        action TEXT NOT NULL,
        timestamp REAL NOT NULL,
        confidence REAL NOT NULL,
        frame_number INTEGER NOT NULL,
        frame_number_end INTEGER,
        metadata TEXT,
        FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE CASCADE
      )
    ''');

    // Index for efficient queries by session
    await db.execute('''
      CREATE INDEX idx_detected_actions_session 
      ON detected_actions(session_id, frame_number)
    ''');

    print('[DatabaseService] ✅ Database tables created');
  }

  /// Handle database upgrades (for future schema changes)
  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    print('[DatabaseService] ⬆️ Upgrading database from v$oldVersion to v$newVersion');

    // Migration from v1 to v2: Add anomalous_frame_ids column (now deprecated)
    if (oldVersion < 2) {
      await db.execute('ALTER TABLE sessions ADD COLUMN anomalous_frame_ids TEXT');
      print('[DatabaseService] ✅ Added anomalous_frame_ids column (deprecated)');
    }

    // Migration v2 to v3: anomalous_frame_ids and created_at are now ignored
    // SQLite doesn't support DROP COLUMN in older versions, so columns remain but are unused
    // Session.fromMap() handles missing/ignored columns gracefully
    if (oldVersion < 3) {
      print('[DatabaseService] ✅ Migrated to v3 - anomalous_frame_ids and created_at deprecated');
    }

    // Migration v3 to v4: Add detected_actions table for Overshoot action segments
    if (oldVersion < 4) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS detected_actions (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          session_id INTEGER NOT NULL,
          action TEXT NOT NULL,
          timestamp REAL NOT NULL,
          confidence REAL NOT NULL,
          frame_number INTEGER NOT NULL,
          frame_number_end INTEGER,
          metadata TEXT,
          FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE CASCADE
        )
      ''');

      await db.execute('''
        CREATE INDEX IF NOT EXISTS idx_detected_actions_session 
        ON detected_actions(session_id, frame_number)
      ''');
      print('[DatabaseService] ✅ Migrated to v4 - added detected_actions table');
    }
  }

  // ============================================================================
  // Session CRUD Operations
  // ============================================================================

  /// Insert a new session and return its ID
  Future<int> insertSession(Session session) async {
    final db = await database;
    final id = await db.insert('sessions', session.toMap());
    print('[DatabaseService] 📝 Inserted session with ID: $id');
    return id;
  }

  /// Get all sessions ordered by timestamp (most recent first)
  Future<List<Session>> getAllSessions({int? limit}) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query('sessions', orderBy: 'timestamp_utc DESC', limit: limit);
    return maps.map((map) => Session.fromMap(map)).toList();
  }

  /// Get a single session by ID
  Future<Session?> getSession(int id) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query('sessions', where: 'id = ?', whereArgs: [id], limit: 1);
    if (maps.isEmpty) return null;
    return Session.fromMap(maps.first);
  }

  /// Delete a session and its associated frame angles
  Future<int> deleteSession(int id) async {
    final db = await database;
    // Frame angles will be deleted automatically due to ON DELETE CASCADE
    final count = await db.delete('sessions', where: 'id = ?', whereArgs: [id]);
    print('[DatabaseService] 🗑️ Deleted session $id');
    return count;
  }

  // ============================================================================
  // Frame Angles CRUD Operations
  // ============================================================================

  /// Insert multiple frame angles in a batch (more efficient)
  Future<void> insertFrameAngles(List<FrameAngle> angles) async {
    if (angles.isEmpty) return;

    final db = await database;
    final batch = db.batch();

    for (final angle in angles) {
      batch.insert('frame_angles', angle.toMap());
    }

    await batch.commit(noResult: true);
    print('[DatabaseService] 📝 Inserted ${angles.length} frame angles');
  }

  /// Get all frame angles for a session, ordered by frame index
  Future<List<FrameAngle>> getSessionAngles(int sessionId) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'frame_angles',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'frame_index ASC',
    );
    return maps.map((map) => FrameAngle.fromMap(map)).toList();
  }

  /// Get frame angles for a specific frame range
  Future<List<FrameAngle>> getFrameRange(int sessionId, int startFrame, int endFrame) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'frame_angles',
      where: 'session_id = ? AND frame_index >= ? AND frame_index <= ?',
      whereArgs: [sessionId, startFrame, endFrame],
      orderBy: 'frame_index ASC',
    );
    return maps.map((map) => FrameAngle.fromMap(map)).toList();
  }

  // ============================================================================
  // Detected Actions CRUD Operations
  // ============================================================================

  /// Insert multiple detected actions in a batch
  Future<void> insertDetectedActions(List<DetectedAction> actions) async {
    if (actions.isEmpty) return;

    final db = await database;
    final batch = db.batch();

    for (final action in actions) {
      batch.insert('detected_actions', action.toMap());
    }

    await batch.commit(noResult: true);
    print('[DatabaseService] 📝 Inserted ${actions.length} detected actions');
  }

  /// Get all detected actions for a session, ordered by frame number
  Future<List<DetectedAction>> getSessionDetectedActions(int sessionId) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'detected_actions',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'frame_number ASC',
    );
    return maps.map((map) => DetectedAction.fromMap(map)).toList();
  }

  /// Get detected actions for a specific frame range
  Future<List<DetectedAction>> getActionsInFrameRange(int sessionId, int startFrame, int endFrame) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'detected_actions',
      where: 'session_id = ? AND frame_number >= ? AND frame_number <= ?',
      whereArgs: [sessionId, startFrame, endFrame],
      orderBy: 'frame_number ASC',
    );
    return maps.map((map) => DetectedAction.fromMap(map)).toList();
  }

  /// Get unique action types for a session
  Future<List<String>> getSessionActionTypes(int sessionId) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.rawQuery(
      'SELECT DISTINCT action FROM detected_actions WHERE session_id = ? ORDER BY action',
      [sessionId],
    );
    return maps.map((m) => m['action'] as String).toList();
  }

  /// Delete all detected actions for a session
  Future<int> deleteSessionDetectedActions(int sessionId) async {
    final db = await database;
    final count = await db.delete(
      'detected_actions',
      where: 'session_id = ?',
      whereArgs: [sessionId],
    );
    print('[DatabaseService] 🗑️ Deleted $count detected actions for session $sessionId');
    return count;;
  }

  // ============================================================================
  // Analytics Queries
  // ============================================================================

  /// Get angle statistics for a single session
  Future<List<AngleStats>> getSessionAngleStats(int sessionId) async {
    final db = await database;
    final stats = <AngleStats>[];

    for (int i = 0; i < FrameAngle.angleColumns.length; i++) {
      final column = FrameAngle.angleColumns[i];
      final name = FrameAngle.angleNames[i];

      final result = await db.rawQuery(
        '''
        SELECT 
          MIN($column) as min_val,
          MAX($column) as max_val,
          AVG($column) as avg_val,
          COUNT($column) as sample_count
        FROM frame_angles
        WHERE session_id = ? AND $column IS NOT NULL
      ''',
        [sessionId],
      );

      if (result.isNotEmpty) {
        final row = result.first;
        stats.add(
          AngleStats(
            angleName: name,
            angleColumn: column,
            min: row['min_val'] as double?,
            max: row['max_val'] as double?,
            avg: row['avg_val'] as double?,
            sampleCount: row['sample_count'] as int? ?? 0,
          ),
        );
      }
    }

    return stats;
  }

  /// Get max angles across all sessions (for progress tracking)
  /// Returns the maximum value achieved for each angle type
  Future<List<AngleStats>> getAllTimeMaxAngles() async {
    final db = await database;
    final stats = <AngleStats>[];

    for (int i = 0; i < FrameAngle.angleColumns.length; i++) {
      final column = FrameAngle.angleColumns[i];
      final name = FrameAngle.angleNames[i];

      final result = await db.rawQuery('''
        SELECT 
          MIN($column) as min_val,
          MAX($column) as max_val,
          AVG($column) as avg_val,
          COUNT($column) as sample_count
        FROM frame_angles
        WHERE $column IS NOT NULL
      ''');

      if (result.isNotEmpty) {
        final row = result.first;
        stats.add(
          AngleStats(
            angleName: name,
            angleColumn: column,
            min: row['min_val'] as double?,
            max: row['max_val'] as double?,
            avg: row['avg_val'] as double?,
            sampleCount: row['sample_count'] as int? ?? 0,
          ),
        );
      }
    }

    return stats;
  }

  /// Get max angle per session for trend analysis
  /// Returns a list of (session timestamp, max angle) pairs for charting
  Future<List<Map<String, dynamic>>> getAngleTrendBySession(String angleColumn) async {
    final db = await database;

    final result = await db.rawQuery('''
      SELECT 
        s.id as session_id,
        s.timestamp_utc,
        MAX(fa.$angleColumn) as max_angle
      FROM sessions s
      LEFT JOIN frame_angles fa ON s.id = fa.session_id
      WHERE fa.$angleColumn IS NOT NULL
      GROUP BY s.id
      ORDER BY s.timestamp_utc ASC
    ''');

    return result;
  }

  /// Get the Nth percentile angle value per session for progress tracking.
  ///
  /// [angleColumn] - The angle column to query (e.g., 'left_knee_flexion')
  /// [percentile] - Value between 0.0 and 1.0 (e.g., 0.9 for 90th percentile)
  ///
  /// Returns list of {session_id, timestamp_utc, percentile_value} maps.
  ///
  /// SQLite doesn't have built-in percentile functions, so we calculate it
  /// by ordering values and selecting at the appropriate offset.
  Future<List<Map<String, dynamic>>> getAnglePercentileBySession(String angleColumn, double percentile) async {
    final db = await database;

    // First get all sessions that have data for this angle
    final sessions = await db.rawQuery('''
      SELECT DISTINCT 
        s.id as session_id,
        s.timestamp_utc
      FROM sessions s
      INNER JOIN frame_angles fa ON s.id = fa.session_id
      WHERE fa.$angleColumn IS NOT NULL
      ORDER BY s.timestamp_utc ASC
    ''');

    final results = <Map<String, dynamic>>[];

    for (final session in sessions) {
      final sessionId = session['session_id'] as int;
      final timestampUtc = session['timestamp_utc'] as int;

      // Get all values for this session, ordered
      final values = await db.rawQuery(
        '''
        SELECT $angleColumn as value
        FROM frame_angles
        WHERE session_id = ? AND $angleColumn IS NOT NULL
        ORDER BY $angleColumn ${percentile >= 0.5 ? 'DESC' : 'ASC'}
      ''',
        [sessionId],
      );

      if (values.isEmpty) continue;

      // Calculate the index for the percentile
      // For 90th percentile with 100 values: index = (1 - 0.9) * 100 = 10 (10th from top when DESC)
      // For 10th percentile with 100 values: index = 0.1 * 100 = 10 (10th from bottom when ASC)
      final count = values.length;
      int index;
      if (percentile >= 0.5) {
        // High percentile: we sorted DESC, so calculate offset from start
        index = ((1 - percentile) * count).floor();
      } else {
        // Low percentile: we sorted ASC, so calculate offset from start
        index = (percentile * count).floor();
      }
      index = index.clamp(0, count - 1);

      final percentileValue = values[index]['value'] as double;

      results.add({'session_id': sessionId, 'timestamp_utc': timestampUtc, 'percentile_value': percentileValue});
    }

    return results;
  }

  // ============================================================================
  // Utility Methods
  // ============================================================================

  /// Get total number of sessions
  Future<int> getSessionCount() async {
    final db = await database;
    final result = await db.rawQuery('SELECT COUNT(*) as count FROM sessions');
    return result.first['count'] as int? ?? 0;
  }

  /// Clear all data (for testing/reset)
  Future<void> clearAllData() async {
    final db = await database;
    await db.delete('frame_angles');
    await db.delete('sessions');
    print('[DatabaseService] 🗑️ All data cleared');
  }

  /// Close the database connection
  Future<void> close() async {
    final db = await database;
    await db.close();
    _database = null;
    print('[DatabaseService] 🔒 Database closed');
  }
}
