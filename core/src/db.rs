//! Schema, migrations, settings, and the stock category taxonomy.
//! The schema matches the Node app's `server/db.mjs` exactly so both apps can share one file.

use std::path::Path;
use std::time::Duration;

use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};

use crate::error::Result;
use crate::models::AppSettings;

pub fn uid() -> String {
    uuid::Uuid::new_v4().to_string()
}

const SCHEMA: &str = r#"
CREATE TABLE IF NOT EXISTS accounts (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  institution TEXT DEFAULT '',
  type TEXT DEFAULT 'checking',
  balance_cents INTEGER DEFAULT 0,
  currency TEXT DEFAULT 'USD',
  color TEXT DEFAULT '#6d7cff',
  archived INTEGER DEFAULT 0,
  created_at TEXT DEFAULT (datetime('now'))
);
CREATE TABLE IF NOT EXISTS categories (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  kind TEXT DEFAULT 'expense',
  color TEXT DEFAULT '#6d7cff',
  icon TEXT DEFAULT 'folder',
  sort INTEGER DEFAULT 0,
  archived INTEGER DEFAULT 0
);
CREATE TABLE IF NOT EXISTS subcategories (
  id TEXT PRIMARY KEY,
  category_id TEXT NOT NULL REFERENCES categories(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  sort INTEGER DEFAULT 0,
  archived INTEGER DEFAULT 0
);
CREATE TABLE IF NOT EXISTS transactions (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  date TEXT NOT NULL,
  description TEXT NOT NULL,
  merchant TEXT DEFAULT '',
  amount_cents INTEGER NOT NULL,
  category_id TEXT REFERENCES categories(id) ON DELETE SET NULL,
  subcategory_id TEXT REFERENCES subcategories(id) ON DELETE SET NULL,
  notes TEXT DEFAULT '',
  is_transfer INTEGER DEFAULT 0,
  hash TEXT NOT NULL,
  import_batch_id TEXT,
  created_at TEXT DEFAULT (datetime('now'))
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_tx_hash ON transactions(hash);
CREATE INDEX IF NOT EXISTS idx_tx_date ON transactions(date);
CREATE INDEX IF NOT EXISTS idx_tx_cat ON transactions(category_id);
CREATE TABLE IF NOT EXISTS import_batches (
  id TEXT PRIMARY KEY,
  filename TEXT,
  account_id TEXT,
  imported_at TEXT DEFAULT (datetime('now')),
  row_count INTEGER,
  skipped INTEGER
);
CREATE TABLE IF NOT EXISTS rules (
  id TEXT PRIMARY KEY,
  priority INTEGER DEFAULT 100,
  enabled INTEGER DEFAULT 1,
  match TEXT DEFAULT 'contains',
  field TEXT DEFAULT 'description',
  pattern TEXT NOT NULL,
  category_id TEXT,
  subcategory_id TEXT
);
CREATE TABLE IF NOT EXISTS budgets (
  id TEXT PRIMARY KEY,
  category_id TEXT NOT NULL,
  subcategory_id TEXT,
  amount_cents INTEGER NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_budget_unique ON budgets(category_id, IFNULL(subcategory_id, ''));
CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT);
-- Native-app tables. The Node app ignores them, so the file stays compatible.
CREATE TABLE IF NOT EXISTS debts (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  lender TEXT DEFAULT '',
  kind TEXT DEFAULT 'loan',
  account_id TEXT,
  balance_source TEXT DEFAULT 'manual',
  balance_cents INTEGER DEFAULT 0,
  balance_as_of TEXT,
  original_cents INTEGER,
  apr REAL DEFAULT 0,
  payment_cents INTEGER DEFAULT 0,
  frequency TEXT DEFAULT 'monthly',
  next_due TEXT,
  payments_left INTEGER,
  match_key TEXT DEFAULT '',
  match_exact_amount INTEGER DEFAULT 1,
  notes TEXT DEFAULT '',
  archived INTEGER DEFAULT 0,
  sort INTEGER DEFAULT 0,
  created_at TEXT DEFAULT (datetime('now'))
);
CREATE TABLE IF NOT EXISTS recurring (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  kind TEXT DEFAULT 'bill',
  amount_cents INTEGER NOT NULL,
  frequency TEXT DEFAULT 'monthly',
  anchor_date TEXT NOT NULL,
  match_key TEXT DEFAULT '',
  match_exact_amount INTEGER DEFAULT 0,
  category_id TEXT,
  account_id TEXT,
  active INTEGER DEFAULT 1,
  notes TEXT DEFAULT '',
  created_at TEXT DEFAULT (datetime('now'))
);
CREATE TABLE IF NOT EXISTS investment_details (
  account_id TEXT PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
  account_label TEXT DEFAULT '',
  employer TEXT DEFAULT '',
  allocation TEXT DEFAULT '',
  contribution_pct REAL,
  employer_match TEXT DEFAULT '',
  account_last4 TEXT DEFAULT '',
  notes TEXT DEFAULT ''
);
CREATE TABLE IF NOT EXISTS balance_history (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  date TEXT NOT NULL,
  balance_cents INTEGER NOT NULL,
  note TEXT DEFAULT '',
  created_at TEXT DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_balance_history ON balance_history(account_id, date);
"#;

const MIGRATIONS: &[(&str, &str, &str)] = &[
    ("accounts", "balance_set", "ALTER TABLE accounts ADD COLUMN balance_set INTEGER DEFAULT 0"),
    ("accounts", "due_day", "ALTER TABLE accounts ADD COLUMN due_day INTEGER DEFAULT 0"),
    ("rules", "min_cents", "ALTER TABLE rules ADD COLUMN min_cents INTEGER"),
    ("rules", "max_cents", "ALTER TABLE rules ADD COLUMN max_cents INTEGER"),
    // Native app: count a transaction toward a different month ("YYYY-MM") in monthly reports.
    ("transactions", "report_month", "ALTER TABLE transactions ADD COLUMN report_month TEXT"),
    // Native app: parts of a split transaction share the original's id here.
    ("transactions", "split_of", "ALTER TABLE transactions ADD COLUMN split_of TEXT"),
];

fn has_column(conn: &Connection, table: &str, col: &str) -> Result<bool> {
    let mut st = conn.prepare(&format!("PRAGMA table_info({table})"))?;
    let names = st.query_map([], |r| r.get::<_, String>(1))?.collect::<std::result::Result<Vec<_>, _>>()?;
    Ok(names.iter().any(|n| n == col))
}

pub fn open(path: &str) -> Result<Connection> {
    if let Some(parent) = Path::new(path).parent() {
        if !parent.as_os_str().is_empty() {
            std::fs::create_dir_all(parent)?;
        }
    }
    let conn = Connection::open(path)?;
    conn.busy_timeout(Duration::from_secs(5))?;
    conn.query_row("PRAGMA journal_mode = WAL", [], |_| Ok(()))?;
    conn.execute_batch("PRAGMA foreign_keys = ON;")?;
    conn.execute_batch(SCHEMA)?;
    for (table, col, sql) in MIGRATIONS {
        if !has_column(&conn, table, col)? {
            conn.execute_batch(sql)?;
        }
    }
    // Only a brand-new, empty database gets the starter taxonomy.
    let n: i64 = conn.query_row("SELECT COUNT(*) FROM categories", [], |r| r.get(0))?;
    if n == 0 {
        upsert_defaults(&conn)?;
    }
    Ok(conn)
}

// ---------- settings (JSON under key 'app', same shape as the Node app; its `ai` object is not used here) ----------

fn default_settings_json() -> Value {
    json!({ "currency": "USD", "theme": "dark" })
}

fn raw_settings(conn: &Connection) -> Result<Value> {
    let raw: Option<String> = conn
        .query_row("SELECT value FROM settings WHERE key = 'app'", [], |r| r.get(0))
        .optional()?;
    let mut base = default_settings_json();
    if let Some(Ok(Value::Object(stored))) = raw.map(|s| serde_json::from_str::<Value>(&s)) {
        let obj = base.as_object_mut().unwrap();
        for (k, v) in stored {
            obj.insert(k, v);
        }
    }
    Ok(base)
}

/// Currency and theme come from the database. The AI fields are placeholders here: which
/// CLI to run is kept per machine (see `Ledger::set_ai_settings`), never read from a database
/// file, so opening someone else's file can't choose a command to run. The `ai` object the
/// Node app stores in this row is left alone.
pub fn get_settings(conn: &Connection) -> Result<AppSettings> {
    let v = raw_settings(conn)?;
    let s = |val: Option<&Value>, d: &str| val.and_then(|x| x.as_str()).unwrap_or(d).to_string();
    Ok(AppSettings {
        currency: s(v.get("currency"), "USD"),
        theme: s(v.get("theme"), "dark"),
        ai_provider: "claude".into(),
        ai_model: String::new(),
        ai_timeout_sec: 240,
    })
}

pub fn save_settings(conn: &Connection, s: &AppSettings) -> Result<AppSettings> {
    // Keep any keys this app doesn't know about.
    let mut v = raw_settings(conn)?;
    let obj = v.as_object_mut().unwrap();
    obj.insert("currency".into(), json!(s.currency));
    obj.insert("theme".into(), json!(s.theme));
    conn.execute(
        "INSERT INTO settings (key, value) VALUES ('app', ?1) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        params![serde_json::to_string(&v)?],
    )?;
    get_settings(conn)
}

// ---------- stock taxonomy ----------

struct DefaultCat {
    name: &'static str,
    kind: &'static str,
    color: &'static str,
    icon: &'static str,
    subs: &'static [&'static str],
}

const DEFAULT_CATEGORIES: &[DefaultCat] = &[
    DefaultCat { name: "Income", kind: "income", color: "#34d399", icon: "💰", subs: &["Paycheck", "Bonus", "Interest & Dividends", "Reimbursement", "Other Income"] },
    DefaultCat { name: "Housing", kind: "expense", color: "#f59e0b", icon: "🏠", subs: &["Rent / Mortgage", "Utilities", "Internet & Phone", "Home Maintenance"] },
    DefaultCat { name: "Groceries", kind: "expense", color: "#22c55e", icon: "🛒", subs: &["Supermarket", "Specialty Foods"] },
    DefaultCat { name: "Dining", kind: "expense", color: "#fb7185", icon: "🍔", subs: &["Restaurants", "Coffee", "Delivery & Takeout", "Bars"] },
    DefaultCat { name: "Transport", kind: "expense", color: "#38bdf8", icon: "🚗", subs: &["Gas & Fuel", "Car Payment", "Car Insurance", "Transit & Rideshare", "Parking"] },
    DefaultCat { name: "Health & Fitness", kind: "expense", color: "#a78bfa", icon: "💊", subs: &["Pharmacy", "Doctor & Dentist", "Gym & Fitness"] },
    DefaultCat { name: "Subscriptions", kind: "expense", color: "#f472b6", icon: "📺", subs: &["Streaming", "Software & Apps", "Memberships"] },
    DefaultCat { name: "Shopping", kind: "expense", color: "#fbbf24", icon: "🛍️", subs: &["Amazon & Online", "Clothing", "Electronics", "Home Goods"] },
    DefaultCat { name: "Entertainment", kind: "expense", color: "#2dd4bf", icon: "🎮", subs: &["Movies & Events", "Games", "Hobbies"] },
    DefaultCat { name: "Travel", kind: "expense", color: "#818cf8", icon: "✈️", subs: &["Flights", "Hotels & Stays", "Car Rental"] },
    DefaultCat { name: "Fees & Interest", kind: "expense", color: "#94a3b8", icon: "🏦", subs: &["Bank Fees", "Credit Card Interest", "ATM Fees"] },
    DefaultCat { name: "Savings & Investing", kind: "expense", color: "#34d399", icon: "📈", subs: &["Investments", "Emergency Fund", "Goals"] },
    DefaultCat { name: "Other", kind: "expense", color: "#64748b", icon: "❓", subs: &["Miscellaneous", "Gifts & Donations", "Education"] },
];

pub const PALETTE: &[&str] = &[
    "#6d7cff", "#22d3ee", "#34d399", "#fbbf24", "#fb7185", "#a78bfa", "#f472b6", "#38bdf8", "#f59e0b", "#2dd4bf", "#f43f5e", "#94a3b8",
];

/// Adds any missing stock categories/subcategories (matched by name, case-insensitive).
/// Only called on an empty database or when the user presses "Restore defaults".
pub fn upsert_defaults(conn: &Connection) -> Result<(u32, u32)> {
    let mut created = 0u32;
    let mut subs_created = 0u32;
    let mut cats: Vec<(String, String, i64)> = {
        let mut st = conn.prepare("SELECT id, name, sort FROM categories")?;
        let rows = st.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get::<_, Option<i64>>(2)?.unwrap_or(0))))?;
        rows.collect::<std::result::Result<_, _>>()?
    };
    let mut sort = cats.iter().map(|c| c.2).max().unwrap_or(-1);
    for d in DEFAULT_CATEGORIES {
        let found = cats.iter().find(|c| c.1.to_lowercase() == d.name.to_lowercase()).map(|c| c.0.clone());
        let cat_id = match found {
            Some(id) => id,
            None => {
                let id = uid();
                sort += 1;
                conn.execute(
                    "INSERT INTO categories (id, name, kind, color, icon, sort) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                    params![id, d.name, d.kind, d.color, d.icon, sort],
                )?;
                cats.push((id.clone(), d.name.to_string(), sort));
                created += 1;
                id
            }
        };
        let mut existing: Vec<String> = {
            let mut st = conn.prepare("SELECT name FROM subcategories WHERE category_id = ?1")?;
            let rows = st.query_map([&cat_id], |r| r.get::<_, String>(0))?;
            rows.map(|r| r.map(|s| s.to_lowercase())).collect::<std::result::Result<_, _>>()?
        };
        for s in d.subs {
            if existing.contains(&s.to_lowercase()) {
                continue;
            }
            conn.execute(
                "INSERT INTO subcategories (id, category_id, name, sort) VALUES (?1, ?2, ?3, ?4)",
                params![uid(), cat_id, s, existing.len() as i64],
            )?;
            existing.push(s.to_lowercase());
            subs_created += 1;
        }
    }
    Ok((created, subs_created))
}
