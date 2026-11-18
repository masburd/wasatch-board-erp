# Wasatch Board Co. ERP — Build Plan

Approved 2026-11-13. Requirements live in [SPEC.md](SPEC.md); this file is how we build them. Demo: Dec 2.

## The core idea

Every physical event (sale, receipt, transfer, build, return, count adjustment) writes a row to one **inventory ledger** (`inventory_movements`). On-hand quantity, inventory value, COGS, usage history, reorder points and MRP are all calculated from that ledger and the documents behind it. Nothing a screen displays is typed in as a total.

Each multi-step transaction (for example "complete sale") runs as a single database function in Supabase, so it either fully happens or does not happen at all. The HTML pages only display data and call those functions.

## Approved design decisions

1. **Weighted average cost is company-wide per item**, not per location. Transfers do not change cost.
2. **Selling a complete board takes a finished board from stock.** Its components were consumed when it was built. If none are on hand the line becomes a backorder.
3. **Custom boards use one generic SKU (`WBC-3000`)** that carries each build's own cost, so they do not distort the average cost of standard boards.
4. **No full accounting ledger.** The P&L is calculated from sales, returns, production and adjustment records. Customer payments are not tracked beyond the sale total.
5. **Periodic manual review.** Each item has `review_interval_days` and `last_reviewed_at`. A "Due for review" screen lists items whose review date has passed; the manager either creates a PO or marks the item reviewed.
6. **Barcodes: USB scanner first.** A scanner types the code into a focused scan box and presses Enter. Phone-camera scanning is the backup.
7. **MRP nets at two levels.** Parent demand minus finished-board stock minus open production orders, then explode what is left through the BOM, then subtract component on-hand and open POs.
8. **Rework is tracked separately.** Reworked units count as good once fixed. First-pass yield = (good − reworked) ÷ started; final yield = good ÷ started.
9. **History goes through the ledger.** The 12-month history generator starts with opening-balance movements and writes every event to `inventory_movements`, so on-hand always equals the sum of the ledger.
10. **Realtime on the key tables**: `inventory_levels`, `sales_orders`, `purchase_orders`, `production_orders` (plus `items` and `bom_lines` for the Items page).

## 1. Database tables

### Master data (set up once)

| Table | Key columns | Purpose |
| --- | --- | --- |
| `locations` | code, name, type (warehouse / store) | The 3 places stock can be. |
| `suppliers` | name, contact, email, phone, quoted_lead_time_days, payment_terms_days | Who we buy from and what they promised. |
| `items` | sku, barcode, name, type (part / complete / custom), category, supplier_id, lead_time_days, price, standard_cost, avg_cost, review_interval_days, last_reviewed_at | All SKUs. `standard_cost` is the supplier's quoted price, used as the default price on a new PO. `avg_cost` is the weighted average cost, maintained by the system and not editable. |
| `bom_lines` | parent_item_id, component_item_id, qty | The recipe: one row per component of each complete board. |
| `customers` | name, type (individual / business / walk-in), email, home_location_id, auth_user_id | Who we sell to; links a portal login to a customer. |
| `profiles` | id (the login), role (staff / customer), default_location_id | What each login is allowed to do. |
| `settings` | key, value | Ordering cost, holding rate, service level z, tax rate, assembly fee. Editable. |
| `reason_codes` | code, label, kind (adjustment / return / scrap), restock | Why something happened. `restock = false` keeps bad returns out of sellable stock. |
| `build_options` | deck_item_id, slot, item_id | Configurator rules: which parts are allowed with each deck. |
| `build_auto_adds` | deck_item_id, wheel_item_id, item_id | Parts added automatically for a deck + wheel combination. |

View `item_costs`: current cost of every item. A part's cost is its `avg_cost`; a complete's cost is rolled up from its BOM.

### Inventory

