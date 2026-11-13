//! Debts: balances, payoff estimates, avalanche/snowball plans, and suggestions.

use std::collections::{HashMap, HashSet};
use std::sync::OnceLock;

use chrono::{Datelike, NaiveDate};
use regex::Regex;
use rusqlite::{params, Connection};

use crate::db::uid;
use crate::error::{err, Result};
use crate::models::*;
use crate::reports::{add_months, list_accounts};
use crate::schedule::*;

pub const KINDS: &[&str] = &["bnpl", "card", "installment", "short_term", "auto", "relief", "loan"];

const SELECT: &str = "SELECT id, name, lender, kind, account_id, balance_source, balance_cents, balance_as_of, original_cents, apr,
    payment_cents, frequency, next_due, payments_left, match_key, match_exact_amount, notes, created_at FROM debts";

fn row_to_input(r: &rusqlite::Row) -> rusqlite::Result<(String, DebtInput)> {
    let created: Option<String> = r.get(17)?;
    Ok((
        r.get(0)?,
        DebtInput {
            name: r.get(1)?,
            lender: r.get::<_, Option<String>>(2)?.unwrap_or_default(),
            kind: r.get::<_, Option<String>>(3)?.unwrap_or_else(|| "loan".into()),
            account_id: r.get(4)?,
            balance_source: r.get::<_, Option<String>>(5)?.unwrap_or_else(|| "manual".into()),
            balance_cents: r.get::<_, Option<i64>>(6)?.unwrap_or(0),
            balance_as_of: r
                .get::<_, Option<String>>(7)?
                .or_else(|| created.map(|c| c.chars().take(10).collect()))
                .unwrap_or_default(),
            original_cents: r.get(8)?,
            apr: r.get::<_, Option<f64>>(9)?.unwrap_or(0.0),
            payment_cents: r.get::<_, Option<i64>>(10)?.unwrap_or(0),
            frequency: r.get::<_, Option<String>>(11)?.unwrap_or_else(|| "monthly".into()),
            next_due: r.get(12)?,
            payments_left: r.get::<_, Option<i64>>(13)?.map(|n| n.max(0) as u32),
            match_key: r.get::<_, Option<String>>(14)?.unwrap_or_default(),
            match_exact_amount: r.get::<_, Option<i64>>(15)?.unwrap_or(1) != 0,
            notes: r.get::<_, Option<String>>(16)?.unwrap_or_default(),
        },
    ))
}

// ---------- payoff math ----------

/// Payments needed and interest paid to clear `balance` paying `payment` per period.
/// With `fixed_payments` (buy-now-pay-later schedules), the count is taken as given.
pub fn payoff_estimate(
    balance: i64,
    apr: f64,
    payment: i64,
    freq: &str,
    fixed_payments: Option<u32>,
    first_payment: Option<NaiveDate>,
    balance_known: bool,
) -> PayoffEstimate {
    let unknown = PayoffEstimate { status: "unknown".into(), payments: None, payoff_date: None, interest_cents: 0, total_cents: 0 };
    if balance_known && balance <= 0 {
        return PayoffEstimate { status: "paid_off".into(), payments: Some(0), payoff_date: None, interest_cents: 0, total_cents: 0 };
    }
    if fixed_payments == Some(0) {
        return PayoffEstimate { status: "paid_off".into(), payments: Some(0), payoff_date: None, interest_cents: 0, total_cents: 0 };
    }
    if payment <= 0 {
        return unknown;
    }
    let date_for = |n: u32| first_payment.map(|f| fmt_date(nth_after(freq, f, n.saturating_sub(1))));
    if !balance_known {
        // Balance unknown, but a fixed number of payments still gives an end date.
        return match fixed_payments {
            Some(n) => PayoffEstimate {
                status: "ok".into(),
                payments: Some(n),
                payoff_date: date_for(n),
                interest_cents: 0,
                total_cents: payment * n as i64,
            },
            None => unknown,
        };
    }
    let rate = apr / 100.0 / periods_per_year(freq);
    let (mut b, mut n, mut interest, mut total) = (balance, 0u32, 0i64, 0i64);
    while b > 0 && n < 1200 {
        let int = (b as f64 * rate).round() as i64;
        if n == 0 && payment <= int {
            return PayoffEstimate { status: "never".into(), payments: None, payoff_date: None, interest_cents: 0, total_cents: 0 };
        }
        b += int;
        interest += int;
        let pay = payment.min(b);
        b -= pay;
        total += pay;
        n += 1;
        if let Some(fixed) = fixed_payments {
            // A fixed schedule ends on its last payment even if our balance is a little off.
            if n >= fixed {
                break;
            }
        }
    }
    if b > 0 && fixed_payments.is_none() {
        return PayoffEstimate { status: "never".into(), payments: None, payoff_date: None, interest_cents: 0, total_cents: 0 };
    }
    PayoffEstimate { status: "ok".into(), payments: Some(n), payoff_date: date_for(n), interest_cents: interest, total_cents: total }
}

