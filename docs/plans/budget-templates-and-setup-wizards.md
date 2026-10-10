# Budget Templates and Selective Setup Wizards

**Status:** Proposed  
**Priority convention:** P1 is the first release; P2 and P3 follow in order.

## Goal

Expand Budget Warden to support personal finances, travel, freelance work, small-business cash planning, events, and projects. Keep templates as starting points for editable budgets. Add setup questions only when a small number of answers can calculate planned amounts for several categories.

This is a budgeting plan, not a bookkeeping plan. Business templates must not imply that cash flow is accounting profit, or that tax reserves are tax advice.

## Review comments and decisions

The direction fits the current four category types. The main investment is making creation and reporting useful for each scenario; adding more category names alone has diminishing returns.

| Point | Assessment | Decision |
| --- | --- | --- |
| Template priorities | Weekly, freelancer, event, and travel presets demonstrate the broader product. Travel initially uses the existing reports. | Ship seven P1 presets, with Vacation and Business Trip immediately after Event Planning. Add travel-specific reporting and setup in P2. |
| Size of P2 | Model changes, migration, reporting, five native interfaces, and wizards form a large release. | Divide P2 into independently reviewable work packages. Upgrade the existing travel presets before adding the remaining P2 presets. |
| Wizard usefulness | Asking for a hotel total or flight total mostly repeats normal category editing. Counts and rates can calculate estimates. | Use a compact travel calculator and an optional event calculator. Keep ordinary category editing in the budget. |
| Dates | A date range does not by itself imply that transactions outside it should disappear from totals. Payments for a holiday often happen before travel dates. | Treat dates as descriptive metadata initially. Continue counting all transactions in the budget. Date-filtered reports require a separate explicit feature. |
| Report terminology | The existing `income` reporting field is planned income; `left_to_budget` uses planned expenses, debt, and savings. | Preserve that formula for existing budgets. Add separate planned and actual revenue/cost metrics for the new mode. |
| Reserves and debt | Reserve transfers and principal repayments are not operating expenses. | Display these separately in Revenue & Cost. Define every headline metric before implementation. |
| Currency | Currency currently comes from app settings, so a travel estimate has no exchange-rate semantics. | Use the existing currency behavior, display it prominently during setup, and scope per-budget currency separately. |
| Learning from usage | The catalog should follow user demand, but the app is based on local files. | Use voluntary feedback and usability sessions. This plan does not assume analytics collection. |

Priority is a delivery order, not a promise to implement every P3 idea. P1 should validate whether people choose these presets and whether the initial category lists need repeated cleanup.

## Product and implementation rules

- Keep template identity, budgeting mode, and date range as separate concepts. A template chooses starting categories; a mode defines reporting; a date range describes the budget's intended period.
- Keep the built-in catalog in `core`. Use stable template IDs and explicit Rust definitions for categories and setup calculations. Do not introduce a general template scripting or JSON configuration system for this catalog.
- New category presets start with zero planned amounts unless a wizard calculates an amount from user input. Do not present invented estimates as recommendations. Preserve the existing Basic Monthly defaults.
- Run all wizard validation and calculations in `core`, using checked money arithmetic. GUI code collects inputs, shows a preview, and calls the shared core API.
- Do not ask for values that cannot produce a meaningful calculation. Templates without useful calculations go straight from template selection to creation; users can edit categories and amounts afterward.
- Do not persist the template definition or one-time wizard answers by default. Persist only information the user or reports need after creation, such as the date range, spending limit, and reporting mode. Add persistent assumptions only when a later feature uses them.

## P1 — Add useful category presets

Add the following templates through the existing `BWTemplateType` and `budget_from_template` path. This phase does not change the `.budget` schema or reporting model.

