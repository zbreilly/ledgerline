//! Dashboard, cash-flow, breakdown, planning, and account reports.
//! Every report excludes transfers (`is_transfer = 1`).

use std::collections::HashMap;

use chrono::{Datelike, Local, NaiveDate};
use regex::Regex;
use rusqlite::types::Value;
use rusqlite::{params, params_from_iter, Connection};

use crate::error::Result;
use crate::models::*;

const MONTH_LABELS: [&str; 12] = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

/// The date a transaction counts on in monthly reports. A transaction moved to another
/// month (report_month, "YYYY-MM") counts on the 1st of that month; otherwise its own date.
pub const ED: &str = "COALESCE(report_month || '-01', date)";
pub const EDT: &str = "COALESCE(t.report_month || '-01', t.date)";
/// Counts toward a budget: normal spending, plus transfers you filed under a spending
/// category (card payments under Debt & Loans › Credit Cards). Spending totals still skip them,
/// because the card purchases themselves are already counted.
pub const BUDGETED: &str = "(is_transfer = 0 OR category_id IN (SELECT id FROM categories WHERE kind = 'expense' AND name != 'Transfers'))";
pub const BUDGETED_T: &str = "(t.is_transfer = 0 OR t.category_id IN (SELECT id FROM categories WHERE kind = 'expense' AND name != 'Transfers'))";

pub fn current_ym() -> String {
    let d = Local::now().date_naive();
    format!("{}-{:02}", d.year(), d.month())
}

pub fn today() -> NaiveDate {
    Local::now().date_naive()
}

fn parse_ym(ym: &str) -> (i32, u32) {
    let mut it = ym.split('-');
    let y = it.next().and_then(|s| s.parse().ok()).unwrap_or(2000);
    let m = it.next().and_then(|s| s.parse().ok()).unwrap_or(1);
    (y, m.clamp(1, 12))
}

pub fn add_months(ym: &str, n: i32) -> String {
    let (y, m) = parse_ym(ym);
    let total = y * 12 + (m as i32 - 1) + n;
    format!("{}-{:02}", total.div_euclid(12), total.rem_euclid(12) + 1)
}

/// (first day, first day of next month)
pub fn month_bounds(ym: &str) -> (String, String) {
    let (y, m) = parse_ym(ym);
    (format!("{y}-{m:02}-01"), format!("{}-01", add_months(&format!("{y}-{m:02}"), 1)))
}

pub fn days_in_month(y: i32, m: u32) -> u32 {
    let (ny, nm) = if m == 12 { (y + 1, 1) } else { (y, m + 1) };
    NaiveDate::from_ymd_opt(ny, nm, 1).unwrap().pred_opt().unwrap().day()
}

fn month_label(ym: &str) -> String {
    let (y, m) = parse_ym(ym);
    format!("{} '{:02}", MONTH_LABELS[(m - 1) as usize], y.rem_euclid(100))
}

/// Optional single-account filter appended to a WHERE clause.
fn acc_cond(account: Option<&str>, alias: &str) -> (String, Vec<Value>) {
    match account {
        Some(a) if !a.is_empty() && a != "all" => {
            let col = if alias.is_empty() { "account_id".to_string() } else { format!("{alias}.account_id") };
            (format!(" AND {col} = ?"), vec![Value::Text(a.to_string())])
        }
        _ => (String::new(), vec![]),
    }
}

fn vals(head: &[&str], tail: &[Value]) -> Vec<Value> {
    head.iter().map(|s| Value::Text(s.to_string())).chain(tail.iter().cloned()).collect()
}

