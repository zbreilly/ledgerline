//! CSV import: preview, commit with duplicate detection, transfer detection,
//! rules, and merchant memory. Ported from the `/api/import/*` routes.

use std::collections::HashMap;
use std::sync::OnceLock;

use chrono::NaiveDate;
use regex::Regex;
use rusqlite::{params, Connection};
use sha1::{Digest, Sha1};

use crate::csv::{guess_mapping, normalize_date, parse_csv, to_cents};
use crate::db::uid;
use crate::memory::merchant_keys;
use crate::error::{err, Result};
use crate::models::{ColumnMapping, ImportBatch, ImportPreview, ImportRequest, ImportResult, PreviewRow};

/// Days apart a pending charge and its posted version can be.
const PENDING_WINDOW_DAYS: i64 = 4;

/// Chase shows not-yet-posted card purchases as "POS DEBIT <merchant> …".
pub fn is_pending_format(desc: &str) -> bool {
    desc.trim_start().to_uppercase().starts_with("POS DEBIT")
}

/// Card payments and account-to-account moves. These are excluded from every report.
pub fn transfer_regex() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| {
        Regex::new(r"(?i)(CAPITAL\s+ONE\s+MOBILE\s+P(Y)?MT|PAYMENT THANK YOU|AUTOPAY PAYMENT|ONLINE TRANSFER (TO|FROM)|CHASE CREDIT CRD|CARD PAYMENT)").unwrap()
    })
}

fn field_of(row: &[String], idx: Option<u32>) -> String {
    idx.and_then(|i| row.get(i as usize)).map(|s| s.trim().to_string()).unwrap_or_default()
}

/// The first row is a header unless its first non-empty cell parses as a date.
fn looks_like_header(first: &[String]) -> bool {
    let cell = first.iter().find(|c| !c.is_empty()).map(String::as_str).unwrap_or("");
    normalize_date(cell, "auto").is_none()
}

/// Amount column if present; otherwise credit minus debit (debits are money out).
fn row_cents(row: &[String], m: &ColumnMapping, invert: bool) -> Option<i64> {
    if let Some(c) = to_cents(&field_of(row, m.amount), invert) {
        return Some(c);
    }
    let d = to_cents(&field_of(row, m.debit), invert);
    let c = to_cents(&field_of(row, m.credit), invert);
    if d.is_some() || c.is_some() {
        Some(c.unwrap_or(0).abs() - d.unwrap_or(0).abs())
    } else {
        None
    }
}

/// Same hash as the Node app, so rows imported by either app dedupe against each other.
pub fn tx_hash(account_id: &str, date: &str, cents: i64, description: &str) -> String {
    static NON_ALNUM: OnceLock<Regex> = OnceLock::new();
    let re = NON_ALNUM.get_or_init(|| Regex::new(r"[^a-z0-9]+").unwrap());
    let lower = description.to_lowercase();
    let norm = re.replace_all(&lower, " ");
    let input = format!("{account_id}|{date}|{cents}|{}", norm.trim());
    let digest = Sha1::digest(input.as_bytes());
    digest.iter().map(|b| format!("{b:02x}")).collect()
}

/// The account balance after the newest row, from a running-balance column.
/// Works for newest-first (Chase) and oldest-first files. Rows newer than the newest row
/// that has a balance (e.g. pending items with a blank balance) are added on top.
pub fn latest_balance(data: &[Vec<String>], m: &ColumnMapping, date_format: &str, invert: bool) -> Option<(String, i64)> {
    m.balance?;
    let dated: Vec<(String, &Vec<String>)> =
        data.iter().filter_map(|r| normalize_date(&field_of(r, m.date), date_format).map(|d| (d, r))).collect();
    let (first, last) = (dated.first()?, dated.last()?);
    let newest_first = first.0 >= last.0;
    let ordered: Vec<&(String, &Vec<String>)> = if newest_first { dated.iter().collect() } else { dated.iter().rev().collect() };
    let newest_date = ordered.first()?.0.clone();
    let mut pending = 0i64;
    for (_, r) in ordered {
        if let Some(b) = to_cents(&field_of(r, m.balance), false) {
            return Some((newest_date, b + pending));
        }
        pending += row_cents(r, m, invert).unwrap_or(0);
    }
    None
}