// ---------- loading with computed fields ----------

pub struct AccountInfo {
    name: String,
    owed: i64,
    /// False when the account has no real balance yet (imports only show activity, not the balance).
    balance_set: bool,
}

fn accounts_map(conn: &Connection, today: NaiveDate) -> Result<HashMap<String, AccountInfo>> {
    let ym = format!("{}-{:02}", today.year(), today.month());
    Ok(list_accounts(conn, &ym)?
        .into_iter()
        .map(|a| (a.id.clone(), AccountInfo { name: a.name, owed: (-a.display_balance_cents).max(0), balance_set: a.balance_set }))
        .collect())
}

pub fn compute(id: String, i: DebtInput, txs: &[TxLite], accounts: &HashMap<String, AccountInfo>, today: NaiveDate) -> Debt {
    let account = i.account_id.as_ref().and_then(|a| accounts.get(a));
    let matches = |t: &&TxLite| {
        !i.match_key.is_empty()
            && t.key == i.match_key
            && t.amount_cents < 0
            && (!i.match_exact_amount || i.payment_cents <= 0 || -t.amount_cents == i.payment_cents)
    };
    // Card/loan accounts: payments are the payment credits on the account itself.
    let card_account = match (i.balance_source.as_str(), &i.account_id) {
        ("account", Some(a)) if i.match_key.is_empty() => Some(a.clone()),
        _ => None,
    };
    let payments: Vec<&TxLite> = match &card_account {
        Some(a) => txs.iter().filter(|t| t.account_id == *a && is_payment_credit(t)).collect(),
        None => txs.iter().filter(matches).collect(),
    };
    let last_payment_date = payments.iter().map(|t| t.date).max().map(fmt_date);
    let recent_payments: Vec<DebtPayment> = payments
        .iter()
        .rev()
        .take(6)
        .map(|t| DebtPayment { date: fmt_date(t.date), amount_cents: t.amount_cents.abs() })
        .collect();
    let (current, estimate, paid_since, count_since) = match (i.balance_source.as_str(), account) {
        ("account", Some(a)) if a.balance_set => (a.owed, false, 0, 0),
        // The account's real balance isn't known; the sum of imported activity isn't a balance.
        ("account", Some(_)) => (0, false, 0, 0),
        _ => {
            let as_of = parse_date(&i.balance_as_of).unwrap_or(today);
            let since: Vec<&TxLite> = txs.iter().filter(matches).filter(|t| t.date > as_of).collect();
            let paid: i64 = since.iter().map(|t| -t.amount_cents).sum();
            let days = (today - as_of).num_days().max(0) as f64;
            let interest = (i.balance_cents as f64 * i.apr / 100.0 * days / 365.0).round() as i64;
            let est = (i.balance_cents + interest - paid).max(0);
            (est, paid > 0 || interest > 0, paid, since.len() as u32)
        }
    };
    let payments_left_now = i.payments_left.map(|n| n.saturating_sub(count_since));
    let balance_known = match (i.balance_source.as_str(), account) {
        ("account", Some(a)) => a.balance_set,
        _ => i.balance_cents > 0,
    };
    let next_payment = if payments_left_now == Some(0) || (balance_known && current == 0) {
        None
    } else {
        i.next_due.as_deref().and_then(parse_date).and_then(|a| next_on_or_after(&i.frequency, a, today))
    };
    let payoff = payoff_estimate(current, i.apr, i.payment_cents, &i.frequency, payments_left_now, next_payment.or(Some(today)), balance_known);
    Debt {
        id,
        account_name: account.map(|a| a.name.clone()),
        current_balance_cents: current,
        balance_is_estimate: estimate,
        paid_since_cents: paid_since,
        payments_since: count_since,
        payments_left_now,
        last_payment_date,
        recent_payments,
        next_payment_date: next_payment.map(fmt_date),
        monthly_payment_cents: if payoff.status == "paid_off" { 0 } else { monthly_equivalent(i.payment_cents, &i.frequency) },
        payoff,
        name: i.name,
        lender: i.lender,
        kind: i.kind,
        account_id: i.account_id,
        balance_source: i.balance_source,
        balance_cents: i.balance_cents,
        balance_as_of: i.balance_as_of,
        original_cents: i.original_cents,
        apr: i.apr,
        payment_cents: i.payment_cents,
        frequency: i.frequency,
        next_due: i.next_due,
        payments_left: i.payments_left,
        match_key: i.match_key,
        match_exact_amount: i.match_exact_amount,
        notes: i.notes,
    }
}