pub fn cashflow(conn: &Connection, ym: &str, count: u32, account: Option<&str>) -> Result<Vec<MonthFlow>> {
    let count = count.clamp(1, 36) as i32;
    let months: Vec<String> = (0..count).rev().map(|i| add_months(ym, -i)).collect();
    let (acc, accp) = acc_cond(account, "");
    let sql = format!(
        "SELECT substr({ED}, 1, 7) AS ym,
           COALESCE(SUM(CASE WHEN amount_cents > 0 THEN amount_cents END), 0),
           COALESCE(SUM(CASE WHEN amount_cents < 0 THEN -amount_cents END), 0)
         FROM transactions WHERE is_transfer = 0 AND {ED} >= ? AND {ED} < ?{acc} GROUP BY ym"
    );
    let from = format!("{}-01", months[0]);
    let to = format!("{}-01", add_months(ym, 1));
    let mut st = conn.prepare(&sql)?;
    let map: HashMap<String, (i64, i64)> = st
        .query_map(params_from_iter(vals(&[&from, &to], &accp)), |r| Ok((r.get(0)?, (r.get(1)?, r.get(2)?))))?
        .collect::<std::result::Result<_, _>>()?;
    Ok(months
        .iter()
        .map(|m| {
            let (inc, exp) = map.get(m).copied().unwrap_or((0, 0));
            MonthFlow { ym: m.clone(), label: month_label(m), income_cents: inc, expense_cents: exp, net_cents: inc - exp }
        })
        .collect())
}

pub fn breakdown(conn: &Connection, ym: &str, income: bool, account: Option<&str>) -> Result<Breakdown> {
    let (from, to) = month_bounds(ym);
    let sign = if income { ">" } else { "<" };
    let (acc, accp) = acc_cond(account, "t");
    let p = vals(&[&from, &to], &accp);
    let mut st = conn.prepare(&format!(
        "SELECT c.id, c.name, c.color, c.icon, SUM(ABS(t.amount_cents)) AS total, COUNT(*)
         FROM transactions t JOIN categories c ON c.id = t.category_id
         WHERE t.amount_cents {sign} 0 AND t.is_transfer = 0 AND {EDT} >= ? AND {EDT} < ?{acc}
         GROUP BY c.id ORDER BY total DESC"
    ))?;
    let mut cats: Vec<BreakdownCategory> = st
        .query_map(params_from_iter(p.clone()), |r| {
            Ok(BreakdownCategory {
                id: r.get(0)?,
                name: r.get(1)?,
                color: r.get::<_, Option<String>>(2)?.unwrap_or_default(),
                icon: r.get::<_, Option<String>>(3)?.unwrap_or_default(),
                total_cents: r.get(4)?,
                count: r.get::<_, i64>(5)? as u32,
                subcategories: vec![],
            })
        })?
        .collect::<std::result::Result<_, _>>()?;
    let mut st = conn.prepare(&format!(
        "SELECT s.category_id, s.id, s.name, SUM(ABS(t.amount_cents)) AS total, COUNT(*)
         FROM transactions t JOIN subcategories s ON s.id = t.subcategory_id
         WHERE t.amount_cents {sign} 0 AND t.is_transfer = 0 AND {EDT} >= ? AND {EDT} < ?{acc}
         GROUP BY s.id ORDER BY total DESC"
    ))?;
    let subs: Vec<(String, BreakdownSub)> = st
        .query_map(params_from_iter(p), |r| {
            Ok((r.get(0)?, BreakdownSub { id: r.get(1)?, name: r.get(2)?, total_cents: r.get(3)?, count: r.get::<_, i64>(4)? as u32 }))
        })?
        .collect::<std::result::Result<_, _>>()?;
    for c in cats.iter_mut() {
        c.subcategories = subs.iter().filter(|(cid, _)| *cid == c.id).map(|(_, s)| s.clone()).collect();
    }
    let (acc0, accp0) = acc_cond(account, "");
    let (unc_total, unc_n): (i64, i64) = conn.query_row(
        &format!(
            "SELECT COALESCE(SUM(ABS(amount_cents)), 0), COUNT(*) FROM transactions
             WHERE amount_cents {sign} 0 AND is_transfer = 0 AND {ED} >= ? AND {ED} < ? AND category_id IS NULL{acc0}"
        ),
        params_from_iter(vals(&[&from, &to], &accp0)),
        |r| Ok((r.get(0)?, r.get(1)?)),
    )?;
    Ok(Breakdown {
        kind: if income { "income" } else { "expense" }.into(),
        month: ym.into(),
        uncategorized_cents: unc_total,
        uncategorized_count: unc_n as u32,
        categories: cats,
    })
}