pub fn preview(text: &str, mapping: Option<ColumnMapping>, date_format: &str) -> Result<ImportPreview> {
    let rows = parse_csv(text);
    if rows.is_empty() {
        return err("No rows found in file");
    }
    let has_header = looks_like_header(&rows[0]);
    let headers: Vec<String> = if has_header {
        rows[0].clone()
    } else {
        (1..=rows[0].len()).map(|i| format!("Column {i}")).collect()
    };
    let mapping = mapping.unwrap_or_else(|| guess_mapping(&headers));
    let data = if has_header { &rows[1..] } else { &rows[..] };
    let sample = data
        .iter()
        .take(40)
        .enumerate()
        .map(|(i, r)| PreviewRow {
            line: (i + if has_header { 2 } else { 1 }) as u32,
            date: field_of(r, mapping.date),
            description: field_of(r, mapping.description),
            merchant: field_of(r, mapping.merchant),
            amount: field_of(r, mapping.amount),
            debit: field_of(r, mapping.debit),
            credit: field_of(r, mapping.credit),
            notes: field_of(r, mapping.notes),
            parsed_date: normalize_date(&field_of(r, mapping.date), date_format),
            parsed_cents: row_cents(r, &mapping, false),
        })
        .collect();
    Ok(ImportPreview { headers, mapping, total: data.len() as u32, sample, has_header })
}