| Template | Suggested categories | Notes |
| --- | --- | --- |
| Weekly Personal | Income: Weekly Income; Expenses: Groceries, Dining, Transport, Entertainment, Miscellaneous; Savings: Weekly Savings | Category preset only. Users can create a separate budget for each week. |
| Biweekly Paycheck | Income: Paycheck; Expenses: Rent Allocation, Bills, Groceries; Debt: Debt Payments; Savings: Savings | Category preset only. No automatic pay-period date filtering yet. |
| Freelancer Monthly | Income: Client Payments, Retainers, Other Revenue; Expenses: Subscriptions, Hardware, Internet, Marketing, Accounting, Travel; Savings: Tax Reserve, Emergency Fund, Equipment Replacement; Debt: Business Loan, Equipment Financing | Treat Tax Reserve as savings, not an expense, to avoid counting it twice. |
| Small Business Monthly | Income: Product Sales, Service Revenue, Subscriptions, Other Revenue; Expenses: Payroll, Contractors, Hosting, Rent, Software, Marketing, Operations, Accounting, Taxes; Savings: Cash Reserve, Equipment Fund; Debt: Business Loans, Credit Payments | Cash planning only. Do not label the result accounting profit. |
| Event Planning | Income: Ticket Sales, Sponsorships, Vendor Fees, Contributions; Expenses: Venue, Catering, Speakers, Equipment, Promotion, Staff, Security; Savings: Contingency Reserve; Debt: Event Financing, Supplier Credit | Existing reporting can show the cash allocation, but has no event-specific break-even metric. |
| Vacation | Expenses: Flights, Accommodation, Food, Local Transport, Activities, Travel Insurance, Visas, Shopping; Savings: Emergency Buffer | Category preset with editable amounts. Spending-limit reporting and the travel estimate wizard follow in P2. |
| Business Trip | Expenses: Flights, Accommodation, Food & Per Diem, Local Transport, Travel Insurance, Visas, Business Expenses; Savings: Emergency Buffer | Category preset with editable amounts. User-entered per-diem calculations follow in P2. |

Keep Monthly Budget and Empty Budget unchanged. For new presets, descriptions should make clear that weekly/biweekly labels do not filter transactions by date and that current reports retain their income-allocation interpretation. The app should not market a travel budget as a complete spending-limit budget in this phase: with no income, the current “left to budget” calculation can be negative even when the user has funds set aside.

Vacation and Business Trip ship in P1 as category presets with zero planned amounts and no setup questions. Their descriptions explain the existing income-allocation reporting limitation. Do not invent Income categories or transactions to represent money already saved for travel. P2 adds Spending Limit as the default for newly created travel budgets; users can switch existing P1 travel budgets to that mode through budget settings without replacing their categories or transactions.

## P2 — Add budget periods, reporting modes, and targeted wizards

### Core model and reporting

Add explicit budget-level metadata in `BWBudget`:

- A reporting mode: Income Allocation, Spending Limit, or Revenue & Cost.
- An optional inclusive start and end date.
- An optional spending limit. Spending Limit mode can still report planned and actual spending without one; show a remaining-limit metric only when a limit is set.

The current schema is version 2. Introduce the next schema version with defaults for existing files: existing budgets decode as Income Allocation with no date range or spending limit. Update validation, encoding, migration, and CRDT merge behavior together. `CRDTChanges` currently tracks the budget title as budget-level state; new fields need field-level change tracking so concurrent edits to the mode, dates, and limit do not overwrite one another.

Use independent merge units for the title, reporting policy, and date range. Merge the start/end pair together to prevent two valid edits from producing an invalid combined range. Treat mode and its limit as one reporting-policy value initially. Clearing a range or limit must be represented as an explicit change, distinct from leaving it untouched.

Validate that a date range is either fully absent or has both dates with start on or before end. Let users edit the mode, period, and limit after creation through normal budget settings, so the creation choice is not permanent.

Recommended report semantics:

- **Income Allocation:** preserve `left_to_budget = planned income − planned Expenses − planned Debt − planned Savings`. Keep existing actual-allocation comparisons; do not reinterpret planned income as received income.
- **Spending Limit:** when a limit is set, show limit minus planned or actual Expenses. Without a limit, show planned and actual Expenses without a remaining-limit metric. Show Savings and Debt separately instead of silently treating them as trip spending.
- **Revenue & Cost:** show planned Income less planned Expenses and actual Income less actual Expenses as distinct values. Show Savings and Debt separately; do not call this accounting profit because the model does not distinguish principal, interest, tax liabilities, or accounting recognition.
- **Date range:** describe the intended period and count all transactions in the budget. A flight purchased before a trip still belongs to that trip's budget. Any future date filter must be explicit and must agree across category and summary views.

