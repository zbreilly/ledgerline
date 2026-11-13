// Same projection as core/examples/parity.rs, but read from the Node API.
const B = `http://127.0.0.1:${process.env.PORT}/api`;
const get = async (p) => { const r = await fetch(B + p); if (!r.ok) throw new Error(p + ' ' + r.status + ' ' + await r.text()); return r.json(); };
const post = async (p, body) => { const r = await fetch(B + p, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) }); if (!r.ok) throw new Error(p + ' ' + await r.text()); return r.json(); };
const r6 = (x) => (x === null || x === undefined ? null : Math.round(x * 1e6) / 1e6);
const out = {};
const mode = process.argv[2];
if (mode === 'import') {
  const fs = await import('node:fs');
  const a = process.argv.slice(3);
  for (let i = 0; i + 1 < a.length; i += 2) {
    const text = fs.readFileSync(a[i + 1], 'utf8');
    const p = await post('/import/preview', { text });
    const r = await post('/import/commit', { text, filename: 'x.csv', accountId: a[i], mapping: p.mapping });
    out[`import|${a[i]}`] = [r.imported, r.skipped, r.rulesApplied, r.remembered, r.errors];
  }
  console.log(JSON.stringify(out));
  process.exit(0);
}
const { accounts } = await get('/accounts');
const accs = [null, ...accounts.map((a) => a.id)];
for (const ym of ['2026-06', '2026-07', '2026-08', '2026-09', '2026-10']) {
  for (const acc of accs) {
    const a = acc || 'all';
    const q = `month=${ym}${acc ? `&account=${acc}` : ''}`;
    const o = await get(`/reports/overview?${q}`);
    out[`overview|${ym}|${a}`] = {
      income: o.income_cents, expense: o.expense_cents, n: o.tx_count, pinc: o.prev_income_cents, pexp: o.prev_expense_cents,
      unc: o.uncategorized, liquid: o.liquid_balance_cents, rate: r6(o.savings_rate),
      merchants: o.merchants.map((m) => [m.m, m.total, m.n]), recent: o.recent.map((t) => t.id),
      series: o.series.map((s) => [s.ym, s.label, s.income_cents, s.expense_cents]),
    };
    for (const income of [false, true]) {
      const b = await get(`/reports/breakdown?${q}&type=${income ? 'income' : 'expense'}`);
      out[`breakdown|${ym}|${income}|${a}`] = {
        unc: [b.uncategorized.total, b.uncategorized.n],
        cats: b.categories.map((c) => [c.id, c.total, c.n, c.subcategories.map((s) => [s.id, s.total, s.n])]),
      };
    }
    const p = await get(`/reports/planning?${q}`);
    const m = p.metrics;
    out[`planning|${ym}|${a}`] = {
      budgeted: p.totals.budgeted_cents, actual: p.totals.actual_cents, income: p.totals.income_cents,
      metrics: [r6(m.savings_rate_month), r6(m.savings_rate_3m), m.avg_expense_3m_cents, m.avg_income_3m_cents, m.liquid_balance_cents, r6(m.runway_months), m.projected_expense_cents],
      tree: p.tree.map((c) => [c.id, c.actual_cents, c.n, c.budget_cents, c.subcategories.map((s) => [s.id, s.actual_cents, s.n, s.budget_cents])]),
      budgets: p.budgets.map((b) => [b.id, b.actual_cents, b.remaining_cents]),
    };
  }
  const ar = await get(`/reports/accounts?month=${ym}`);
  out[`accounts|${ym}`] = ar.accounts.map((a) => [a.id, a.display_balance_cents, a.month_in_cents, a.month_out_cents, a.tx_count, a.all_in_cents, a.all_out_cents,
    a.last_activity, a.is_debt, a.health ? [a.health.late_fee_count, a.health.late_fee_total_cents, a.health.on_time_pct] : null, a.series.map((s) => [s.ym, s.net])]);
}
const cf = await get('/reports/cashflow?month=2026-10&months=12');
out.cashflow = cf.months.map((s) => [s.ym, s.income_cents, s.expense_cents]);
const { categories } = await get('/categories');
out.categories = categories.map((c) => [c.id, c.tx_count, c.out_cents, c.in_cents, c.subcategories.map((s) => [s.id, s.tx_count])]);
const queries = {
  default: '', page3: 'page=3', affirm: 'q=AFFIRM&transfer=all', transfers: 'transfer=only&pageSize=200',
  amount_asc: 'sort=amount&dir=asc', merchant: 'sort=merchant&dir=asc&type=expense', uncat: 'category=none&transfer=all',
  range: 'from=2026-09-01&to=2026-09-30&min=-50&max=-10&pageSize=200',
};
for (const [name, qs] of Object.entries(queries)) {
  const p = await get(`/transactions?${qs}`);
  out[`tx|${name}`] = { total: p.total, pages: p.pages, in: p.inflow_cents, out: p.outflow_cents, ids: p.rows.map((t) => t.id) };
}
console.log(JSON.stringify(out));
