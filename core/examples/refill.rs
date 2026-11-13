//! Re-run rules then merchant memory over uncategorized rows: cargo run --example refill -- <db>
fn main() {
    let l = ledgerline_core::Ledger::open(std::env::args().nth(1).unwrap()).unwrap();
    let r = l.apply_rules(false).unwrap();
    let m = l.apply_merchant_memory().unwrap();
    println!("rules filled {r}, memory filled {m}");
}
