//! Splitting one bank transaction into parts with different categories
//! (e.g. a Shopwell receipt: groceries + pharmacy), and undoing it.
//!
//! The original row keeps its id and import hash, so re-importing the same bank file
//! never brings the full charge back; the other parts get derived hashes.
//! Every part (including the original) has `split_of` = the original's id.

use rusqlite::{params, Connection, OptionalExtension};

use crate::db::uid;
use crate::error::{err, Result};
use crate::models::SplitPart;

pub fn split(conn: &Connection, id: &str, parts: &[SplitPart]) -> Result<Vec<String>> {
    // Re-splitting a split transaction starts from the whole charge again (the original row).
    let id_owned = match group_of(conn, id)? {
        Some(group) => {
            unsplit(conn, &group)?;
            group
        }
        None => id.to_string(),
    };
    let id = id_owned.as_str();
    let orig: Option<(i64, String)> = conn
        .query_row("SELECT amount_cents, hash FROM transactions WHERE id = ?1", [id], |r| Ok((r.get(0)?, r.get(1)?)))
        .optional()?;
    let Some((total, hash)) = orig else { return err("Transaction not found") };
    if parts.len() < 2 {
        return err("A split needs at least two parts");
    }
    if parts.iter().any(|p| p.amount_cents == 0 || p.amount_cents.signum() != total.signum()) {
        return err("Each part needs an amount, with the same sign as the original");
    }
    let sum: i64 = parts.iter().map(|p| p.amount_cents).sum();
    if sum != total {
        return err(format!(
            "The parts add up to {} but the transaction is {}",
            crate::schedule::dollars(sum.abs()),
            crate::schedule::dollars(total.abs())
        ));
    }
    let tx = conn.unchecked_transaction()?;
    let first = &parts[0];
    tx.execute(
        "UPDATE transactions SET amount_cents = ?1, category_id = ?2, subcategory_id = ?3,
           notes = CASE WHEN ?4 = '' THEN notes ELSE ?4 END, split_of = ?5 WHERE id = ?5",
        params![first.amount_cents, first.category_id, sub_for(first), first.notes, id],
    )?;
    let mut ids = vec![id.to_string()];
    for (n, p) in parts.iter().enumerate().skip(1) {
        let new_id = uid();
        tx.execute(
            "INSERT INTO transactions (id, account_id, date, description, merchant, amount_cents, category_id, subcategory_id,
               notes, is_transfer, hash, import_batch_id, report_month, split_of)
             SELECT ?1, account_id, date, description, merchant, ?2, ?3, ?4, ?5, is_transfer, ?6, import_batch_id, report_month, id
             FROM transactions WHERE id = ?7",
            params![new_id, p.amount_cents, p.category_id, sub_for(p), p.notes, format!("{hash}#split{n}"), id],
        )?;
        ids.push(new_id);
    }
    tx.commit()?;
    Ok(ids)
}

/// Merges all parts back into the original transaction. Returns the original's id.
pub fn unsplit(conn: &Connection, id: &str) -> Result<String> {
    let Some(group) = group_of(conn, id)? else { return err("This transaction isn't split") };
    let tx = conn.unchecked_transaction()?;
    let total: i64 = tx.query_row("SELECT SUM(amount_cents) FROM transactions WHERE split_of = ?1", [&group], |r| r.get(0))?;
    tx.execute("DELETE FROM transactions WHERE split_of = ?1 AND id != ?1", [&group])?;
    tx.execute("UPDATE transactions SET amount_cents = ?1, split_of = NULL WHERE id = ?2", params![total, group])?;
    tx.commit()?;
    Ok(group)
}

fn group_of(conn: &Connection, id: &str) -> Result<Option<String>> {
    Ok(conn.query_row("SELECT split_of FROM transactions WHERE id = ?1", [id], |r| r.get(0)).optional()?.flatten())
}

fn sub_for(p: &SplitPart) -> Option<String> {
    if p.category_id.is_some() { p.subcategory_id.clone() } else { None }
}

#[cfg(test)]
mod tests {
    use crate::models::*;

    fn part(cents: i64, cat: Option<&str>) -> SplitPart {
        SplitPart { amount_cents: cents, category_id: cat.map(String::from), subcategory_id: None, notes: String::new() }
    }

    #[test]
    fn split_reimport_and_unsplit() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("t.db");
        let l = crate::Ledger::open(path.to_str().unwrap().into()).unwrap();
        let acct = l.create_account(NewAccount { name: "Chk".into(), institution: String::new(), kind: "checking".into(), balance_cents: 0, color: String::new(), due_day: 0 }).unwrap();
        let csv = "Date,Description,Amount\n2026-10-19,SHOPWELL STORE #114 SPRINGFIELD IL,-118.40\n";
        let req = |text: &str| ImportRequest {
            text: text.into(), filename: "m.csv".into(), account_id: Some(acct.clone()), new_account: None,
            mapping: l.preview_import(text.into(), None, "auto".into()).unwrap().mapping, date_format: "auto".into(),
            invert: false, skip_duplicates: true, apply_rules: false,
        };
        assert_eq!(l.commit_import(req(csv)).unwrap().imported, 1);
        let cats = l.list_categories().unwrap();
        let groc = cats.iter().find(|c| c.name == "Groceries").unwrap().id.clone();
        let health = cats.iter().find(|c| c.name.starts_with("Health")).unwrap().id.clone();
        let q = || TxQuery {
            search: None, account_ids: vec![], category_ids: vec![], subcategory_ids: vec![], date_from: None, date_to: None, month: None,
            min_cents: None, max_cents: None, flow: None, uncategorized_only: false, transfers: "all".into(), sort: "amount".into(),
            ascending: true, page: 1, page_size: 50,
        };
        let id = l.list_transactions(q()).unwrap().rows[0].id.clone();

        // Parts must add up.
        assert!(l.split_transaction(id.clone(), vec![part(-10_000, Some(&groc)), part(-2_000, Some(&health))]).is_err());
        let ids = l.split_transaction(id.clone(), vec![part(-8_840, Some(&groc)), part(-3_000, Some(&health))]).unwrap();
        assert_eq!(ids.len(), 2);
        let rows = l.list_transactions(q()).unwrap().rows;
        assert_eq!(rows.len(), 2);
        assert!(rows.iter().all(|r| r.split_of.as_deref() == Some(id.as_str())));
        assert_eq!(rows.iter().map(|r| r.amount_cents).sum::<i64>(), -11_840);

        // Re-importing the same bank row doesn't bring the full charge back.
        let r = l.commit_import(req(csv)).unwrap();
        assert_eq!(r.imported, 0);
        assert_eq!(l.list_transactions(q()).unwrap().rows.len(), 2);

        // Re-splitting starts from the whole charge; unsplit merges back.
        l.split_transaction(ids[1].clone(), vec![part(-11_000, None), part(-800, None), part(-40, None)]).unwrap();
        assert_eq!(l.list_transactions(q()).unwrap().rows.len(), 3);
        l.unsplit_transaction(ids[1].clone()).unwrap_err();
        let back = l.unsplit_transaction(id.clone()).unwrap();
        assert_eq!(back, id);
        let rows = l.list_transactions(q()).unwrap().rows;
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].amount_cents, -11_840);
        assert!(rows[0].split_of.is_none());
    }
}
