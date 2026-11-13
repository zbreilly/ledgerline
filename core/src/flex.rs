//! Flexible spending: the part of each monthly budget that isn't already a scheduled
//! bill or debt payment (groceries, dining, fuel, shopping, …). The cash-flow projection
//! spreads it evenly across each month so the forecast reflects day-to-day spending.

use std::collections::HashMap;

use chrono::{Datelike, NaiveDate};
use rusqlite::{params, Connection};

use crate::error::Result;
use crate::models::{FlexLine, FlexibleBudgets};
use crate::reports::{month_bounds, BUDGETED_T, EDT};
use crate::schedule::{monthly_equivalent, TxLite};

type Key = (String, Option<String>);

/// Monthly scheduled amounts (bills and debt payments) by the category/subcategory their
/// payments land in, inferred from the newest matching transaction.
fn scheduled_by_category(conn: &Connection, txs: &[TxLite], today: NaiveDate) -> Result<HashMap<Key, i64>> {
    let cat_ids: HashMap<String, String> = {
        let mut st = conn.prepare("SELECT name, id FROM categories")?;
        let rows = st.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?;
        rows.collect::<std::result::Result<_, _>>()?
    };
    let sub_ids: HashMap<(String, String), String> = {
        let mut st = conn.prepare("SELECT c.name, s.name, s.id FROM subcategories s JOIN categories c ON c.id = s.category_id")?;
        let rows = st.query_map([], |r| Ok(((r.get(0)?, r.get(1)?), r.get(2)?)))?;
        rows.collect::<std::result::Result<_, _>>()?
    };
    let infer = |key: &str, exact: Option<i64>| -> Option<Key> {
        if key.is_empty() {
            return None;
        }
        let t = txs
            .iter()
            .rev()
            .find(|t| t.key == key && t.amount_cents < 0 && exact.map(|c| -t.amount_cents == c).unwrap_or(true))?;
        let cat = cat_ids.get(t.category_name.as_ref()?)?.clone();
        let sub = t.subcategory_name.as_ref().and_then(|s| sub_ids.get(&(t.category_name.clone()?, s.clone())).cloned());
        Some((cat, sub))
    };
    let mut out: HashMap<Key, i64> = HashMap::new();
    for r in crate::recurring::list_with(conn, txs, today)?.into_iter().filter(|r| r.active && r.kind == "bill") {
        let monthly = monthly_equivalent(r.amount_cents, &r.frequency);
        let key = infer(&r.match_key, r.match_exact_amount.then_some(r.amount_cents)).or_else(|| r.category_id.clone().map(|c| (c, None)));
        if let Some(k) = key {
            *out.entry(k).or_insert(0) += monthly;
        }
    }
    for d in crate::debts::list_with(conn, txs, today)?.into_iter().filter(|d| d.payment_cents > 0 && d.payoff.status != "paid_off") {
        // Card minimums are paid from checking into Debt & Loans › Credit Cards.
        let card_line = || -> Option<Key> {
            let cat = cat_ids.get("Debt & Loans")?.clone();
            Some((cat, sub_ids.get(&("Debt & Loans".to_string(), "Credit Cards".to_string())).cloned()))
        };
        let key = if d.match_key.is_empty() && d.kind == "card" { card_line() } else { infer(&d.match_key, d.match_exact_amount.then_some(d.payment_cents)) };
        if let Some(k) = key {
            *out.entry(k).or_insert(0) += d.monthly_payment_cents;
        }
    }
    Ok(out)
}