pub fn commit(conn: &Connection, req: &ImportRequest) -> Result<ImportResult> {
    let rows = parse_csv(&req.text);
    if rows.is_empty() {
        return err("No rows found in file");
    }
    let account_id = match (&req.account_id, &req.new_account) {
        (Some(id), _) if !id.is_empty() => id.clone(),
        (_, Some(na)) if !na.name.trim().is_empty() => {
            let id = uid();
            let kind = if na.kind.is_empty() { "checking" } else { na.kind.as_str() };
            let color = if na.color.is_empty() { "#6d7cff" } else { na.color.as_str() };
            conn.execute(
                "INSERT INTO accounts (id, name, institution, type, balance_cents, color, due_day) VALUES (?1, ?2, ?3, ?4, 0, ?5, ?6)",
                params![id, na.name.trim(), na.institution, kind, color, na.due_day.min(31)],
            )?;
            id
        }
        _ => return err("Select an account or create a new one"),
    };

    let has_header = looks_like_header(&rows[0]);
    let data = if has_header { &rows[1..] } else { &rows[..] };
    let m = &req.mapping;
    let date_format = if req.date_format.is_empty() { "auto" } else { req.date_format.as_str() };

    // Existing date+amount counts for this account catch re-imported rows whose
    // description format changed between exports.
    let mut existing: HashMap<(String, i64), u32> = HashMap::new();
    // Existing rows for the pending/posted check: (date, cents, merchant key, pending format, used).
    let mut on_file: Vec<(NaiveDate, i64, String, bool, bool)> = vec![];
    {
        let mut st = conn.prepare("SELECT date, amount_cents, description FROM transactions WHERE account_id = ?1")?;
        let mut q = st.query([&account_id])?;
        while let Some(r) = q.next()? {
            let (date, cents, desc): (String, i64, String) = (r.get(0)?, r.get(1)?, r.get(2)?);
            if let Ok(d) = NaiveDate::parse_from_str(&date, "%Y-%m-%d") {
                on_file.push((d, cents, merchant_keys(&desc).0, is_pending_format(&desc), false));
            }
            *existing.entry((date, cents)).or_insert(0) += 1;
        }
    }
    let mut pending_duplicates_skipped = 0u32;

    // Newest date already on the account, so an older file never overwrites a newer balance.
    let (kind, prior_newest): (Option<String>, Option<String>) = conn.query_row(
        "SELECT a.type, (SELECT MAX(date) FROM transactions t WHERE t.account_id = a.id) FROM accounts a WHERE a.id = ?1",
        [&account_id],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )?;
    let batch_id = uid();
    let mut imported = 0u32;
    let mut skipped = 0u32;
    let mut errors = Vec::new();
    let tx = conn.unchecked_transaction()?;
    {
        let mut ins = tx.prepare(
            "INSERT INTO transactions (id, account_id, date, description, merchant, amount_cents, notes, hash, import_batch_id)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
        )?;
        for (i, r) in data.iter().enumerate() {
            let line = i + if has_header { 2 } else { 1 };
            let date = normalize_date(&field_of(r, m.date), date_format);
            let mut description = field_of(r, m.description);
            if description.is_empty() {
                description = field_of(r, m.merchant);
            }
            if description.is_empty() {
                description = "Unknown".into();
            }
            let cents = row_cents(r, m, req.invert);
            let (Some(date), Some(cents)) = (date.clone(), cents) else {
                if errors.len() < 10 {
                    errors.push(format!("Line {line}: {}", if date.is_none() { "bad date" } else { "bad amount" }));
                }
                continue;
            };
            let key = (date.clone(), cents);
            if req.skip_duplicates {
                if let Some(n) = existing.get_mut(&key) {
                    if *n > 0 {
                        *n -= 1;
                        skipped += 1;
                        // That existing row is accounted for; don't let it absorb another row below.
                        if let Some(e) = on_file.iter_mut().find(|e| !e.4 && e.1 == cents && e.0.format("%Y-%m-%d").to_string() == date) {
                            e.4 = true;
                        }
                        continue;
                    }
                }
                // The same purchase seen twice: once pending ("POS DEBIT …", one date) and once
                // posted (a few days later, different text). Same account, amount, and merchant.
                if let Ok(d) = NaiveDate::parse_from_str(&date, "%Y-%m-%d") {
                    let new_key = merchant_keys(&description).0;
                    let new_pending = is_pending_format(&description);
                    if let Some(e) = on_file.iter_mut().find(|e| {
                        !e.4 && e.1 == cents && !new_key.is_empty() && e.2 == new_key
                            && (e.3 || new_pending) && (e.0 - d).num_days().abs() <= PENDING_WINDOW_DAYS
                    }) {
                        e.4 = true;
                        skipped += 1;
                        pending_duplicates_skipped += 1;
                        continue;
                    }
                }
            }
            let hash = tx_hash(&account_id, &date, cents, &description);
            match ins.execute(params![
                uid(), account_id, date, description, field_of(r, m.merchant), cents, field_of(r, m.notes), hash, batch_id
            ]) {
                Ok(_) => imported += 1,
                Err(_) => skipped += 1,
            }
        }
        tx.execute(
            "INSERT INTO import_batches (id, filename, account_id, row_count, skipped) VALUES (?1, ?2, ?3, ?4, ?5)",
            params![batch_id, if req.filename.is_empty() { "paste" } else { req.filename.as_str() }, account_id, imported, skipped],
        )?;
    }
    tx.commit()?;

    let rules_applied = if req.apply_rules { crate::rules::apply(conn, false)? } else { 0 };

    let mut transfers_marked = 0u32;
    {
        let batch_rows: Vec<(String, String)> = {
            let mut st = conn.prepare("SELECT id, description FROM transactions WHERE import_batch_id = ?1")?;
            let rows = st.query_map([&batch_id], |r| Ok((r.get(0)?, r.get(1)?)))?;
            rows.collect::<std::result::Result<_, _>>()?
        };
        let re = transfer_regex();
        let tx = conn.unchecked_transaction()?;
        for (id, _) in batch_rows.iter().filter(|(_, d)| re.is_match(d)) {
            tx.execute("UPDATE transactions SET is_transfer = 1 WHERE id = ?1", [id])?;
            transfers_marked += 1;
        }
        tx.commit()?;
    }

    let remembered = crate::memory::apply(conn, Some(&batch_id))?;

    // Running-balance column on a cash account: that's the real balance, so use it.
    let mut balance_updated_cents = None;
    let mut balance_as_of = None;
    let is_cash = matches!(kind.as_deref(), Some("checking") | Some("savings") | Some("cash"));
    if is_cash {
        if let Some((date, cents)) = latest_balance(data, m, date_format, req.invert) {
            if prior_newest.as_deref().map(|p| date.as_str() >= p).unwrap_or(true) {
                conn.execute("UPDATE accounts SET balance_cents = ?1, balance_set = 1 WHERE id = ?2", params![cents, account_id])?;
                balance_updated_cents = Some(cents);
                balance_as_of = Some(date);
            }
        }
    }
    Ok(ImportResult {
        batch_id,
        account_id,
        imported,
        skipped,
        errors,
        rules_applied,
        transfers_marked,
        remembered,
        pending_duplicates_skipped,
        balance_updated_cents,
        balance_as_of,
    })
}

