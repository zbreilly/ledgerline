//! Repeating schedules (weekly, biweekly, monthly, …), matching scheduled items to real
//! transactions, and finding recurring series in transaction history.

use std::collections::{HashMap, HashSet};
use std::sync::OnceLock;

use chrono::{Datelike, Duration, NaiveDate};
use regex::Regex;
use rusqlite::Connection;

use crate::error::Result;
use crate::memory::merchant_keys;
use crate::reports::days_in_month;

pub const FREQUENCIES: &[&str] = &["once", "weekly", "biweekly", "monthly", "quarterly", "semiannual", "yearly"];

pub fn parse_date(s: &str) -> Option<NaiveDate> {
    NaiveDate::parse_from_str(s.get(..10)?, "%Y-%m-%d").ok()
}

pub fn fmt_date(d: NaiveDate) -> String {
    d.format("%Y-%m-%d").to_string()
}

pub fn dollars(cents: i64) -> String {
    format!("${:.2}", cents as f64 / 100.0)
}

pub fn periods_per_year(freq: &str) -> f64 {
    match freq {
        "weekly" => 52.0,
        "biweekly" => 26.0,
        "quarterly" => 4.0,
        "semiannual" => 2.0,
        "yearly" => 1.0,
        "once" => 0.0,
        _ => 12.0,
    }
}

/// Average amount per month for something paid `cents` at `freq`.
pub fn monthly_equivalent(cents: i64, freq: &str) -> i64 {
    (cents as f64 * periods_per_year(freq) / 12.0).round() as i64
}

/// Typical gap in days, used for staleness and matching windows.
pub fn interval_days(freq: &str) -> i64 {
    match freq {
        "weekly" => 7,
        "biweekly" => 14,
        "quarterly" => 91,
        "semiannual" => 182,
        "yearly" => 365,
        _ => 30,
    }
}

fn month_step(freq: &str) -> Option<i32> {
    match freq {
        "monthly" => Some(1),
        "quarterly" => Some(3),
        "semiannual" => Some(6),
        "yearly" => Some(12),
        _ => None,
    }
}

/// Every date in [from, to] on the schedule that repeats from `anchor`.
/// Monthly dates keep the anchor's day, clamped to short months (31 -> 30 or 28).
pub fn occurrences(freq: &str, anchor: NaiveDate, from: NaiveDate, to: NaiveDate) -> Vec<NaiveDate> {
    let mut out = vec![];
    if from > to {
        return out;
    }
    if freq == "once" {
        if anchor >= from && anchor <= to {
            out.push(anchor);
        }
        return out;
    }
    match month_step(freq) {
        None => {
            let step = if freq == "weekly" { 7 } else { 14 };
            let k = (from - anchor).num_days().div_euclid(step);
            let mut d = anchor + Duration::days(k * step);
            if d < from {
                d += Duration::days(step);
            }
            while d <= to {
                out.push(d);
                d += Duration::days(step);
            }
        }
        Some(m) => {
            let anchor_idx = anchor.year() * 12 + anchor.month0() as i32;
            let start = from.year() * 12 + from.month0() as i32;
            let end = to.year() * 12 + to.month0() as i32;
            for idx in start..=end {
                if (idx - anchor_idx).rem_euclid(m) != 0 {
                    continue;
                }
                let (y, mo) = (idx.div_euclid(12), idx.rem_euclid(12) as u32 + 1);
                let d = NaiveDate::from_ymd_opt(y, mo, anchor.day().min(days_in_month(y, mo))).unwrap();
                if d >= from && d <= to {
                    out.push(d);
                }
            }
        }
    }
    out
}

pub fn next_on_or_after(freq: &str, anchor: NaiveDate, d: NaiveDate) -> Option<NaiveDate> {
    occurrences(freq, anchor, d, d + Duration::days(400)).into_iter().next()
}

