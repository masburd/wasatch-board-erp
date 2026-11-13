# Wasatch Board Co. ERP

School project (GSCM 401): a working mini-ERP for a fictional Utah skateboard company, demoed live on Dec 2, 2026. The team must be able to explain every part, so favour simple, readable code and plain-language explanations over cleverness.

- [SPEC.md](SPEC.md) — all 12 required capabilities, seed data, formulas. The source of truth for requirements.
- [PLAN.md](PLAN.md) — approved table design, transaction flows, screens, build order and status. Update the status table as steps finish.

## Stack

- Plain HTML + JavaScript, **no build step, no npm, no framework**. Supabase JS is loaded from a CDN.
- Supabase: Postgres database, auth (email + password), realtime.
- Hosted on GitHub Pages from a public repo, so everything in the repo is public.
- The machine has no Node, Postgres or Docker. SQL cannot be run locally: the user pastes files from `sql/` into the Supabase SQL Editor. Preview pages with `python3 -m http.server`.

## Layout

- `index.html` — login. Other pages sit beside it at the top level (`dashboard.html`, `items.html`, `about.html`, …).
- `js/config.js` — Supabase URL and publishable (anon) key. `js/app.js` — client, login guard, navigation, helpers shared by every page.
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