Use signed report results even though category money amounts are nonnegative. Overspending and negative net amounts are valid report outcomes. Calculate sums, multiplication, and subtraction with overflow checks.

| Example | Expected headline result |
| --- | --- |
| Income Allocation: planned income 3,000; expenses 2,000; debt 200; savings 500 | Left to budget: 300. |
| Spending Limit: limit 2,000; planned expenses 1,800; actual expenses 1,250 | Unallocated limit: 200; remaining to spend: 750. |
| Spending Limit: no limit; planned expenses 1,800; actual expenses 1,250 | Show both totals; omit remaining-to-spend values rather than showing zero. |
| Revenue & Cost: planned revenue 5,000; planned expenses 3,000; received revenue 2,000; actual expenses 2,500 | Planned net: 2,000; actual net: −500. Reserve and debt allocations appear separately. |

For Spending Limit, keep contingency inside the overall cap without recording it as actual spending. The unallocated part of the cap can represent contingency; do not add the cap itself as an Income category or a transaction. If a template includes a Savings reserve, label it separately and do not deduct it twice.

The template definition itself need not be written into each budget. Persist the chosen mode, date range, and limit because they remain useful after creation and must merge across devices. Keep per-budget currency and foreign-exchange conversion out of P2; wizard amounts use the app's selected currency.

### P2 template upgrades and additions

| Template | Priority | Reason / behavior |
| --- | --- | --- |
| Vacation | P1 preset; P2 upgrade | Add Spending Limit mode and the optional travel setup wizard to the existing P1 template. |
| Business Trip | P1 preset; P2 upgrade | Add Spending Limit mode and the optional travel setup wizard to the existing P1 template. |
| Freelancer Project | P2 | Revenue & Cost preset for client revenue, software, equipment, contractor costs, travel, and optional tax reserve. Do not estimate revenue or taxes without user input. |
| Home Renovation | P2 | Spending Limit preset for materials, contractors, permits, furniture, tools, and contingency. Do not invent category splits from one total. |
| Wedding Planning | P2 | Spending Limit preset for venue, catering, photography, attire, flowers, entertainment, and transport. |
| Startup Budget | P2 | Default to Spending Limit for setup costs, initial inventory, and launch marketing. Users can change the mode for operating revenue later; avoid an extra mode question during creation. |
| Side Hustle | P2 | Revenue & Cost preset for a small, separate income stream and its operating costs. |

Event Planning, Vacation, and Business Trip remain available from P1 with stable template IDs. P2 adds their reporting and setup features without duplicating the templates or automatically changing the mode of existing budgets.

### Selective setup wizard

The new-budget flow should ask for a title and template first. Show an additional setup section only for templates with useful calculations. Show the resulting categories and planned amounts before creation; amounts remain editable in the normal budget UI.

| Wizard | Inputs | Core calculation |
| --- | --- | --- |
| Travel: Vacation or Business Trip | Travelers (default 1), allowance days, lodging nights, total lodging cost per night, daily food/per-diem amount per traveler | Accommodation is nights × total nightly cost. Food (Vacation) or Food & Per Diem (Business Trip) is travelers × allowance days × daily amount. Other categories start at zero. |
| Ticketed Event | Expected attendance, ticket price, catering cost per attendee (optional) | Ticket Sales is attendance × ticket price. Catering is attendance × per-attendee cost. Other categories start at zero. |

Money estimates may be skipped and then create zero-planned categories. Travelers default to one. Allow zero nights for a day trip and zero allowance days when no daily estimate is needed; travelers must be positive. The nightly lodging input is the combined accommodation cost for all travelers, so the calculation does not assume one room per person. Allowance days and lodging nights are independent, and neither is inferred from dates.

The event calculator is offered through “Estimate ticket revenue” inside Event Planning setup. Non-ticketed events can create the preset directly. Attendance and ticket price are the minimum inputs for a revenue estimate; catering is optional. Per-diem values are user-entered allowances. Do not ask for flight class, individual meal amounts, insurance, activities, or detailed supplier costs; users enter those in categories. Monthly Freelancer, Small Business, Home Renovation, and Wedding start as presets without calculation questions.

