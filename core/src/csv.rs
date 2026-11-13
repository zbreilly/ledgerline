//! CSV parsing, header guessing, money and date parsing. Ported from `server/csv.mjs`.

use std::sync::OnceLock;

use chrono::NaiveDate;
use regex::Regex;

use crate::models::ColumnMapping;

/// RFC 4180 parser. Handles quoted fields, escaped quotes, CRLF, and a leading BOM.
/// Blank lines are dropped.
pub fn parse_csv(text: &str) -> Vec<Vec<String>> {
    let text = text.strip_prefix('\u{FEFF}').unwrap_or(text);
    let mut rows = Vec::new();
    let mut row: Vec<String> = Vec::new();
    let mut field = String::new();
    let mut in_quotes = false;
    let mut chars = text.chars().peekable();
    let push_row = |row: &mut Vec<String>, rows: &mut Vec<Vec<String>>| {
        if row.len() > 1 || row.first().map(|f| !f.is_empty()).unwrap_or(false) {
            rows.push(std::mem::take(row));
        } else {
            row.clear();
        }
    };
    while let Some(ch) = chars.next() {
        if in_quotes {
            if ch == '"' {
                if chars.peek() == Some(&'"') {
                    field.push('"');
                    chars.next();
                } else {
                    in_quotes = false;
                }
            } else {
                field.push(ch);
            }
        } else if ch == '"' {
            in_quotes = true;
        } else if ch == ',' {
            row.push(std::mem::take(&mut field));
        } else if ch == '\n' || ch == '\r' {
            if ch == '\r' && chars.peek() == Some(&'\n') {
                chars.next();
            }
            row.push(std::mem::take(&mut field));
            push_row(&mut row, &mut rows);
        } else {
            field.push(ch);
        }
    }
    row.push(field);
    push_row(&mut row, &mut rows);
    rows
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Field {
    Date,
    Description,
    Merchant,
    Amount,
    Debit,
    Credit,
    Notes,
    Type,
    Category,
    Check,
    Balance,
}

fn hints() -> &'static [(Field, Regex)] {
    static H: OnceLock<Vec<(Field, Regex)>> = OnceLock::new();
    H.get_or_init(|| {
        let r = |s: &str| Regex::new(&format!("(?i)^({s})")).unwrap();
        vec![
            (Field::Date, r(r"date|posted.?date|transaction.?date|trans.?date|posting.?date|date posted|when")),
            (Field::Description, r(r"description|name|transaction|details|detail|payee|narrative|memo.?desc|original description|description 1|description 2|tx")),
            (Field::Merchant, r(r"merchant|cleaned|canonical|payee name|name cleaned")),
            (Field::Amount, r(r"amount|transaction amount|amt|value|debit amount|amount \(usd\)")),
            (Field::Debit, r(r"debit|withdrawal|money out|paid out|withdrawals?")),
            (Field::Credit, r(r"credit|deposit|money in|paid in|deposits?")),
            (Field::Notes, r(r"memo|notes?|note|comment|details memo")),
            (Field::Type, r(r"type|transaction type|dr/cr|debit/credit")),
            (Field::Category, r(r"category|categories")),
            (Field::Check, r(r"check|cheque|check number")),
            (Field::Balance, r(r"balance|running balance|bal")),
        ]
    })
}

fn slot(m: &mut ColumnMapping, f: Field) -> &mut Option<u32> {
    match f {
        Field::Date => &mut m.date,
        Field::Description => &mut m.description,
        Field::Merchant => &mut m.merchant,
        Field::Amount => &mut m.amount,
        Field::Debit => &mut m.debit,
        Field::Credit => &mut m.credit,
        Field::Notes => &mut m.notes,
        Field::Type => &mut m.txn_type,
        Field::Category => &mut m.category,
        Field::Check => &mut m.check_number,
        Field::Balance => &mut m.balance,
    }
}

