//! Recurring income (paychecks) and bills: storage and suggestions from history.

use std::collections::HashMap;

use chrono::NaiveDate;
use rusqlite::{params, Connection};

use crate::db::uid;
use crate::error::{err, Result};
use crate::models::{Recurring, RecurringInput, RecurringSuggestion};
use crate::schedule::*;

const SELECT: &str = "SELECT r.id, r.name, r.kind, r.amount_cents, r.frequency, r.anchor_date, r.match_key, r.match_exact_amount,
    r.category_id, r.account_id, r.active, r.notes, c.name, a.name, a.type
  FROM recurring r LEFT JOIN categories c ON c.id = r.category_id LEFT JOIN accounts a ON a.id = r.account_id";

/// Credit cards, loans, and investment accounts don't move checking; everything else (or no account) does.
pub fn account_affects_cash(kind: Option<&str>) -> bool {
    !matches!(kind, Some("credit") | Some("loan") | Some("brokerage") | Some("retirement") | Some("hsa"))
}

pub fn list(conn: &Connection, today: NaiveDate) -> Result<Vec<Recurring>> {
    let txs = load_txs(conn)?;
    list_with(conn, &txs, today)
}

pub fn list_with(conn: &Connection, txs: &[TxLite], today: NaiveDate) -> Result<Vec<Recurring>> {
    let mut st = conn.prepare(&format!("{SELECT} ORDER BY r.kind DESC, r.amount_cents DESC"))?;
    let rows: Vec<(Recurring, Option<String>)> = st
        .query_map([], |r| {
            let freq: String = r.get::<_, Option<String>>(4)?.unwrap_or_else(|| "monthly".into());
            let amount: i64 = r.get(3)?;
            Ok((
                Recurring {
                    id: r.get(0)?,
                    name: r.get(1)?,
                    kind: r.get::<_, Option<String>>(2)?.unwrap_or_else(|| "bill".into()),
                    amount_cents: amount,
                    monthly_cents: monthly_equivalent(amount, &freq),
                    frequency: freq,
                    anchor_date: r.get(5)?,
                    match_key: r.get::<_, Option<String>>(6)?.unwrap_or_default(),
                    match_exact_amount: r.get::<_, Option<i64>>(7)?.unwrap_or(0) != 0,
                    category_id: r.get(8)?,
                    account_id: r.get(9)?,
                    active: r.get::<_, Option<i64>>(10)?.unwrap_or(1) != 0,
                    notes: r.get::<_, Option<String>>(11)?.unwrap_or_default(),
                    category_name: r.get(12)?,
                    account_name: r.get(13)?,
                    affects_cash: true,
                    next_date: None,
                    last_seen: None,
                },
                r.get::<_, Option<String>>(14)?,
            ))
        })?
        .collect::<std::result::Result<_, _>>()?;
    Ok(rows
        .into_iter()
        .map(|(mut r, acct_kind)| {
            r.affects_cash = account_affects_cash(acct_kind.as_deref());
            if let Some(a) = parse_date(&r.anchor_date) {
                r.next_date = next_on_or_after(&r.frequency, a, today).map(fmt_date);
            }
            let sign = if r.kind == "income" { 1 } else { -1 };
            r.last_seen = txs
                .iter()
                .rev()
                .find(|t| {
                    !r.match_key.is_empty()
                        && t.key == r.match_key
                        && t.amount_cents.signum() == sign
                        && (!r.match_exact_amount || t.amount_cents.abs() == r.amount_cents)
                })
                .map(|t| fmt_date(t.date));
            r
        })
        .collect())
}

fn validate(i: &RecurringInput) -> Result<()> {
    if i.name.trim().is_empty() {
        return err("Name required");
    }
    if i.amount_cents <= 0 {
        return err("Amount must be more than zero");
    }
    if !FREQUENCIES.contains(&i.frequency.as_str()) {
        return err("Unknown frequency");
    }
    if parse_date(&i.anchor_date).is_none() {
        return err("Pick a date it happens on");
    }
    Ok(())
}

pub fn create(conn: &Connection, i: &RecurringInput) -> Result<String> {
    validate(i)?;
    let id = uid();
    conn.execute(
        "INSERT INTO recurring (id, name, kind, amount_cents, frequency, anchor_date, match_key, match_exact_amount, category_id, account_id, active, notes)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
        params![id, i.name.trim(), if i.kind == "income" { "income" } else { "bill" }, i.amount_cents, i.frequency, i.anchor_date,
            i.match_key, i.match_exact_amount as i64, i.category_id, i.account_id, i.active as i64, i.notes],
    )?;
    Ok(id)
}

pub fn update(conn: &Connection, id: &str, i: &RecurringInput) -> Result<()> {
    validate(i)?;
    let n = conn.execute(
        "UPDATE recurring SET name=?1, kind=?2, amount_cents=?3, frequency=?4, anchor_date=?5, match_key=?6, match_exact_amount=?7,
           category_id=?8, account_id=?9, active=?10, notes=?11 WHERE id=?12",
        params![i.name.trim(), if i.kind == "income" { "income" } else { "bill" }, i.amount_cents, i.frequency, i.anchor_date,
            i.match_key, i.match_exact_amount as i64, i.category_id, i.account_id, i.active as i64, i.notes, id],
    )?;
    if n == 0 {
        return err("Recurring item not found");
    }
    Ok(())
}