### Wizard behavior and examples

Use one compact setup screen on desktop and a short native form on mobile. The flow is: choose template and title, optionally estimate, review, then save through the existing file-location workflow. “Use categories only” bypasses calculation inputs. Keep previous-budget creation alongside the catalog rather than presenting every recent file as a built-in template.

The travel estimate uses five fields, two of which are quantity/rate pairs. Flights, insurance, activities, and other costs remain ordinary editable categories. The spending limit belongs in an optional budget-settings section on the review screen; it is independent of the sum of estimates and does not change when a category estimate is edited.

For a business trip with two travelers, five allowance days, four lodging nights, a combined nightly cost of 150, and a daily allowance of 45 per traveler, core produces Accommodation = 600 and Food & Per Diem = 450. The review says “Estimated so far: 1,050” and identifies the categories still at zero. It must not imply that this is a complete trip cost.

For 120 attendees, tickets at 25, and catering at 8 per attendee, core produces Ticket Sales = 3,000 and Catering = 960. The review identifies venue, staff, promotion, and other costs as not estimated. The difference of 2,040 is not presented as final event profit or break-even.

Recalculate the preview when inputs change. Keep the title and inputs when going Back or canceling the file picker. Switching templates clears incompatible estimates with a clear UI indication; never silently transfer a travel estimate into another preset. Avoid editing the same planned amount both in wizard inputs and in preview: the first version uses a read-only preview, followed by normal editing after creation.

Cancellation before saving must not create a budget file or add a recent-file entry. Creation errors preserve the draft so users can correct a value or retry saving. Android must preserve the full creation draft through its document-picker lifecycle, not just title and template ID.

The travel dates are descriptive period metadata. Offer the same optional date range on every supported platform using native date controls; do not require dates for creation. Wizard answers are one-time setup values and need not persist once their calculated category amounts are saved. If a future break-even view needs attendance and ticket-price assumptions after creation, add those as explicit versioned budget metadata with CRDT support then. Do not provide a “re-run setup” action on an existing budget until overwrite behavior for edited category amounts is designed.

### GUI and core delivery order

1. Extend core models, defaults, validation, migration, reporting, and merge semantics.
2. Add stable template IDs, category definitions, and typed setup input/result APIs in core; regenerate and consume the generated bindings.
3. Update each native creation flow: macOS, iOS, Android, Linux, and Windows. Keep labels in the platform localization layer and calculations in core.
4. Add template descriptions, conditional setup inputs, a category/amount preview, and a direct create path for templates without a wizard.
5. Keep CLI creation non-interactive; it may call the same core APIs when a caller supplies setup values, but no CLI prompt flow is part of this work.

### Core API and catalog contract

Keep a single core-owned catalog with an entry for each built-in template. Each entry contains a stable ID, family, description/localization key, ordered category definitions, default reporting mode, and supported setup kind. Template versioning is unnecessary for already-created budgets because they contain independent categories and amounts.

Preserve `Empty`, `BasicMonthly`, and the existing creation function. Append new template variants without changing existing identities. Provide a catalog-list operation so GUIs and CLI do not maintain separate template inventories. Platform translations may map core keys to local strings; define an English fallback and avoid translating identifiers. Category localization during creation must preserve core-defined types, ordering, and amounts.

Use concrete travel and event setup records with integer counts and `BWMoneyAmount` values. Missing monetary estimates are explicit optional values; they must not be confused with an invalid text input. Native clients use the existing money parser to convert text before calling core. Core rejects negative amounts/counts, invalid dates, and overflow independently of client validation. Do not add a generic dictionary of arbitrary template parameters.

Separate preview calculation from budget creation. Preview returns category estimates and aggregate totals without creating UUIDs, CRDT changes, or files. Creation consumes the validated setup and builds a fresh budget through the existing domain mutation APIs. Initial actuals and transactions are empty, accumulated amounts are zero for built-in templates, and every created category has a fresh ID and CRDT initialization.

The normal category model remains canonical after creation. Templates do not keep formulas attached to category amounts. Editing Food & Per Diem later changes that planned amount directly and does not alter the original daily allowance.

### Work packages and exit conditions