fn in_out(conn: &Connection, from: &str, to: &str, account: Option<&str>) -> Result<(i64, i64, i64)> {
    let (acc, accp) = acc_cond(account, "");
    Ok(conn.query_row(
        &format!(
            "SELECT COALESCE(SUM(CASE WHEN amount_cents > 0 THEN amount_cents END), 0),
                    COALESCE(SUM(CASE WHEN amount_cents < 0 THEN -amount_cents END), 0), COUNT(*)
             FROM transactions WHERE is_transfer = 0 AND {ED} >= ? AND {ED} < ?{acc}"
        ),
        params_from_iter(vals(&[from, to], &accp)),
        |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
    )?)
}

const DISPLAY_BALANCE: &str = "CASE WHEN a.balance_set = 1 THEN a.balance_cents
  ELSE COALESCE((SELECT SUM(amount_cents) FROM transactions t WHERE t.account_id = a.id), a.balance_cents) END";

fn liquid_balance(conn: &Connection) -> Result<i64> {
    Ok(conn.query_row(
        &format!("SELECT COALESCE(SUM({DISPLAY_BALANCE}), 0) FROM accounts a WHERE a.archived = 0 AND a.type IN ('checking','savings','cash')"),
        [],
        |r| r.get(0),
    )?)
}

pub const TX_SELECT: &str = "SELECT t.id, t.account_id, t.date, t.description, t.merchant, t.amount_cents, t.category_id,
    t.subcategory_id, t.notes, t.is_transfer, t.import_batch_id, a.name, a.color, c.name, c.color, c.icon, s.name, t.report_month, t.split_of
  FROM transactions t
  LEFT JOIN categories c ON c.id = t.category_id
  LEFT JOIN subcategories s ON s.id = t.subcategory_id
  LEFT JOIN accounts a ON a.id = t.account_id";

pub fn row_to_tx(r: &rusqlite::Row) -> rusqlite::Result<Transaction> {
    Ok(Transaction {
        id: r.get(0)?,
        account_id: r.get(1)?,
        date: r.get(2)?,
        description: r.get(3)?,
        merchant: r.get::<_, Option<String>>(4)?.unwrap_or_default(),
        amount_cents: r.get(5)?,
        category_id: r.get(6)?,
        subcategory_id: r.get(7)?,
        notes: r.get::<_, Option<String>>(8)?.unwrap_or_default(),
        is_transfer: r.get::<_, Option<i64>>(9)?.unwrap_or(0) != 0,
        import_batch_id: r.get(10)?,
        account_name: r.get(11)?,
        account_color: r.get(12)?,
        category_name: r.get(13)?,
        category_color: r.get(14)?,
        category_icon: r.get(15)?,
        subcategory_name: r.get(16)?,
        report_month: r.get(17)?,
        split_of: r.get(18)?,
    })
}

pub fn overview(conn: &Connection, ym: &str, account: Option<&str>) -> Result<Overview> {
    let (from, to) = month_bounds(ym);
    let (pfrom, pto) = month_bounds(&add_months(ym, -1));
    let (inc, exp, n) = in_out(conn, &from, &to, account)?;
    let (pinc, pexp, _) = in_out(conn, &pfrom, &pto, account)?;
    let (acc0, accp0) = acc_cond(account, "");
    let uncategorized: i64 = conn.query_row(
        &format!("SELECT COUNT(*) FROM transactions WHERE category_id IS NULL{acc0}"),
        params_from_iter(accp0.clone()),
        |r| r.get(0),
    )?;
    let mut st = conn.prepare(&format!(
        "SELECT COALESCE(NULLIF(merchant, ''), description) AS m, SUM(-amount_cents) AS total, COUNT(*)
         FROM transactions WHERE amount_cents < 0 AND is_transfer = 0 AND {ED} >= ? AND {ED} < ?{acc0}
         GROUP BY m ORDER BY total DESC LIMIT 8"
    ))?;
    let merchants = st
        .query_map(params_from_iter(vals(&[&from, &to], &accp0)), |r| {
            Ok(MerchantTotal { name: r.get(0)?, total_cents: r.get(1)?, count: r.get::<_, i64>(2)? as u32 })
        })?
        .collect::<std::result::Result<_, _>>()?;
    let (acct, accpt) = acc_cond(account, "t");
    let mut st = conn.prepare(&format!("{TX_SELECT} WHERE 1=1{acct} ORDER BY t.date DESC, t.rowid DESC LIMIT 8"))?;
    let recent = st.query_map(params_from_iter(accpt), row_to_tx)?.collect::<std::result::Result<_, _>>()?;
    Ok(Overview {
        month: ym.into(),
        income_cents: inc,
        expense_cents: exp,
        net_cents: inc - exp,
        tx_count: n as u32,
        prev_income_cents: pinc,
        prev_expense_cents: pexp,
        prev_net_cents: pinc - pexp,
        savings_rate: if inc > 0 { Some((inc - exp) as f64 / inc as f64) } else { None },
        uncategorized: uncategorized as u32,
        liquid_balance_cents: liquid_balance(conn)?,
        merchants,
        recent,
        series: cashflow(conn, ym, 6, account)?,
    })
}

