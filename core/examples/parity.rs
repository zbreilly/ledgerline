//! Dumps report numbers in a neutral JSON shape so they can be diffed against the Node app.
//! Usage:
//!   cargo run --example parity -- <db> reports
//!   cargo run --example parity -- <db> import <account_id> <csv>...   (alternating pairs)
use ledgerline_core::*;
use serde_json::{json, Value};

fn r6(x: Option<f64>) -> Value {
    x.map(|v| json!((v * 1e6).round() / 1e6)).unwrap_or(Value::Null)
}

fn tx_query() -> TxQuery {
    TxQuery {
        search: None, account_ids: vec![], category_ids: vec![], subcategory_ids: vec![], date_from: None, date_to: None, month: None,
        min_cents: None, max_cents: None, flow: None, uncategorized_only: false, transfers: "exclude".into(),
        sort: "date".into(), ascending: false, page: 1, page_size: 50,
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let l = Ledger::open(args[1].clone()).unwrap();
    let mut out = serde_json::Map::new();
    if args[2] == "actions" {
        println!("{}", json!([l.apply_merchant_memory().unwrap(), l.apply_rules(true).unwrap()]));
        return;
    }
    if args[2] == "import" {
        let mut i = 3;
        while i + 1 < args.len() {
            let text = std::fs::read_to_string(&args[i + 1]).unwrap();
            let p = l.preview_import(text.clone(), None, "auto".into()).unwrap();
            let r = l
                .commit_import(ImportRequest {
                    text, filename: "x.csv".into(), account_id: Some(args[i].clone()), new_account: None, mapping: p.mapping,
                    date_format: "auto".into(), invert: false, skip_duplicates: true, apply_rules: true,
                })
                .unwrap();
            out.insert(format!("import|{}", args[i]), json!([r.imported, r.skipped, r.rules_applied, r.remembered, r.errors]));
            i += 2;
        }
        println!("{}", Value::Object(out));
        return;
    }
    let accounts: Vec<Option<String>> =
        std::iter::once(None).chain(l.list_accounts().unwrap().into_iter().map(|a| Some(a.id))).collect();
    for ym in ["2026-06", "2026-07", "2026-08", "2026-09", "2026-10"] {
        for acc in &accounts {
            let a = acc.clone().unwrap_or_else(|| "all".into());
            let o = l.overview(ym.into(), acc.clone()).unwrap();
            out.insert(format!("overview|{ym}|{a}"), json!({
                "income": o.income_cents, "expense": o.expense_cents, "n": o.tx_count, "pinc": o.prev_income_cents,
                "pexp": o.prev_expense_cents, "unc": o.uncategorized, "liquid": o.liquid_balance_cents, "rate": r6(o.savings_rate),
                "merchants": o.merchants.iter().map(|m| json!([m.name, m.total_cents, m.count])).collect::<Vec<_>>(),
                "recent": o.recent.iter().map(|t| t.id.clone()).collect::<Vec<_>>(),
                "series": o.series.iter().map(|s| json!([s.ym, s.label, s.income_cents, s.expense_cents])).collect::<Vec<_>>(),
            }));
            for income in [false, true] {
                let b = l.breakdown(ym.into(), income, acc.clone()).unwrap();
                out.insert(format!("breakdown|{ym}|{income}|{a}"), json!({
                    "unc": [b.uncategorized_cents, b.uncategorized_count],
                    "cats": b.categories.iter().map(|c| json!([c.id, c.total_cents, c.count,
                        c.subcategories.iter().map(|s| json!([s.id, s.total_cents, s.count])).collect::<Vec<_>>()])).collect::<Vec<_>>(),
                }));
            }
            let p = l.planning(ym.into(), acc.clone()).unwrap();
            let m = &p.metrics;
            out.insert(format!("planning|{ym}|{a}"), json!({
                "budgeted": p.budgeted_cents, "actual": p.actual_cents, "income": p.income_cents,
                "metrics": [r6(m.savings_rate_month), r6(m.savings_rate_3m), m.avg_expense_3m_cents, m.avg_income_3m_cents,
                    m.liquid_balance_cents, r6(m.runway_months), m.projected_expense_cents],
                "tree": p.tree.iter().map(|c| json!([c.id, c.actual_cents, c.count, c.budget_cents,
                    c.subcategories.iter().map(|s| json!([s.id, s.actual_cents, s.count, s.budget_cents])).collect::<Vec<_>>()])).collect::<Vec<_>>(),
                "budgets": p.budgets.iter().map(|b| json!([b.id, b.actual_cents, b.remaining_cents])).collect::<Vec<_>>(),
            }));
        }
        let ar = l.accounts_report(ym.into()).unwrap();
        out.insert(format!("accounts|{ym}"), json!(ar.iter().map(|r| {
            let a = &r.account;
            json!([a.id, a.display_balance_cents, a.month_in_cents, a.month_out_cents, a.tx_count, a.all_in_cents, a.all_out_cents,
                a.last_activity, r.is_debt, r.health.as_ref().map(|h| json!([h.late_fee_count, h.late_fee_total_cents, h.on_time_pct])),
                r.series.iter().map(|s| json!([s.ym, s.net_cents])).collect::<Vec<_>>()])
        }).collect::<Vec<_>>()));
    }
    let cf = l.cashflow("2026-10".into(), 12, None).unwrap();
    out.insert("cashflow".into(), json!(cf.iter().map(|s| json!([s.ym, s.income_cents, s.expense_cents])).collect::<Vec<_>>()));
    let cats = l.list_categories().unwrap();
    out.insert("categories".into(), json!(cats.iter().map(|c| json!([c.id, c.tx_count, c.out_cents, c.in_cents,
        c.subcategories.iter().map(|s| json!([s.id, s.tx_count])).collect::<Vec<_>>()])).collect::<Vec<_>>()));
    let queries: Vec<(&str, TxQuery)> = vec![
        ("default", tx_query()),
        ("page3", TxQuery { page: 3, ..tx_query() }),
        ("affirm", TxQuery { search: Some("AFFIRM".into()), transfers: "all".into(), ..tx_query() }),
        ("transfers", TxQuery { transfers: "only".into(), page_size: 200, ..tx_query() }),
        ("amount_asc", TxQuery { sort: "amount".into(), ascending: true, ..tx_query() }),
        ("merchant", TxQuery { sort: "merchant".into(), ascending: true, flow: Some("expense".into()), ..tx_query() }),
        ("uncat", TxQuery { category_ids: vec!["none".into()], transfers: "all".into(), ..tx_query() }),
        ("range", TxQuery { date_from: Some("2026-09-01".into()), date_to: Some("2026-09-30".into()), min_cents: Some(-5000), max_cents: Some(-1000), page_size: 200, ..tx_query() }),
    ];
    for (name, q) in queries {
        let p = l.list_transactions(q).unwrap();
        out.insert(format!("tx|{name}"), json!({"total": p.total, "pages": p.pages, "in": p.inflow_cents, "out": p.outflow_cents,
            "ids": p.rows.iter().map(|t| t.id.clone()).collect::<Vec<_>>()}));
    }
    println!("{}", Value::Object(out));
}