/// The `n`-th scheduled date (0-based) starting at `first`.
pub fn nth_after(freq: &str, first: NaiveDate, n: u32) -> NaiveDate {
    if freq == "once" {
        return first;
    }
    match month_step(freq) {
        None => first + Duration::days(n as i64 * if freq == "weekly" { 7 } else { 14 }),
        Some(m) => {
            let idx = first.year() * 12 + first.month0() as i32 + m * n as i32;
            let (y, mo) = (idx.div_euclid(12), idx.rem_euclid(12) as u32 + 1);
            NaiveDate::from_ymd_opt(y, mo, first.day().min(days_in_month(y, mo))).unwrap()
        }
    }
}

// ---------- transactions, slimmed down for matching ----------

#[derive(Debug, Clone)]
pub struct TxLite {
    pub date: NaiveDate,
    pub amount_cents: i64,
    pub description: String,
    pub key: String,
    pub account_id: String,
    pub is_transfer: bool,
    pub category_name: Option<String>,
    pub subcategory_name: Option<String>,
    pub report_month: Option<String>,
}

pub fn load_txs(conn: &Connection) -> Result<Vec<TxLite>> {
    let mut st = conn.prepare(
        "SELECT t.date, t.amount_cents, t.description, t.account_id, t.is_transfer, c.name, s.name, t.report_month
         FROM transactions t LEFT JOIN categories c ON c.id = t.category_id LEFT JOIN subcategories s ON s.id = t.subcategory_id
         ORDER BY t.date, t.rowid",
    )?;
    let rows = st.query_map([], |r| {
        Ok((
            r.get::<_, String>(0)?,
            r.get::<_, i64>(1)?,
            r.get::<_, String>(2)?,
            r.get::<_, String>(3)?,
            r.get::<_, Option<i64>>(4)?.unwrap_or(0) != 0,
            r.get::<_, Option<String>>(5)?,
            r.get::<_, Option<String>>(6)?,
            r.get::<_, Option<String>>(7)?,
        ))
    })?;
    let mut out = vec![];
    for r in rows {
        let (date, amount_cents, description, account_id, is_transfer, category_name, subcategory_name, report_month) = r?;
        let Some(date) = parse_date(&date) else { continue };
        let key = merchant_keys(&description).0;
        out.push(TxLite { date, amount_cents, description, key, account_id, is_transfer, category_name, subcategory_name, report_month });
    }
    Ok(out)
}

/// What a scheduled item looks for in transactions.
pub struct Matcher<'a> {
    pub key: &'a str,
    /// Positive amount when the amount must match exactly; None = any amount.
    pub exact_cents: Option<i64>,
    /// +1 for money in, −1 for money out.
    pub sign: i64,
    /// For a card or loan account: match payment credits on that account instead of by merchant.
    pub account: Option<&'a str>,
    /// With `account`: how many days before the due date a payment still counts (the billing cycle).
    pub before_days: i64,
}

/// A payment arriving on a card/loan account ("CAPITAL ONE MOBILE PYMT", "PAYMENT THANK YOU", …),
/// as opposed to a refund or a loan disbursement.
pub fn is_payment_credit(t: &TxLite) -> bool {
    static R: OnceLock<Regex> = OnceLock::new();
    let re = R.get_or_init(|| Regex::new(r"(?i)(PYMT|\bPMT\b|PAYMENT)").unwrap());
    t.amount_cents > 0 && re.is_match(&t.description)
}