| Package | Concrete work | Exit condition |
| --- | --- | --- |
| P1.1 — Catalog and presets | Add core catalog entries and the seven P1 category definitions, with Vacation and Business Trip after Event Planning; retain the existing template API. | Catalog IDs are unique; categories have correct types and per-type ordering; new amounts are zero; existing Monthly output is preserved. |
| P1.2 — Catalog across clients | Replace hardcoded built-in template lists in five GUIs and CLI list/show/create paths. Add family labels and short descriptions where useful. | Each client offers the same built-ins; Empty and Previous Budget still work. P1 can ship without schema changes. |
| P2.1 — Persistent budget settings | Add reporting policy, optional date range, domain setters, schema migration, and CRDT resolution. | Old files retain their behavior; new metadata survives save/reopen and concurrent edits; explicit clearing works. |
| P2.2 — Reports and settings UI | Extend core reporting with separate planned/actual income and mode-specific results; update native report labels and budget settings. | All report examples above produce the specified values on every GUI. Category actuals continue including all transactions. |
| P2.3 — Travel upgrade and estimate | Upgrade the existing Vacation/Business Trip templates with Spending Limit defaults and pure preview/creation APIs, then native setup and review screens. | Stable template IDs are preserved; existing budgets remain editable; the worked example agrees everywhere; skipped estimates are visible; cancel/retry preserves the draft. |
| P2.4 — Event estimate | Add attendance/ticket/catering calculations and an optional Event Planning setup section. | Ticketed and non-ticketed paths both work; no break-even or accounting-profit claim appears. |
| P2.5 — Remaining presets | Add Freelancer Project, Home Renovation, Wedding, Startup, and Side Hustle with correct default modes. | Each creates an ordinary editable budget without unnecessary setup questions. |
| P3 — Selected additions | Choose a small batch of presets or reusable-template work based on feedback. | Each addition has a distinct use case and a clear benefit beyond renaming an existing preset. |

P2.1 and P2.2 must land together before a new-mode budget is offered to users. P2.3 can then ship before P2.4 and P2.5. Deploy schema support to supported clients before broadly exchanging files that require it: older clients should reject the newer schema using the existing update-required behavior, rather than open and rewrite it without metadata.

### Repository routing

| Area | Main files / responsibility |
| --- | --- |
| Core catalog and calculation | `core/src/templates.rs`; add a small adjacent module only if setup calculations make this file unwieldy. |
| Persistent model and validation | `core/src/models.rs`, `domain.rs`, `validation.rs`, `codec.rs`, and `legacy_migration.rs`. |
| Merge semantics | `core/src/crdt.rs`; migrate existing title changes while introducing reporting-policy and date-range merge units. |
| Shared reports | `core/src/reporting.rs`; consumers must use core results rather than repeat formulas. |
| Apple | Generate Apple bindings; update `apple-core/src/BWReporting.swift` and the macOS/iOS creation views and `BWStore.swift` files. |
| Android | Generate Kotlin bindings; update `BudgetDialogs.kt`, creation draft state in `MainActivity.kt`/`BudgetSessionViewModel.kt`, and `data/BudgetRepository.kt`. |
| Linux | Update `linux/src/ui.rs`, `store.rs`, and reporting consumers. Linux calls core directly. |
| Windows | Generate C# bindings; update `windows/Views/BudgetDialogs.cs`, `ViewModels/AppViewModel.Persistence.cs`, template inventory, and report view models. |
| CLI | Update `cli/src/args.rs`, `commands.rs`, template discovery, and the affected protocol schemas/documentation together. Keep accepted IDs stable. |

When creating from a previous budget, preserve the existing planned and accumulated category amounts and reset actuals/transactions as today. In P2, copy the reporting policy and spending limit, but clear the old date range so a new weekly budget does not inherit last week's dates. Existing budgets retain their category names and amounts when built-in definitions change.

### Validation and review scenarios

During implementation, use focused core checks for catalog output, checked calculations, old-file migration, reporting formulas, and metadata merges. Exercise native lifecycle behavior manually on every platform; a passing core calculation alone does not verify file-picker or draft preservation behavior.