/// Guess which column holds which field from the header row.
/// An exact `Description` header wins over `Details` (Chase puts DEBIT/CREDIT in `Details` first).
pub fn guess_mapping(headers: &[String]) -> ColumnMapping {
    static DESC2: OnceLock<Regex> = OnceLock::new();
    let desc2 = DESC2.get_or_init(|| Regex::new(r"(?i)^(description 2|memo)").unwrap());
    let mut map = ColumnMapping::default();
    'headers: for (i, h) in headers.iter().enumerate() {
        let hdr = h.trim();
        if hdr.is_empty() {
            continue;
        }
        for (field, re) in hints() {
            if re.is_match(hdr) && slot(&mut map, *field).is_none() {
                if *field == Field::Description && desc2.is_match(hdr) {
                    if map.description.is_none() {
                        map.description = Some(i as u32);
                    } else if map.notes.is_none() {
                        map.notes = Some(i as u32);
                    }
                    continue 'headers;
                }
                *slot(&mut map, *field) = Some(i as u32);
            }
        }
    }
    static RANK: OnceLock<Vec<Regex>> = OnceLock::new();
    let rank = RANK.get_or_init(|| {
        ["description", "original description", "description 1", "payee", "name", "narrative", "transaction"]
            .iter()
            .map(|s| Regex::new(&format!("(?i)^{s}$")).unwrap())
            .collect()
    });
    for re in rank {
        if let Some(idx) = headers.iter().position(|h| re.is_match(h.trim())) {
            map.description = Some(idx as u32);
            break;
        }
    }
    if map.description.is_none() {
        let excluded = [map.date, map.amount, map.debit, map.credit, map.balance];
        let mut best: Option<usize> = None;
        let mut best_len = 0usize;
        for (i, h) in headers.iter().enumerate() {
            if excluded.contains(&Some(i as u32)) {
                continue;
            }
            let len = h.encode_utf16().count();
            if len > best_len {
                best_len = len;
                best = Some(i);
            }
        }
        map.description = best.map(|b| b as u32);
    }
    map
}

/// "$1,234.56" -> 123456, "(12.00)" -> -1200, "12.00-" -> -1200. None if unparseable.
pub fn to_cents(raw: &str, invert: bool) -> Option<i64> {
    let mut s = raw.trim().to_string();
    if s.is_empty() {
        return None;
    }
    let mut neg = false;
    if s.len() >= 2 && s.starts_with('(') && s.ends_with(')') {
        neg = true;
        s = s[1..s.len() - 1].to_string();
    }
    s.retain(|c| !matches!(c, '$' | '€' | '£' | '¥' | ',') && !c.is_whitespace());
    if let Some(rest) = s.strip_suffix('-') {
        neg = true;
        s = rest.to_string();
    }
    if let Some(rest) = s.strip_prefix('-') {
        neg = true;
        s = rest.to_string();
    }
    if let Some(rest) = s.strip_prefix('+') {
        s = rest.to_string();
    }
    static NUM: OnceLock<Regex> = OnceLock::new();
    if !NUM.get_or_init(|| Regex::new(r"^\d*(\.\d*)?$").unwrap()).is_match(&s) {
        return None;
    }
    let src = if s.is_empty() { "0" } else { s.as_str() };
    let v: f64 = src.parse().ok()?;
    let n = (v * 100.0).round() as i64;
    let n = if neg { -n } else { n };
    Some(if invert { -n } else { n })
}

fn iso(y: i32, mo: u32, d: u32) -> Option<String> {
    if !(1..=12).contains(&mo) || !(1..=31).contains(&d) {
        return None;
    }
    Some(format!("{y}-{mo:02}-{d:02}"))
}

