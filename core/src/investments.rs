//! Investment accounts (brokerage, retirement, HSA) with a value history, and the
//! whole-picture net worth overview that combines cash, investments, and every debt.

use std::collections::HashSet;

use chrono::{Datelike, NaiveDate};
use rusqlite::{params, Connection, OptionalExtension};

use crate::db::uid;
use crate::error::{err, Result};
use crate::models::*;
use crate::reports::{add_months, list_accounts, month_bounds};
use crate::schedule::{fmt_date, monthly_equivalent, parse_date};

pub const INVESTMENT_KINDS: &[&str] = &["brokerage", "retirement", "hsa"];

pub fn is_investment(kind: &str) -> bool {
    INVESTMENT_KINDS.contains(&kind)
}

fn validate(i: &InvestmentInput) -> Result<()> {
    if i.name.trim().is_empty() {
        return err("Name required");
    }
    if !is_investment(&i.kind) {
        return err("Type must be brokerage, retirement, or HSA");
    }
    if let Some(p) = i.contribution_pct {
        if !(0.0..=100.0).contains(&p) {
            return err("Contribution must be between 0% and 100%");
        }
    }
    let digits: String = i.account_last4.chars().filter(|c| c.is_ascii_alphanumeric()).collect();
    if digits.len() > 4 {
        return err("Only store the last 4 characters of the account number");
    }
    if i.value_as_of.as_deref().map(|d| parse_date(d).is_none()).unwrap_or(false) {
        return err("Value date isn't a valid date");
    }
    Ok(())
}

fn upsert_details(conn: &Connection, id: &str, i: &InvestmentInput) -> Result<()> {
    conn.execute(
        "INSERT INTO investment_details (account_id, account_label, employer, allocation, contribution_pct, employer_match, account_last4, notes)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
         ON CONFLICT(account_id) DO UPDATE SET account_label=excluded.account_label, employer=excluded.employer,
           allocation=excluded.allocation, contribution_pct=excluded.contribution_pct, employer_match=excluded.employer_match,
           account_last4=excluded.account_last4, notes=excluded.notes",
        params![id, i.account_label, i.employer, i.allocation, i.contribution_pct, i.employer_match, i.account_last4.trim(), i.notes],
    )?;
    Ok(())
}

pub fn create(conn: &Connection, i: &InvestmentInput) -> Result<String> {
    validate(i)?;
    let id = uid();
    let tx = conn.unchecked_transaction()?;
    tx.execute(
        "INSERT INTO accounts (id, name, institution, type, balance_cents, balance_set, color) VALUES (?1, ?2, ?3, ?4, ?5, 1, ?6)",
        params![id, i.name.trim(), i.institution, i.kind, i.value_cents.unwrap_or(0), if i.color.is_empty() { "#34d399" } else { &i.color }],
    )?;
    upsert_details(&tx, &id, i)?;
    if let Some(v) = i.value_cents {
        let date = i.value_as_of.clone().unwrap_or_else(|| fmt_date(crate::reports::today()));
        tx.execute(
            "INSERT INTO balance_history (id, account_id, date, balance_cents, note) VALUES (?1, ?2, ?3, ?4, 'Starting value')",
            params![uid(), id, date, v],
        )?;
    }
    tx.commit()?;
    Ok(id)
}

pub fn update(conn: &Connection, id: &str, i: &InvestmentInput) -> Result<()> {
    validate(i)?;
    let tx = conn.unchecked_transaction()?;
    let n = tx.execute(
        "UPDATE accounts SET name=?1, institution=?2, type=?3, color=COALESCE(NULLIF(?4, ''), color) WHERE id=?5",
        params![i.name.trim(), i.institution, i.kind, i.color, id],
    )?;
    if n == 0 {
        return err("Investment account not found");
    }
    upsert_details(&tx, id, i)?;
    tx.commit()?;
    Ok(())
}

/// Adds a dated value. The newest value becomes the account's balance.
pub fn record_value(conn: &Connection, id: &str, date: &str, value: i64, note: &str) -> Result<()> {
    if parse_date(date).is_none() {
        return err("Pick a valid date");
    }
    let tx = conn.unchecked_transaction()?;
    tx.execute(
        "INSERT INTO balance_history (id, account_id, date, balance_cents, note) VALUES (?1, ?2, ?3, ?4, ?5)",
        params![uid(), id, date, value, note],
    )?;
    sync_balance(&tx, id)?;
    tx.commit()?;
    Ok(())
}

pub fn delete_value(conn: &Connection, entry_id: &str) -> Result<()> {
    let account: Option<String> =
        conn.query_row("SELECT account_id FROM balance_history WHERE id = ?1", [entry_id], |r| r.get(0)).optional()?;
    conn.execute("DELETE FROM balance_history WHERE id = ?1", [entry_id])?;
    if let Some(a) = account {
        sync_balance(conn, &a)?;
    }
    Ok(())
}