pub fn planning(conn: &Connection, ym: &str, account: Option<&str>) -> Result<Planning> {
    let (from, to) = month_bounds(ym);
    let (m3from, _) = month_bounds(&add_months(ym, -3));
    let (cur_inc, cur_exp, _) = in_out(conn, &from, &to, account)?;
    let (l3_inc, l3_exp, _) = in_out(conn, &m3from, &to, account)?;
    let avg_exp = l3_exp as f64 / 3.0;
    let avg_inc = l3_inc as f64 / 3.0;
    let liquid = liquid_balance(conn)?;

    let mut st = conn.prepare(
        "SELECT b.id, b.category_id, b.subcategory_id, b.amount_cents, c.name, c.color, c.icon, s.name
         FROM budgets b JOIN categories c ON c.id = b.category_id LEFT JOIN subcategories s ON s.id = b.subcategory_id
         ORDER BY c.sort, c.name COLLATE NOCASE",
    )?;
    let budgets_raw: Vec<BudgetLine> = st
        .query_map([], |r| {
            Ok(BudgetLine {
                id: r.get(0)?,
                category_id: r.get(1)?,
                subcategory_id: r.get(2)?,
                amount_cents: r.get(3)?,
                category_name: r.get(4)?,
                category_color: r.get::<_, Option<String>>(5)?.unwrap_or_default(),
                category_icon: r.get::<_, Option<String>>(6)?.unwrap_or_default(),
                subcategory_name: r.get(7)?,
                actual_cents: 0,
                remaining_cents: 0,
                pct: 0.0,
            })
        })?
        .collect::<std::result::Result<_, _>>()?;

    let (acc0, accp0) = acc_cond(account, "");
    let actuals = |col: &str| -> Result<HashMap<String, (i64, u32)>> {
        let mut st = conn.prepare(&format!(
            "SELECT {col}, SUM(-amount_cents), COUNT(*) FROM transactions
             WHERE amount_cents < 0 AND {BUDGETED} AND {ED} >= ? AND {ED} < ? AND {col} IS NOT NULL{acc0}
             GROUP BY {col}"
        ))?;
        let m = st
            .query_map(params_from_iter(vals(&[&from, &to], &accp0)), |r| Ok((r.get(0)?, (r.get(1)?, r.get::<_, i64>(2)? as u32))))?
            .collect::<std::result::Result<_, _>>()?;
        Ok(m)
    };
    let cat_act = actuals("category_id")?;
    let sub_act = actuals("subcategory_id")?;

    let budgets: Vec<BudgetLine> = budgets_raw
        .into_iter()
        .map(|mut b| {
            let actual = match &b.subcategory_id {
                Some(s) => sub_act.get(s).map(|x| x.0).unwrap_or(0),
                None => cat_act.get(&b.category_id).map(|x| x.0).unwrap_or(0),
            };
            b.actual_cents = actual;
            b.remaining_cents = b.amount_cents - actual;
            b.pct = if b.amount_cents > 0 { actual as f64 / b.amount_cents as f64 } else { 0.0 };
            b
        })
        .collect();
    let by_cat: HashMap<&str, &BudgetLine> =
        budgets.iter().filter(|b| b.subcategory_id.is_none()).map(|b| (b.category_id.as_str(), b)).collect();
    let by_sub: HashMap<&str, &BudgetLine> =
        budgets.iter().filter_map(|b| b.subcategory_id.as_deref().map(|s| (s, b))).collect();

    let mut st = conn.prepare(
        "SELECT id, name, color, icon FROM categories WHERE kind = 'expense' AND archived = 0 ORDER BY sort, name COLLATE NOCASE",
    )?;
    let cats: Vec<(String, String, String, String)> = st
        .query_map([], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get::<_, Option<String>>(2)?.unwrap_or_default(), r.get::<_, Option<String>>(3)?.unwrap_or_default()))
        })?
        .collect::<std::result::Result<_, _>>()?;
    let mut st = conn.prepare("SELECT id, category_id, name FROM subcategories WHERE archived = 0 ORDER BY sort, name COLLATE NOCASE")?;
    let subs: Vec<(String, String, String)> =
        st.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?.collect::<std::result::Result<_, _>>()?;

    let tree: Vec<PlanCategory> = cats
        .into_iter()
        .map(|(id, name, color, icon)| {
            let (actual, n) = cat_act.get(&id).copied().unwrap_or((0, 0));
            let b = by_cat.get(id.as_str());
            let subcategories = subs
                .iter()
                .filter(|s| s.1 == id)
                .map(|s| {
                    let (a, n) = sub_act.get(&s.0).copied().unwrap_or((0, 0));
                    let sb = by_sub.get(s.0.as_str());
                    PlanSub {
                        id: s.0.clone(),
                        name: s.2.clone(),
                        actual_cents: a,
                        count: n,
                        budget_id: sb.map(|x| x.id.clone()),
                        budget_cents: sb.map(|x| x.amount_cents).unwrap_or(0),
                    }
                })
                .filter(|s| s.actual_cents > 0 || s.budget_cents > 0)
                .collect::<Vec<_>>();
            PlanCategory {
                id,
                name,
                color,
                icon,
                actual_cents: actual,
                count: n,
                budget_id: b.map(|x| x.id.clone()),
                budget_cents: b.map(|x| x.amount_cents).unwrap_or(0),
                subcategories,
            }
        })
        .filter(|c| c.actual_cents > 0 || c.budget_cents > 0 || !c.subcategories.is_empty())
        .collect();

    // A category-level budget overrides the sum of its subcategory budgets.
    let budgeted: i64 = tree
        .iter()
        .map(|c| if c.budget_cents > 0 { c.budget_cents } else { c.subcategories.iter().map(|s| s.budget_cents).sum() })
        .sum();

    let now = today();
    let is_current = ym == current_ym();
    let (y, m) = parse_ym(ym);
    let dim = days_in_month(y, m);
    let day = if is_current { now.day() } else { 31 };
    let pace = ((cur_exp as f64 / day as f64) * dim as f64).round() as i64;

    Ok(Planning {
        month: ym.into(),
        budgets,
        tree,
        budgeted_cents: budgeted,
        actual_cents: cur_exp,
        income_cents: cur_inc,
        metrics: PlanMetrics {
            savings_rate_month: if cur_inc > 0 { Some((cur_inc - cur_exp) as f64 / cur_inc as f64) } else { None },
            savings_rate_3m: if l3_inc > 0 { Some((l3_inc - l3_exp) as f64 / l3_inc as f64) } else { None },
            avg_expense_3m_cents: avg_exp.round() as i64,
            avg_income_3m_cents: avg_inc.round() as i64,
            liquid_balance_cents: liquid,
            runway_months: if avg_exp > 0.0 { Some(liquid as f64 / avg_exp) } else { None },
            projected_expense_cents: if is_current { Some(pace) } else { None },
        },
        series: cashflow(conn, ym, 6, account)?,
    })
}

