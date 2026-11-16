# Wasatch Board Co. ERP

School project (GSCM 401): a working mini-ERP for a fictional Utah skateboard company, demoed live on Dec 2, 2026. The team must be able to explain every part, so favour simple, readable code and plain-language explanations over cleverness.

- [SPEC.md](SPEC.md) — all 12 required capabilities, seed data, formulas. The source of truth for requirements.
- [PLAN.md](PLAN.md) — approved table design, transaction flows, screens, build order and status. Update the status table as steps finish.

## Where things stand (updated 2026-11-16)

- **Live site:** https://masburd.github.io/wasatch-board-erp/ — GitHub repo `masburd/wasatch-board-erp` (public), Pages serves `main` / root.
- **Supabase project URL** and publishable key are in `js/config.js`.
- **Steps 1–4 done and live:** login, navigation, dashboard, Items & BOMs, Inventory, Suppliers, Purchasing, About.
- **Step 5 (POS) written but not finished:** `pos.html`, `sql/07`, camera-scan buttons on Inventory and Purchasing exist locally, uncommitted and unpushed. The first thing to do is in PLAN.md → "Open issues / to-do".
- **Next to build:** step 6, sales orders, returns and exchanges.

### SQL files and whether they have been run in Supabase

| Order | File | Run? |
| --- | --- | --- |
| 1 | `sql/01_master_schema.sql` | Yes |
| 2 | `sql/02_master_seed.sql` | Yes |
| 3 | `sql/03_make_me_staff.sql` | Yes, for Mason's login (run again per teammate, with their email, in the SQL Editor only) |
| 4 | `sql/04_inventory.sql` | Yes |
| 5 | `sql/05_starter_stock_TEMPORARY.sql` | Yes |
| 6 | `sql/06_purchasing.sql` | Yes |
| 7 | `sql/07_sales_pos.sql` | **Not yet** — ask the user |

Keep this table current whenever a SQL file is added or the user confirms a run.

### Decisions made while building (beyond PLAN.md's numbered list)

- `items.standard_cost` = supplier's quoted price (default PO price). `avg_cost` starts equal to it and the browser has no permission to write `avg_cost`.
- `wbc_post_movement()` is the only code that inserts into the ledger and re-averages cost. All later transaction functions must call it. It is not callable from the browser.
- Stock can never go negative: the trigger on `inventory_movements` refuses the transaction. Sales with no stock become backorders instead.
- Ledger rows cannot be updated or deleted (trigger). Corrections are new rows.
- Transfers are immediate (no in-transit state).
- Return reason "Damaged in transit" is set to not restock, like "Defective".
- Review interval defaults to 30 days per item.
- Master data is staff-only for now; customer-facing read access is added with the portal (step 11), using views that hide cost.
- `sql/05` starter stock is temporary; step 8 replaces it.
- PO statuses: draft → sent ("Order Sent") → received → closed, or cancelled. A PO becomes received when every line is complete or the user ticks "close short"; marking it paid closes it. A PO has no location; the location is chosen on each receipt.
- Business dates use Mountain time via `wbc_today()`. Backdated receipts post their ledger row at noon on that date.
- `po_summary` and `po_line_status` views carry fill rate, days late, actual lead time, payment due date and amount owed. The step 9 scorecard and MRP (open PO quantity = `qty_open`) should build on them, not recompute.
- Screens that take dates (sent, received, paid) let the user backdate, so late deliveries can be demonstrated.
- `sales_orders` + `sales_order_lines` hold every sale; a POS sale is inserted already `closed` with `qty_fulfilled = qty`. Step 6 sales orders reuse the same tables with status `placed` → `fulfilled` → `closed`.
- One order-level `discount_pct`; `tax_rate` is copied onto the order from settings. Prices and costs are read server-side in `post_pos_sale`, never trusted from the browser.
- Money views: `sales_line_totals` (line_gross, line_net, revenue, cogs) and `sales_order_totals` (gross, discount_amount, net, tax, total, revenue, cogs). Revenue and COGS count fulfilled units only; tax is not revenue. P&L, returns and reports should build on these.
- Camera scanning is `WBC.cameraScan(onCode)` in `js/app.js` (lazy-loads html5-qrcode from unpkg). Any new scan box should get both `WBC.scanBox` and a "Use camera" button.

### How the user works

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
