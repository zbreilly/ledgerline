//! Paycheck-aware cash-flow calendar: scheduled income, bills, and debt payments on dates,
//! matched against real transactions, with a projected cash balance.

use std::collections::{BTreeMap, HashSet};

use chrono::{Datelike, Duration, NaiveDate};
use rusqlite::Connection;

use crate::error::Result;
use crate::models::*;
use crate::reports::{add_months, month_bounds};
use crate::schedule::*;

#[derive(Clone)]
struct Source {
    id: String,
    name: String,
    kind: &'static str,
    amount: i64,
    freq: String,
    anchor: NaiveDate,
    key: String,
    exact: bool,
    affects_cash: bool,
    /// Last scheduled date for debts that end (from the payoff estimate).
    last_date: Option<NaiveDate>,
    /// Card/loan account whose payment credits mark this debt paid (when it has no merchant key).
    account: Option<String>,
}

impl Source {
    fn sign(&self) -> i64 {
        if self.kind == "income" { 1 } else { -1 }
    }
    fn window(&self) -> i64 {
        match self.freq.as_str() {
            "weekly" => 2,
            "biweekly" => 4,
            _ => 5,
        }
    }
}

struct Ctx {
    sources: Vec<Source>,
    txs: Vec<TxLite>,
    today: NaiveDate,
    data_end: NaiveDate,
    start_balance: i64,
    needs_setup: bool,
    main_income: Option<Source>,
    flex: FlexibleBudgets,
}

fn load(conn: &Connection, today: NaiveDate) -> Result<Ctx> {
    let txs = load_txs(conn)?;
    let data_end = txs.iter().map(|t| t.date).max().unwrap_or(today);
    let mut sources = vec![];
    for r in crate::recurring::list_with(conn, &txs, today)?.into_iter().filter(|r| r.active) {
        let Some(anchor) = parse_date(&r.anchor_date) else { continue };
        sources.push(Source {
            id: r.id,
            name: r.name,
            kind: if r.kind == "income" { "income" } else { "bill" },
            amount: r.amount_cents,
            freq: r.frequency,
            anchor,
            key: r.match_key,
            exact: r.match_exact_amount,
            affects_cash: r.affects_cash,
            last_date: None,
            account: None,
        });
    }
    for d in crate::debts::list_with(conn, &txs, today)? {
        if d.payment_cents <= 0 || d.payoff.status == "paid_off" {
            continue;
        }
        let Some(anchor) = d.next_due.as_deref().and_then(parse_date) else { continue };
        // Stop showing payments after the expected final one.
        let last_date = match (d.payoff.payments.or(d.payments_left_now), d.next_payment_date.as_deref().and_then(parse_date)) {
            (Some(n), Some(first)) if n > 0 => Some(nth_after(&d.frequency, first, n - 1)),
            _ => None,
        };
        let account = if d.match_key.is_empty() && d.balance_source == "account" { d.account_id.clone() } else { None };
        sources.push(Source {
            id: d.id,
            name: d.name,
            kind: "debt",
            amount: d.payment_cents,
            freq: d.frequency,
            anchor,
            key: d.match_key,
            exact: d.match_exact_amount,
            affects_cash: true,
            last_date,
            account,
        });
    }
    let (start_balance, needs_setup): (i64, bool) = conn.query_row(
        "SELECT COALESCE(SUM(CASE WHEN a.balance_set = 1 THEN a.balance_cents
            ELSE COALESCE((SELECT SUM(amount_cents) FROM transactions t WHERE t.account_id = a.id), a.balance_cents) END), 0),
           COALESCE(MAX(CASE WHEN a.balance_set = 1 THEN 0 ELSE 1 END), 0)
         FROM accounts a WHERE a.archived = 0 AND a.type IN ('checking', 'savings', 'cash')",
        [],
        |r| Ok((r.get(0)?, r.get::<_, i64>(1)? != 0)),
    )?;
    let main_income = sources
        .iter()
        .filter(|s| s.kind == "income")
        .max_by_key(|s| monthly_equivalent(s.amount, &s.freq))
        .cloned();
    let flex = crate::flex::flexible_budgets(conn, &txs, today)?;
    Ok(Ctx { sources, txs, today, data_end, start_balance, needs_setup, main_income, flex })
}