pub fn list_batches(conn: &Connection) -> Result<Vec<ImportBatch>> {
    let mut st = conn.prepare(
        "SELECT b.id, b.filename, b.account_id, a.name, b.imported_at, b.row_count, b.skipped,
           (SELECT COUNT(*) FROM transactions t WHERE t.import_batch_id = b.id)
         FROM import_batches b LEFT JOIN accounts a ON a.id = b.account_id ORDER BY b.imported_at DESC LIMIT 50",
    )?;
    let rows = st
        .query_map([], |r| {
            Ok(ImportBatch {
                id: r.get(0)?,
                filename: r.get::<_, Option<String>>(1)?.unwrap_or_default(),
                account_id: r.get(2)?,
                account_name: r.get(3)?,
                imported_at: r.get::<_, Option<String>>(4)?.unwrap_or_default(),
                row_count: r.get::<_, Option<i64>>(5)?.unwrap_or(0) as u32,
                skipped: r.get::<_, Option<i64>>(6)?.unwrap_or(0) as u32,
                tx_count: r.get::<_, i64>(7)? as u32,
            })
        })?
        .collect::<std::result::Result<_, _>>()?;
    Ok(rows)
}

pub fn delete_batch(conn: &Connection, id: &str) -> Result<u32> {
    let tx = conn.unchecked_transaction()?;
    let n = tx.execute("DELETE FROM transactions WHERE import_batch_id = ?1", [id])?;
    tx.execute("DELETE FROM import_batches WHERE id = ?1", [id])?;
    tx.commit()?;
    Ok(n as u32)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn transfers() {
        let re = transfer_regex();
        assert!(re.is_match("CAPITAL ONE MOBILE PYMT"));
        assert!(re.is_match("Capital One Mobile Pmt"));
        assert!(re.is_match("Online Transfer to SAV ...1234"));
        assert!(!re.is_match("ALDI INC SPRINGFIELD IL"));
    }

    #[test]
    fn capital_one_debit_is_negative() {
        let m = ColumnMapping { debit: Some(0), credit: Some(1), ..Default::default() };
        let row = |a: &str, b: &str| vec![a.to_string(), b.to_string()];
        assert_eq!(row_cents(&row("18.75", ""), &m, false), Some(-1875));
        assert_eq!(row_cents(&row("", "50.00"), &m, false), Some(5000));
        assert_eq!(row_cents(&row("", ""), &m, false), None);
    }

    #[test]
    fn running_balance_newest_first_with_pending_rows() {
        let csv = "Details,Posting Date,Description,Amount,Type,Balance\n\
            DEBIT,10/26/2026,TO CHK,-100.00,ACCT_XFER, \n\
            DEBIT,10/26/2026,TO CHK,-150.00,ACCT_XFER, \n\
            DEBIT,10/23/2026,TO CHK,-50.00,ACCT_XFER,1550.00\n\
            CREDIT,10/15/2026,FROM CHK,1600.00,ACCT_XFER,1600.00\n";
        let rows = parse_csv(csv);
        let m = guess_mapping(&rows[0]);
        assert_eq!(latest_balance(&rows[1..], &m, "auto", false), Some(("2026-10-26".into(), 130_000)));
        // Oldest-first files take the last row's balance.
        let asc = "Date,Description,Amount,Balance\n2026-10-01,a,-5.00,95.00\n2026-10-02,b,-10.00,85.00\n";
        let rows = parse_csv(asc);
        let m = guess_mapping(&rows[0]);
        assert_eq!(latest_balance(&rows[1..], &m, "auto", false), Some(("2026-10-02".into(), 8_500)));
    }

    #[test]
    fn pending_then_posted_is_skipped_but_other_merchants_are_not() {
        use crate::models::*;
        let dir = tempfile::tempdir().unwrap();
        let l = crate::Ledger::open(dir.path().join("t.db").to_str().unwrap().into()).unwrap();
        let acct = l.create_account(NewAccount { name: "Chk".into(), institution: String::new(), kind: "checking".into(), balance_cents: 0, color: String::new(), due_day: 0 }).unwrap();
        let import = |text: &str| {
            let p = l.preview_import(text.into(), None, "auto".into()).unwrap();
            l.commit_import(ImportRequest {
                text: text.into(), filename: "x.csv".into(), account_id: Some(acct.clone()), new_account: None, mapping: p.mapping,
                date_format: "auto".into(), invert: false, skip_duplicates: true, apply_rules: false,
            })
            .unwrap()
        };
        // First export, while still pending.
        let r = import("Date,Description,Amount\n\
            2026-09-26,POS DEBIT SHOPWELL STORE #114 SPRINGFIELD IL,-152.30\n\
            2026-09-26,POS DEBIT CASH APP*JORDAN cash.app TX 5550,-4.00\n\
            2026-09-28,POS DEBIT GASMART 10234 SPRINGFIELD IL,-40.00\n");
        assert_eq!(r.imported, 3);
        // Next export, after posting: new dates and descriptions.
        let r = import("Date,Description,Amount\n\
            2026-09-28,SHOPWELL STORE #114 SPRINGFIELD IL 09/24,-152.30\n\
            2026-09-28,CASH APP*JORDAN cash.app TX 09/26,-4.00\n\
            2026-09-24,SHOPWELL STORE #114 SPRINGFIELD IL 09/23,-40.00\n\
            2026-10-10,SHOPWELL STORE #114 SPRINGFIELD IL 10/09,-152.30\n");
        // Shopwell $152.30 and Cash App $4 are the same purchases; the $40 Shopwell is a different
        // merchant from the $40 Gasmart; the Oct 10 Shopwell is too far apart to be the same.
        assert_eq!(r.pending_duplicates_skipped, 2);
        assert_eq!(r.imported, 2);
        // Re-importing the posted file changes nothing.
        let r = import("Date,Description,Amount\n2026-09-28,SHOPWELL STORE #114 SPRINGFIELD IL 09/24,-152.30\n");
        assert_eq!(r.imported, 0);
    }

    #[test]
    fn hash_is_stable() {
        // Same normalization as the Node app: lowercase, non-alphanumerics collapse to one space.
        assert_eq!(tx_hash("a", "2026-01-01", -100, "Foo*Bar  9"), tx_hash("a", "2026-01-01", -100, "foo bar 9"));
    }
}