| Table | Key columns | Purpose |
| --- | --- | --- |
| `inventory_movements` | occurred_at, item_id, location_id, qty_change (+/−), unit_cost, type, reason_code, source document, user_id | The ledger. Rows are only added, never edited. |
| `inventory_levels` | item_id, location_id, qty_on_hand | Running total per item per location, updated by a database trigger whenever a ledger row is added. |
| `transfers` + `transfer_lines` | from_location, to_location, date; item, qty | Transfer paperwork. Posting writes a minus row and a plus row to the ledger. |

### Selling

| Table | Key columns | Purpose |
| --- | --- | --- |
| `sales_orders` | order_number, customer_id, location_id, channel (POS / sales order / portal), status, order_date, requested_date, fulfilled_at, discount, tax_rate | One table for all sales. A POS sale is a sales order placed, fulfilled and closed in one step. |
| `sales_order_lines` | order_id, item_id, qty, qty_fulfilled, unit_price, unit_cost | What was sold. `unit_cost` is copied from `avg_cost` at fulfillment, which fixes that line's COGS. |
| `returns` | original_order_id, location_id, date, type (refund / exchange), exchange_order_id | Return header, linked to the original sale and to the replacement sale for an exchange. |
| `return_lines` | return_id, sales_order_line_id, qty, reason_code, restocked | What came back and why. |

### Buying

| Table | Key columns | Purpose |
| --- | --- | --- |
| `purchase_orders` | supplier_id, status, sent_date, expected_date, paid_at | `expected_date` = sent date + supplier lead time. |
| `purchase_order_lines` | po_id, item_id, qty_ordered, unit_cost | What we asked for. |
| `po_receipts` + `po_receipt_lines` | po_id, location_id, received_date; po_line_id, qty_received | What actually arrived and when. |

### Making

| Table | Key columns | Purpose |
| --- | --- | --- |
| `production_orders` | item_id, location_id, status, qty_started, qty_good, qty_scrapped, qty_reworked, started_at, finished_at, sales_order_line_id, destination_location_id | A job to assemble boards. `qty_good` includes reworked units. The last two columns are for custom builds. |
| `production_order_components` | production_order_id, item_id, qty_issued, unit_cost | The parts actually consumed (BOM copy, or the one-time list for a custom build). |
| `production_scrap` | production_order_id, qty, reason_code, disposition (scrap / rework) | Quality events, used for scrap rate by reason. |

### Calculated, not stored

Backorders, estimated available date, reorder point, EOQ, items due for review, MRP, supplier scorecard, P&L, valuation, turnover and production metrics are database views over the tables above.

## 2. Transaction flows

**POS sale**
1. Cashier scans a barcode into the scan box; the page looks it up in `items` and adds a cart line.
2. "Complete sale" creates a `sales_orders` row (channel POS, status Closed) and its lines, copying each item's `avg_cost` into `unit_cost`.
3. One negative ledger row per line at that store; `inventory_levels` drops.
4. Revenue = qty × price − discount. COGS = qty × `unit_cost`. Tax is collected but is not revenue.
5. Realtime pushes the change to every open screen; the receipt prints from the order rows.

**Production order (warehouse only)**
1. Create: complete + quantity. Status Planned; nothing moves.
2. Issue: BOM × quantity is copied into `production_order_components`; negative ledger rows remove parts; `started_at` stamped.
3. Complete: enter good, scrapped and reworked quantities with reason codes. A positive ledger row receives the good boards at the cost of the components consumed; the board's `avg_cost` is re-averaged.
4. Component cost of scrapped units goes to scrap expense; `finished_at` stamped.
5. Metrics: final yield, first-pass yield, scrap rate by reason, average build time.

**Purchase order receipt**
1. Create the PO (usually from a reorder, review or MRP suggestion). Marking it Sent sets `expected_date`.
2. Receive: date, location, quantities → `po_receipts` rows.
3. Positive ledger rows at the PO unit cost; `avg_cost` = (old qty × old avg + received qty × PO cost) ÷ new qty.
4. Status Received; payment due = receipt date + terms. Marking paid sets Closed.
5. Scorecard: received vs. expected date (on-time), received vs. ordered (fill rate), unpaid POs (owed).