pub fn list_with(conn: &Connection, txs: &[TxLite], today: NaiveDate) -> Result<Vec<Debt>> {
    let accounts = accounts_map(conn, today)?;
    let mut st = conn.prepare(&format!("{SELECT} WHERE archived = 0 ORDER BY sort, name COLLATE NOCASE"))?;
    let rows: Vec<(String, DebtInput)> = st.query_map([], row_to_input)?.collect::<std::result::Result<_, _>>()?;
    Ok(rows.into_iter().map(|(id, i)| compute(id, i, txs, &accounts, today)).collect())
}

pub fn list(conn: &Connection, today: NaiveDate) -> Result<Vec<Debt>> {
    let txs = load_txs(conn)?;
    list_with(conn, &txs, today)
}

pub fn summary(debts: &[Debt]) -> DebtSummary {
    let active: Vec<&Debt> = debts.iter().filter(|d| d.payoff.status != "paid_off").collect();
    let total: i64 = active.iter().map(|d| d.current_balance_cents).sum();
    let weighted = if total > 0 {
        Some(active.iter().map(|d| d.apr * d.current_balance_cents as f64).sum::<f64>() / total as f64)
    } else {
        None
    };
    DebtSummary {
        count: active.len() as u32,
        total_cents: total,
        monthly_payments_cents: active.iter().map(|d| d.monthly_payment_cents).sum(),
        weighted_apr: weighted,
        interest_remaining_cents: active.iter().map(|d| d.payoff.interest_cents).sum(),
        debt_free_date: active.iter().filter_map(|d| d.payoff.payoff_date.clone()).max(),
        unknown_count: active.iter().filter(|d| d.payoff.status == "unknown" || d.payoff.status == "never").count() as u32,
    }
}

/// Groups debts by the account they follow (e.g. "Capital One 1234"), otherwise by lender
/// (all Affirm loans together), otherwise by name. Biggest balances first.
pub fn groups(debts: &[Debt]) -> Vec<DebtGroup> {
    let mut out: Vec<DebtGroup> = vec![];
    for d in debts.iter().filter(|d| d.payoff.status != "paid_off") {
        let (key, name) = match (&d.account_name, d.balance_source.as_str()) {
            (Some(a), "account") => (a.to_lowercase(), a.clone()),
            _ if !d.lender.trim().is_empty() => (d.lender.trim().to_lowercase(), d.lender.trim().to_string()),
            _ => (d.name.to_lowercase(), d.name.clone()),
        };
        let g = match out.iter_mut().position(|g| g.key == key) {
            Some(i) => &mut out[i],
            None => {
                out.push(DebtGroup {
                    key: key.clone(),
                    name,
                    account_id: None,
                    debts: vec![],
                    total_cents: 0,
                    monthly_cents: 0,
                    interest_cents: 0,
                    payoff_date: None,
                    unknown_count: 0,
                    apr_min: None,
                    apr_max: None,
                });
                out.last_mut().unwrap()
            }
        };
        if g.account_id.is_none() && d.balance_source == "account" {
            g.account_id = d.account_id.clone();
        }
        g.debts.push(d.clone());
    }
    for g in out.iter_mut() {
        g.total_cents = g.debts.iter().map(|d| d.current_balance_cents).sum();
        g.monthly_cents = g.debts.iter().map(|d| d.monthly_payment_cents).sum();
        g.interest_cents = g.debts.iter().map(|d| d.payoff.interest_cents).sum();
        g.unknown_count = g.debts.iter().filter(|d| d.payoff.status == "unknown" || d.payoff.status == "never").count() as u32;
        g.payoff_date = if g.unknown_count == 0 { g.debts.iter().filter_map(|d| d.payoff.payoff_date.clone()).max() } else { None };
        let aprs: Vec<f64> = g.debts.iter().map(|d| d.apr).filter(|a| *a > 0.0).collect();
        g.apr_min = aprs.iter().cloned().reduce(f64::min);
        g.apr_max = aprs.iter().cloned().reduce(f64::max);
        g.debts.sort_by(|a, b| b.current_balance_cents.cmp(&a.current_balance_cents).then(a.name.cmp(&b.name)));
    }
    out.sort_by(|a, b| b.total_cents.cmp(&a.total_cents).then(b.monthly_cents.cmp(&a.monthly_cents)));
    out
}

