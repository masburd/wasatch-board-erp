# Wasatch Board Co. ERP

School project (GSCM 401): a working mini-ERP for a fictional Utah skateboard company, demoed live on Dec 2, 2026. The team must be able to explain every part, so favour simple, readable code and plain-language explanations over cleverness.

- [SPEC.md](SPEC.md) — all 12 required capabilities, seed data, formulas. The source of truth for requirements.
- [PLAN.md](PLAN.md) — approved table design, transaction flows, screens, build order and status. Update the status table as steps finish.

## Where things stand (updated 2026-11-16, session 4)

- **Live site:** https://masburd.github.io/wasatch-board-erp/ — GitHub repo `masburd/wasatch-board-erp` (public), Pages serves `main` / root.
- **Supabase project URL** and publishable key are in `js/config.js`.
- **Steps 1–7 done and live:** login, navigation, dashboard, Items & BOMs, Inventory, Suppliers, Purchasing, Point of Sale, About.
- **Step 5 (POS) done and live:** test sale confirmed. On 2026-11-17 the user confirmed the phone camera opens and that printed labels scan.
- **Step 6 (sales orders, returns, exchanges) pushed and live.** `sql/08` is in the database (checked from the live site on 2026-11-16: `returns`, `return_lines` and `open_order_lines` all answer). Mason thinks he ran the two tests but was not sure; the expected numbers are in PLAN.md → "Open issues / to-do" if anything looks off.
- All code through step 11 is committed and pushed (user pushed 2026-11-17).
- Time pressure: demo is Dec 2. Remaining: step 7 production, 8 history generator, 9 planning (ROP, EOQ, review, MRP, scorecard), 10 financials and reports, 11 customer portal and configurator, 12 labels and rehearsal. The user has a usage limit per session, so keep each session to one or two steps and update these notes before stopping.
- **Step 7 (production orders and metrics) done and live:** `sql/09` run, test confirmed by the user on 2026-11-16.
- **Step 8 (history generator) done:** `sql/10_history.sql` run and confirmed by the user on 2026-11-16. Re-running it erases and rebuilds all transactions.
- **Step 9 (planning) done and live:** `sql/11` run, confirmed by the user on 2026-11-16.
- **Step 10 (financials and reports) done and live:** `sql/12` run, confirmed by the user on 2026-11-16.
- **Weekly MRP (SPEC capability 8) done and live:** `sql/13` run, confirmed by the user on 2026-11-16.
- **Step 11 (customer portal and Build Your Own Board) live:** `sql/11` and `sql/13` re-run, `sql/14` run, "Confirm email" turned off in Supabase Auth, and everything pushed (user confirmed 2026-11-17). The step 11 test is still waiting for the team test session.
- **Step 12 done:** user confirmed on 2026-11-17 that a printed label scans (scanner type not stated). Built: `labels.html` (printable Code 128 labels, Avery 5160 size, plus a "Test a label" scan box), `about.html` rewritten as a guide to every requirement and formula, `DEMO.md` (the demo script and day-before checklist) and `TESTING.md` (full test script). Movement history has a newest/oldest-first switch so the opening balances can be shown. No SQL. All coding steps in PLAN.md are now built; what is left is the team test session, the printed-label scan test, and rehearsing `DEMO.md`.

### SQL files and whether they have been run in Supabase

| Order | File | Run? |
| --- | --- | --- |
| 1 | `sql/01_master_schema.sql` | Yes |
| 2 | `sql/02_master_seed.sql` | Yes |
| 3 | `sql/03_make_me_staff.sql` | Yes, for Mason's login (run again per teammate, with their email, in the SQL Editor only) |
| 4 | `sql/04_inventory.sql` | Yes |
| 5 | `sql/05_starter_stock_TEMPORARY.sql` | Yes |
| 6 | `sql/06_purchasing.sql` | Yes |
| 7 | `sql/07_sales_pos.sql` | Yes |
| 8 | `sql/08_sales_orders_returns.sql` | Yes (tables and view confirmed present 2026-11-16) |
| 9 | `sql/09_production.sql` | Yes |
| 10 | `sql/10_history.sql` | Yes. Erases and rebuilds all transactions each time it is run. |
| 11 | `sql/11_planning.sql` | Yes (re-run after the step 11 edit) |
| 12 | `sql/12_financials_reports.sql` | Yes |
| 13 | `sql/13_mrp_weekly.sql` | Yes (re-run after the step 11 edit) |
| 14 | `sql/14_portal.sql` | Yes |
| 15 | `sql/15_test_checklist.sql` | Yes (the checklist saves results) |
| 16 | `sql/16_test_history.sql` | Yes (user saw history on 2026-11-25) |
| 17 | `sql/17_test_history_simple.sql` | **Not yet** — replaces the history trigger and tidies old lines |
| 18 | `sql/18_financials_speed.sql` | Yes (2026-11-25; Financials loads now). pnl and inventory_turnover are security definer with a staff check inside |