/// Scheduled events in [from, to] with paid / missed / upcoming status.
fn events(ctx: &Ctx, from: NaiveDate, to: NaiveDate) -> Vec<CalendarEvent> {
    // Start matching a few weeks early so earlier occurrences claim their own payments
    // before a later one in range could grab them.
    let alloc_from = from - Duration::days(40);
    let mut pairs: Vec<(NaiveDate, usize)> = vec![];
    for (si, s) in ctx.sources.iter().enumerate() {
        for d in occurrences(&s.freq, s.anchor, alloc_from, to) {
            if s.last_date.map(|l| d > l).unwrap_or(false) {
                continue;
            }
            pairs.push((d, si));
        }
    }
    pairs.sort();
    let mut used: HashSet<usize> = HashSet::new();
    let mut out = vec![];
    for (date, si) in pairs {
        let s = &ctx.sources[si];
        let m = Matcher {
            key: &s.key,
            exact_cents: if s.exact { Some(s.amount) } else { None },
            sign: s.sign(),
            account: s.account.as_deref(),
            before_days: 31,
        };
        let hit = find_match(&ctx.txs, &mut used, &m, date, s.window());
        if date < from {
            continue;
        }
        let status = match (hit, date < ctx.today) {
            (Some(_), _) => "paid",
            (None, false) => "upcoming",
            (None, true) => {
                // Debts only show past payments we can see; their schedules may predate the loan.
                // Bills only from the date they were first seen.
                if s.kind == "debt" || date < s.anchor {
                    continue;
                }
                if date > ctx.data_end || s.key.is_empty() { "unknown" } else { "missed" }
            }
        };
        out.push(CalendarEvent {
            date: fmt_date(date),
            kind: s.kind.into(),
            name: s.name.clone(),
            amount_cents: s.sign() * s.amount,
            source_id: s.id.clone(),
            status: status.into(),
            actual_cents: hit.map(|i| ctx.txs[i].amount_cents),
            affects_cash: s.affects_cash,
            counts_in_month: hit
                .and_then(|i| ctx.txs[i].report_month.clone())
                .unwrap_or_else(|| fmt_date(date)[..7].to_string()),
        });
    }
    out
}

/// End-of-day projected cash for each day in [today, to].
fn projection(ctx: &Ctx, to: NaiveDate) -> BTreeMap<NaiveDate, i64> {
    let mut map = BTreeMap::new();
    if to < ctx.today {
        return map;
    }
    let evs = events(ctx, ctx.today, to);
    let spread = crate::flex::daily_spread(&ctx.flex, ctx.today, to);
    let mut bal = ctx.start_balance;
    let mut d = ctx.today;
    while d <= to {
        let ds = fmt_date(d);
        bal += evs.iter().filter(|e| e.date == ds && e.status == "upcoming" && e.affects_cash).map(|e| e.amount_cents).sum::<i64>();
        bal -= spread.get(&d).copied().unwrap_or(0);
        map.insert(d, bal);
        d += Duration::days(1);
    }
    map
}

/// Events that count toward `ym`, including ones dated in a neighboring month whose
/// transaction was moved into it (e.g. an Oct 1 paycheck counted in September).
fn events_counting_in(ctx: &Ctx, ym: &str) -> Vec<CalendarEvent> {
    let (f, t) = month_bounds(ym);
    let from = parse_date(&f).unwrap() - Duration::days(31);
    let to = parse_date(&t).unwrap() + Duration::days(30);
    events(ctx, from, to).into_iter().filter(|e| e.counts_in_month == ym).collect()
}

