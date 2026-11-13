//! Merchant memory: an uncategorized row copies the category of the most recent
//! categorized row with the same merchant key.

use std::collections::HashMap;

use rusqlite::{params, Connection};

use crate::error::Result;

const KEY_STOP: &[&str] = &[
    "POS", "DEBIT", "CREDIT", "ORIG", "CO", "NAME", "TST", "SQ", "CARD", "PURCHASE", "PPD", "WEB", "ID", "INST", "XFER",
    "ACH", "CHECKCARD", "RECURRING", "PAYPAL", "PP", "ZELLE", "PAYMENT", "TO", "FROM", "THE",
];

/// Returns (two-word key, one-word key). Survives format changes like
/// "POS DEBIT GASMART 10234 SPRINGFIELD IL" vs "GASMART 10234 SPRINGFIELD IL 09/27" -> "GASMART SPRINGFIELD".
/// The one-word key is empty unless the first word has at least 4 letters.
pub fn merchant_keys(desc: &str) -> (String, String) {
    let upper = desc.to_uppercase();
    let words: Vec<String> = upper
        .split(|c: char| c.is_whitespace() || c == '*')
        .filter(|t| !t.is_empty() && !t.chars().any(|c| c.is_ascii_digit()))
        .map(|t| t.chars().filter(|c| c.is_ascii_uppercase()).collect::<String>())
        .filter(|w| w.len() >= 2 && !KEY_STOP.contains(&w.as_str()))
        .collect();
    let k2 = words.iter().take(2).cloned().collect::<Vec<_>>().join(" ");
    let k1 = match words.first() {
        Some(w) if w.len() >= 4 => w.clone(),
        _ => String::new(),
    };
    (k2, k1)
}

#[derive(Clone)]
enum Memo {
    Hit { category_id: String, subcategory_id: Option<String> },
    Conflict,
}

/// `batch_id = None` re-runs memory over every uncategorized transaction.
/// With a batch, only that batch's rows are filled, learning from rows outside it.
pub fn apply(conn: &Connection, batch_id: Option<&str>) -> Result<u32> {
    let known: Vec<(String, String, Option<String>)> = {
        let (sql, p): (&str, Vec<&str>) = match batch_id {
            Some(b) => (
                "SELECT description, category_id, subcategory_id FROM transactions
                 WHERE category_id IS NOT NULL AND split_of IS NULL AND (import_batch_id IS NULL OR import_batch_id != ?1) ORDER BY date ASC",
                vec![b],
            ),
            None => (
                "SELECT description, category_id, subcategory_id FROM transactions WHERE category_id IS NOT NULL AND split_of IS NULL ORDER BY date ASC",
                vec![],
            ),
        };
        let mut st = conn.prepare(sql)?;
        let rows = st.query_map(rusqlite::params_from_iter(p), |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?;
        rows.collect::<std::result::Result<_, _>>()?
    };
    let mut memo2: HashMap<String, Memo> = HashMap::new();
    let mut memo1: HashMap<String, Memo> = HashMap::new();
    for (desc, cat, sub) in known {
        let (k2, k1) = merchant_keys(&desc);
        let hit = Memo::Hit { category_id: cat.clone(), subcategory_id: sub };
        if !k2.is_empty() && k2 != "DEBIT" && k2 != "CREDIT" {
            memo2.insert(k2, hit.clone());
        }
        if !k1.is_empty() {
            let next = match memo1.get(&k1) {
                Some(Memo::Hit { category_id, .. }) if *category_id != cat => Memo::Conflict,
                Some(Memo::Conflict) => Memo::Conflict,
                _ => hit,
            };
            memo1.insert(k1, next);
        }
    }
    let todo: Vec<(String, String)> = {
        let (sql, p): (&str, Vec<&str>) = match batch_id {
            Some(b) => ("SELECT id, description FROM transactions WHERE category_id IS NULL AND import_batch_id = ?1", vec![b]),
            None => ("SELECT id, description FROM transactions WHERE category_id IS NULL", vec![]),
        };
        let mut st = conn.prepare(sql)?;
        let rows = st.query_map(rusqlite::params_from_iter(p), |r| Ok((r.get(0)?, r.get(1)?)))?;
        rows.collect::<std::result::Result<_, _>>()?
    };
    let tx = conn.unchecked_transaction()?;
    let mut n = 0u32;
    {
        let mut upd = tx.prepare("UPDATE transactions SET category_id = ?1, subcategory_id = ?2 WHERE id = ?3")?;
        for (id, desc) in &todo {
            let (k2, k1) = merchant_keys(desc);
            let mut hit = memo2.get(&k2).cloned();
            if hit.is_none() && !k1.is_empty() {
                hit = memo1.get(&k1).cloned();
            }
            if let Some(Memo::Hit { category_id, subcategory_id }) = hit {
                upd.execute(params![category_id, subcategory_id, id])?;
                n += 1;
            }
        }
    }
    tx.commit()?;
    Ok(n)
}

#[cfg(test)]
mod tests {
    use super::merchant_keys;

    #[test]
    fn keys_survive_format_changes() {
        let a = merchant_keys("POS DEBIT GASMART 10234 SPRINGFIELD IL ... 1234");
        let b = merchant_keys("GASMART 10234 SPRINGFIELD IL 09/27");
        assert_eq!(a.0, "GASMART SPRINGFIELD");
        assert_eq!(a.0, b.0);
        assert_eq!(a.1, "GASMART");
    }

    #[test]
    fn stop_words_and_star() {
        assert_eq!(merchant_keys("PAYPAL *SPOTIFY 4029357733").0, "SPOTIFY");
        assert_eq!(merchant_keys("SQ *JOE'S CAFE").0, "JOES CAFE");
        assert_eq!(merchant_keys("TST* ABC").1, "");
    }
}