Keep this table current whenever a SQL file is added or the user confirms a run.

### Decisions made while building (beyond PLAN.md's numbered list)

- `items.standard_cost` = supplier's quoted price (default PO price). `avg_cost` starts equal to it and the browser has no permission to write `avg_cost`.
- `wbc_post_movement()` is the only code that inserts into the ledger and re-averages cost. All later transaction functions must call it. It is not callable from the browser.
- Stock can never go negative: the trigger on `inventory_movements` refuses the transaction. Sales with no stock become backorders instead.
- Ledger rows cannot be updated or deleted (trigger). Corrections are new rows.
- Transfers are immediate (no in-transit state).
- Return reason "Damaged in transit" is set to not restock, like "Defective".
- Review interval defaults to 30 days per item.
- Master data is staff-only. Customers never read tables directly (except `inventory_levels`, which any signed-in user may read so stock is live): the portal uses `security definer` functions named `portal_*` that return no cost columns and only the caller's own orders.
- Plan agreed 2026-11-21: test on the current data, then re-run `sql/10_history.sql` on the evening of Dec 1 so the history reaches Nov 30 and test transactions are gone. It does not touch `test_results`, customers or logins.
- `sql/05` starter stock is temporary; `sql/10` erases it and posts real opening balances.
- PO statuses: draft → sent ("Order Sent") → received → closed, or cancelled. A PO becomes received when every line is complete or the user ticks "close short"; marking it paid closes it. A PO has no location; the location is chosen on each receipt.
- Business dates use Mountain time via `wbc_today()`. Backdated receipts post their ledger row at noon on that date.
- `po_summary` and `po_line_status` views carry fill rate, days late, actual lead time, payment due date and amount owed. The step 9 scorecard and MRP (open PO quantity = `qty_open`) should build on them, not recompute.
- Screens that take dates (sent, received, paid) let the user backdate, so late deliveries can be demonstrated.
- `sales_orders` + `sales_order_lines` hold every sale; a POS sale is inserted already `closed` with `qty_fulfilled = qty`. Step 6 sales orders reuse the same tables with status `placed` → `fulfilled` → `closed`.
- One order-level `discount_pct`; `tax_rate` is copied onto the order from settings. Prices and costs are read server-side in `post_pos_sale`, never trusted from the browser.
- Money views: `sales_line_totals` (line_gross, line_net, revenue, cogs) and `sales_order_totals` (gross, discount_amount, net, tax, total, revenue, cogs). Revenue and COGS count fulfilled units only; tax is not revenue. P&L, returns and reports should build on these.
- Sales orders: `create_sales_order` (placed, no stock movement) → `fulfill_sales_order` (ships min(open, on hand at the order's location); partial leaves the order placed) → `close_sales_order`. `cancel_sales_order` cancels, or trims unshipped lines if partly shipped. Stock is not reserved.
- Backorders are not a table: view `open_order_lines` lists every waiting line with `availability` (ready / transfer / on_order / reorder / build) and `est_available_date`. A backorder is any row that is not `ready`. MRP (step 9) should take confirmed demand from placed orders via this view or the same tables.
- Returns: `post_return` handles refund and exchange. Reason codes with `restock = false` put nothing back in stock; views `return_line_totals` / `return_totals` give `refund_net`, `cogs_reversed` and `write_off`. For the P&L: net sales = revenue − refund_net; COGS = cogs − cogs_reversed; write_off goes on the scrap/adjustments line. An exchange's replacement is a new till sale made by calling `post_pos_sale` inside `post_return`.
- Production orders: `create_production_order` (planned, always at the warehouse) → `issue_production_order` (copies BOM × qty into `production_order_components` at current average cost, posts `production_issue` rows) → `complete_production_order` (takes a list of scrap/rework events; good = started − scrapped is computed, never typed; receives good boards at component cost ÷ boards started with re-averaging). `cancel_production_order` only before issue. Order numbers show as `MO-00001` (`WBC.moNumber`).
- Scrap cost is not a ledger row: the parts left stock at issue and only good boards come back. `production_order_summary` gives `component_cost`, `unit_cost`, `good_value`, `scrap_cost`, `final_yield`, `first_pass_yield`, `build_hours`, `finished_date` (Mountain). The P&L scrap line should sum `scrap_cost`.
- Date-range reports are SQL functions, not views: `production_report(p_from, p_to)` (one row of totals) and `production_scrap_report(p_from, p_to)` (by reason). Later reports with a date range should follow this pattern.
- Open production quantity for MRP = `qty_started` on orders that are `planned` or `in_progress`.
- `production_orders.sales_order_line_id` and `destination_location_id` exist but are unused until custom builds (step 11). `issue_production_order` uses component rows that already exist instead of the BOM, so a custom build can arrive with its own list.
- History generator: `wbc_generate_history(seed)` (SQL Editor only) truncates all transaction tables, resets `avg_cost` to `standard_cost`, posts opening balances dated 2025-11-16, then replays each day: PO receipts, returns, monthly count adjustments, production, business sales orders, store restock transfers (Mon/Thu), purchasing, till sales. It inserts document rows directly and calls `wbc_post_movement` for every stock change (it cannot use the browser functions because they need a staff login). It ends with one planned production order and two placed sales orders (one a backorder) so the screens have open work.
- The generator's demand model (base rates, seasonal factors, events, supplier behaviour) lives only inside `sql/10`. Step 9 must compute usage, ROP, EOQ and the scorecard from the stored transactions, never from that model.
- PO prices in history drift −3% to +5% around `standard_cost`, so `avg_cost` differs from `standard_cost` after the history is built.
- Planning is all views and functions, no new tables. `item_usage_stats` (d, σ, daily sales, annual usage from `sale` + `production_issue` ledger rows over the `usage_window_days` setting) → `item_planning` (on hand, on order, safety stock, reorder point, EOQ, `needs_reorder`, `review_due`). A board's lead time is treated as 1 day and its "on order" is open production.
- MRP is two functions with a horizon in days: `mrp_parents(p_days)` (forecast + open sales orders − on hand − open production) and `mrp_components(p_days)` (net boards × BOM + parts for planned jobs + part sales forecast + open orders − on hand − open PO quantity). Single bucket, no safety stock, no time phasing. Draft POs do not count as on order until sent.
- `mrp_weekly(p_weeks)` is the time-phased plan (week 1 starts today, 7-day weeks, lot-for-lot, no safety stock). Boards are netted first; each week's net boards × BOM becomes that week's dependent demand for parts. Sales orders land in the week of `requested_date`, sent POs in the week of `expected_date`, open production orders in week 1. Net per week comes from a running maximum of (cumulative gross − on hand − cumulative scheduled). `order_by_date` = week start − lead time, never before today; `overdue` marks parts that cannot arrive in time. The weekly tab is read-only: ordering is done on the "Order now" tab.
- `supplier_scorecard` view: score = 40% on-time rate + 40% fill score (1 − 4 × shortfall) + 20% lead-time score; A = Keep, B/C = Watch, D/F = Replace. The weights are in the view, not in settings.
- Two settings were added: `usage_window_days` (90) and `mrp_horizon_days` (30). Settings are edited on `settings.html` with a direct table update (staff only).
- "Mark reviewed" is a direct update of `items.last_reviewed_at` from the page. The history generator leaves every item "never reviewed".
- `WBC.createDraftPOs(lines)` makes one draft PO per supplier; used by Due for Review and MRP.
- Financials and reports add no tables. `sales_facts` view (one row per fulfilled sales line with Mountain `sale_date`) feeds `report_sales(from, to, grain)`, `report_sales_by_location(from, to)` and `report_top_sellers(from, to, limit)`.
- `pnl(from, to, 'total' | 'month')` is the P&L: revenue − refunds = net sales; − (COGS sold − COGS returned) = gross profit; − production scrap − return write-offs − stock adjustments = profit. Sales count on the hand-over date (`fulfilled_at`, else `order_date`). Tax collected is shown but is not revenue. There are no operating expenses in the system.
- `inventory_turnover(from, to)` = COGS ÷ the average of each day's closing stock value, where a day's value is the running sum of ledger `qty_change × unit_cost`. That ledger value can differ from `inventory_value` (qty × current average cost) by a few dollars of rounding, so the page shows only the average.
- Valuation uses `inventory_value_detail` and `inventory_value_by_location`. `low_stock_report` adds `order_by_date` (the day stock + on order reaches the reorder point) to `item_planning`.
- Portal flow: `signup.html` creates the login (trigger gives it a `customer` profile) → `portal.html` asks for name and home store → `portal_register` creates a `customers` row (`P-001`…) linked by `auth_user_id`. Sign-ups are never linked to the seeded customers, because an unconfirmed email proves nothing. `index.html` sends staff to the dashboard and everyone else to the portal.
- `portal_setup()` returns tax rate, assembly fee, locations, sellable items with prices, and the build rules in one JSON answer. `portal_place_order` creates a `portal` sales order as `placed` (no stock moves; staff fulfil it on Sales Orders). `portal_my_orders` and `portal_cancel_order` cover the customer's own orders.
- Custom build: `portal_place_custom_order` checks each choice against `build_options`, adds `build_auto_adds`, prices it at parts + `assembly_fee`, creates a sales order line for `WBC-3000` and a planned production order (qty 1) with its own component rows, `sales_order_line_id` and `destination_location_id` = pickup store. Staff issue and complete it on Production; completion receives the board at the store; staff then fulfil the sales order there.
- `planned_job_parts` view (in `sql/11`) gives the parts planned production orders will take: component rows if the order has them (custom), otherwise BOM × quantity. Both MRP functions use it, so custom builds count as direct component demand.
- The portal cart lives in the browser's localStorage until the order is placed. Customers get realtime only on `inventory_levels`; "My orders" refreshes on open, on the Refresh button and when stock changes.
- Timestamps are shown with `WBC.dateOf` (viewer's time zone); plain dates with `WBC.date`.
- Parts are added and retired on Items & BOMs ("Add part", supplier choice and an Active tick box in Edit), by direct insert/update on `items` (staff policy + column grants). New parts get `barcode = sku`; avg_cost is set by the insert trigger. Adding complete boards or BOM lines is not built. Retiring sets `is_active = false` (the Items list still shows them greyed). "Delete item" in Edit works only for an item with no history: every transaction table references `items` without cascade, so Postgres refuses (23503) and the page tells the user to retire it instead.
- Labels use JsBarcode 3.11.6 from jsdelivr, Code 128 of `items.barcode` (= SKU). The About page reads the formula numbers from `settings`, so keep its `data-setting` spans in step with setting keys.
- Camera scanning is `WBC.cameraScan(onCode)` in `js/app.js` (lazy-loads html5-qrcode from unpkg). Any new scan box should get both `WBC.scanBox` and a "Use camera" button.

### How the user works

- Test checklist history (`sql/16` + `sql/17`): one line per result in `test_result_history`, written only by a trigger on `test_results`. A different result adds a line; the same result clicked again with a new note replaces the latest line's note; Clear deletes the result and all its lines (start over). Notes are saved only by the Pass/Fail buttons (no auto-save on typing or leaving the box); the note box is blank after each click. Fail needs a note.
- Fixes from the first test batch (2026-11-25): POS shows "After discount" and today's list has before-tax and with-tax columns; Dashboard card says "Sales today (before tax)"; Sales Orders shows "Ready to fulfil / Partly ready / Waiting for stock" under Order Placed (from `open_order_lines`); Due for Review shows EOQ to 1 decimal (order qty = EOQ rounded up), "OK — on order covers it", and creating draft POs (there or on MRP) opens Purchasing via `WBC.openDraftPOs` (`purchasing.html?po=ID` or `?status=draft`); Settings shows "Service level z-score" with the service % computed from z; Financials shows average cost to 4 decimals and errors in the P&L table. Financials stuck on "Loading…" was assumed to be the 8-second request timeout caused by row-level security checks on every row; `sql/18` fixed it (confirmed 2026-11-25). If another report page times out, use the same pattern.
- `TESTING.md` is the team's full test script (sections A–P). `tests.html` (System → Test checklist) reads it from the site and stores Pass/Fail/notes in the `test_results` table (`sql/15`), shared and realtime. Test lines must keep the form `- [ ] **X1.** …` (optionally `**X1. Title.**`) and sections `## X. Title`, or the page will not see them. Keep it current when a page or rule changes; failures will come back from it by section number (for example "H5 failed").
- From step 7 on, Mason runs the SQL files as each step is built but leaves the "Try it" tests for one combined session with teammates at the end. Keep every step's test in PLAN.md → "Open issues / to-do" until he reports it done; do not delete them when a step's SQL is confirmed.
- Working rhythm that has gone well: build one step, test page logic locally with a fake database, hand over numbered Supabase/GitHub steps plus a "Try it" test with expected numbers, wait for "works" before the next step, then update PLAN.md and CLAUDE.md.
- Teammate logins: Mason ran his own query in the Supabase SQL Editor (not saved in this repo) to give all teammates a login. He confirmed they can sign in and are marked `staff`.
- Mason is new to Supabase, git and GitHub. He publishes with **GitHub Desktop** (commit, then Push origin); the command line here has no GitHub login, so `git push` fails. Do not ask him to use terminal git.
- Commits made here use the repo-local noreply email. Do not put real email addresses in any file: the repo is public.
- Browser pages cannot be tested against the real database from here. Test page logic with a throwaway copy plus a fake `supabase` object in the scratchpad, served with `python3 -m http.server` run from Bash (the preview launcher fails on this machine), and say clearly that SQL is unverified until the user runs it.

## Stack

- Plain HTML + JavaScript, **no build step, no npm, no framework**. Supabase JS is loaded from a CDN.
- Supabase: Postgres database, auth (email + password), realtime.
- Hosted on GitHub Pages from a public repo, so everything in the repo is public.
- The machine has no Node, Postgres or Docker. SQL cannot be run locally: the user pastes files from `sql/` into the Supabase SQL Editor. Preview pages with `python3 -m http.server`.

## Layout

- `index.html` — login. Other pages sit beside it at the top level (`dashboard.html`, `items.html`, `inventory.html`, `about.html`, …).
- `js/config.js` — Supabase URL and publishable (anon) key. `js/app.js` — client, login guard (`WBC.initPage`), navigation (`NAV`; set `built: true` when a page exists), scan-box helpers (`WBC.scanBox`, `WBC.findByCode`), formatting helpers.
- `css/style.css` — one stylesheet.
- `sql/NN_name.sql` — numbered, run in order, safe to re-run. Never edit a file the user has already run without telling them what to re-run.

## Design rules (do not break these)

1. **The ledger is the truth.** Every stock change is a row in `inventory_movements`. `inventory_levels` is only a running total kept by a trigger. On-hand must always equal the sum of the ledger, including seeded history (which starts from opening-balance movements).
2. **Everything displayed is computed.** No totals, costs, statuses-by-date or metrics are typed in or hard-coded. Use views or queries over stored transactions. The professor will change an input in the demo and expect results to update.
3. **Weighted average cost, company-wide per item.** `items.avg_cost` is re-averaged on each receipt (PO receipt, production completion, restocked return) and is never editable from the browser. A complete's cost is rolled up from components, never entered.
4. **Transactions are database functions.** Anything that touches more than one table (sale, receipt, issue, completion, return, transfer) is one Postgres function called with `supabase.rpc()`, so it is all-or-nothing. Pages do not write multi-table transactions themselves.
5. **Row Level Security on every table.** The publishable key is public. Staff access goes through `is_staff()`; customers see only their own rows. Never put the `service_role` / secret key in the repo or in browser code.
6. **Realtime** on `inventory_levels`, `sales_orders`, `purchase_orders`, `production_orders` (plus `items`, `bom_lines`).
7. Selling a complete takes a finished board from stock (backorder if none). Custom builds use generic SKU `WBC-3000` with per-build cost.
8. No general ledger: P&L is derived from sales, returns, production and adjustment records.
9. Barcode input: a focused scan box that accepts keyboard input + Enter (USB scanner); phone camera is the backup.
10. Production orders only at the warehouse. Reworked units count as good but are tracked separately (first-pass yield).

## Working with the user

- Explain what each new table or function does in plain language as it is added.
- Give Supabase / GitHub instructions one action per step.