/// Closest transaction within ±`window` days of `date` that fits the matcher and isn't used yet.
pub fn find_match(txs: &[TxLite], used: &mut HashSet<usize>, m: &Matcher, date: NaiveDate, window: i64) -> Option<usize> {
    if let Some(acct) = m.account {
        // Payments can land any time in the cycle before the due date.
        let mut best: Option<(i64, usize)> = None;
        for (i, t) in txs.iter().enumerate() {
            if used.contains(&i) || t.account_id != acct || !is_payment_credit(t) {
                continue;
            }
            let diff = (t.date - date).num_days();
            if diff >= -m.before_days && diff <= window && best.map(|b| diff.abs() < b.0).unwrap_or(true) {
                best = Some((diff.abs(), i));
            }
        }
        if let Some((_, i)) = best {
            used.insert(i);
        }
        return best.map(|b| b.1);
    }
    if m.key.is_empty() {
        return None;
    }
    let mut best: Option<(i64, usize)> = None;
    for (i, t) in txs.iter().enumerate() {
        if used.contains(&i) || t.key != m.key || t.amount_cents.signum() != m.sign {
            continue;
        }
        if let Some(c) = m.exact_cents {
            if t.amount_cents.abs() != c {
                continue;
            }
        }
        let diff = (t.date - date).num_days().abs();
        if diff <= window && best.map(|b| diff < b.0).unwrap_or(true) {
            best = Some((diff, i));
        }
    }
    if let Some((_, i)) = best {
        used.insert(i);
    }
    best.map(|b| b.1)
}

/// A readable name from a bank description: words up to the first one with a digit.
/// "ACME CORP      PAYROLL   PPD ID: 231" -> "Acme Corp Payroll"
pub fn display_name(desc: &str) -> String {
    // Chase ACH format: "ORIG CO NAME:AFFIRM.COM PAYME CO ENTRY DESCR:..." -> "AFFIRM.COM PAYME"
    let upper = desc.to_uppercase();
    let desc = match upper.find("ORIG CO NAME:") {
        Some(i) => {
            let rest = &desc[i + "ORIG CO NAME:".len()..];
            let end = rest.to_uppercase().find(" CO ENTRY").unwrap_or(rest.len());
            &rest[..end]
        }
        None => desc,
    };
    let mut words = vec![];
    for (i, w) in desc.split_whitespace().enumerate() {
        if i > 0 && w.chars().any(|c| c.is_ascii_digit()) {
            break;
        }
        if matches!(w.to_uppercase().as_str(), "PPD" | "WEB" | "ID:" | "TEL" | "CO") {
            break;
        }
        words.push(w);
        if words.len() >= 5 {
            break;
        }
    }
    let s = words.join(" ");
    let s = s.trim_end_matches(['*', ':', '-', ',']).trim().to_string();
    let has_lower = s.chars().any(|c| c.is_lowercase());
    let s = if has_lower {
        s
    } else {
        s.split(' ')
            .map(|w| {
                let mut c = w.chars();
                match c.next() {
                    Some(f) => f.to_uppercase().collect::<String>() + &c.as_str().to_lowercase(),
                    None => String::new(),
                }
            })
            .collect::<Vec<_>>()
            .join(" ")
    };
    s.chars().take(40).collect()
}

pub fn debt_regex() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| {
        Regex::new(r"(?i)(\bPMT\b|\bLOAN|FINANCE|AFFIRM|KLARNA|\bZIP\b|ZIP\*|AFTERPAY|SEZZLE|MONEYKEY|ADVANCE AMERICA|CREDIT ONE|CONSOLIDATED CRE)").unwrap()
    })
}

// ---------- recurring series detection ----------

#[derive(Debug, Clone)]
pub struct Series {
    pub key: String,
    pub sign: i64,
    pub frequency: String,
    /// Positive typical amount.
    pub amount_cents: i64,
    pub exact: bool,
    pub dates: Vec<NaiveDate>,
    pub sample: TxLite,
}