// ---------- accounts ----------

pub fn list_accounts(conn: &Connection, ym: &str) -> Result<Vec<Account>> {
    let (from, to) = month_bounds(ym);
    let mut st = conn.prepare(&format!(
        "SELECT a.id, a.name, a.institution, a.type, a.balance_cents, a.balance_set, a.currency, a.color, a.archived, a.due_day,
           {DISPLAY_BALANCE},
           (SELECT COUNT(*) FROM transactions t WHERE t.account_id = a.id),
           (SELECT COALESCE(SUM(CASE WHEN t.amount_cents > 0 THEN t.amount_cents END), 0) FROM transactions t WHERE t.account_id = a.id AND t.is_transfer = 0),
           (SELECT COALESCE(SUM(CASE WHEN t.amount_cents < 0 THEN -t.amount_cents END), 0) FROM transactions t WHERE t.account_id = a.id AND t.is_transfer = 0),
           (SELECT COALESCE(SUM(CASE WHEN t.amount_cents > 0 THEN t.amount_cents END), 0) FROM transactions t WHERE t.account_id = a.id AND t.is_transfer = 0 AND {EDT} >= ?1 AND {EDT} < ?2),
           (SELECT COALESCE(SUM(CASE WHEN t.amount_cents < 0 THEN -t.amount_cents END), 0) FROM transactions t WHERE t.account_id = a.id AND t.is_transfer = 0 AND {EDT} >= ?1 AND {EDT} < ?2),
           (SELECT MAX(t.date) FROM transactions t WHERE t.account_id = a.id)
         FROM accounts a WHERE a.archived = 0 ORDER BY a.name COLLATE NOCASE"
    ))?;
    let rows = st
        .query_map(params![from, to], |r| {
            Ok(Account {
                id: r.get(0)?,
                name: r.get(1)?,
                institution: r.get::<_, Option<String>>(2)?.unwrap_or_default(),
                kind: r.get::<_, Option<String>>(3)?.unwrap_or_else(|| "checking".into()),
                balance_cents: r.get::<_, Option<i64>>(4)?.unwrap_or(0),
                balance_set: r.get::<_, Option<i64>>(5)?.unwrap_or(0) != 0,
                currency: r.get::<_, Option<String>>(6)?.unwrap_or_else(|| "USD".into()),
                color: r.get::<_, Option<String>>(7)?.unwrap_or_else(|| "#6d7cff".into()),
                archived: r.get::<_, Option<i64>>(8)?.unwrap_or(0) != 0,
                due_day: r.get::<_, Option<i64>>(9)?.unwrap_or(0).clamp(0, 31) as u32,
                display_balance_cents: r.get::<_, Option<i64>>(10)?.unwrap_or(0),
                tx_count: r.get::<_, i64>(11)? as u32,
                all_in_cents: r.get(12)?,
                all_out_cents: r.get(13)?,
                month_in_cents: r.get(14)?,
                month_out_cents: r.get(15)?,
                last_activity: r.get(16)?,
            })
        })?
        .collect::<std::result::Result<_, _>>()?;
    Ok(rows)
}

