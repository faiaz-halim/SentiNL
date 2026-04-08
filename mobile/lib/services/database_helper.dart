import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;

  DatabaseHelper._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('sentinl.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, filePath);

    return await openDatabase(
      path,
      version: 1,
      onCreate: _createDB,
    );
  }

  Future<void> _createDB(Database db, int version) async {
    await db.execute('''
      CREATE TABLE BlacklistedUrls (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        url TEXT NOT NULL UNIQUE,
        threat_level TEXT NOT NULL,
        description TEXT,
        created_at INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE ScamPatterns (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        pattern TEXT NOT NULL UNIQUE,
        pattern_type TEXT NOT NULL,
        threat_level TEXT NOT NULL,
        description TEXT,
        created_at INTEGER NOT NULL
      )
    ''');
  }

  Future<int> insertBlacklistedUrl(Map<String, dynamic> url) async {
    final db = await database;
    return await db.insert(
      'BlacklistedUrls',
      url,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<int> insertScamPattern(Map<String, dynamic> pattern) async {
    final db = await database;
    return await db.insert(
      'ScamPatterns',
      pattern,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<bool> checkIfUrlMalicious(String url) async {
    final db = await database;
    final result = await db.query(
      'BlacklistedUrls',
      where: 'url LIKE ?',
      whereArgs: ['%$url%'],
      limit: 1,
    );
    return result.isNotEmpty;
  }

  Future<bool> checkIfPatternMalicious(String text) async {
    final db = await database;
    final patterns = await db.query('ScamPatterns');

    for (final pattern in patterns) {
      final patternText = pattern['pattern'] as String;
      if (text.toLowerCase().contains(patternText.toLowerCase())) {
        return true;
      }
    }
    return false;
  }

  Future<List<Map<String, dynamic>>> getAllBlacklistedUrls() async {
    final db = await database;
    return await db.query('BlacklistedUrls');
  }

  Future<List<Map<String, dynamic>>> getAllScamPatterns() async {
    final db = await database;
    return await db.query('ScamPatterns');
  }

  Future<int> getDbVersion() async {
    final db = await database;
    final result =
        await db.rawQuery('SELECT MAX(id) as version FROM BlacklistedUrls');
    return (result.first['version'] as int?) ?? 0;
  }

  Future<void> close() async {
    final db = await database;
    db.close();
  }
}