fn classify(dates: &[NaiveDate], exact: bool) -> Option<&'static str> {
    if dates.len() < 2 {
        return None;
    }
    let gaps: Vec<i64> = dates.windows(2).map(|w| (w[1] - w[0]).num_days()).collect();
    let mut sorted = gaps.clone();
    sorted.sort();
    let median = sorted[sorted.len() / 2];
    let (freq, lo, hi): (&str, i64, i64) = match median {
        5..=9 => ("weekly", 5, 9),
        11..=17 => ("biweekly", 11, 17),
        25..=36 => ("monthly", 25, 36),
        80..=100 => ("quarterly", 80, 100),
        170..=195 => ("semiannual", 170, 195),
        340..=390 => ("yearly", 340, 390),
        _ => return None,
    };
    let fits = gaps.iter().filter(|g| (lo..=hi).contains(*g)).count();
    if fits * 3 < gaps.len() * 2 {
        return None;
    }
    // Two sightings are enough only for an exact-amount monthly charge.
    let min = if freq == "monthly" && exact { 2 } else { 3 };
    if dates.len() < min {
        return None;
    }
    Some(freq)
}

fn median(v: &mut [i64]) -> i64 {
    v.sort();
    v[v.len() / 2]
}

/// Finds repeating charges and deposits. Exact-amount series first (so several Affirm
/// loans under one merchant stay separate), then one similar-amount series per merchant.
/// Series that stopped (no sighting for ~1.5 intervals before the newest data) are dropped.
pub fn detect_series(txs: &[TxLite]) -> Vec<Series> {
    let Some(data_end) = txs.iter().map(|t| t.date).max() else { return vec![] };
    let mut groups: HashMap<(String, i64), Vec<usize>> = HashMap::new();
    for (i, t) in txs.iter().enumerate() {
        if t.key.is_empty() || t.amount_cents == 0 || (t.is_transfer && t.amount_cents > 0) {
            continue;
        }
        groups.entry((t.key.clone(), t.amount_cents.signum())).or_default().push(i);
    }
    let mut out = vec![];
    let fresh = |freq: &str, last: NaiveDate| {
        let gap = interval_days(freq);
        last + Duration::days(gap * 3 / 2 + 5) >= data_end
    };
    let mut keys: Vec<_> = groups.keys().cloned().collect();
    keys.sort();
    for k in keys {
        let idxs = &groups[&k];
        let mut used: HashSet<usize> = HashSet::new();
        let mut by_amount: HashMap<i64, Vec<usize>> = HashMap::new();
        for &i in idxs {
            by_amount.entry(txs[i].amount_cents.abs()).or_default().push(i);
        }
        let mut amounts: Vec<_> = by_amount.keys().copied().collect();
        amounts.sort();
        for amt in amounts {
            let list = &by_amount[&amt];
            let mut dates: Vec<NaiveDate> = list.iter().map(|&i| txs[i].date).collect();
            dates.dedup();
            if let Some(freq) = classify(&dates, true) {
                // Attempted series also claim their rows, stale or not.
                used.extend(list.iter().copied());
                if fresh(freq, *dates.last().unwrap()) {
                    let sample = txs[*list.last().unwrap()].clone();
                    out.push(Series { key: k.0.clone(), sign: k.1, frequency: freq.into(), amount_cents: amt, exact: true, dates, sample });
                }
            }
        }
        let rest: Vec<usize> = idxs.iter().copied().filter(|i| !used.contains(i)).collect();
        if rest.len() >= 3 {
            let mut amts: Vec<i64> = rest.iter().map(|&i| txs[i].amount_cents.abs()).collect();
            let med = median(&mut amts);
            let close: Vec<usize> = rest
                .iter()
                .copied()
                .filter(|&i| ((txs[i].amount_cents.abs() - med) as f64).abs() <= med as f64 * 0.25)
                .collect();
            let mut dates: Vec<NaiveDate> = close.iter().map(|&i| txs[i].date).collect();
            dates.dedup();
            if let Some(freq) = classify(&dates, false) {
                if fresh(freq, *dates.last().unwrap()) {
                    let mut a: Vec<i64> = close.iter().map(|&i| txs[i].amount_cents.abs()).collect();
                    let sample = txs[*close.last().unwrap()].clone();
                    out.push(Series { key: k.0.clone(), sign: k.1, frequency: freq.into(), amount_cents: median(&mut a), exact: false, dates, sample });
                }
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn d(s: &str) -> NaiveDate {
        parse_date(s).unwrap()
    }

    #[test]
    fn biweekly_and_monthly_occurrences() {
        let o = occurrences("biweekly", d("2026-07-09"), d("2026-10-01"), d("2026-10-31"));
        assert_eq!(o, vec![d("2026-10-01"), d("2026-10-15"), d("2026-10-29")]);
        let o = occurrences("monthly", d("2026-01-31"), d("2026-02-01"), d("2026-04-30"));
        assert_eq!(o, vec![d("2026-02-28"), d("2026-03-31"), d("2026-04-30")]);
        let o = occurrences("quarterly", d("2026-01-15"), d("2026-01-01"), d("2026-12-31"));
        assert_eq!(o.len(), 4);
        assert_eq!(nth_after("monthly", d("2026-01-31"), 1), d("2026-02-28"));
        assert_eq!(nth_after("biweekly", d("2026-10-29"), 2), d("2026-11-26"));
        assert_eq!(occurrences("once", d("2026-11-11"), d("2026-11-01"), d("2026-11-30")), vec![d("2026-11-11")]);
        assert!(occurrences("once", d("2026-11-11"), d("2026-12-01"), d("2026-12-31")).is_empty());
        assert_eq!(monthly_equivalent(50_000, "once"), 0);
    }

    #[test]
    fn names() {
        assert_eq!(display_name("ACME CORP      PAYROLL                    PPD ID: 231"), "Acme Corp Payroll");
        assert_eq!(display_name("ZIP* BEST BUY 183-10000002 NY"), "Zip* Best Buy");
        assert_eq!(display_name("Zelle payment to Morgan (Landlord) 10000000001"), "Zelle payment to Morgan (Landlord)");
        assert_eq!(display_name("ORIG CO NAME:AFFIRM.COM PAYME CO ENTRY DESCR:AFFIRM"), "Affirm.com Payme");
    }

    fn tx(date: &str, cents: i64, desc: &str) -> TxLite {
        TxLite {
            date: d(date), amount_cents: cents, description: desc.into(), key: merchant_keys(desc).0,
            account_id: "a".into(), is_transfer: false, category_name: None, subcategory_name: None, report_month: None,
        }
    }

    #[test]
    fn detects_paycheck_and_separate_affirm_loans() {
        let mut txs = vec![];
        for day in ["2026-07-09", "2026-07-23", "2026-08-06", "2026-08-20", "2026-09-03", "2026-09-17", "2026-10-01", "2026-10-15"] {
            txs.push(tx(day, 250000, "ACME CORP PAYROLL PPD ID: 231"));
        }
        for day in ["2026-07-28", "2026-08-28", "2026-09-28"] {
            txs.push(tx(day, -6150, "AFFIRM.COM PAYME AFFIRM.COM ST-X1 WEB ID"));
        }
        for day in ["2026-07-21", "2026-08-21", "2026-09-21", "2026-10-21"] {
            txs.push(tx(day, -1725, "AFFIRM.COM PAYME AFFIRM.COM ST-Y2 WEB ID"));
        }
        // A series that stopped in August is stale.
        for day in ["2026-07-09", "2026-07-23", "2026-08-06"] {
            txs.push(tx(day, -2500, "KLARNA CC FLOW DEBIT"));
        }
        txs.sort_by_key(|t| t.date);
        let s = detect_series(&txs);
        let pay = s.iter().find(|x| x.sign > 0).unwrap();
        assert_eq!(pay.frequency, "biweekly");
        assert_eq!(pay.amount_cents, 250000);
        let affirm: Vec<_> = s.iter().filter(|x| x.key.starts_with("AFFIRMCOM")).collect();
        assert_eq!(affirm.len(), 2);
        assert!(affirm.iter().all(|x| x.frequency == "monthly" && x.exact));
        assert!(!s.iter().any(|x| x.key.starts_with("KLARNA")));
    }
}
