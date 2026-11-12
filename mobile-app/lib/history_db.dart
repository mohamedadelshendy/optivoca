import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

enum TransferStatus {
  sending,
  sent,
  failed,
}

class TransferHistoryItem {
  final int? id;
  final String filename;
  final String filePath;
  final int fileSizeBytes;
  final int timestampMs;
  final TransferStatus status;
  final int durationMs;
  final String? targetDevice;
  final String? errorMessage;

  const TransferHistoryItem({
    this.id,
    required this.filename,
    required this.filePath,
    required this.fileSizeBytes,
    required this.timestampMs,
    required this.status,
    required this.durationMs,
    this.targetDevice,
    this.errorMessage,
  });

  TransferHistoryItem copyWith({
    int? id,
    String? filename,
    String? filePath,
    int? fileSizeBytes,
    int? timestampMs,
    TransferStatus? status,
    int? durationMs,
    String? targetDevice,
    String? errorMessage,
  }) {
    return TransferHistoryItem(
      id: id ?? this.id,
      filename: filename ?? this.filename,
      filePath: filePath ?? this.filePath,
      fileSizeBytes: fileSizeBytes ?? this.fileSizeBytes,
      timestampMs: timestampMs ?? this.timestampMs,
      status: status ?? this.status,
      durationMs: durationMs ?? this.durationMs,
      targetDevice: targetDevice ?? this.targetDevice,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'filename': filename,
      'file_path': filePath,
      'file_size_bytes': fileSizeBytes,
      'timestamp_ms': timestampMs,
      'status': status.name,
      'duration_ms': durationMs,
      'target_device': targetDevice,
      'error_message': errorMessage,
    };
  }

  factory TransferHistoryItem.fromMap(Map<String, dynamic> map) {
    final statusStr = map['status'] as String? ?? 'failed';
    final status = TransferStatus.values.firstWhere(
      (e) => e.name == statusStr,
      orElse: () => TransferStatus.failed,
    );

    return TransferHistoryItem(
      id: map['id'] as int?,
      filename: map['filename'] as String,
      filePath: map['file_path'] as String,
      fileSizeBytes: (map['file_size_bytes'] as num?)?.toInt() ?? 0,
      timestampMs: (map['timestamp_ms'] as num?)?.toInt() ?? 0,
      status: status,
      durationMs: (map['duration_ms'] as num?)?.toInt() ?? 0,
      targetDevice: map['target_device'] as String?,
      errorMessage: map['error_message'] as String?,
    );
  }

  /// Human-readable file size (e.g. `2.4 MB` or `840 KB`).
  String get formattedSize {
    if (fileSizeBytes >= 1024 * 1024) {
      final mb = fileSizeBytes / (1024.0 * 1024.0);
      return '${mb.toStringAsFixed(1)} MB';
    } else if (fileSizeBytes >= 1024) {
      final kb = fileSizeBytes / 1024.0;
      return '${kb.toStringAsFixed(0)} KB';
    }
    return '$fileSizeBytes B';
  }

  /// Throughput calculation in MB/s when sent.
  String get formattedThroughput {
    if (durationMs <= 0 || fileSizeBytes <= 0) return '';
    final seconds = durationMs / 1000.0;
    final mb = fileSizeBytes / (1024.0 * 1024.0);
    final mbps = mb / seconds;
    return '${mbps.toStringAsFixed(1)} MB/s';
  }
}

/// SQLite persistence layer (`sqflite`) for local transfer history.
class HistoryDatabase {
  static final HistoryDatabase instance = HistoryDatabase._internal();
  HistoryDatabase._internal();

  static const String _dbName = 'instant_drop_history.db';
  static const String _tableName = 'transfer_history';
  Database? _db;

  Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _initDatabase();
    return _db!;
  }

  Future<Database> _initDatabase() async {
    final dbFolder = await getDatabasesPath();
    final path = p.join(dbFolder, _dbName);

    return openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE $_tableName (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            filename TEXT NOT NULL,
            file_path TEXT NOT NULL,
            file_size_bytes INTEGER NOT NULL,
            timestamp_ms INTEGER NOT NULL,
            status TEXT NOT NULL,
            duration_ms INTEGER NOT NULL,
            target_device TEXT,
            error_message TEXT
          )
        ''');
        await db.execute(
          'CREATE INDEX idx_timestamp ON $_tableName (timestamp_ms DESC)',
        );
      },
    );
  }

  Future<TransferHistoryItem> insertRecord(TransferHistoryItem item) async {
    final db = await database;
    final id = await db.insert(
      _tableName,
      item.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    return item.copyWith(id: id);
  }

  Future<void> updateRecord(TransferHistoryItem item) async {
    if (item.id == null) return;
    final db = await database;
    await db.update(
      _tableName,
      item.toMap(),
      where: 'id = ?',
      whereArgs: [item.id],
    );
  }

  Future<void> deleteRecord(int id) async {
    final db = await database;
    await db.delete(
      _tableName,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> clearAllHistory() async {
    final db = await database;
    await db.delete(_tableName);
  }

  Future<List<TransferHistoryItem>> fetchAllHistory() async {
    final db = await database;
    final rows = await db.query(
      _tableName,
      orderBy: 'timestamp_ms DESC, id DESC',
    );
    return rows.map(TransferHistoryItem.fromMap).toList();
  }
}

