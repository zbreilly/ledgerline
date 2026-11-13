//! Prints detected recurring items, debts, the calendar, and pay periods for a database.
//! Usage: cargo run --example cashflow_demo -- <db> [--accept]
//! --accept adds every untracked suggestion (only use on a copy).
use ledgerline_core::*;

fn d(c: i64) -> String {
    format!("{}${:.2}", if c < 0 { "-" } else { "" }, c.abs() as f64 / 100.0)
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let l = Ledger::open(args[1].clone()).unwrap();
    let accept = args.iter().any(|a| a == "--accept");

    println!("== Recurring suggestions");
    for s in l.recurring_suggestions().unwrap() {
        println!(
            "{:7} {:9} {:>10} x{:<2} {} → next {:?} | {} | key={} exact={} tracked={} rec={}",
            s.suggested_kind, s.input.frequency, d(s.input.amount_cents), s.occurrences, s.last_date, s.next_date,
            s.input.name, s.input.match_key, s.input.match_exact_amount, s.already_tracked, s.recommended
        );
        if accept && !s.already_tracked && s.recommended && s.suggested_kind != "debt" {
            l.create_recurring(s.input).unwrap();
        }
    }
    println!("\n== Debt suggestions");
    for s in l.debt_suggestions().unwrap() {
        println!("{:11} {:>9} {:9} | {} | {}", s.input.kind, d(s.input.payment_cents), s.input.frequency, s.input.name, s.reason);
        if accept && (s.occurrences > 1 || s.input.balance_source == "account") {
            let mut i = s.input;
            if i.name.starts_with("Zip") { i.balance_cents = 20_000; i.payments_left = Some(4); }
            if i.balance_source == "account" && i.kind == "card" { i.apr = 29.99; i.payment_cents = 4_000; i.next_due = Some("2026-11-05".into()); }
            l.create_debt(i).unwrap();
        }
    }
    println!("\n== Debts");
    for x in l.list_debts().unwrap() {
        println!(
            "{:28} bal {:>10}{} apr {:>5.2} pay {:>8} {:9} next {:?} last {:?} payoff {} {:?} {:?}",
            x.name, d(x.current_balance_cents), if x.balance_is_estimate { "*" } else { " " }, x.apr, d(x.payment_cents), x.frequency,
            x.next_payment_date, x.last_payment_date, x.payoff.status, x.payoff.payments, x.payoff.payoff_date
        );
    }
    let s = l.debt_summary().unwrap();
    println!("summary: {} debts, total {}, monthly {}, unknown {}", s.count, d(s.total_cents), d(s.monthly_payments_cents), s.unknown_count);
    for strat in ["minimum", "avalanche", "snowball"] {
        let p = l.payoff_plan(strat.into(), 20_000).unwrap();
        println!("plan {strat}: months {} free {:?} interest {} never {} excluded {} order {:?}", p.months, p.debt_free_month, d(p.total_interest_cents), p.never, p.excluded, p.debts.iter().map(|x| (x.name.clone(), x.payoff_month.clone())).collect::<Vec<_>>());
    }

    for m in ["2026-10", "2026-11"] {
        let c = l.calendar(m.into()).unwrap();
        println!(
            "\n== Calendar {m}: paychecks {} income {} bills {} debt {} start {} setup? {} lowest {:?} on {:?}\n   3-paycheck months: {:?}",
            c.paychecks, d(c.income_cents), d(c.bills_cents), d(c.debt_cents), d(c.start_balance_cents), c.balance_needs_setup,
            c.lowest_balance_cents.map(d), c.lowest_date, c.three_paycheck_months
        );
        for day in c.days.iter().filter(|x| !x.events.is_empty()) {
            let evs: Vec<String> = day.events.iter().map(|e| format!("{} {} [{}]", e.name, d(e.amount_cents), e.status)).collect();
            println!("  {} {:>11} {}", day.date, day.projected_balance_cents.map(d).unwrap_or_default(), evs.join("; "));
        }
    }
    println!("\n== Pay periods");
    for p in l.pay_periods(4).unwrap() {
        println!(
            "{} → {}{} pay {} other {} bills {} debt {} left {} end {:?} ({} events)",
            p.start, p.end, if p.is_current { " (now)" } else { "" }, d(p.paycheck_cents), d(p.other_income_cents), d(p.bills_cents),
            d(p.debt_cents), d(p.leftover_cents), p.ending_balance_cents.map(d), p.events.len()
        );
    }
}