**Customer return**
1. Find the original sale; pick lines, quantities and a reason code.
2. `returns` + `return_lines` created; refund at the original price, so net sales fall.
3. Restockable reason: positive ledger row at the store at original cost; COGS reversed.
4. Not restockable (defective): nothing returns to stock; the cost shows as a quality loss on the P&L.
5. Exchange: the return is linked to a new sale for the replacement.

**MRP (weekly, next 4 weeks)**
1. Parent demand per week from confirmed sales orders (`requested_date`).
2. Subtract finished-board on-hand and open production orders → net parent requirement.
3. Explode the net requirement through the BOM; add custom-build component demand directly.
4. Subtract component on-hand and open PO quantities → suggested order quantity.
5. Order-by date = requirement date − component lead time.

## 3. Screens

**Staff app:** Login · Dashboard · POS · Sales Orders · Returns & Exchanges · Inventory (on-hand, transfers, adjustments, scan, history) · Items & BOMs · Purchasing (suggestions, POs, receiving) · Due for Review · Suppliers (CRUD + scorecard) · Production (orders + report) · MRP · Financials · Reports · Settings · About this system

**Customer portal:** Login / sign-up · Catalog with availability by store · Build Your Own Board · Cart and pickup checkout · My Orders

## 4. Build order

| # | Step | Status |
| --- | --- | --- |
| 1 | Setup: Supabase project, GitHub Pages, login, shared navigation | **Done** — live at https://masburd.github.io/wasatch-board-erp/, staff sign-in confirmed |
| 2 | Master data: tables, seed, Items & BOMs page | **Done** — `sql/01`–`03` run in Supabase, pushed to GitHub |
| 3 | Inventory core: ledger, levels, adjustments, transfers, realtime | **Done** — `sql/04`–`05` run in Supabase, live, cycle count confirmed working |
| 4 | Purchasing: suppliers, POs, receiving, weighted average cost | **Done** — `sql/06` run in Supabase, live, PO receipt and re-averaging confirmed working |
| 5 | POS: barcode scanning and receipt | **Done** — `sql/07` run, live, test sale confirmed. Phone camera test skipped for now (see Open issues). |
| 6 | Sales orders, returns and exchanges | **Done** — pages live, `sql/08` confirmed in the database. The two tests were probably run but not confirmed with numbers (see Open issues). |
| 7 | Production orders and metrics | **Done** — `sql/09` run, live, test confirmed. |
| 8 | History generator (12 months, all through the ledger) | **Done** — `sql/10` run and confirmed. |
| 9 | Planning: reorder point, EOQ, due for review, MRP, supplier scorecard | **Done** — `sql/11` run, live, confirmed. |
| 10 | Financials and reports | **Done** — `sql/12` and `sql/13` (weekly MRP) run, live, confirmed. |
| 11 | Customer portal and configurator | **Done** — `sql/11`, `sql/13` re-run, `sql/14` run, email confirmation off, pushed. Test waits for the team session (see Open issues). |
| 12 | About page polish, barcode labels, demo rehearsal | **Built** — labels page, About guide and `DEMO.md` committed. Still to do: push, print and scan labels, team test session, rehearse `DEMO.md`. |

Status last updated: 2026-11-16 (session 4, through step 11).

## Open issues / to-do

### Step 11 test (SQL run and pushed; only the test is left)

