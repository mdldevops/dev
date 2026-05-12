const path = require('path');
const crypto = require('crypto');
const sqlite3 = require('sqlite3').verbose();

const db = new sqlite3.Database(path.join(__dirname, '..', '..', 'kiosk.db'));

function hashPassword(password) {
  return crypto.createHash('sha256').update(password).digest('hex');
}

db.serialize(() => {
  db.run(`
    CREATE TABLE IF NOT EXISTS customer_accounts (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      username TEXT NOT NULL UNIQUE,
      password_hash TEXT NOT NULL,
      role TEXT NOT NULL DEFAULT 'customer',
      account_status TEXT NOT NULL DEFAULT 'active',
      saved_session_seconds INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
      updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
  `);

  db.run(`
    CREATE TABLE IF NOT EXISTS coin_insert_logs (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      device_id TEXT NOT NULL,
      coin_value REAL NOT NULL,
      credited_minutes INTEGER NOT NULL,
      source TEXT NOT NULL DEFAULT 'system',
      created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
  `);

  db.run(`
    CREATE TABLE IF NOT EXISTS admin_settings (
      id INTEGER PRIMARY KEY CHECK (id = 1),
      pin TEXT NOT NULL,
      updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
  `);

  db.run(`
    INSERT OR IGNORE INTO admin_settings (id, pin)
    VALUES (1, '123456')
  `);

  db.run(`
    CREATE TABLE IF NOT EXISTS coin_settings (
      id INTEGER PRIMARY KEY CHECK (id = 1),
      p1_minutes INTEGER NOT NULL DEFAULT 6,
      p5_minutes INTEGER NOT NULL DEFAULT 30,
      p10_minutes INTEGER NOT NULL DEFAULT 60,
      p20_minutes INTEGER NOT NULL DEFAULT 120,
      updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
  `);

  db.run(`
    INSERT OR IGNORE INTO coin_settings (
      id,
      p1_minutes,
      p5_minutes,
      p10_minutes,
      p20_minutes
    )
    VALUES (1, 6, 30, 60, 120)
  `);

  db.run(`
    CREATE TABLE IF NOT EXISTS charging_settings (
      id INTEGER PRIMARY KEY CHECK (id = 1),
      start_below_percent INTEGER NOT NULL DEFAULT 30,
      stop_at_percent INTEGER NOT NULL DEFAULT 80,
      updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
  `);

  db.run(`
    INSERT OR IGNORE INTO charging_settings (
      id,
      start_below_percent,
      stop_at_percent
    )
    VALUES (1, 30, 80)
  `);

  db.run(`
    CREATE TABLE IF NOT EXISTS known_devices (
      device_id TEXT PRIMARY KEY,
      device_name TEXT NOT NULL,
      is_locked INTEGER NOT NULL DEFAULT 0,
      last_seen TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
      last_ip_address TEXT NOT NULL DEFAULT ''
    )
  `);

  db.run(`
    CREATE TABLE IF NOT EXISTS audio_settings (
      id INTEGER PRIMARY KEY CHECK (id = 1),
      audio_enabled INTEGER NOT NULL DEFAULT 0,
      audio_url TEXT,
      audio_loop INTEGER NOT NULL DEFAULT 1,
      audio_volume REAL NOT NULL DEFAULT 1.0,
      updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
  `);

  db.run(`
    INSERT OR IGNORE INTO audio_settings (id, audio_enabled, audio_url, audio_loop, audio_volume)
    VALUES (1, 0, NULL, 1, 1.0)
  `);

  db.run(`
    CREATE TABLE IF NOT EXISTS esp32_coin_transactions (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      device_id TEXT NOT NULL,
      tx_id TEXT NOT NULL,
      amount REAL NOT NULL,
      credited_minutes INTEGER NOT NULL,
      source TEXT NOT NULL DEFAULT 'esp32',
      created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
      UNIQUE(device_id, tx_id)
    )
  `);

  db.all(`PRAGMA table_info(customer_accounts)`, (error, rows) => {
    if (error) {
      console.error('PRAGMA customer_accounts failed', error);
      return;
    }

    const hasRoleColumn = rows.some((row) => row.name === 'role');
    const hasAccountStatusColumn = rows.some(
      (row) => row.name === 'account_status',
    );
    if (!hasRoleColumn) {
      db.run(
        `
          ALTER TABLE customer_accounts
          ADD COLUMN role TEXT NOT NULL DEFAULT 'customer'
        `,
        (alterError) => {
          if (alterError) {
            console.error('ALTER customer_accounts role failed', alterError);
          }
        },
      );
    }

    if (!hasAccountStatusColumn) {
      db.run(
        `
          ALTER TABLE customer_accounts
          ADD COLUMN account_status TEXT NOT NULL DEFAULT 'active'
        `,
        (alterError) => {
          if (alterError) {
            console.error(
              'ALTER customer_accounts account_status failed',
              alterError,
            );
          }
        },
      );
    }

    db.run(
      `
        INSERT OR IGNORE INTO customer_accounts (
          username,
          password_hash,
          role,
          saved_session_seconds
        )
        VALUES (?, ?, 'admin', 0)
      `,
      ['admin', hashPassword('admin1234')],
      (seedError) => {
        if (seedError) {
          console.error('Seed admin account failed', seedError);
        }
      },
    );

    db.run(
      `
        UPDATE customer_accounts
        SET
          password_hash = ?,
          role = 'admin',
          account_status = 'active',
          updated_at = CURRENT_TIMESTAMP
        WHERE username = 'admin'
      `,
      [hashPassword('admin1234')],
      (updateError) => {
        if (updateError) {
          console.error('Normalize admin account failed', updateError);
        }
      },
    );
  });

  db.all(`PRAGMA table_info(known_devices)`, (error, rows) => {
    if (error) {
      console.error('PRAGMA known_devices failed', error);
      return;
    }

    const hasLockedColumn = rows.some((row) => row.name === 'is_locked');
    if (!hasLockedColumn) {
      db.run(
        `
          ALTER TABLE known_devices
          ADD COLUMN is_locked INTEGER NOT NULL DEFAULT 0
        `,
        (alterError) => {
          if (alterError) {
            console.error('ALTER known_devices is_locked failed', alterError);
          }
        },
      );
    }
  });
});

module.exports = db;