// ---------- CRUD ----------

fn validate(i: &DebtInput) -> Result<()> {
    if i.name.trim().is_empty() {
        return err("Name required");
    }
    if !FREQUENCIES.contains(&i.frequency.as_str()) {
        return err("Unknown payment frequency");
    }
    if i.balance_source == "account" && i.account_id.is_none() {
        return err("Pick the account whose balance this debt follows");
    }
    if !(0.0..=1000.0).contains(&i.apr) {
        return err("APR must be between 0 and 1000");
    }
    if i.next_due.as_deref().map(|d| parse_date(d).is_none()).unwrap_or(false) {
        return err("Next due date isn't a valid date");
    }
    Ok(())
}

pub fn create(conn: &Connection, i: &DebtInput) -> Result<String> {
    validate(i)?;
    let id = uid();
    conn.execute(
        "INSERT INTO debts (id, name, lender, kind, account_id, balance_source, balance_cents, balance_as_of, original_cents, apr,
           payment_cents, frequency, next_due, payments_left, match_key, match_exact_amount, notes)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17)",
        params![id, i.name.trim(), i.lender, i.kind, i.account_id, i.balance_source, i.balance_cents.max(0), i.balance_as_of,
            i.original_cents, i.apr, i.payment_cents.max(0), i.frequency, i.next_due, i.payments_left, i.match_key,
            i.match_exact_amount as i64, i.notes],
    )?;
    Ok(id)
}

pub fn update(conn: &Connection, id: &str, i: &DebtInput) -> Result<()> {
    validate(i)?;
    let n = conn.execute(
        "UPDATE debts SET name=?1, lender=?2, kind=?3, account_id=?4, balance_source=?5, balance_cents=?6, balance_as_of=?7,
           original_cents=?8, apr=?9, payment_cents=?10, frequency=?11, next_due=?12, payments_left=?13, match_key=?14,
           match_exact_amount=?15, notes=?16 WHERE id=?17",
        params![i.name.trim(), i.lender, i.kind, i.account_id, i.balance_source, i.balance_cents.max(0), i.balance_as_of,
            i.original_cents, i.apr, i.payment_cents.max(0), i.frequency, i.next_due, i.payments_left, i.match_key,
            i.match_exact_amount as i64, i.notes, id],
    )?;
    if n == 0 {
        return err("Debt not found");
    }
    Ok(())
}

pub fn delete(conn: &Connection, id: &str) -> Result<()> {
    conn.execute("DELETE FROM debts WHERE id = ?1", [id])?;
    Ok(())
}

// ---------- payoff plans ----------

