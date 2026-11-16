//! Plain data records shared with Swift (and any future front end) through UniFFI.
//! Money is always integer cents; negative = money out.

// ---------- meta / settings ----------

#[derive(Debug, Clone, uniffi::Record)]
pub struct Meta {
    pub db_path: String,
    pub version: String,
    pub accounts: u32,
    pub transactions: u32,
    pub categories: u32,
    pub uncategorized: u32,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct AppSettings {
    pub currency: String,
    pub theme: String,
    /// claude (Anthropic) | codex (OpenAI).
    /// The three `ai_` fields are per machine and are never stored in the database file.
    pub ai_provider: String,
    pub ai_model: String,
    pub ai_timeout_sec: u32,
}

// ---------- accounts ----------

#[derive(Debug, Clone, uniffi::Record)]
pub struct Account {
    pub id: String,
    pub name: String,
    pub institution: String,
    /// checking | savings | cash | credit | loan
    pub kind: String,
    pub balance_cents: i64,
    pub balance_set: bool,
    pub currency: String,
    pub color: String,
    pub archived: bool,
    pub due_day: u32,
    /// Manual balance if one was set, otherwise the sum of the account's transactions.
    pub display_balance_cents: i64,
    pub tx_count: u32,
    pub all_in_cents: i64,
    pub all_out_cents: i64,
    pub month_in_cents: i64,
    pub month_out_cents: i64,
    pub last_activity: Option<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct NewAccount {
    pub name: String,
    pub institution: String,
    pub kind: String,
    pub balance_cents: i64,
    pub color: String,
    pub due_day: u32,
}

#[derive(Debug, Clone, Default, uniffi::Record)]
pub struct AccountPatch {
    pub name: Option<String>,
    pub institution: Option<String>,
    pub kind: Option<String>,
    /// Setting a balance marks it as manual (balance_set = 1).
    pub balance_cents: Option<i64>,
    pub color: Option<String>,
    pub archived: Option<bool>,
    pub due_day: Option<u32>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct DebtHealth {
    pub late_fee_count: u32,
    pub late_fee_total_cents: i64,
    pub on_time_pct: Option<u32>,
    pub on_time_months: u32,
    pub total_months: u32,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct NetPoint {
    pub ym: String,
    pub net_cents: i64,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct AccountReport {
    pub account: Account,
    pub is_debt: bool,
    pub health: Option<DebtHealth>,
    pub series: Vec<NetPoint>,
}

// ---------- categories ----------

#[derive(Debug, Clone, uniffi::Record)]
pub struct Subcategory {
    pub id: String,
    pub category_id: String,
    pub name: String,
    pub sort: i64,
    pub tx_count: u32,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct Category {
    pub id: String,
    pub name: String,
    /// expense | income
    pub kind: String,
    pub color: String,
    pub icon: String,
    pub sort: i64,
    pub archived: bool,
    pub tx_count: u32,
    pub out_cents: i64,
    pub in_cents: i64,
    pub subcategories: Vec<Subcategory>,
}

#[derive(Debug, Clone, Default, uniffi::Record)]
pub struct CategoryPatch {
    pub name: Option<String>,
    pub kind: Option<String>,
    pub color: Option<String>,
    pub icon: Option<String>,
    pub sort: Option<i64>,
    pub archived: Option<bool>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct ProposedCategory {
    pub name: String,
    pub kind: String,
    pub color: String,
    pub icon: String,
    pub subcategories: Vec<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct TaxonomyResult {
    pub created: u32,
    pub subs_created: u32,
    pub skipped: u32,
}

// ---------- transactions ----------

#[derive(Debug, Clone, uniffi::Record)]
pub struct Transaction {
    pub id: String,
    pub account_id: String,
    pub date: String,
    pub description: String,
    pub merchant: String,
    pub amount_cents: i64,
    pub category_id: Option<String>,
    pub subcategory_id: Option<String>,
    pub notes: String,
    pub is_transfer: bool,
    pub import_batch_id: Option<String>,
    pub account_name: Option<String>,
    pub account_color: Option<String>,
    pub category_name: Option<String>,
    pub category_color: Option<String>,
    pub category_icon: Option<String>,
    pub subcategory_name: Option<String>,
    /// "YYYY-MM" when this transaction counts toward a different month than its date.
    pub report_month: Option<String>,
    /// Set on every part of a split transaction: the id of the original transaction.
    pub split_of: Option<String>,
}

/// One part of a split. Amounts are signed like the transaction (money out is negative).
#[derive(Debug, Clone, uniffi::Record)]
pub struct SplitPart {
    pub amount_cents: i64,
    pub category_id: Option<String>,
    pub subcategory_id: Option<String>,
    pub notes: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct TxQuery {
    pub search: Option<String>,
    pub account_ids: Vec<String>,
    /// Use "none" to include uncategorized rows.
    pub category_ids: Vec<String>,
    pub subcategory_ids: Vec<String>,
    pub date_from: Option<String>,
    pub date_to: Option<String>,
    /// "YYYY-MM": rows that count toward this month (same rule as the monthly reports).
    pub month: Option<String>,
    pub min_cents: Option<i64>,
    pub max_cents: Option<i64>,
    /// "expense" | "income" | None
    pub flow: Option<String>,
    pub uncategorized_only: bool,
    /// "exclude" (default) | "only" | "all"
    pub transfers: String,
    /// date | amount | description | merchant | account | category
    pub sort: String,
    pub ascending: bool,
    pub page: u32,
    pub page_size: u32,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct TxPage {
    pub rows: Vec<Transaction>,
    pub page: u32,
    pub page_size: u32,
    pub total: u32,
    pub pages: u32,
    pub inflow_cents: i64,
    pub outflow_cents: i64,
    /// When transfers are hidden: how many transfers match the other filters.
    pub hidden_transfers: u32,
}

#[derive(Debug, Clone, Default, uniffi::Record)]
pub struct TxPatch {
    pub date: Option<String>,
    pub description: Option<String>,
    pub merchant: Option<String>,
    pub amount_cents: Option<i64>,
    pub notes: Option<String>,
    pub is_transfer: Option<bool>,
    /// When true, category_id / subcategory_id below are written (None clears them).
    pub set_category: bool,
    pub category_id: Option<String>,
    pub subcategory_id: Option<String>,
    /// When true, report_month below is written (None = count in its own month).
    pub set_report_month: bool,
    pub report_month: Option<String>,
}

// ---------- import ----------

/// Zero-based column indexes. None = column not mapped.
#[derive(Debug, Clone, Default, PartialEq, uniffi::Record)]
pub struct ColumnMapping {
    pub date: Option<u32>,
    pub description: Option<u32>,
    pub merchant: Option<u32>,
    pub amount: Option<u32>,
    pub debit: Option<u32>,
    pub credit: Option<u32>,
    pub notes: Option<u32>,
    pub txn_type: Option<u32>,
    pub category: Option<u32>,
    pub check_number: Option<u32>,
    pub balance: Option<u32>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct PreviewRow {
    pub line: u32,
    pub date: String,
    pub description: String,
    pub merchant: String,
    pub amount: String,
    pub debit: String,
    pub credit: String,
    pub notes: String,
    pub parsed_date: Option<String>,
    pub parsed_cents: Option<i64>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct ImportPreview {
    pub headers: Vec<String>,
    pub mapping: ColumnMapping,
    pub total: u32,
    pub sample: Vec<PreviewRow>,
    pub has_header: bool,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct ImportRequest {
    pub text: String,
    pub filename: String,
    pub account_id: Option<String>,
    /// Used when account_id is None.
    pub new_account: Option<NewAccount>,
    pub mapping: ColumnMapping,
    /// auto | mdy | dmy
    pub date_format: String,
    pub invert: bool,
    pub skip_duplicates: bool,
    pub apply_rules: bool,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct ImportResult {
    pub batch_id: String,
    pub account_id: String,
    pub imported: u32,
    pub skipped: u32,
    pub errors: Vec<String>,
    pub rules_applied: u32,
    pub transfers_marked: u32,
    pub remembered: u32,
    /// Rows skipped because they're the pending/posted twin of a transaction already on file
    /// (included in `skipped`).
    pub pending_duplicates_skipped: u32,
    /// Set when the file had a running-balance column and the account's balance was updated from it.
    pub balance_updated_cents: Option<i64>,
    pub balance_as_of: Option<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct ImportBatch {
    pub id: String,
    pub filename: String,
    pub account_id: Option<String>,
    pub account_name: Option<String>,
    pub imported_at: String,
    pub row_count: u32,
    pub skipped: u32,
    pub tx_count: u32,
}

// ---------- rules ----------

#[derive(Debug, Clone, uniffi::Record)]
pub struct Rule {
    pub id: String,
    pub priority: i64,
    pub enabled: bool,
    /// contains | exact | starts | regex
    pub match_type: String,
    /// description | merchant
    pub field: String,
    pub pattern: String,
    pub category_id: Option<String>,
    pub subcategory_id: Option<String>,
    pub min_cents: Option<i64>,
    pub max_cents: Option<i64>,
    pub category_name: Option<String>,
    pub subcategory_name: Option<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct RuleInput {
    pub priority: i64,
    pub enabled: bool,
    pub match_type: String,
    pub field: String,
    pub pattern: String,
    pub category_id: Option<String>,
    pub subcategory_id: Option<String>,
    pub min_cents: Option<i64>,
    pub max_cents: Option<i64>,
}

// ---------- reports ----------

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct MonthFlow {
    pub ym: String,
    pub label: String,
    pub income_cents: i64,
    pub expense_cents: i64,
    pub net_cents: i64,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct MerchantTotal {
    pub name: String,
    pub total_cents: i64,
    pub count: u32,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct Overview {
    pub month: String,
    pub income_cents: i64,
    pub expense_cents: i64,
    pub net_cents: i64,
    pub tx_count: u32,
    pub prev_income_cents: i64,
    pub prev_expense_cents: i64,
    pub prev_net_cents: i64,
    pub savings_rate: Option<f64>,
    pub uncategorized: u32,
    pub liquid_balance_cents: i64,
    pub merchants: Vec<MerchantTotal>,
    pub recent: Vec<Transaction>,
    pub series: Vec<MonthFlow>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct BreakdownSub {
    pub id: String,
    pub name: String,
    pub total_cents: i64,
    pub count: u32,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct BreakdownCategory {
    pub id: String,
    pub name: String,
    pub color: String,
    pub icon: String,
    pub total_cents: i64,
    pub count: u32,
    pub subcategories: Vec<BreakdownSub>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct Breakdown {
    pub kind: String,
    pub month: String,
    pub uncategorized_cents: i64,
    pub uncategorized_count: u32,
    pub categories: Vec<BreakdownCategory>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct BudgetLine {
    pub id: String,
    pub category_id: String,
    pub subcategory_id: Option<String>,
    pub amount_cents: i64,
    pub category_name: String,
    pub category_color: String,
    pub category_icon: String,
    pub subcategory_name: Option<String>,
    pub actual_cents: i64,
    pub remaining_cents: i64,
    pub pct: f64,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct PlanSub {
    pub id: String,
    pub name: String,
    pub actual_cents: i64,
    pub count: u32,
    pub budget_id: Option<String>,
    pub budget_cents: i64,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct PlanCategory {
    pub id: String,
    pub name: String,
    pub color: String,
    pub icon: String,
    pub actual_cents: i64,
    pub count: u32,
    pub budget_id: Option<String>,
    pub budget_cents: i64,
    pub subcategories: Vec<PlanSub>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct PlanMetrics {
    pub savings_rate_month: Option<f64>,
    pub savings_rate_3m: Option<f64>,
    pub avg_expense_3m_cents: i64,
    pub avg_income_3m_cents: i64,
    pub liquid_balance_cents: i64,
    pub runway_months: Option<f64>,
    pub projected_expense_cents: Option<i64>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct Planning {
    pub month: String,
    pub budgets: Vec<BudgetLine>,
    pub tree: Vec<PlanCategory>,
    /// Category budget if set, otherwise the sum of its subcategory budgets.
    pub budgeted_cents: i64,
    pub actual_cents: i64,
    pub income_cents: i64,
    pub metrics: PlanMetrics,
    pub series: Vec<MonthFlow>,
}

// ---------- AI ----------

#[derive(Debug, Clone, uniffi::Record)]
pub struct AiStatus {
    pub provider: String,
    pub claude: Option<String>,
    pub codex: Option<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct AiTestResult {
    pub ok: bool,
    pub reply: String,
    pub elapsed_ms: u64,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct Suggestion {
    pub id: String,
    pub date: String,
    pub description: String,
    pub amount_cents: i64,
    pub category_id: Option<String>,
    pub category_name: Option<String>,
    pub subcategory_id: Option<String>,
    pub subcategory_name: Option<String>,
    pub new_category: bool,
    pub matched: bool,
    pub confidence: f64,
    pub reason: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct SuggestResult {
    pub suggestions: Vec<Suggestion>,
    pub provider: String,
    pub elapsed_ms: u64,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct AiApplyResult {
    pub updated: u32,
    pub categories_created: u32,
    pub subcategories_created: u32,
}

// ---------- debts ----------

/// What's left to pay on one debt at its current payment.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct PayoffEstimate {
    /// ok | paid_off | never (payment doesn't cover interest) | unknown (balance or payment not set)
    pub status: String,
    pub payments: Option<u32>,
    pub payoff_date: Option<String>,
    pub interest_cents: i64,
    pub total_cents: i64,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct Debt {
    pub id: String,
    pub name: String,
    pub lender: String,
    /// bnpl | card | installment | short_term | auto | relief | loan
    pub kind: String,
    pub account_id: Option<String>,
    /// manual | account (balance follows a linked account)
    pub balance_source: String,
    /// Owed amount (positive) as of `balance_as_of`.
    pub balance_cents: i64,
    pub balance_as_of: String,
    pub original_cents: Option<i64>,
    /// Annual percentage rate, e.g. 29.99
    pub apr: f64,
    pub payment_cents: i64,
    /// weekly | biweekly | monthly | quarterly | semiannual | yearly
    pub frequency: String,
    pub next_due: Option<String>,
    pub payments_left: Option<u32>,
    /// Merchant key used to find this debt's payments in transactions.
    pub match_key: String,
    pub match_exact_amount: bool,
    pub notes: String,
    // Computed
    pub account_name: Option<String>,
    pub current_balance_cents: i64,
    pub balance_is_estimate: bool,
    pub paid_since_cents: i64,
    pub payments_since: u32,
    pub payments_left_now: Option<u32>,
    pub last_payment_date: Option<String>,
    /// Newest first (up to 6).
    pub recent_payments: Vec<DebtPayment>,
    pub next_payment_date: Option<String>,
    pub monthly_payment_cents: i64,
    pub payoff: PayoffEstimate,
}

/// Result of building rules from already-categorized transactions.
#[derive(Debug, Clone, uniffi::Record)]
pub struct LearnRulesResult {
    pub created: u32,
    /// Merchants an existing rule already handles the same way.
    pub already_covered: u32,
    /// Merchants left to merchant memory because they're filed under different categories.
    pub skipped: Vec<String>,
    /// Categorized rows whose category the full rule set would now give differently (should be 0
    /// apart from the skipped merchants' minority rows).
    pub rows_disagreeing: u32,
    pub rows_checked: u32,
    /// "description: filed as X, rule says Y" for each disagreeing row.
    pub disagreements: Vec<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct DebtPayment {
    pub date: String,
    pub amount_cents: i64,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct DebtInput {
    pub name: String,
    pub lender: String,
    pub kind: String,
    pub account_id: Option<String>,
    pub balance_source: String,
    pub balance_cents: i64,
    pub balance_as_of: String,
    pub original_cents: Option<i64>,
    pub apr: f64,
    pub payment_cents: i64,
    pub frequency: String,
    pub next_due: Option<String>,
    pub payments_left: Option<u32>,
    pub match_key: String,
    pub match_exact_amount: bool,
    pub notes: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct DebtSuggestion {
    pub input: DebtInput,
    /// Why it was suggested, in plain words.
    pub reason: String,
    pub occurrences: u32,
    pub last_date: Option<String>,
    /// Strong match (regular payments or a card/loan account); start it checked in the UI.
    pub recommended: bool,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct DebtSummary {
    pub count: u32,
    pub total_cents: i64,
    pub monthly_payments_cents: i64,
    /// Balance-weighted APR across debts with a balance.
    pub weighted_apr: Option<f64>,
    pub interest_remaining_cents: i64,
    /// Latest payoff date among debts with a known payoff.
    pub debt_free_date: Option<String>,
    /// Debts whose payoff can't be computed (no balance, or payment below interest).
    pub unknown_count: u32,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct PlanDebt {
    pub id: String,
    pub name: String,
    /// 1-based order the plan pays debts off in.
    pub order: u32,
    pub payoff_month: Option<String>,
    pub interest_cents: i64,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct BalancePoint {
    pub ym: String,
    pub balance_cents: i64,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct PlanResult {
    /// avalanche | snowball | minimum
    pub strategy: String,
    pub extra_cents: i64,
    pub months: u32,
    pub debt_free_month: Option<String>,
    pub total_interest_cents: i64,
    pub total_paid_cents: i64,
    /// True when the plan never finishes (payments don't cover interest).
    pub never: bool,
    /// Debts left out because their balance or payment isn't set.
    pub excluded: u32,
    pub debts: Vec<PlanDebt>,
    pub series: Vec<BalancePoint>,
}

// ---------- recurring income and bills, calendar ----------

#[derive(Debug, Clone, uniffi::Record)]
pub struct Recurring {
    pub id: String,
    pub name: String,
    /// income | bill
    pub kind: String,
    /// Positive amount.
    pub amount_cents: i64,
    pub frequency: String,
    /// Any one date it happens on; the schedule repeats from there.
    pub anchor_date: String,
    pub match_key: String,
    pub match_exact_amount: bool,
    pub category_id: Option<String>,
    pub account_id: Option<String>,
    pub active: bool,
    pub notes: String,
    // Computed
    pub category_name: Option<String>,
    pub account_name: Option<String>,
    /// False when it's charged to a credit card, so it doesn't move checking.
    pub affects_cash: bool,
    pub next_date: Option<String>,
    pub last_seen: Option<String>,
    pub monthly_cents: i64,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct RecurringInput {
    pub name: String,
    pub kind: String,
    pub amount_cents: i64,
    pub frequency: String,
    pub anchor_date: String,
    pub match_key: String,
    pub match_exact_amount: bool,
    pub category_id: Option<String>,
    pub account_id: Option<String>,
    pub active: bool,
    pub notes: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct RecurringSuggestion {
    pub input: RecurringInput,
    /// income | bill | debt
    pub suggested_kind: String,
    pub occurrences: u32,
    pub first_date: String,
    pub last_date: String,
    pub next_date: Option<String>,
    pub category_name: Option<String>,
    pub account_name: Option<String>,
    pub already_tracked: bool,
    /// Looks like a real bill or paycheck; start it checked in the UI.
    pub recommended: bool,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct CalendarEvent {
    pub date: String,
    /// income | bill | debt
    pub kind: String,
    pub name: String,
    /// Signed: income positive, bills and debt payments negative.
    pub amount_cents: i64,
    pub source_id: String,
    /// upcoming | paid | missed | unknown (after the last imported transaction)
    pub status: String,
    pub actual_cents: Option<i64>,
    pub affects_cash: bool,
    /// "YYYY-MM" this event counts toward (differs from its date when the matched
    /// transaction was moved to another month).
    pub counts_in_month: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct CalendarDay {
    pub date: String,
    pub events: Vec<CalendarEvent>,
    /// Projected cash at the end of the day; only for today and later.
    pub projected_balance_cents: Option<i64>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct CalendarMonth {
    pub month: String,
    pub today: String,
    pub days: Vec<CalendarDay>,
    pub paychecks: u32,
    pub income_cents: i64,
    pub bills_cents: i64,
    pub debt_cents: i64,
    /// Cash in checking/savings/cash accounts today.
    pub start_balance_cents: i64,
    /// True when a cash account has no manual balance, so the projection may be off.
    pub balance_needs_setup: bool,
    pub lowest_balance_cents: Option<i64>,
    pub lowest_date: Option<String>,
    /// Months in the next year with three paydays of the main paycheck ("YYYY-MM").
    pub three_paycheck_months: Vec<String>,
    pub main_income_name: Option<String>,
    /// Day-to-day spending from budgets included in this month's projection
    /// (for the current month, what's left of it).
    pub flexible_cents: i64,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct PayPeriod {
    pub start: String,
    pub end: String,
    pub is_current: bool,
    pub paycheck_cents: i64,
    pub other_income_cents: i64,
    pub bills_cents: i64,
    pub debt_cents: i64,
    /// Day-to-day spending from budgets spread over this period's days (from today on).
    pub flexible_cents: i64,
    /// Paycheck + other income − bills − debt payments − day-to-day budgets.
    pub leftover_cents: i64,
    pub ending_balance_cents: Option<i64>,
    pub events: Vec<CalendarEvent>,
}

// ---------- investments and net worth ----------

#[derive(Debug, Clone, uniffi::Record)]
pub struct ValuePoint {
    pub id: String,
    pub date: String,
    pub value_cents: i64,
    pub note: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct Investment {
    /// Same as the underlying account id.
    pub id: String,
    pub name: String,
    pub institution: String,
    /// brokerage | retirement | hsa
    pub kind: String,
    pub color: String,
    pub value_cents: i64,
    pub value_as_of: Option<String>,
    /// e.g. "401(k)", "Individual brokerage", "Roth IRA"
    pub account_label: String,
    pub employer: String,
    /// Free text, e.g. "Target Retirement 2050 — 100%"
    pub allocation: String,
    pub contribution_pct: Option<f64>,
    pub employer_match: String,
    pub account_last4: String,
    pub notes: String,
    /// Oldest first.
    pub history: Vec<ValuePoint>,
    /// Latest value minus the earliest recorded value.
    pub change_cents: i64,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct InvestmentInput {
    pub name: String,
    pub institution: String,
    pub kind: String,
    pub color: String,
    pub account_label: String,
    pub employer: String,
    pub allocation: String,
    pub contribution_pct: Option<f64>,
    pub employer_match: String,
    pub account_last4: String,
    pub notes: String,
    /// Starting value (create only); recorded as the first history point.
    pub value_cents: Option<i64>,
    pub value_as_of: Option<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct NetWorthLine {
    /// cash | investments | debt
    pub group: String,
    pub name: String,
    /// Signed: debts are negative.
    pub amount_cents: i64,
    pub detail: String,
    /// True when the amount is an estimate or not set yet.
    pub needs_attention: bool,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FinancialOverview {
    pub as_of: String,
    pub cash_cents: i64,
    pub cash_needs_setup: bool,
    pub investments_cents: i64,
    pub debt_cents: i64,
    pub debts_missing_balance: u32,
    pub net_worth_cents: i64,
    /// Monthly take-home from scheduled income, or the 3-month average if none is scheduled.
    pub monthly_income_cents: i64,
    pub income_from_schedule: bool,
    pub monthly_bills_cents: i64,
    pub monthly_debt_payments_cents: i64,
    /// Day-to-day spending budgets not already covered by bills or debt payments.
    pub monthly_flexible_cents: i64,
    pub monthly_left_cents: i64,
    /// Monthly debt payments ÷ monthly take-home.
    pub debt_to_income: Option<f64>,
    pub lines: Vec<NetWorthLine>,
}

/// Debts grouped by the card/loan account they follow, or by lender.
#[derive(Debug, Clone, uniffi::Record)]
pub struct DebtGroup {
    pub key: String,
    pub name: String,
    pub account_id: Option<String>,
    pub debts: Vec<Debt>,
    pub total_cents: i64,
    pub monthly_cents: i64,
    pub interest_cents: i64,
    /// Latest payoff date in the group (when every debt in it has one).
    pub payoff_date: Option<String>,
    /// Debts in the group without a balance or payoff estimate.
    pub unknown_count: u32,
    pub apr_min: Option<f64>,
    pub apr_max: Option<f64>,
}

/// One budget's flexible part: the budget minus scheduled bills/debt payments in it.
#[derive(Debug, Clone, uniffi::Record)]
pub struct FlexLine {
    pub category_id: String,
    pub subcategory_id: Option<String>,
    pub name: String,
    pub budget_cents: i64,
    pub scheduled_cents: i64,
    /// Monthly amount spread across the month in the cash projection.
    pub monthly_cents: i64,
    pub spent_this_month_cents: i64,
    pub remaining_this_month_cents: i64,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FlexibleBudgets {
    pub lines: Vec<FlexLine>,
    pub monthly_cents: i64,
    pub remaining_this_month_cents: i64,
}
