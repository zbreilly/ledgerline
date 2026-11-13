//! Priority-ordered categorization rules. A rule that targets the `Transfers` category
//! also marks the transaction as a transfer.

use regex::Regex;
use rusqlite::{params, Connection, OptionalExtension};

use crate::error::Result;
use crate::memory::merchant_keys;
use crate::models::{LearnRulesResult, Rule, RuleInput};
use std::collections::HashMap;

pub(crate) struct CompiledRule {
    pub rule: Rule,
    regex: Option<Regex>,
}

pub(crate) struct TxView<'a> {
    pub description: &'a str,
    pub merchant: &'a str,
    pub amount_cents: i64,
}

impl CompiledRule {
    pub fn new(rule: Rule) -> Self {
        let regex = if rule.match_type == "regex" { Regex::new(&format!("(?i){}", rule.pattern)).ok() } else { None };
        CompiledRule { rule, regex }
    }

    pub fn matches(&self, tx: &TxView) -> bool {
        let r = &self.rule;
        let value = if r.field == "merchant" && !tx.merchant.is_empty() { tx.merchant } else { tx.description };
        let v = value.to_lowercase();
        let p = r.pattern.to_lowercase();
        let hit = match r.match_type.as_str() {
            "exact" => v == p,
            "starts" => v.starts_with(&p),
            "regex" => self.regex.as_ref().map(|re| re.is_match(value)).unwrap_or(false),
            // Same cleaned-up merchant name as merchant memory uses, so store numbers,
            // dates and "POS DEBIT" prefixes don't matter.
            "merchant" => rule_key(value).eq_ignore_ascii_case(r.pattern.trim()),
            _ => v.contains(&p),
        };
        if !hit {
            return false;
        }
        if matches!(r.min_cents, Some(min) if tx.amount_cents < min) {
            return false;
        }
        if matches!(r.max_cents, Some(max) if tx.amount_cents > max) {
            return false;
        }
        true
    }
}

const RULE_SELECT: &str = "SELECT r.id, r.priority, r.enabled, r.match, r.field, r.pattern, r.category_id, r.subcategory_id,
    r.min_cents, r.max_cents, c.name, s.name
  FROM rules r LEFT JOIN categories c ON c.id = r.category_id LEFT JOIN subcategories s ON s.id = r.subcategory_id";

fn row_to_rule(r: &rusqlite::Row) -> rusqlite::Result<Rule> {
    Ok(Rule {
        id: r.get(0)?,
        priority: r.get::<_, Option<i64>>(1)?.unwrap_or(100),
        enabled: r.get::<_, Option<i64>>(2)?.unwrap_or(1) != 0,
        match_type: r.get::<_, Option<String>>(3)?.unwrap_or_else(|| "contains".into()),
        field: r.get::<_, Option<String>>(4)?.unwrap_or_else(|| "description".into()),
        pattern: r.get(5)?,
        category_id: r.get(6)?,
        subcategory_id: r.get(7)?,
        min_cents: r.get(8)?,
        max_cents: r.get(9)?,
        category_name: r.get(10)?,
        subcategory_name: r.get(11)?,
    })
}

pub fn list(conn: &Connection) -> Result<Vec<Rule>> {
    let mut st = conn.prepare(&format!("{RULE_SELECT} ORDER BY r.priority, r.rowid"))?;
    let rows = st.query_map([], row_to_rule)?.collect::<std::result::Result<_, _>>()?;
    Ok(rows)
}

fn validate(input: &RuleInput) -> Result<()> {
    if input.pattern.trim().is_empty() {
        return crate::error::err("Pattern required");
    }
    if input.match_type == "regex" && Regex::new(&input.pattern).is_err() {
        return crate::error::err("That regular expression is not valid");
    }
    Ok(())
}

pub fn create(conn: &Connection, input: &RuleInput) -> Result<String> {
    validate(input)?;
    let id = crate::db::uid();
    let sub = if input.category_id.is_some() { input.subcategory_id.clone() } else { None };
    conn.execute(
        "INSERT INTO rules (id, priority, enabled, match, field, pattern, category_id, subcategory_id, min_cents, max_cents)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
        params![id, input.priority, input.enabled as i64, input.match_type, input.field, input.pattern.trim(),
            input.category_id, sub, input.min_cents, input.max_cents],
    )?;
    Ok(id)
}