Try it (use a private/incognito window so your staff login stays signed in elsewhere):
- Open the live site, click **Create an account**, sign up with a made-up email and a password. You land on the shop and are asked for a name and usual store.
- **Shop:** stock shows per store and warehouse. Add 1 Skate Tool and 2 Grip Tape Sheets to the cart. **Cart:** subtotal $35.00, tax $2.54, total $37.54. Place the order.
- **My orders:** the order shows "Ready for pickup" if the store has the stock.
- **Build Your Own Board:** choose Street Deck 8.0", Standard Trucks, Street Wheels, ABEC-7 Bearings. The box and 1" hardware are added automatically: parts $181.00 + $10.00 assembly = $191.00. Switch wheels to Soft Cruiser: riser pads and 1.25" hardware replace the 1" hardware. Choose the Longboard Deck: only longboard trucks and wheels are offered. Order one.
- **As staff:** Sales Orders shows both portal orders. Production shows a planned "Custom Board" order with the chosen parts. Issue it, complete it: the board is received at the pickup store. Then fulfil the sales order. Back in the customer's My orders it shows "Picked up".
- **MRP → Order now:** before the custom order is issued, its parts appear under "For planned jobs".
- **Security check:** signed in as the customer, open `dashboard.html`: it says "Staff access needed".

### Step 12 test (no SQL; push first)

- Stock → **Barcode labels** → "1 of each shown" → **Print labels**. In the print window choose 100% scale. Plain paper is fine.
- On the same page, click into **Test a label** and scan a label with the USB scanner: it shows "Found: WBC-…". Click **Use camera** on a phone and scan a label: same result. This also finishes the phone camera test.
- Scan the same label into Point of Sale: the item goes into the cart.
- **About this system** reads as a guide to all 12 requirements; the formula numbers match the Settings page.
- Rehearse [DEMO.md](DEMO.md) once end to end with the devices you will use on Dec 2.

### Team test session: steps 7–10 (SQL already run; only the tests are left)

The history generator (step 8) replaced the starter stock, so stock levels and average costs differ from the early tests. Check the behaviour and the yields; dollar amounts will not match the old starter-stock figures.

**Step 7, production**
- Production → New production order → `WBC-2001`, quantity 5. Every part shows "Yes" under Enough?. Click **Save and issue parts now**.
- Inventory → Movement history shows a "Production issue" row for each part, and each part's OREM stock is down by 5.
- Back on the order: Add scrap or rework line twice. Line 1: 1 board, Cracked deck, Scrapped. Line 2: 1 board, Grip tape misapplied, Reworked. The summary reads "4 good = 5 started − 1 scrapped. Final yield 80% · first-pass yield 60%."
- Click **Complete order**: `WBC-2001` at OREM goes up by 4. Into stock + scrap cost = parts cost, and scrap cost = one board's cost.
- Production report tab, today only: 1 job, 5 started, 4 good, 80.0% / 60.0% / 20.0% scrap rate.
- Try quantity 500: issuing is refused with "Not enough stock" and nothing moves.

**Step 8, history**
- Inventory: the ledger check passes. Movement history (oldest first) starts with "Opening balance" rows on 16 Nov 2025.
- Purchasing: Timberline POs show days late; Urethane POs show fill rates under 100%.
- Production report over the whole year: yields below 100%, scrap listed by reason.
- Sales Orders: the 12-longboard order for Provo Board Rentals sits in the Backorders panel.

**Step 9, planning**
- Suppliers: the scorecard grades Timberline lowest (Replace), Ridgeline / Precision Spin / Beehive A (Keep).
- Due for Review: filter "At or below reorder point", tick a part, **Create draft POs for ticked parts**: a draft appears in Purchasing and the part's next review moves 30 days out.
- Settings: "Service level z" 1.65 → 2.33 raises safety stock and reorder points; "Ordering cost per PO" 25 → 100 doubles every EOQ. Put both back.
- MRP → Order now: `WBC-2004` shows the 12-unit open sales order and the 12-unit planned production order. 30 → 60 planning days makes the needs grow.
- Dashboard: an "Items at reorder point" card.

**Step 10, financials, reports and weekly MRP**
- Financials: net sales = revenue − refunds; gross profit = net sales − COGS. Monthly table shows a summer peak and a December bump. "Last 30 days" changes every number.
- Live update (needs two people or two windows): keep Financials open, ring up a POS sale elsewhere; revenue rises by the sale's subtotal within a few seconds.
- Reports: Sales by Day / Week / Month; Provo and SLC split the revenue, Orem has none. Top sellers, Low stock, Inventory by location and Supplier performance all fill in.
- MRP → Weekly plan: five rows per item over 4 weeks. Place a sales order for 10 of a board wanted two weeks out: that week's need rises for the board and its parts.