pub fn delete(conn: &Connection, id: &str) -> Result<()> {
    conn.execute("DELETE FROM recurring WHERE id = ?1", [id])?;
    Ok(())
}

/// income, debt, or bill for a detected series.
pub fn suggested_kind(s: &Series) -> &'static str {
    if s.sign > 0 {
        return "income";
    }
    let cat = format!("{} {}", s.sample.category_name.as_deref().unwrap_or(""), s.sample.subcategory_name.as_deref().unwrap_or(""))
        .to_lowercase();
    if cat.contains("debt") || cat.contains("loan") || debt_regex().is_match(&s.sample.description) {
        "debt"
    } else {
        "bill"
    }
}

/// Likely a real bill or paycheck rather than a coincidence (e.g. pizza twice a month apart).
fn is_recommended(kind: &str, s: &Series) -> bool {
    if kind == "income" {
        return s.dates.len() >= 3;
    }
    let cat = format!("{} {}", s.sample.category_name.as_deref().unwrap_or(""), s.sample.subcategory_name.as_deref().unwrap_or(""))
        .to_lowercase();
    let casual = ["dining", "grocer", "shopping", "fee", "gas", "food", "restaurant", "entertain", "travel", "personal", "health"]
        .iter()
        .any(|w| cat.contains(w));
    s.dates.len() >= 3 && !casual
}

/// Recurring series found in transactions, ready to add. Debt payments are included
/// (marked "debt") so the Debt screen can reuse them; the Calendar shows income and bills.
pub fn suggestions(conn: &Connection, today: NaiveDate) -> Result<Vec<RecurringSuggestion>> {
    let txs = load_txs(conn)?;
    let series = detect_series(&txs);
    let tracked: Vec<(String, i64, bool)> = {
        let mut st = conn.prepare(
            "SELECT match_key, amount_cents, match_exact_amount FROM recurring
             UNION ALL SELECT match_key, payment_cents, match_exact_amount FROM debts WHERE archived = 0",
        )?;
        let rows = st.query_map([], |r| {
            Ok((r.get::<_, Option<String>>(0)?.unwrap_or_default(), r.get::<_, Option<i64>>(1)?.unwrap_or(0), r.get::<_, Option<i64>>(2)?.unwrap_or(0) != 0))
        })?;
        rows.collect::<std::result::Result<_, _>>()?
    };
    let accounts: HashMap<String, (String, Option<String>)> = {
        let mut st = conn.prepare("SELECT id, name, type FROM accounts")?;
        let rows = st.query_map([], |r| Ok((r.get::<_, String>(0)?, (r.get::<_, String>(1)?, r.get::<_, Option<String>>(2)?))))?;
        rows.collect::<std::result::Result<_, _>>()?
    };
    let category_ids: HashMap<String, String> = {
        let mut st = conn.prepare("SELECT name, id FROM categories")?;
        let rows = st.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?;
        rows.collect::<std::result::Result<_, _>>()?
    };
    let mut per_key: HashMap<(String, i64), u32> = HashMap::new();
    for s in &series {
        *per_key.entry((s.key.clone(), s.sign)).or_insert(0) += 1;
    }
    let mut out: Vec<RecurringSuggestion> = series
        .iter()
        .map(|s| {
            let kind = suggested_kind(s);
            // Exact amounts only matter when one merchant has several series (e.g. several Affirm loans).
            // Otherwise match any amount, so a price change doesn't look like a missed bill.
            let exact = s.exact && per_key.get(&(s.key.clone(), s.sign)).copied().unwrap_or(0) > 1;
            let already = tracked.iter().any(|(k, amt, e)| *k == s.key && (!*e || !exact || *amt == s.amount_cents));
            let first = *s.dates.first().unwrap();
            let last = *s.dates.last().unwrap();
            let acct = accounts.get(&s.sample.account_id);
            let mut name = display_name(&s.sample.description);
            if exact && kind == "debt" {
                name = format!("{name} {}", crate::schedule::dollars(s.amount_cents));
            }
            RecurringSuggestion {
                input: RecurringInput {
                    name,
                    kind: if kind == "income" { "income".into() } else { "bill".into() },
                    amount_cents: s.amount_cents,
                    frequency: s.frequency.clone(),
                    anchor_date: fmt_date(first),
                    match_key: s.key.clone(),
                    match_exact_amount: exact,
                    category_id: s.sample.category_name.as_ref().and_then(|n| category_ids.get(n).cloned()),
                    account_id: Some(s.sample.account_id.clone()),
                    active: true,
                    notes: String::new(),
                },
                suggested_kind: kind.into(),
                occurrences: s.dates.len() as u32,
                first_date: fmt_date(first),
                last_date: fmt_date(last),
                next_date: next_on_or_after(&s.frequency, last, today).map(fmt_date),
                category_name: s.sample.category_name.clone(),
                account_name: acct.map(|a| a.0.clone()),
                already_tracked: already,
                recommended: is_recommended(kind, s),
            }
        })
        .collect();
    let rank = |k: &str| match k {
        "income" => 0,
        "bill" => 1,
        _ => 2,
    };
    out.sort_by(|a, b| {
        rank(&a.suggested_kind)
            .cmp(&rank(&b.suggested_kind))
            .then(monthly_equivalent(b.input.amount_cents, &b.input.frequency).cmp(&monthly_equivalent(a.input.amount_cents, &a.input.frequency)))
    });
    Ok(out)
}
