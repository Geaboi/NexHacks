import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import '../models/session.dart';
import '../models/frame_angle.dart';

/// SQLite database service for persistent storage of angle analysis data
class DatabaseService {
  static const String _databaseName = 'smartpt_angles.db';
  static const int _databaseVersion = 1;

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

    return await openDatabase(
      path,
      version: _databaseVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  /// Create database tables
  Future<void> _onCreate(Database db, int version) async {
    print('[DatabaseService] 🏗️ Creating database tables...');

    // Sessions table - stores recording session metadata
    await db.execute('''
      CREATE TABLE sessions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        timestamp_utc INTEGER NOT NULL,
        original_video_path TEXT,
        processed_video_path TEXT,
        duration_ms INTEGER,
        fps INTEGER,
        total_frames INTEGER,
        num_angles INTEGER,
        created_at TEXT NOT NULL
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

    print('[DatabaseService] ✅ Database tables created');
  }

  /// Handle database upgrades (for future schema changes)
  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    print('[DatabaseService] ⬆️ Upgrading database from v$oldVersion to v$newVersion');
    // Add migration logic here when schema changes
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
    final List<Map<String, dynamic>> maps = await db.query(
      'sessions',
      orderBy: 'timestamp_utc DESC',
      limit: limit,
    );
    return maps.map((map) => Session.fromMap(map)).toList();
  }

  /// Get a single session by ID
  Future<Session?> getSession(int id) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'sessions',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
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
  Future<List<FrameAngle>> getFrameRange(
    int sessionId,
    int startFrame,
    int endFrame,
  ) async {
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
  // Analytics Queries
  // ============================================================================

  /// Get angle statistics for a single session
  Future<List<AngleStats>> getSessionAngleStats(int sessionId) async {
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
        WHERE session_id = ? AND $column IS NOT NULL
      ''', [sessionId]);

      if (result.isNotEmpty) {
        final row = result.first;
        stats.add(AngleStats(
          angleName: name,
          min: row['min_val'] as double?,
          max: row['max_val'] as double?,
          avg: row['avg_val'] as double?,
          sampleCount: row['sample_count'] as int? ?? 0,
        ));
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
        stats.add(AngleStats(
          angleName: name,
          min: row['min_val'] as double?,
          max: row['max_val'] as double?,
          avg: row['avg_val'] as double?,
          sampleCount: row['sample_count'] as int? ?? 0,
        ));
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
        s.created_at,
        MAX(fa.$angleColumn) as max_angle
      FROM sessions s
      LEFT JOIN frame_angles fa ON s.id = fa.session_id
      WHERE fa.$angleColumn IS NOT NULL
      GROUP BY s.id
      ORDER BY s.timestamp_utc ASC
    ''');

    return result;
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