pub fn update(conn: &Connection, id: &str, input: &RuleInput) -> Result<()> {
    validate(input)?;
    let sub = if input.category_id.is_some() { input.subcategory_id.clone() } else { None };
    let n = conn.execute(
        "UPDATE rules SET priority=?1, enabled=?2, match=?3, field=?4, pattern=?5, category_id=?6, subcategory_id=?7,
           min_cents=?8, max_cents=?9 WHERE id=?10",
        params![input.priority, input.enabled as i64, input.match_type, input.field, input.pattern.trim(),
            input.category_id, sub, input.min_cents, input.max_cents, id],
    )?;
    if n == 0 {
        return crate::error::err("Rule not found");
    }
    Ok(())
}

pub fn delete(conn: &Connection, id: &str) -> Result<()> {
    conn.execute("DELETE FROM rules WHERE id = ?1", [id])?;
    Ok(())
}

/// Apply enabled rules to uncategorized rows (or all rows when `all`). First match wins.
pub fn apply(conn: &Connection, all: bool) -> Result<u32> {
    let rules: Vec<CompiledRule> = list(conn)?.into_iter().filter(|r| r.enabled).map(CompiledRule::new).collect();
    if rules.is_empty() {
        return Ok(0);
    }
    let txs: Vec<(String, String, String, i64)> = {
        let sql = format!(
            "SELECT id, description, COALESCE(merchant, ''), amount_cents FROM transactions {}",
            // "All" never overwrites the parts of a split transaction.
            if all { "WHERE split_of IS NULL" } else { "WHERE category_id IS NULL" }
        );
        let mut st = conn.prepare(&sql)?;
        let rows = st.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))?;
        rows.collect::<std::result::Result<_, _>>()?
    };
    let xfer_cat: Option<String> = conn
        .query_row("SELECT id FROM categories WHERE name = 'Transfers'", [], |r| r.get(0))
        .optional()?;
    let tx = conn.unchecked_transaction()?;
    let mut updated = 0u32;
    {
        let mut upd = tx.prepare("UPDATE transactions SET category_id = ?1, subcategory_id = ?2 WHERE id = ?3")?;
        let mut mark = tx.prepare("UPDATE transactions SET is_transfer = 1 WHERE id = ?1")?;
        for (id, desc, merchant, cents) in &txs {
            let view = TxView { description: desc, merchant, amount_cents: *cents };
            if let Some(cr) = rules.iter().find(|r| r.matches(&view)) {
                let r = &cr.rule;
                let sub = if r.category_id.is_some() { r.subcategory_id.clone() } else { None };
                upd.execute(params![r.category_id, sub, id])?;
                if xfer_cat.is_some() && r.category_id == xfer_cat {
                    mark.execute([id])?;
                }
                updated += 1;
            }
        }
    }
    tx.commit()?;
    Ok(updated)
}

fn between<'a>(s: &'a str, upper: &str, start: &str, end: &str) -> Option<&'a str> {
    let i = upper.find(start)? + start.len();
    let j = upper[i..].find(end).map(|j| i + j).unwrap_or(s.len());
    Some(s[i..j].trim())
}

/// Merchant name used by "same merchant" rules. Same as merchant memory's key, except Chase's
/// ACH format ("ORIG CO NAME:PAYPAL CO ENTRY ... IND ID:APPLE.COM BILL ORIG ID:...") is read
/// for the real payee, so it matches the card-style "PAYPAL PURCHASE APPLE.COM BILL" rows.
pub fn rule_key(desc: &str) -> String {
    let upper = desc.to_uppercase();
    if let Some(name) = between(desc, &upper, "ORIG CO NAME:", " CO ENTRY") {
        let key = merchant_keys(name).0;
        if !key.is_empty() {
            return key;
        }
        if let Some(ind) = between(desc, &upper, "IND ID:", " ORIG ID") {
            return merchant_keys(ind).0;
        }
    }
    merchant_keys(desc).0
}

/// When you recategorize transactions, learned "same merchant" rules for those merchants follow,
/// so the next statement files them your new way. Hand-made rules (priority below 100) and
/// split parts are left alone. Returns how many rules changed.
pub fn follow_edit(conn: &Connection, ids: &[String], category_id: &str, subcategory_id: Option<&str>) -> Result<u32> {
    let mut changed = 0u32;
    for id in ids {
        let row: Option<(String, i64)> = conn
            .query_row("SELECT description, amount_cents FROM transactions WHERE id = ?1 AND split_of IS NULL", [id], |r| {
                Ok((r.get(0)?, r.get(1)?))
            })
            .optional()?;
        let Some((desc, cents)) = row else { continue };
        let key = rule_key(&desc);
        if key.is_empty() {
            continue;
        }
        let side = if cents > 0 { "min_cents = 1 AND max_cents IS NULL" } else { "max_cents = -1 AND min_cents IS NULL" };
        changed += conn.execute(
            &format!(
                "UPDATE rules SET category_id = ?1, subcategory_id = ?2
                 WHERE match = 'merchant' AND priority >= 100 AND UPPER(TRIM(pattern)) = ?3 AND {side}
                   AND (category_id IS NOT ?1 OR subcategory_id IS NOT ?2)"
            ),
            params![category_id, subcategory_id, key],
        )? as u32;
    }
    Ok(changed)
}

