import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

class StandaloneCoinConfig {
  const StandaloneCoinConfig({
    required this.onePesoMinutes,
    required this.fivePesoMinutes,
    required this.tenPesoMinutes,
    required this.twentyPesoMinutes,
  });

  final int onePesoMinutes;
  final int fivePesoMinutes;
  final int tenPesoMinutes;
  final int twentyPesoMinutes;
}

class StandaloneSalesSummary {
  const StandaloneSalesSummary({
    required this.total,
    required this.daily,
    required this.weekly,
    required this.monthly,
  });

  final int total;
  final int daily;
  final int weekly;
  final int monthly;
}

class StandaloneCoinSaleLog {
  const StandaloneCoinSaleLog({
    required this.id,
    required this.amount,
    required this.minutesAdded,
    required this.createdAt,
  });

  final int id;
  final int amount;
  final int minutesAdded;
  final DateTime createdAt;
}

class LocalDbService {
  LocalDbService._();

  static final LocalDbService instance = LocalDbService._();

  Database? _database;

  Future<Database> get database async {
    if (_database != null) {
      return _database!;
    }

    final databasesPath = await getDatabasesPath();
    final path = p.join(databasesPath, 'piso_stream_local.db');
    _database = await openDatabase(
      path,
      version: 2,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE standalone_config (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            one_peso_minutes INTEGER NOT NULL,
            five_peso_minutes INTEGER NOT NULL,
            ten_peso_minutes INTEGER NOT NULL,
            twenty_peso_minutes INTEGER NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE standalone_sales (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            amount INTEGER NOT NULL,
            minutes_added INTEGER NOT NULL,
            created_at INTEGER NOT NULL
          )
        ''');
        await db.insert('standalone_config', <String, Object>{
          'id': 1,
          'one_peso_minutes': 6,
          'five_peso_minutes': 30,
          'ten_peso_minutes': 60,
          'twenty_peso_minutes': 120,
        });
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('''
            ALTER TABLE standalone_config
            ADD COLUMN one_peso_minutes INTEGER NOT NULL DEFAULT 6
          ''');
          await db.execute('''
            ALTER TABLE standalone_config
            ADD COLUMN five_peso_minutes INTEGER NOT NULL DEFAULT 30
          ''');
          await db.execute('''
            ALTER TABLE standalone_config
            ADD COLUMN ten_peso_minutes INTEGER NOT NULL DEFAULT 60
          ''');
          await db.execute('''
            ALTER TABLE standalone_config
            ADD COLUMN twenty_peso_minutes INTEGER NOT NULL DEFAULT 120
          ''');
        }
      },
    );
    return _database!;
  }

  Future<StandaloneCoinConfig> getStandaloneCoinConfig() async {
    final db = await database;
    final rows = await db.query(
      'standalone_config',
      where: 'id = ?',
      whereArgs: const <Object>[1],
      limit: 1,
    );

    if (rows.isEmpty) {
      await saveStandaloneCoinConfig(
        onePesoMinutes: 6,
        fivePesoMinutes: 30,
        tenPesoMinutes: 60,
        twentyPesoMinutes: 120,
      );
      return const StandaloneCoinConfig(
        onePesoMinutes: 6,
        fivePesoMinutes: 30,
        tenPesoMinutes: 60,
        twentyPesoMinutes: 120,
      );
    }

    final row = rows.first;
    return StandaloneCoinConfig(
      onePesoMinutes: (row['one_peso_minutes'] as num?)?.toInt() ?? 6,
      fivePesoMinutes: (row['five_peso_minutes'] as num?)?.toInt() ?? 30,
      tenPesoMinutes: (row['ten_peso_minutes'] as num?)?.toInt() ?? 60,
      twentyPesoMinutes: (row['twenty_peso_minutes'] as num?)?.toInt() ?? 120,
    );
  }

  Future<void> saveStandaloneCoinConfig({
    required int onePesoMinutes,
    required int fivePesoMinutes,
    required int tenPesoMinutes,
    required int twentyPesoMinutes,
  }) async {
    final db = await database;
    await db.insert(
      'standalone_config',
      <String, Object>{
        'id': 1,
        'one_peso_minutes': onePesoMinutes,
        'five_peso_minutes': fivePesoMinutes,
        'ten_peso_minutes': tenPesoMinutes,
        'twenty_peso_minutes': twentyPesoMinutes,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<int> convertAmountToMinutes(int amount) async {
    final config = await getStandaloneCoinConfig();
    if (amount <= 0) {
      return 0;
    }
    switch (amount) {
      case 1:
        return config.onePesoMinutes;
      case 5:
        return config.fivePesoMinutes;
      case 10:
        return config.tenPesoMinutes;
      case 20:
        return config.twentyPesoMinutes;
      default:
        return 0;
    }
  }

  Future<void> recordStandaloneSale({
    required int amount,
    required int minutesAdded,
    int? createdAtMillis,
  }) async {
    final db = await database;
    await db.insert(
      'standalone_sales',
      <String, Object>{
        'amount': amount,
        'minutes_added': minutesAdded,
        'created_at': createdAtMillis ?? DateTime.now().millisecondsSinceEpoch,
      },
    );
  }

  Future<StandaloneSalesSummary> getStandaloneSalesSummary() async {
    final db = await database;
    final now = DateTime.now();
    final startOfDay = DateTime(now.year, now.month, now.day);
    final startOfWeek = startOfDay.subtract(Duration(days: startOfDay.weekday - 1));
    final startOfMonth = DateTime(now.year, now.month);

    Future<int> sumFrom(int? fromMillis) async {
      final result = await db.rawQuery(
        fromMillis == null
            ? 'SELECT COALESCE(SUM(amount), 0) AS total FROM standalone_sales'
            : 'SELECT COALESCE(SUM(amount), 0) AS total FROM standalone_sales WHERE created_at >= ?',
        fromMillis == null ? null : <Object>[fromMillis],
      );
      return (result.first['total'] as num?)?.toInt() ?? 0;
    }

    return StandaloneSalesSummary(
      total: await sumFrom(null),
      daily: await sumFrom(startOfDay.millisecondsSinceEpoch),
      weekly: await sumFrom(startOfWeek.millisecondsSinceEpoch),
      monthly: await sumFrom(startOfMonth.millisecondsSinceEpoch),
    );
  }

  Future<List<StandaloneCoinSaleLog>> getStandaloneSaleLogs({
    int limit = 300,
  }) async {
    final db = await database;
    final rows = await db.query(
      'standalone_sales',
      orderBy: 'created_at DESC',
      limit: limit,
    );

    return rows
        .map(
          (row) => StandaloneCoinSaleLog(
            id: (row['id'] as num?)?.toInt() ?? 0,
            amount: (row['amount'] as num?)?.toInt() ?? 0,
            minutesAdded: (row['minutes_added'] as num?)?.toInt() ?? 0,
            createdAt: DateTime.fromMillisecondsSinceEpoch(
              (row['created_at'] as num?)?.toInt() ?? 0,
            ),
          ),
        )
        .toList();
  }

  Future<void> resetStandaloneSales() async {
    final db = await database;
    await db.delete('standalone_sales');
  }
}