pub fn flexible_budgets(conn: &Connection, txs: &[TxLite], today: NaiveDate) -> Result<FlexibleBudgets> {
    let scheduled = scheduled_by_category(conn, txs, today)?;
    let ym = format!("{}-{:02}", today.year(), today.month());
    let (from, to) = month_bounds(&ym);
    let mut st = conn.prepare(
        "SELECT b.category_id, b.subcategory_id, b.amount_cents, c.name, s.name
         FROM budgets b JOIN categories c ON c.id = b.category_id LEFT JOIN subcategories s ON s.id = b.subcategory_id
         WHERE c.kind = 'expense' AND b.amount_cents > 0",
    )?;
    let budgets: Vec<(String, Option<String>, i64, String, Option<String>)> =
        st.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)))?.collect::<std::result::Result<_, _>>()?;
    // A category-level budget replaces that category's subcategory budgets.
    let category_level: std::collections::HashSet<String> =
        budgets.iter().filter(|b| b.1.is_none()).map(|b| b.0.clone()).collect();
    let spent = |cat: &str, sub: Option<&str>| -> Result<i64> {
        let sql = format!(
            "SELECT COALESCE(SUM(-t.amount_cents), 0) FROM transactions t
             WHERE t.amount_cents < 0 AND {BUDGETED_T} AND {EDT} >= ?1 AND {EDT} < ?2 AND t.category_id = ?3
               AND (?4 IS NULL OR t.subcategory_id = ?4)"
        );
        Ok(conn.query_row(&sql, params![from, to, cat, sub], |r| r.get(0))?)
    };
    let mut lines = vec![];
    for (cat, sub, amount, cat_name, sub_name) in budgets {
        if sub.is_some() && category_level.contains(&cat) {
            continue;
        }
        let sched: i64 = scheduled
            .iter()
            .filter(|((c, s), _)| *c == cat && (sub.is_none() || *s == sub))
            .map(|(_, v)| *v)
            .sum();
        let flexible = (amount - sched).max(0);
        let spent_month = spent(&cat, sub.as_deref())?;
        // Spending beyond the scheduled part counts against the flexible part.
        let remaining = (flexible - (spent_month - sched).max(0)).max(0);
        lines.push(FlexLine {
            category_id: cat,
            subcategory_id: sub,
            name: match sub_name {
                Some(s) => format!("{cat_name} › {s}"),
                None => cat_name,
            },
            budget_cents: amount,
            scheduled_cents: sched,
            monthly_cents: flexible,
            spent_this_month_cents: spent_month,
            remaining_this_month_cents: remaining,
        });
    }
    // Scheduled amounts known only by category (no subcategory) use up that category's
    // subcategory budgets, largest flexible amount first.
    for ((cat, sub), amount) in scheduled.iter() {
        if sub.is_some() || category_level.contains(cat) {
            continue;
        }
        let mut left = *amount;
        let mut idx: Vec<usize> = (0..lines.len()).filter(|&i| lines[i].category_id == *cat).collect();
        idx.sort_by(|&a, &b| lines[b].monthly_cents.cmp(&lines[a].monthly_cents));
        for i in idx {
            if left <= 0 {
                break;
            }
            let take = left.min(lines[i].monthly_cents);
            lines[i].monthly_cents -= take;
            lines[i].scheduled_cents += take;
            lines[i].remaining_this_month_cents = lines[i].remaining_this_month_cents.min(lines[i].monthly_cents);
            left -= take;
        }
    }
    // Under $1 left after scheduled items is rounding, not real spending room.
    lines.retain(|l| l.monthly_cents >= 100);
    lines.sort_by(|a, b| b.monthly_cents.cmp(&a.monthly_cents));
    Ok(FlexibleBudgets {
        monthly_cents: lines.iter().map(|l| l.monthly_cents).sum(),
        remaining_this_month_cents: lines.iter().map(|l| l.remaining_this_month_cents).sum(),
        lines,
    })
}

/// Flexible spending assigned to each day from `today` through `to`: the current month's
/// remaining amount over its remaining days, full monthly amounts over later months.
/// Cents are spread so each month adds up exactly.
pub fn daily_spread(f: &FlexibleBudgets, today: NaiveDate, to: NaiveDate) -> HashMap<NaiveDate, i64> {
    let mut out = HashMap::new();
    let mut d = today;
    while d <= to {
        let dim = crate::reports::days_in_month(d.year(), d.month()) as i64;
        let current = d.year() == today.year() && d.month() == today.month();
        let (total, first_day, days) = if current {
            (f.remaining_this_month_cents, today.day() as i64, dim - today.day() as i64 + 1)
        } else {
            (f.monthly_cents, 1, dim)
        };
        let k = d.day() as i64 - first_day;
        let share = |k: i64| (total as f64 * k as f64 / days as f64).round() as i64;
        out.insert(d, share(k + 1) - share(k));
        d = d.succ_opt().unwrap();
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn spread_adds_up_per_month() {
        let f = FlexibleBudgets { lines: vec![], monthly_cents: 181_500, remaining_this_month_cents: 50_000 };
        let today = NaiveDate::from_ymd_opt(2026, 10, 26).unwrap();
        let to = NaiveDate::from_ymd_opt(2026, 11, 30).unwrap();
        let s = daily_spread(&f, today, to);
        let oct: i64 = s.iter().filter(|(d, _)| d.month() == 10).map(|(_, v)| v).sum();
        let nov: i64 = s.iter().filter(|(d, _)| d.month() == 11).map(|(_, v)| v).sum();
        assert_eq!(oct, 50_000);
        assert_eq!(nov, 181_500);
        assert_eq!(s.len(), 36);
    }
}