| Scenario | Required behavior |
| --- | --- |
| Existing schema-v2 file with transactions and CRDT history | Decode, preserve title/category/transaction data, default to Income Allocation, and round-trip into the supported schema. |
| Legacy file without a schema-version field | Continue through the existing migration path, then initialize new metadata defaults. |
| Concurrent title edit and spending-limit edit | Preserve both edits. |
| Concurrent date-range edits | Select one complete valid range deterministically; never combine start and end from different edits. |
| Clearing previously saved metadata | Clearing survives a merge and reopening. |
| Zero amounts, day trip, no catering | Produce valid zero estimates; no invented amounts or division errors. |
| Maximum counts or amounts that overflow | Return a field-relevant validation error before creating a file. |
| Actual costs exceed the cap or actual revenue is below costs | Show a negative signed result rather than reject the budget. |
| Preview followed by save | Saved planned amounts match the preview; all categories have initialized CRDT state. |
| Cancel file selection, retry after failure, or Android recreation | Preserve the creation draft and avoid duplicate budgets/recent entries. |
| Open the same created file on another supported platform | Preserve mode, limit, dates, and monetary values. Display currency according to the explicitly documented current app-setting behavior. |

Review P1 with a weekly-budget user, a freelancer, someone planning an event, and a traveler. Check whether travel categories are useful despite the current reporting limitation. Review the P2 travel upgrade with both a solo traveler and a group organizer. Ask whether the categories cover the scenario, whether setup saves arithmetic, and whether the preview makes missing estimates clear. Collect feedback voluntarily; no telemetry system is required.

## P3 — Broaden the catalog after validating demand

Add the remaining preset families based on template selection and category-edit usage:

- **Personal:** Student, Household, Annual Personal, Debt Payoff, Savings Goal.
- **Travel and lifestyle:** Weekend Getaway, Moving, Holiday Shopping, New Baby, Car Ownership, Car Purchase.
- **Business and creators:** Annual Business, Content Creator, Indie App Developer, Subscription Audit.
- **Events and community:** Birthday Party, Conference, Fundraising Event, Community Project, Nonprofit.

Choose P3 additions according to how much they differ from an existing preset:

| Candidate | Default mode | Useful distinction |
| --- | --- | --- |
| Student | Income Allocation | Grants, part-time income, tuition, textbooks, rent, and term-related costs. |
| Household | Income Allocation | Multiple income categories and shared housing, childcare, utilities, and household savings. |
| Content Creator | Revenue & Cost | Sponsorships, advertising revenue, platform fees, production, editing, and equipment reserves. |
| Indie App Developer | Revenue & Cost | App/subscription revenue, store fees, hosting, developer tools, testing devices, and marketing. |
| Fundraising / Nonprofit | Revenue & Cost | Donations and sponsorships separated from fundraising and program costs; no claim of fund accounting. |
| Moving | Spending Limit | Movers, deposit, setup fees, furniture, utility connections, and transport. A deposit is a cash outlay in this budget, not an accounting expense claim. |
| Annual Personal / Annual Business | Respective personal/business mode | An annual date range and appropriate categories; no automatic monthly multiplication of arbitrary amounts. |

Weekend Getaway can initially use Vacation, Conference can use Event Planning, and Birthday Party can use a Spending Limit event preset. Add separate entries when their default categories materially reduce setup work. Debt Payoff and Savings Goal may start as category presets; payoff schedules and time-to-goal projections need additional state and calculations and should be scoped separately.

Consider user-created reusable templates, improvements to the existing previous-budget reuse flow, foreign currency, and persistent event break-even assumptions after the built-in catalog and core modes are established. These require separate UX and data-model decisions; they are not prerequisites for the first presets or wizards.

## Completion criteria

- P1 templates are available from all supported GUI budget-creation flows and produce the same categories from the shared core.
- Existing schema-v2 `.budget` files continue to open and save with Income Allocation behavior and retain their existing data.
- Each reporting mode has a defined core calculation, planned/actual revenue are distinguished, and dates do not silently exclude transactions from totals.
- Wizard inputs are limited to high-impact values, calculations are identical on every platform, and created amounts can be edited normally.
- Template descriptions distinguish category presets from period-aware reporting and cash planning from accounting.