**Step 6 note:** the step 6 test below assumed starter stock ("Provo only has 3 cruisers"). After the history rebuild, pick a quantity larger than what Provo holds to see the backorder.

### Step 6 loose ends

`sql/08` is confirmed in the database (2026-11-16). Mason believes he ran the tests below but was not certain, so they stay here as a quick check before the demo.

- **GitHub Desktop:** commit (summary `Update notes`) and **Push origin** if PLAN.md / CLAUDE.md show as changed.

Try it, part 1 (sales order with a backorder):
- Sales Orders → New sales order → customer Provo Board Rentals (pickup switches to PROVO).
- Add `WBC-2003` (Cruiser Complete) and set quantity 5; add `WBC-1603` (Skate Tool), quantity 2. Place order.
- Provo only has 3 cruisers, so that line shows **Backorder · Transfer from another location** with tomorrow's date, and the order appears in the Backorders panel.
- Click **Fulfil what is in stock**: 5 units fulfilled (3 cruisers + 2 tools). The order stays "Order Placed" with 2 still open.
- Inventory → Transfer 2 × WBC-2003 from OREM to PROVO. Back on the order, the line turns "In stock"; fulfil again and the order becomes Fulfilled. Then **Close order**.

Try it, part 2 (return and exchange):
- On that order click **Return or exchange**. Return 1 Skate Tool as "Wrong size" and 1 Cruiser Complete as "Defective (quality failure)".
- Expected: refund $165.00 + $11.96 tax = $176.96. The tool goes back into stock; the cruiser does not and its cost ($79.25) is written off.
- For an exchange instead of a refund, scan a replacement item in section 3 before posting: the screen shows what the customer pays or gets back.

### Skipped for now

- **Phone camera test** (step 5). The camera opens and shows the picture on a phone (confirmed 2026-11-17). Still to do: point it at a real barcode. Any product barcode should say "Nothing matches"; a printed label from step 12 should add the item.

### Not verified yet

- Step 6 test numbers (refund $176.96, write-off $79.25) were not confirmed by the user.
- Camera reading a real barcode (the camera itself opens; see above).
- Realtime has not been tested with two real browsers on any page.
- USB barcode scanner: only tested with typed input + Enter, not a physical scanner.
- Receipt printing has not been tried on a real printer.

### Known gaps, planned for later steps

- A draft PO cannot be edited, only cancelled and re-created.
- "Send" marks the PO as sent; it does not email the supplier.
- Supplier scorecard, reorder point, EOQ, Due for Review: step 9 (they read the `po_summary` view built in step 4).
- POS takes no payment details (cash/card) and has one order-level discount percentage, per the approved plan.
- A placed sales order cannot be edited, only cancelled and re-entered. Fulfilment ships whatever is in stock (no choosing quantities per line).
- Stock is not reserved for a placed order: two orders can both show "In stock" for the same last unit; the first one fulfilled gets it.
- An exchange's replacement items are rung up as a new till sale at today's prices with no discount.
- Starter stock from `sql/05` is temporary: step 8's history generator replaces it with real opening balances and 12 months of history. Test POs made now will be wiped then.
- Settings are read-only on the dashboard: an editable Settings page is still to be built (needed before step 9).
- Customers cannot log in yet: portal and its security rules are step 11. Master data is staff-only until then.

### Housekeeping

- The first GitHub commit ("Initial commit") shows Mason's personal Gmail address publicly. To hide it on future commits, set the noreply address in GitHub Desktop → Settings → Git.
- If GitHub Desktop ever shows "Publish repository" instead of "Push origin", it is pointing at the wrong folder. Use File → Add Local Repository and pick the `wasatch-board-erp` folder on the Desktop; never "New Repository".