/// Month-by-month plan paying every debt's minimum, plus `extra` per month.
/// avalanche: extra goes to the highest APR first. snowball: smallest balance first.
/// minimum: no extra, and freed-up payments are not rolled over.
pub fn plan(debts: &[Debt], strategy: &str, extra: i64, today: NaiveDate) -> PlanResult {
    struct P {
        id: String,
        name: String,
        apr: f64,
        b: i64,
        min: i64,
        interest: i64,
        done: Option<u32>,
    }
    let mut ps: Vec<P> = debts
        .iter()
        .filter(|d| d.current_balance_cents > 0 && d.payment_cents > 0 && d.payoff.status != "paid_off")
        .map(|d| P {
            id: d.id.clone(),
            name: d.name.clone(),
            apr: d.apr,
            b: d.current_balance_cents,
            min: monthly_equivalent(d.payment_cents, &d.frequency).max(1),
            interest: 0,
            done: None,
        })
        .collect();
    let excluded = debts.iter().filter(|d| d.payoff.status != "paid_off").count() as u32 - ps.len() as u32;
    let rollover = strategy != "minimum";
    let extra = if strategy == "minimum" { 0 } else { extra.max(0) };
    let start_ym = format!("{}-{:02}", today.year(), today.month());
    let mut series = vec![BalancePoint { ym: start_ym.clone(), balance_cents: ps.iter().map(|p| p.b).sum() }];
    let (mut month, mut total_interest, mut total_paid) = (0u32, 0i64, 0i64);
    while ps.iter().any(|p| p.b > 0) && month < 600 {
        month += 1;
        for p in ps.iter_mut().filter(|p| p.b > 0) {
            let int = (p.b as f64 * p.apr / 100.0 / 12.0).round() as i64;
            p.b += int;
            p.interest += int;
            total_interest += int;
        }
        let mut pool = extra + if rollover { ps.iter().filter(|p| p.done.is_some()).map(|p| p.min).sum::<i64>() } else { 0 };
        for p in ps.iter_mut().filter(|p| p.b > 0) {
            let pay = p.min.min(p.b);
            p.b -= pay;
            total_paid += pay;
            // Leftover minimum in the payoff month joins the pool.
            if rollover {
                pool += p.min - pay;
            }
        }
        let mut order: Vec<usize> = (0..ps.len()).filter(|&i| ps[i].b > 0).collect();
        match strategy {
            "snowball" => order.sort_by(|&a, &b| ps[a].b.cmp(&ps[b].b)),
            _ => order.sort_by(|&a, &b| ps[b].apr.partial_cmp(&ps[a].apr).unwrap().then(ps[a].b.cmp(&ps[b].b))),
        }
        for i in order {
            if pool <= 0 {
                break;
            }
            let pay = pool.min(ps[i].b);
            ps[i].b -= pay;
            pool -= pay;
            total_paid += pay;
        }
        for p in ps.iter_mut() {
            if p.b <= 0 && p.done.is_none() {
                p.done = Some(month);
            }
        }
        series.push(BalancePoint { ym: add_months(&start_ym, month as i32), balance_cents: ps.iter().map(|p| p.b.max(0)).sum() });
    }
    let never = ps.iter().any(|p| p.b > 0);
    let mut finished: Vec<&P> = ps.iter().collect();
    finished.sort_by_key(|p| p.done.unwrap_or(u32::MAX));
    let debts_out = finished
        .iter()
        .enumerate()
        .map(|(i, p)| PlanDebt {
            id: p.id.clone(),
            name: p.name.clone(),
            order: i as u32 + 1,
            payoff_month: p.done.map(|m| add_months(&start_ym, m as i32)),
            interest_cents: p.interest,
        })
        .collect();
    // Keep the chart readable: at most ~120 points.
    let stride = (series.len() / 120).max(1);
    let series = series.into_iter().enumerate().filter(|(i, _)| i % stride == 0).map(|(_, p)| p).collect();
    PlanResult {
        strategy: strategy.into(),
        extra_cents: extra,
        months: month,
        debt_free_month: if never || ps.is_empty() { None } else { Some(add_months(&start_ym, month as i32)) },
        total_interest_cents: total_interest,
        total_paid_cents: total_paid,
        never,
        excluded,
        debts: debts_out,
        series,
    }
}

// ---------- suggestions ----------

fn apr_note() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| Regex::new(r"(?i)^(.*?),?\s*(\d+(?:\.\d+)?)\s*%\s*APR").unwrap())
}

fn guess_kind(desc: &str, sub: Option<&str>) -> &'static str {
    let s = format!("{} {}", desc, sub.unwrap_or("")).to_uppercase();
    if ["AFFIRM", "KLARNA", "ZIP", "AFTERPAY", "SEZZLE", "BUY NOW"].iter().any(|k| s.contains(k)) {
        "bnpl"
    } else if ["MONEYKEY", "ADVANCE AMERICA", "SHORT-TERM", "PAYDAY"].iter().any(|k| s.contains(k)) {
        "short_term"
    } else if ["CONSOLIDATED", "DEBT RELIEF"].iter().any(|k| s.contains(k)) {
        "relief"
    } else if ["HONDA", "TOYOTA", "AUTO", "CAR "].iter().any(|k| s.contains(k)) {
        "auto"
    } else {
        "installment"
    }
}

fn lender_of(name: &str) -> String {
    name.split([' ', '*', '.']).next().unwrap_or("").to_string()
}

