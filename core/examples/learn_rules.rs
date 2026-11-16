//! Build rules from categorized history: cargo run --example learn_rules -- <db path>
fn main() {
    let path = std::env::args().nth(1).expect("db path");
    let l = ledgerline_core::Ledger::open(path).expect("open");
    let r = l.learn_rules().expect("learn");
    println!("created {} rules, {} already covered, {} skipped", r.created, r.already_covered, r.skipped.len());
    println!("rows checked {}, rows a rule would file differently {}", r.rows_checked, r.rows_disagreeing);
    for s in &r.skipped { println!("  skipped: {s}"); }
    for s in &r.disagreements { println!("  differs: {s}"); }
}