pub fn calendar(conn: &Connection, month: &str, today: NaiveDate) -> Result<CalendarMonth> {
    let ctx = load(conn, today)?;
    let (from_s, to_excl) = month_bounds(month);
    let from = parse_date(&from_s).unwrap();
    let to = parse_date(&to_excl).unwrap() - Duration::days(1);
    let evs = events(&ctx, from, to);
    let proj = projection(&ctx, to);
    let mut days = vec![];
    let mut d = from;
    while d <= to {
        let ds = fmt_date(d);
        days.push(CalendarDay {
            events: evs.iter().filter(|e| e.date == ds).cloned().collect(),
            projected_balance_cents: proj.get(&d).copied(),
            date: ds,
        });
        d += Duration::days(1);
    }
    let lowest = days
        .iter()
        .filter_map(|d| d.projected_balance_cents.map(|b| (b, d.date.clone())))
        .min_by_key(|x| x.0);
    let amount = |e: &CalendarEvent| e.actual_cents.unwrap_or(e.amount_cents).abs();
    let main_id = ctx.main_income.as_ref().map(|m| m.id.clone());
    let paychecks_in = |evs: &[CalendarEvent]| evs.iter().filter(|e| Some(&e.source_id) == main_id.as_ref()).count();
    let counted = events_counting_in(&ctx, month);
    let three = match &ctx.main_income {
        Some(_) => {
            let cur = format!("{}-{:02}", today.year(), today.month());
            (0..12).map(|i| add_months(&cur, i)).filter(|ym| paychecks_in(&events_counting_in(&ctx, ym)) >= 3).collect()
        }
        None => vec![],
    };
    Ok(CalendarMonth {
        month: month.into(),
        today: fmt_date(today),
        paychecks: paychecks_in(&counted) as u32,
        income_cents: counted.iter().filter(|e| e.kind == "income").map(amount).sum(),
        bills_cents: counted.iter().filter(|e| e.kind == "bill").map(amount).sum(),
        debt_cents: counted.iter().filter(|e| e.kind == "debt").map(amount).sum(),
        start_balance_cents: ctx.start_balance,
        balance_needs_setup: ctx.needs_setup,
        lowest_balance_cents: lowest.as_ref().map(|l| l.0),
        lowest_date: lowest.map(|l| l.1),
        three_paycheck_months: three,
        main_income_name: ctx.main_income.as_ref().map(|m| m.name.clone()),
        flexible_cents: if to < today {
            0
        } else {
            crate::flex::daily_spread(&ctx.flex, today, to).iter().filter(|(d, _)| **d >= from).map(|(_, v)| *v).sum()
        },
        days,
    })
}

/// Pay periods (payday to the day before the next payday), starting with the current one.
pub fn pay_periods(conn: &Connection, count: u32, today: NaiveDate) -> Result<Vec<PayPeriod>> {
    let ctx = load(conn, today)?;
    let Some(main) = ctx.main_income.clone() else { return Ok(vec![]) };
    let span = interval_days(&main.freq) * (count as i64 + 2);
    let paydays = occurrences(&main.freq, main.anchor, today - Duration::days(interval_days(&main.freq) + 1), today + Duration::days(span));
    let first = paydays.iter().rposition(|p| *p <= today).unwrap_or(0);
    let ends: Vec<NaiveDate> = paydays.iter().skip(first + 1).map(|p| *p - Duration::days(1)).collect();
    let last_end = ends.iter().take(count as usize).last().copied().unwrap_or(today);
    let proj = projection(&ctx, last_end);
    let spread = crate::flex::daily_spread(&ctx.flex, today, last_end.max(today));
    let flex_in = |a: NaiveDate, b: NaiveDate| -> i64 { spread.iter().filter(|(d, _)| **d >= a && **d <= b).map(|(_, v)| *v).sum() };
    let mut out = vec![];
    for (i, start) in paydays.iter().skip(first).take(count as usize).enumerate() {
        let Some(&end) = ends.get(i) else { break };
        let evs = events(&ctx, *start, end);
        let amt = |e: &CalendarEvent| e.actual_cents.unwrap_or(e.amount_cents).abs();
        let paycheck: i64 = evs.iter().filter(|e| e.source_id == main.id).map(amt).sum();
        let other: i64 = evs.iter().filter(|e| e.kind == "income" && e.source_id != main.id).map(amt).sum();
        let bills: i64 = evs.iter().filter(|e| e.kind == "bill" && e.affects_cash).map(amt).sum();
        let debt: i64 = evs.iter().filter(|e| e.kind == "debt").map(amt).sum();
        out.push(PayPeriod {
            start: fmt_date(*start),
            end: fmt_date(end),
            is_current: *start <= today && today <= end,
            paycheck_cents: paycheck,
            other_income_cents: other,
            bills_cents: bills,
            debt_cents: debt,
            flexible_cents: flex_in(*start, end),
            leftover_cents: paycheck + other - bills - debt - flex_in(*start, end),
            ending_balance_cents: proj.get(&end).copied(),
            events: evs.into_iter().filter(|e| e.source_id != main.id).collect(),
        });
    }
    Ok(out)
}