fn debt_health(conn: &Connection, account_id: &str, due_day: u32) -> Result<DebtHealth> {
    let fee_re = Regex::new(
        r"(?i)\b(late\s*(fee|charge|payment)|penalt|over.?limit|returned payment|delinquen|Collections?|Institute of Credit)\b",
    )
    .unwrap();
    let mut st = conn.prepare(
        "SELECT date, amount_cents, description, COALESCE(merchant, '') FROM transactions
         WHERE account_id = ?1 AND is_transfer = 0 ORDER BY date",
    )?;
    let txs: Vec<(String, i64, String, String)> =
        st.query_map([account_id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))?.collect::<std::result::Result<_, _>>()?;
    let parse = |s: &str| NaiveDate::parse_from_str(s, "%Y-%m-%d").ok();
    let fees: Vec<(Option<NaiveDate>, i64)> = txs
        .iter()
        .filter(|t| t.1 < 0 && fee_re.is_match(&format!("{} {}", t.2, t.3)))
        .map(|t| (parse(&t.0), t.1))
        .collect();
    let payments: Vec<Option<NaiveDate>> = txs.iter().filter(|t| t.1 > 0).map(|t| parse(&t.0)).collect();
    let mut h = DebtHealth {
        late_fee_count: fees.len() as u32,
        late_fee_total_cents: fees.iter().map(|f| -f.1).sum(),
        on_time_pct: None,
        on_time_months: 0,
        total_months: 0,
    };
    if due_day == 0 || payments.is_empty() || txs.is_empty() {
        return Ok(h);
    }
    let now = today();
    let (mut y, mut m) = parse_ym(&txs[0].0[..7.min(txs[0].0.len())]);
    let (cy, cm) = (now.year(), now.month());
    let mut on_time = 0u32;
    let mut total = 0u32;
    let mut guard = 0;
    while (y < cy || (y == cy && m <= cm)) && guard < 600 {
        guard += 1;
        let due = NaiveDate::from_ymd_opt(y, m, due_day.min(days_in_month(y, m))).unwrap();
        let (py, pm) = if m == 1 { (y - 1, 12) } else { (y, m - 1) };
        let prev_due = NaiveDate::from_ymd_opt(py, pm, due_day.min(days_in_month(py, pm))).unwrap();
        let start = prev_due.succ_opt().unwrap();
        if due <= now {
            total += 1;
            let within = |d: &Option<NaiveDate>| matches!(d, Some(d) if *d >= start && *d <= due);
            let paid = payments.iter().any(within);
            let fee = fees.iter().any(|f| within(&f.0));
            if paid && !fee {
                on_time += 1;
            }
        }
        m += 1;
        if m > 12 {
            m = 1;
            y += 1;
        }
    }
    h.on_time_months = on_time;
    h.total_months = total;
    h.on_time_pct = if total > 0 { Some(((on_time as f64 / total as f64) * 100.0).round() as u32) } else { None };
    Ok(h)
}