fn sync_balance(conn: &Connection, id: &str) -> Result<()> {
    let latest: Option<i64> = conn
        .query_row(
            "SELECT balance_cents FROM balance_history WHERE account_id = ?1 ORDER BY date DESC, created_at DESC, rowid DESC LIMIT 1",
            [id],
            |r| r.get(0),
        )
        .optional()?;
    if let Some(v) = latest {
        conn.execute("UPDATE accounts SET balance_cents = ?1, balance_set = 1 WHERE id = ?2", params![v, id])?;
    }
    Ok(())
}

pub fn list(conn: &Connection) -> Result<Vec<Investment>> {
    let mut st = conn.prepare(
        "SELECT a.id, a.name, COALESCE(a.institution, ''), a.type, COALESCE(a.color, '#34d399'),
           CASE WHEN a.balance_set = 1 THEN a.balance_cents
             ELSE COALESCE((SELECT SUM(amount_cents) FROM transactions t WHERE t.account_id = a.id), a.balance_cents) END,
           COALESCE(d.account_label, ''), COALESCE(d.employer, ''), COALESCE(d.allocation, ''), d.contribution_pct,
           COALESCE(d.employer_match, ''), COALESCE(d.account_last4, ''), COALESCE(d.notes, '')
         FROM accounts a LEFT JOIN investment_details d ON d.account_id = a.id
         WHERE a.archived = 0 AND a.type IN ('brokerage', 'retirement', 'hsa')
         ORDER BY a.type DESC, a.name COLLATE NOCASE",
    )?;
    let rows: Vec<Investment> = st
        .query_map([], |r| {
            Ok(Investment {
                id: r.get(0)?,
                name: r.get(1)?,
                institution: r.get(2)?,
                kind: r.get(3)?,
                color: r.get(4)?,
                value_cents: r.get::<_, Option<i64>>(5)?.unwrap_or(0),
                value_as_of: None,
                account_label: r.get(6)?,
                employer: r.get(7)?,
                allocation: r.get(8)?,
                contribution_pct: r.get(9)?,
                employer_match: r.get(10)?,
                account_last4: r.get(11)?,
                notes: r.get(12)?,
                history: vec![],
                change_cents: 0,
            })
        })?
        .collect::<std::result::Result<_, _>>()?;
    let mut st = conn.prepare(
        "SELECT id, date, balance_cents, COALESCE(note, '') FROM balance_history WHERE account_id = ?1 ORDER BY date, created_at, rowid",
    )?;
    let mut out = vec![];
    for mut inv in rows {
        inv.history = st
            .query_map([&inv.id], |r| Ok(ValuePoint { id: r.get(0)?, date: r.get(1)?, value_cents: r.get(2)?, note: r.get(3)? }))?
            .collect::<std::result::Result<_, _>>()?;
        inv.value_as_of = inv.history.last().map(|p| p.date.clone());
        inv.change_cents = match (inv.history.first(), inv.history.last()) {
            (Some(a), Some(b)) => b.value_cents - a.value_cents,
            _ => 0,
        };
        out.push(inv);
    }
    Ok(out)
}

// ---------- the whole picture ----------