pub fn suggestions(conn: &Connection, today: NaiveDate) -> Result<Vec<DebtSuggestion>> {
    let txs = load_txs(conn)?;
    let existing = list_with(conn, &txs, today)?;
    let mut out = vec![];
    let tracked_keys: HashSet<(String, i64)> = existing.iter().map(|d| (d.match_key.clone(), d.payment_cents)).collect();
    let linked: HashSet<String> = existing.iter().filter_map(|d| d.account_id.clone()).collect();
    let as_of = fmt_date(today);

    // 1. Repeating payments that look like debt.
    let series = detect_series(&txs);
    let shared = |key: &str| series.iter().filter(|x| x.key == key && x.sign < 0).count() > 1;
    for s in series.iter() {
        if s.sign > 0 || crate::recurring::suggested_kind(s) != "debt" {
            continue;
        }
        if tracked_keys.contains(&(s.key.clone(), s.amount_cents)) || (!s.exact && existing.iter().any(|d| d.match_key == s.key)) {
            continue;
        }
        let name = display_name(&s.sample.description);
        let last = *s.dates.last().unwrap();
        out.push(DebtSuggestion {
            input: DebtInput {
                name: if s.exact && shared(&s.key) { format!("{name} {}", dollars(s.amount_cents)) } else { name.clone() },
                lender: lender_of(&name),
                kind: guess_kind(&s.sample.description, s.sample.subcategory_name.as_deref()).into(),
                account_id: None,
                balance_source: "manual".into(),
                balance_cents: 0,
                balance_as_of: as_of.clone(),
                original_cents: None,
                apr: 0.0,
                payment_cents: s.amount_cents,
                frequency: s.frequency.clone(),
                next_due: next_on_or_after(&s.frequency, last, today).map(fmt_date),
                payments_left: None,
                match_key: s.key.clone(),
                match_exact_amount: s.exact && shared(&s.key),
                notes: String::new(),
            },
            reason: format!("Paid {} {} times, {}, last on {}", dollars(s.amount_cents), s.dates.len(), s.frequency, fmt_date(last)),
            occurrences: s.dates.len() as u32,
            last_date: Some(fmt_date(last)),
            recommended: true,
        });
    }

    // 2. Credit card and loan accounts not linked to a debt yet.
    let mut st = conn.prepare("SELECT id, name, type, due_day FROM accounts WHERE archived = 0 AND type IN ('credit', 'loan')")?;
    let accts: Vec<(String, String, String, i64)> = st
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get::<_, Option<i64>>(3)?.unwrap_or(0))))?
        .collect::<std::result::Result<_, _>>()?;
    for (id, name, kind, due_day) in accts {
        if linked.contains(&id) {
            continue;
        }
        let next_due = if due_day > 0 {
            let d = NaiveDate::from_ymd_opt(today.year(), today.month(), (due_day as u32).min(crate::reports::days_in_month(today.year(), today.month())));
            d.and_then(|d| next_on_or_after("monthly", d, today)).map(fmt_date)
        } else {
            None
        };
        out.push(DebtSuggestion {
            input: DebtInput {
                name: name.clone(),
                lender: lender_of(&name),
                kind: if kind == "credit" { "card".into() } else { guess_kind(&name, None).into() },
                account_id: Some(id),
                balance_source: "account".into(),
                balance_cents: 0,
                balance_as_of: as_of.clone(),
                original_cents: None,
                apr: 0.0,
                payment_cents: 0,
                frequency: "monthly".into(),
                next_due,
                payments_left: None,
                match_key: String::new(),
                match_exact_amount: false,
                notes: String::new(),
            },
            reason: format!("{} account; its balance updates as you import", if kind == "credit" { "Credit card" } else { "Loan" }),
            occurrences: 0,
            last_date: None,
            recommended: true,
        });
    }

    // 3. Payments in a debt category that don't repeat on a clear schedule yet
    //    (e.g. a car payment with a skipped month). Offered, but not pre-checked.
    let series_keys: HashSet<String> = series.iter().map(|x| x.key.clone()).collect();
    let tracked_any: HashSet<String> = existing.iter().map(|d| d.match_key.clone()).collect();
    // Purchases on card/loan accounts are spending, not payments toward a debt.
    let debt_accounts: HashSet<String> = {
        let mut st = conn.prepare("SELECT id FROM accounts WHERE type IN ('credit', 'loan')")?;
        let rows = st.query_map([], |r| r.get::<_, String>(0))?;
        rows.collect::<std::result::Result<_, _>>()?
    };
    let mut loose: HashMap<String, Vec<&TxLite>> = HashMap::new();
    for t in txs.iter().filter(|t| t.amount_cents < 0 && !t.is_transfer && !t.key.is_empty() && !debt_accounts.contains(&t.account_id)) {
        let cat = format!("{} {}", t.category_name.as_deref().unwrap_or(""), t.subcategory_name.as_deref().unwrap_or("")).to_lowercase();
        let debt_like = cat.contains("debt") || cat.contains("loan") || cat.contains("car payment") || debt_regex().is_match(&t.description);
        if debt_like && !series_keys.contains(&t.key) && !tracked_any.contains(&t.key) {
            loose.entry(t.key.clone()).or_default().push(t);
        }
    }
    let mut loose: Vec<(String, Vec<&TxLite>)> = loose.into_iter().collect();
    loose.sort_by(|a, b| b.1.last().unwrap().date.cmp(&a.1.last().unwrap().date));
    for (key, list) in loose {
        let last = *list.last().unwrap();
        // Skip one-off purchases from buy-now-pay-later merchants seen only once long ago.
        if list.len() < 2 && (today - last.date).num_days() > 45 {
            continue;
        }
        let name = display_name(&last.description);
        let amounts: Vec<String> = list.iter().rev().take(3).map(|t| dollars(-t.amount_cents)).collect();
        out.push(DebtSuggestion {
            input: DebtInput {
                name: name.clone(),
                lender: lender_of(&name),
                kind: guess_kind(&last.description, last.subcategory_name.as_deref()).into(),
                account_id: None,
                balance_source: "manual".into(),
                balance_cents: 0,
                balance_as_of: as_of.clone(),
                original_cents: None,
                apr: 0.0,
                payment_cents: -last.amount_cents,
                frequency: "monthly".into(),
                next_due: next_on_or_after("monthly", last.date, today).map(fmt_date),
                payments_left: None,
                match_key: key,
                match_exact_amount: false,
                notes: String::new(),
            },
            reason: format!(
                "Paid {} time{} ({}), last on {}; not on a regular schedule yet, so check the amount and due date",
                list.len(),
                if list.len() == 1 { "" } else { "s" },
                amounts.join(", "),
                fmt_date(last.date)
            ),
            occurrences: list.len() as u32,
            last_date: Some(fmt_date(last.date)),
            recommended: false,
        });
    }

    // 4. Individual loans recorded with an APR in their notes (e.g. "Affirm loan ABCD-1234, 29.99% APR").
    let mut st = conn.prepare(
        "SELECT t.date, t.amount_cents, t.notes, t.account_id FROM transactions t JOIN accounts a ON a.id = t.account_id
         WHERE t.amount_cents < 0 AND t.notes LIKE '%APR%' ORDER BY t.date",
    )?;
    let notes: Vec<(String, i64, String, String)> = st
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))?
        .collect::<std::result::Result<_, _>>()?;
    let names: HashSet<String> = existing.iter().map(|d| d.name.to_lowercase()).collect();
    for (date, cents, note, _acct) in notes {
        let Some(c) = apr_note().captures(&note) else { continue };
        let name = c[1].trim().to_string();
        if name.is_empty() || names.contains(&name.to_lowercase()) {
            continue;
        }
        let apr: f64 = c[2].parse().unwrap_or(0.0);
        out.push(DebtSuggestion {
            input: DebtInput {
                name: name.clone(),
                lender: lender_of(&name),
                kind: guess_kind(&name, None).into(),
                account_id: None,
                balance_source: "manual".into(),
                balance_cents: -cents,
                balance_as_of: date.clone(),
                original_cents: Some(-cents),
                apr,
                payment_cents: 0,
                frequency: "monthly".into(),
                next_due: None,
                payments_left: None,
                match_key: String::new(),
                match_exact_amount: true,
                notes: note.clone(),
            },
            reason: format!("{} borrowed on {} at {}% APR (from the transaction's notes)", dollars(-cents), date, apr),
            occurrences: 1,
            last_date: Some(date),
            recommended: false,
        });
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn d(s: &str) -> NaiveDate {
        parse_date(s).unwrap()
    }

    #[test]
    fn amortizing_loan() {
        // $1,000 at 24% APR, $100/month: 11.3 months, so 12 payments (the last one small).
        let p = payoff_estimate(100_000, 24.0, 10_000, "monthly", None, Some(d("2026-11-01")), true);
        assert_eq!(p.status, "ok");
        assert_eq!(p.payments, Some(12));
        assert!((12_000..13_500).contains(&p.interest_cents), "{}", p.interest_cents);
        assert_eq!(p.payoff_date.as_deref(), Some("2027-10-01"));
    }

    #[test]
    fn payment_below_interest_never_ends() {
        let p = payoff_estimate(100_000, 36.0, 2_000, "monthly", None, None, true);
        assert_eq!(p.status, "never");
    }

    #[test]
    fn bnpl_fixed_schedule() {
        let p = payoff_estimate(20_000, 0.0, 5_000, "biweekly", Some(4), Some(d("2026-10-27")), true);
        assert_eq!(p.payments, Some(4));
        assert_eq!(p.payoff_date.as_deref(), Some("2026-12-08"));
        let unknown_balance = payoff_estimate(0, 0.0, 1_800, "biweekly", Some(3), Some(d("2026-10-29")), false);
        assert_eq!(unknown_balance.payoff_date.as_deref(), Some("2026-11-26"));
        assert_eq!(payoff_estimate(0, 0.0, 1_800, "biweekly", None, None, false).status, "unknown");
    }

    fn debt(id: &str, apr: f64, bal: i64, pay: i64) -> Debt {
        let i = DebtInput {
            name: id.into(), lender: String::new(), kind: "loan".into(), account_id: None, balance_source: "manual".into(),
            balance_cents: bal, balance_as_of: "2026-10-26".into(), original_cents: None, apr, payment_cents: pay,
            frequency: "monthly".into(), next_due: Some("2026-11-01".into()), payments_left: None, match_key: String::new(),
            match_exact_amount: true, notes: String::new(),
        };
        compute(id.into(), i, &[], &HashMap::new(), d("2026-10-26"))
    }

    #[test]
    fn card_without_real_balance_is_not_set() {
        let mut accts = HashMap::new();
        accts.insert("cc".to_string(), AccountInfo { name: "Card".into(), owed: 61_812, balance_set: false });
        let mut i = debt("x", 29.99, 0, 4_000);
        i.balance_source = "account".into();
        i.account_id = Some("cc".into());
        let input = DebtInput {
            name: "Card".into(), lender: String::new(), kind: "card".into(), account_id: Some("cc".into()), balance_source: "account".into(),
            balance_cents: 0, balance_as_of: "2026-10-26".into(), original_cents: None, apr: 29.99, payment_cents: 4_000,
            frequency: "monthly".into(), next_due: None, payments_left: None, match_key: String::new(), match_exact_amount: false, notes: String::new(),
        };
        let unset = compute("c".into(), input.clone(), &[], &accts, d("2026-10-26"));
        assert_eq!(unset.current_balance_cents, 0);
        assert_eq!(unset.payoff.status, "unknown");
        accts.get_mut("cc").unwrap().balance_set = true;
        let set = compute("c".into(), input, &[], &accts, d("2026-10-26"));
        assert_eq!(set.current_balance_cents, 61_812);
        assert_eq!(set.payoff.status, "ok");
    }

    #[test]
    fn groups_by_lender() {
        let mut a = debt("Affirm loan 1", 0.0, 10_000, 1_000);
        a.lender = "Affirm".into();
        let mut b = debt("Affirm loan 2", 30.0, 5_000, 500);
        b.lender = "affirm ".into();
        let c = debt("Toyota", 10.0, 2_000_000, 45_000);
        let g = groups(&[a, b, c]);
        assert_eq!(g.len(), 2);
        assert_eq!(g[0].name, "Toyota");
        assert_eq!(g[1].debts.len(), 2);
        assert_eq!(g[1].total_cents, 15_000);
        assert_eq!(g[1].apr_max, Some(30.0));
    }

    #[test]
    fn avalanche_beats_snowball_on_interest() {
        let ds = vec![debt("small_low", 5.0, 80_000, 2_000), debt("big_high", 30.0, 300_000, 10_000)];
        let av = plan(&ds, "avalanche", 20_000, d("2026-10-26"));
        let sb = plan(&ds, "snowball", 20_000, d("2026-10-26"));
        let min = plan(&ds, "minimum", 20_000, d("2026-10-26"));
        assert!(!av.never && !sb.never && !min.never);
        assert!(av.total_interest_cents <= sb.total_interest_cents);
        assert!(av.months < min.months);
        assert_eq!(av.debts[0].id, "big_high");
        assert_eq!(sb.debts[0].id, "small_low");
        assert_eq!(min.extra_cents, 0);
    }
}