pub fn accounts_report(conn: &Connection, ym: &str) -> Result<Vec<AccountReport>> {
    let (_, to) = month_bounds(ym);
    let start = format!("{}-01", add_months(ym, -5));
    let mut st = conn.prepare(&format!(
        "SELECT account_id, substr({ED}, 1, 7) AS ym, SUM(amount_cents) FROM transactions
         WHERE is_transfer = 0 AND {ED} >= ?1 AND {ED} < ?2 GROUP BY account_id, ym"
    ))?;
    let series: HashMap<(String, String), i64> = st
        .query_map(params![start, to], |r| Ok(((r.get(0)?, r.get(1)?), r.get(2)?)))?
        .collect::<std::result::Result<_, _>>()?;
    let months: Vec<String> = (0..6).rev().map(|i| add_months(ym, -i)).collect();
    // In this report, counts and last activity ignore transfers.
    let mut st = conn.prepare("SELECT account_id, COUNT(*), MAX(date) FROM transactions WHERE is_transfer = 0 GROUP BY account_id")?;
    let non_xfer: HashMap<String, (u32, Option<String>)> = st
        .query_map([], |r| Ok((r.get(0)?, (r.get::<_, i64>(1)? as u32, r.get(2)?))))?
        .collect::<std::result::Result<_, _>>()?;
    list_accounts(conn, ym)?
        .into_iter()
        .map(|mut a| {
            let (n, last) = non_xfer.get(&a.id).cloned().unwrap_or((0, None));
            a.tx_count = n;
            a.last_activity = last;
            let is_debt = a.kind == "credit" || a.kind == "loan";
            let health = if is_debt { Some(debt_health(conn, &a.id, a.due_day)?) } else { None };
            let s = months
                .iter()
                .map(|m| NetPoint { ym: m.clone(), net_cents: series.get(&(a.id.clone(), m.clone())).copied().unwrap_or(0) })
                .collect();
            Ok(AccountReport { account: a, is_debt, health, series: s })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn month_math() {
        assert_eq!(add_months("2026-01", -1), "2025-12");
        assert_eq!(add_months("2026-12", 1), "2027-01");
        assert_eq!(add_months("2026-10", -5), "2026-05");
        assert_eq!(month_bounds("2026-12"), ("2026-12-01".into(), "2027-01-01".into()));
        assert_eq!(days_in_month(2028, 2), 29);
        assert_eq!(month_label("2026-10"), "Oct '26");
    }
}