/// Normalize a bank date to YYYY-MM-DD. `format` is auto | mdy | dmy.
pub fn normalize_date(raw: &str, format: &str) -> Option<String> {
    let s = raw.trim();
    if s.is_empty() {
        return None;
    }
    static YMD: OnceLock<Regex> = OnceLock::new();
    static XYZ: OnceLock<Regex> = OnceLock::new();
    let ymd = YMD.get_or_init(|| Regex::new(r"^(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})").unwrap());
    let xyz = XYZ.get_or_init(|| Regex::new(r"^(\d{1,2})[-/.](\d{1,2})[-/.](\d{2,4})").unwrap());
    if let Some(c) = ymd.captures(s) {
        return iso(c[1].parse().ok()?, c[2].parse().ok()?, c[3].parse().ok()?);
    }
    if let Some(c) = xyz.captures(s) {
        let a: u32 = c[1].parse().ok()?;
        let b: u32 = c[2].parse().ok()?;
        let mut y: i32 = c[3].parse().ok()?;
        if y < 100 {
            y += if y > 70 { 1900 } else { 2000 };
        }
        let (mo, d) = if format == "dmy" || (format == "auto" && a > 12) { (b, a) } else { (a, b) };
        return iso(y, mo, d);
    }
    // Free-form dates like "Oct 5, 2026" or "5 October 2026".
    for f in ["%b %d, %Y", "%B %d, %Y", "%b %d %Y", "%B %d %Y", "%d %b %Y", "%d %B %Y", "%a, %d %b %Y"] {
        if let Ok(d) = NaiveDate::parse_from_str(s, f) {
            return Some(d.format("%Y-%m-%d").to_string());
        }
    }
    if let Ok(dt) = chrono::DateTime::parse_from_rfc3339(s) {
        return Some(dt.date_naive().format("%Y-%m-%d").to_string());
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn h(v: &[&str]) -> Vec<String> {
        v.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn parses_quotes_and_crlf() {
        let rows = parse_csv("\u{FEFF}a,\"b,c\",\"d \"\"q\"\"\"\r\n\r\n1,2,3\n");
        assert_eq!(rows, vec![h(&["a", "b,c", "d \"q\""]), h(&["1", "2", "3"])]);
    }

    #[test]
    fn chase_prefers_description_over_details() {
        let m = guess_mapping(&h(&["Details", "Posting Date", "Description", "Amount", "Type", "Balance", "Check or Slip #"]));
        assert_eq!(m.description, Some(2));
        assert_eq!(m.date, Some(1));
        assert_eq!(m.amount, Some(3));
        assert_eq!(m.balance, Some(5));
    }

    #[test]
    fn capital_one_debit_credit() {
        let m = guess_mapping(&h(&["Transaction Date", "Posted Date", "Card No.", "Description", "Category", "Debit", "Credit"]));
        assert_eq!(m.date, Some(0));
        assert_eq!(m.description, Some(3));
        assert_eq!(m.debit, Some(5));
        assert_eq!(m.credit, Some(6));
        assert_eq!(m.amount, None);
    }

    #[test]
    fn cents() {
        assert_eq!(to_cents("$1,234.56", false), Some(123456));
        assert_eq!(to_cents("(12.00)", false), Some(-1200));
        assert_eq!(to_cents("12.00-", false), Some(-1200));
        assert_eq!(to_cents("-7.25", false), Some(-725));
        assert_eq!(to_cents("5", true), Some(-500));
        assert_eq!(to_cents("", false), None);
        assert_eq!(to_cents("abc", false), None);
        assert_eq!(to_cents(".", false), None);
        assert_eq!(to_cents("1.005", false), Some(100));
    }

    #[test]
    fn dates() {
        assert_eq!(normalize_date("10/23/2026", "auto").as_deref(), Some("2026-10-23"));
        assert_eq!(normalize_date("2026-10-23", "auto").as_deref(), Some("2026-10-23"));
        assert_eq!(normalize_date("23/10/26", "auto").as_deref(), Some("2026-10-23"));
        assert_eq!(normalize_date("05/06/2026", "dmy").as_deref(), Some("2026-06-05"));
        assert_eq!(normalize_date("Oct 5, 2026", "auto").as_deref(), Some("2026-10-05"));
        assert_eq!(normalize_date("Description", "auto"), None);
    }
}