pub fn overview(conn: &Connection, today: NaiveDate) -> Result<FinancialOverview> {
    let ym = format!("{}-{:02}", today.year(), today.month());
    let accounts = list_accounts(conn, &ym)?;
    let txs = crate::schedule::load_txs(conn)?;
    let debts = crate::debts::list_with(conn, &txs, today)?;
    let mut lines = vec![];

    // Cash
    let mut cash = 0;
    let mut cash_needs_setup = false;
    for a in accounts.iter().filter(|a| matches!(a.kind.as_str(), "checking" | "savings" | "cash")) {
        cash += a.display_balance_cents;
        cash_needs_setup |= !a.balance_set;
        lines.push(NetWorthLine {
            group: "cash".into(),
            name: a.name.clone(),
            amount_cents: a.display_balance_cents,
            detail: if a.balance_set { "Balance you entered, plus imports since".into() } else { "Sum of imported transactions; set the real balance".into() },
            needs_attention: !a.balance_set,
        });
    }

    // Investments
    let invs = list(conn)?;
    let investments: i64 = invs.iter().map(|i| i.value_cents).sum();
    for i in &invs {
        lines.push(NetWorthLine {
            group: "investments".into(),
            name: i.name.clone(),
            amount_cents: i.value_cents,
            detail: match &i.value_as_of {
                Some(d) => format!("Value as of {d}"),
                None => "No value recorded yet".into(),
            },
            needs_attention: i.value_as_of.is_none(),
        });
    }

    // Debts: tracked debts, plus card/loan accounts that no debt follows yet.
    let active: Vec<&Debt> = debts.iter().filter(|d| d.payoff.status != "paid_off").collect();
    let linked: HashSet<String> = debts.iter().filter_map(|d| d.account_id.clone()).collect();
    let mut debt_total = 0;
    let mut missing = 0;
    for d in &active {
        let unknown = d.current_balance_cents == 0 && d.payoff.status == "unknown";
        missing += unknown as u32;
        debt_total += d.current_balance_cents;
        lines.push(NetWorthLine {
            group: "debt".into(),
            name: d.name.clone(),
            amount_cents: -d.current_balance_cents,
            detail: if unknown {
                "Balance not set".into()
            } else if d.balance_is_estimate {
                "Estimated from the last balance you entered".into()
            } else {
                String::new()
            },
            needs_attention: unknown,
        });
    }
    for a in accounts.iter().filter(|a| (a.kind == "credit" || a.kind == "loan") && !linked.contains(&a.id)) {
        // Without a real balance, the sum of imported activity isn't what's owed; leave it out.
        let owed = if a.balance_set { (-a.display_balance_cents).max(0) } else { 0 };
        missing += (!a.balance_set) as u32;
        debt_total += owed;
        lines.push(NetWorthLine {
            group: "debt".into(),
            name: a.name.clone(),
            amount_cents: -owed,
            detail: if a.balance_set { "Account balance (not on the Debt page yet)".into() } else { "Balance not set".into() },
            needs_attention: !a.balance_set,
        });
    }

    // Monthly picture
    let recurring = crate::recurring::list_with(conn, &txs, today)?;
    let scheduled_income: i64 =
        recurring.iter().filter(|r| r.active && r.kind == "income").map(|r| monthly_equivalent(r.amount_cents, &r.frequency)).sum();
    let (income, from_schedule) = if scheduled_income > 0 {
        (scheduled_income, true)
    } else {
        // Average of the last three full months of real (non-transfer) income.
        let (from, _) = month_bounds(&add_months(&ym, -3));
        let (to, _) = month_bounds(&ym);
        let sum: i64 = conn.query_row(
            &format!(
                "SELECT COALESCE(SUM(amount_cents), 0) FROM transactions WHERE amount_cents > 0 AND is_transfer = 0 AND {ED} >= ?1 AND {ED} < ?2",
                ED = crate::reports::ED
            ),
            params![from, to],
            |r| r.get(0),
        )?;
        (sum / 3, false)
    };
    let bills: i64 = recurring
        .iter()
        .filter(|r| r.active && r.kind == "bill" && r.affects_cash && r.frequency != "once")
        .map(|r| monthly_equivalent(r.amount_cents, &r.frequency))
        .sum();
    let debt_payments: i64 = active.iter().map(|d| d.monthly_payment_cents).sum();
    let flexible = crate::flex::flexible_budgets(conn, &txs, today)?.monthly_cents;

    Ok(FinancialOverview {
        as_of: fmt_date(today),
        cash_cents: cash,
        cash_needs_setup,
        investments_cents: investments,
        debt_cents: debt_total,
        debts_missing_balance: missing,
        net_worth_cents: cash + investments - debt_total,
        monthly_income_cents: income,
        income_from_schedule: from_schedule,
        monthly_bills_cents: bills,
        monthly_debt_payments_cents: debt_payments,
        monthly_flexible_cents: flexible,
        monthly_left_cents: income - bills - debt_payments - flexible,
        debt_to_income: if income > 0 { Some(debt_payments as f64 / income as f64) } else { None },
        lines,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn input(name: &str, kind: &str, value: Option<i64>) -> InvestmentInput {
        InvestmentInput {
            name: name.into(), institution: "Vanguard".into(), kind: kind.into(), color: String::new(),
            account_label: "401(k)".into(), employer: "Acme".into(), allocation: "Target 2050 — 100%".into(),
            contribution_pct: Some(5.0), employer_match: String::new(), account_last4: "1234".into(), notes: String::new(),
            value_cents: value, value_as_of: Some("2026-10-23".into()),
        }
    }

    #[test]
    fn values_history_and_net_worth() {
        let dir = tempfile::tempdir().unwrap();
        let conn = crate::db::open(dir.path().join("t.db").to_str().unwrap()).unwrap();
        let id = create(&conn, &input("401k", "retirement", Some(0))).unwrap();
        record_value(&conn, &id, "2026-11-30", 120_000, "").unwrap();
        // An older value doesn't replace the current balance.
        record_value(&conn, &id, "2026-11-01", 50_000, "").unwrap();
        let inv = &list(&conn).unwrap()[0];
        assert_eq!(inv.value_cents, 120_000);
        assert_eq!(inv.history.len(), 3);
        assert_eq!(inv.change_cents, 120_000);
        assert_eq!(inv.value_as_of.as_deref(), Some("2026-11-30"));

        conn.execute("INSERT INTO accounts (id, name, type, balance_cents, balance_set) VALUES ('c', 'Checking', 'checking', 150000, 1)", []).unwrap();
        conn.execute("INSERT INTO accounts (id, name, type, balance_cents, balance_set) VALUES ('cc', 'Card', 'credit', -30000, 1)", []).unwrap();
        let o = overview(&conn, parse_date("2026-12-01").unwrap()).unwrap();
        assert_eq!(o.cash_cents, 150_000);
        assert_eq!(o.investments_cents, 120_000);
        assert_eq!(o.debt_cents, 30_000);
        assert_eq!(o.net_worth_cents, 240_000);
        assert!(input("x", "checking", None) != input("x", "retirement", None));
        assert!(create(&conn, &input("bad", "checking", None)).is_err());
        let mut long = input("y", "brokerage", None);
        long.account_last4 = "X00-001234".into();
        assert!(create(&conn, &long).is_err());
    }
}