/// Share of a merchant's rows that must agree before it gets a rule.
const LEARN_AGREEMENT: f64 = 0.8;

/// Builds one "same merchant" rule per merchant (and direction: money out vs in) that you've
/// filed consistently. Mixed merchants are left to merchant memory and listed.
pub fn learn_from_history(conn: &Connection) -> Result<LearnRulesResult> {
    type Cat = (String, Option<String>);
    let rows: Vec<(String, String, i64, String, Option<String>)> = {
        let mut st = conn.prepare(
            "SELECT description, COALESCE(merchant, ''), amount_cents, category_id, subcategory_id FROM transactions
             WHERE category_id IS NOT NULL AND split_of IS NULL ORDER BY date",
        )?;
        let r = st.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)))?;
        r.collect::<std::result::Result<_, _>>()?
    };
    let names: HashMap<String, String> = {
        let mut st = conn.prepare("SELECT id, name FROM categories")?;
        let r = st.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?;
        r.collect::<std::result::Result<_, _>>()?
    };
    let existing: Vec<CompiledRule> = list(conn)?.into_iter().filter(|r| r.enabled).map(CompiledRule::new).collect();
    let first_match = |rules: &[CompiledRule], desc: &str, merchant: &str, cents: i64| -> Option<Cat> {
        let view = TxView { description: desc, merchant, amount_cents: cents };
        rules.iter().find(|r| r.matches(&view)).and_then(|r| r.rule.category_id.clone().map(|c| (c, r.rule.subcategory_id.clone())))
    };

    // (merchant key, money in?) -> rows
    let mut groups: HashMap<(String, bool), Vec<usize>> = HashMap::new();
    for (i, (desc, _, cents, _, _)) in rows.iter().enumerate() {
        let key = rule_key(desc);
        if key.is_empty() || key == "DEBIT" || key == "CREDIT" {
            continue;
        }
        groups.entry((key, *cents > 0)).or_default().push(i);
    }
    let mut keys: Vec<_> = groups.keys().cloned().collect();
    keys.sort();

    let (mut created, mut covered, mut skipped) = (0u32, 0u32, vec![]);
    for (key, money_in) in keys {
        let idx = &groups[&(key.clone(), money_in)];
        let total = idx.len() as f64;
        let mut by_cat: HashMap<&str, usize> = HashMap::new();
        for &i in idx {
            *by_cat.entry(rows[i].3.as_str()).or_default() += 1;
        }
        let (cat, n) = by_cat.iter().max_by_key(|(c, n)| (**n, std::cmp::Reverse(**c))).map(|(c, n)| (c.to_string(), *n)).unwrap();
        if (n as f64) / total < LEARN_AGREEMENT {
            let mut parts: Vec<String> = by_cat.iter().map(|(c, n)| format!("{} ×{n}", names.get(*c).cloned().unwrap_or_default())).collect();
            parts.sort();
            skipped.push(format!("{key}{}: {}", if money_in { " (money in)" } else { "" }, parts.join(", ")));
            continue;
        }
        // Subcategory only when the rows in that category agree on it too.
        let in_cat: Vec<usize> = idx.iter().copied().filter(|&i| rows[i].3 == cat).collect();
        let mut by_sub: HashMap<Option<&str>, usize> = HashMap::new();
        for &i in &in_cat {
            *by_sub.entry(rows[i].4.as_deref()).or_default() += 1;
        }
        let (sub, sn) = by_sub.iter().max_by_key(|(s, n)| (**n, std::cmp::Reverse(**s))).map(|(s, n)| (s.map(String::from), *n)).unwrap();
        let sub = if (sn as f64) / (in_cat.len() as f64) >= LEARN_AGREEMENT { sub } else { None };
        let want: Cat = (cat.clone(), sub.clone());

        // Already handled the same way by an existing rule?
        let has_merchant_rule = existing.iter().any(|r| {
            let r = &r.rule;
            r.match_type == "merchant"
                && r.pattern.trim().eq_ignore_ascii_case(&key)
                && (if money_in { r.min_cents == Some(1) && r.max_cents.is_none() } else { r.max_cents == Some(-1) && r.min_cents.is_none() })
        });
        if has_merchant_rule {
            covered += 1;
            continue;
        }
        if idx.iter().all(|&i| first_match(&existing, &rows[i].0, &rows[i].1, rows[i].2).as_ref() == Some(&want)) {
            covered += 1;
            continue;
        }
        create(
            conn,
            &RuleInput {
                priority: 100,
                enabled: true,
                match_type: "merchant".into(),
                field: "description".into(),
                pattern: key,
                category_id: Some(cat),
                subcategory_id: sub,
                min_cents: if money_in { Some(1) } else { None },
                max_cents: if money_in { None } else { Some(-1) },
            },
        )?;
        created += 1;
    }

    // Check: would the full rule set file today's rows the way they're filed now?
    let all: Vec<CompiledRule> = list(conn)?.into_iter().filter(|r| r.enabled).map(CompiledRule::new).collect();
    let subnames: HashMap<String, String> = {
        let mut st = conn.prepare("SELECT id, name FROM subcategories")?;
        let r = st.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?;
        r.collect::<std::result::Result<_, _>>()?
    };
    let label = |c: &str, s: &Option<String>| {
        let cn = names.get(c).cloned().unwrap_or_default();
        match s.as_ref().and_then(|s| subnames.get(s)) {
            Some(sn) => format!("{cn} › {sn}"),
            None => cn,
        }
    };
    let mut disagreements = vec![];
    for (desc, merchant, cents, cat, sub) in &rows {
        if let Some((c, s)) = first_match(&all, desc, merchant, *cents) {
            if c != *cat || (sub.is_some() && s != *sub) {
                disagreements.push(format!("{desc} ({}): filed as {}, rule says {}", crate::schedule::dollars(*cents), label(cat, sub), label(&c, &s)));
            }
        }
    }
    Ok(LearnRulesResult {
        created,
        already_covered: covered,
        skipped,
        rows_disagreeing: disagreements.len() as u32,
        rows_checked: rows.len() as u32,
        disagreements,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rule(m: &str, pat: &str, min: Option<i64>, max: Option<i64>) -> CompiledRule {
        CompiledRule::new(Rule {
            id: "r".into(), priority: 10, enabled: true, match_type: m.into(), field: "description".into(),
            pattern: pat.into(), category_id: Some("c".into()), subcategory_id: None,
            min_cents: min, max_cents: max, category_name: None, subcategory_name: None,
        })
    }

    #[test]
    fn affirm_amount_rule() {
        let r = rule("contains", "AFFIRM", Some(-725), Some(-725));
        let hit = TxView { description: "AFFIRM.COM PAYME AFFIRM.COM", merchant: "", amount_cents: -725 };
        let miss = TxView { description: "AFFIRM.COM PAYME AFFIRM.COM", merchant: "", amount_cents: -810 };
        assert!(r.matches(&hit));
        assert!(!r.matches(&miss));
    }

    #[test]
    fn match_types() {
        let t = TxView { description: "Netflix.com 866", merchant: "", amount_cents: -1599 };
        assert!(rule("starts", "netflix", None, None).matches(&t));
        assert!(!rule("exact", "netflix", None, None).matches(&t));
        assert!(rule("regex", r"^net\w+\.com", None, None).matches(&t));
        assert!(!rule("regex", "(", None, None).matches(&t));
    }

    #[test]
    fn merchant_match_ignores_store_numbers_and_prefixes() {
        let r = rule("merchant", "GASMART SPRINGFIELD", None, Some(-1));
        let a = TxView { description: "POS DEBIT GASMART 10234 SPRINGFIELD IL", merchant: "", amount_cents: -4000 };
        let b = TxView { description: "GASMART 51234 SPRINGFIELD IL 10/02", merchant: "", amount_cents: -2500 };
        let refund = TxView { description: "GASMART 51234 SPRINGFIELD IL", merchant: "", amount_cents: 2500 };
        let other = TxView { description: "GASMART 1 SHELBYVILLE IL", merchant: "", amount_cents: -2500 };
        assert!(r.matches(&a) && r.matches(&b));
        assert!(!r.matches(&refund));
        assert!(!r.matches(&other));
    }

    #[test]
    fn ach_paypal_rows_use_the_real_payee() {
        let ach = "ORIG CO NAME:PAYPAL           CO ENTRY DESCR:PURCHASE   SEC:WEB IND ID:APPLE.COM BILL  ORIG ID:PAYPALSI77";
        assert_eq!(rule_key(ach), "APPLECOM BILL");
        assert_eq!(rule_key("Paypal Purchase Apple.com Bill"), "APPLECOM BILL");
        assert_eq!(rule_key("ORIG CO NAME:AFFIRM.COM PAYME CO ENTRY DESCR:AFFIRM.COM"), merchant_keys("AFFIRM.COM PAYME AFFIRM.COM ST-X").0);
    }
}
