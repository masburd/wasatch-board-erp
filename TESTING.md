# Wasatch Board Co. ERP — full test script

Every test of the system in one place, in an order that also works as a tour of how it works. Each section starts with **what it shows**, then steps and the result you should see. Work through it with the team; split sections between people if you like.

Live site: https://masburd.github.io/wasatch-board-erp/

## How to use this

- **Record results on the ERP's Test checklist page** (System → Test checklist). It shows these same tests with Pass and Fail buttons and a note box, and saves the results for the whole team. The boxes in this file cannot be ticked.
- If something fails, write the page, what you clicked and the exact message in the note, and paste it to Claude Code with the test number.
- **Numbers.** Prices come from the spec and never change unless you edit them, so totals worked out from prices are exact. Stock levels and average costs come from the generated year of history, so those you check by **rule** (for example "goes down by 2"), not by an exact figure.
- **Put things back.** Some tests change a setting or a price. Each one says when to change it back.
- **Logins you need:**
  - Two staff logins (two people, or one person with a normal window and a private window).
  - One customer login, made in test N1.
- A calculator helps.

Tax is 7.25%. Prices used below: Street Complete 8.0" (`WBC-2001`) $140, Pro Complete 8.5" (`WBC-2002`) $180, Cruiser Complete (`WBC-2003`) $150, Skate Tool (`WBC-1603`) $15, Helmet (`WBC-1602`) $45, Grip Tape Sheet (`WBC-1501`) $10.

---

## A. Getting around and security

*What it shows: who can get in, and that every page is protected by the database, not just hidden.*

- [ ] **A1.** Open the live site signed out. You see the sign-in page. Open `…/dashboard.html` directly: you are sent back to sign-in.
- [ ] **A2.** Sign in as staff: you land on the Dashboard. The menu on the left lists every page; none are greyed out.
- [ ] **A3.** Dashboard cards show numbers (Sales today, Units on hand, Inventory value, POs on their way, Owed to suppliers, Production jobs open, Items at reorder point, and counts). None shows "!".
- [ ] **A4.** Sign out (top right): you are back at sign-in.
- [ ] **A5.** (After N1) Signed in as the **customer**, open `…/dashboard.html`: it says "Staff access needed" and offers a link to the shop.

## B. Master data: items, BOMs, suppliers, settings

*What it shows: the reference data everything else uses, and that costs are calculated, not typed.*

- [ ] **B1. Items & BOMs.** Parts show a Cost (the weighted average cost) and a Price. Complete boards show a Cost rolled up from their bill of materials.
- [ ] **B2.** Open the Street Complete 8.0" BOM: 7 components, 1 each. Cost = the sum of the Extended cost column.
- [ ] **B3.** Edit a part's **price**: change Skate Tool from $15 to $16 and Save. The Margin column changes. At Point of Sale, the Skate Tool now rings up at $16. **Change it back to $15.**
- [ ] **B4.** Change a BOM quantity (Street Complete: grip tape 1 → 2). The board's rolled-up cost goes up by one grip tape's cost. **Change it back to 1.**
- [ ] **B5. Average cost cannot be typed in.** Click **Edit** on Skate Tool. The form has Price, Supplier quoted cost, Lead time and Review every, but no box for the average cost (the "Cost" column). Change **Supplier quoted cost** from $5.00 to $6.00 and Save: the Cost column does **not** change, because average cost only moves when stock is received. Purchasing → New purchase order → GripLine Accessories: the Skate Tool's unit cost now starts at $6.00 (close the form without saving). **Change the quoted cost back to $5.00.**
- [ ] **B6. Suppliers.** Add a test supplier, edit its phone number, deactivate it, then delete it. Try deleting Timberline Deck Works: it is refused because items use it.
- [ ] **B6a. Add a part.** Items & BOMs → **Add part**: SKU `WBC-1801`, category Accessory, name "Test Wax", supplier GripLine Accessories (lead time fills in as 5), price $8.00, quoted cost $3.00 → Save. It appears in the list with Cost $3.00 and margin 62.5%. Try adding another part with SKU `WBC-1001`: refused, "That SKU is already used".
- [ ] **B6b. It is used everywhere.** Purchasing → New PO → GripLine: Test Wax is listed at $3.00. Barcode labels lists it. Point of Sale finds it by typing `WBC-1801` (it has no stock yet, so it cannot be sold until a PO is received).
- [ ] **B6c. Change supplier and retire.** Edit Test Wax → change supplier to Beehive Packaging → Save: the Supplier column changes. Edit it again → untick **Active** → Save: it shows "retired" in grey and disappears from Purchasing, POS, the shop and planning.
- [ ] **B6d. Delete.** Edit Test Wax → **Delete item** → OK: it is gone from the list (it was never bought or sold). Edit Street Deck 8.0" → **Delete item**: refused with "This item has history … retire it instead", and nothing changes.
- [ ] **B7. Settings.** Every setting has a plain-language "Where it is used" note. (Changing them is tested in J.)

## C. Inventory and the ledger

*What it shows: one ledger of every stock movement; on-hand is the running total of it.*

- [ ] **C1. On hand.** Each item shows a quantity per location (OREM, PROVO, SLC), a total, the average cost and the value. Value = total × average cost (check one row).
- [ ] **C2.** The ledger check line says every location matches the ledger.
- [ ] **C3. Cycle count.** Adjust / count → choose an item at SLC → "Cycle count: I counted this many" → enter 2 fewer than on hand → reason "Cycle count correction" → **Post adjustment**. SLC drops by 2.
- [ ] **C4. Change.** Same item, "Change (+ to add, − to remove)" → +2, reason "Cycle count correction". SLC is back where it started.
- [ ] **C5. Movement history** shows both adjustments with their reason, unit cost and your name.
- [ ] **C6. Never negative.** Try a change of −999 on any item: refused with "Not enough stock", nothing moves.
- [ ] **C7. Transfer.** Transfer → from OREM to PROVO → add 2 of any part → **Post transfer**. OREM −2, PROVO +2, total unchanged. History shows a "Transfer out" and a "Transfer in" row.
- [ ] **C8. History.** Movement history → "Oldest first": the first ledger rows are "Opening balance" dated Nov 16, 2025.

## D. Barcodes

*What it shows: printed labels work with a USB scanner and with a phone camera.*

- [ ] **D1.** Barcode labels → "1 of each shown" → **Print labels** at 100% scale. Each label has the name, a barcode and the price.
- [ ] **D2.** Test a label with the **USB scanner**: "Found: WBC-…".
- [ ] **D3.** Test a label with the **phone camera** (Use camera): same result.
- [ ] **D4.** Scan a product barcode from home (a cereal box): "does not match any item".
- [ ] **D5.** A scan into Point of Sale, Inventory → Adjust, and a Purchasing receipt all pick up the item.

## E. Point of Sale

*What it shows: a till sale takes stock from that store and records revenue and cost of goods sold.*

Make sure Provo has at least 1 Street Complete 8.0" and 1 Skate Tool (transfer from Orem if not).

- [ ] **E1.** Point of Sale → Store: Provo, Customer: Walk-in. Scan `WBC-2001` and `WBC-1603`. Subtotal **$155.00**.
- [ ] **E2.** Discount % = 10. Discount −$15.50, after discount $139.50, tax **$10.11**, total **$149.61**.
- [ ] **E3.** **Complete sale.** A receipt appears with SO number, lines, discount, tax and total. **Print** opens a print window with only the receipt.
- [ ] **E4.** Inventory: Provo is down 1 Street Complete and 1 Skate Tool. History shows two "Sale" rows with a unit cost (that cost is the COGS).
- [ ] **E5.** Dashboard "Sales today" went up by $139.50 (revenue is after discount and before tax).
- [ ] **E6. Out of stock.** Try to sell more of an item than Provo has: the sale is refused and nothing is saved.
- **Keep this sale's SO number for test G.**

## F. Sales orders and backorders

*What it shows: Order Placed → Fulfilled → Closed, partial fulfilment, backorders with an estimated date.*

- [ ] **F1.** Sales Orders → **New sales order** → customer Provo Board Rentals (pickup switches to Provo). Add Cruiser Complete with a quantity **3 more than Provo has**, plus 2 Skate Tools. **Place order**. Status "Order Placed".
- [ ] **F2.** The Cruiser line shows Availability "Transfer from another location" with tomorrow's date, and the order appears in the Backorders panel.
- [ ] **F3.** **Fulfil what is in stock**: the tools and Provo's cruisers ship; the order stays "Order Placed" with 3 still open.
- [ ] **F4.** Inventory → Transfer 3 Cruiser Complete from OREM to PROVO. Back on the order the line turns ready. Fulfil again: status **Fulfilled**. **Close order (collected)**: **Closed**.
- [ ] **F5. Cancel.** New order for any customer → Place → **Cancel order**: status Cancelled, no stock moved.
- [ ] **F6. Ordered from a store with nothing anywhere:** a part with no stock at any location shows "On order" (if a PO is coming) or "Reorder", with a date based on the supplier's lead time.

## G. Returns and exchanges

*What it shows: refunds, reason codes, restock or write-off, and an exchange.*

- [ ] **G1. Refund.** Returns & Exchanges → find the sale from E → Select. Return 1 Skate Tool, reason "Wrong size". Settle up: refund **$13.50** + tax **$0.98** = **$14.48**. "Goes back into stock?" Yes. **Post return**.
- [ ] **G2.** Provo Skate Tool stock is +1. History shows a "Return" row.
- [ ] **G3. Defective.** On the same sale return the Street Complete as "Defective (quality failure)": refund $126.00 + $9.14 tax = $135.14. It does **not** go back into stock; its cost shows under "Written off".
- [ ] **G4. Can't over-return.** Try returning the same Skate Tool again: the quantity is capped at what is left.
- [ ] **G5. Exchange.** Ring up a new POS sale at Provo (no discount) for 1 Street Complete ($140 + $10.15 tax = $150.15). Return it as "Changed mind" and, in section 3, add 1 Pro Complete 8.5" ($180). Settle up: the customer **pays $42.90** ($193.05 for the new board − $150.15 refunded). Post it: the returned board is back in stock, the Pro Complete is out, and the return links to a replacement sale.
- [ ] **G6.** Recent returns lists all of these with refund, write-off and replacement sale.

## H. Purchasing and average cost

*What it shows: the PO life cycle, expected vs. actual dates, partial receipts, payables, and weighted average cost.*

- [ ] **H1.** Before starting, Inventory → On hand: write down **ABEC-7 Bearings (`WBC-1301`)** total units **Q** and average cost **A**.
- [ ] **H2.** Purchasing → **New purchase order** → Precision Spin Supply → ABEC-7 Bearings qty **100** at unit cost **$7.00** → **Save as draft**. Status Draft.
- [ ] **H3.** Open it → **Mark as sent** with a sent date **20 days ago**. Expected date = sent date + 7 days, so it shows as overdue.
- [ ] **H4. Partial receipt.** Receive **60** into OREM today → **Post receipt**. Still "Order Sent", 40 open.
- [ ] **H5. Average cost.** New average cost should be (Q × A + 60 × 7) ÷ (Q + 60). Check it on Inventory → On hand.
- [ ] **H6. Close short.** Receive **30** more and tick "Close this PO short". Status **Received**, fill rate **90%**, days late shown, payment due = received date + 15 (Net 15), owed $630.00.
- [ ] **H7.** Dashboard "Owed to suppliers" includes the $630.00.
- [ ] **H8.** **Mark paid and close**: status **Closed**, owed drops.
- [ ] **H9.** Suppliers → scorecard: Precision Spin's on-time rate and fill rate dropped a little.
- [ ] **H10. Cancel.** New draft PO → **Cancel PO**: Cancelled, nothing received.

## I. Production

*What it shows: issuing parts, completing with scrap and rework, cost rolled up from parts, quality metrics.*

- [ ] **I1.** Production → **New production order** → Street Complete 8.0", quantity 5. The parts table lists 7 parts × 5 with "Enough?" for each and the expected cost. **Save and issue parts now**.
- [ ] **I2.** Inventory: each of the 7 parts at OREM is down by 5; history shows "Production issue" rows.
- [ ] **I3.** On the order: **Add scrap or rework line** twice. Line 1: 1 board, Cracked deck, Scrapped. Line 2: 1 board, Grip tape misapplied, Reworked. Summary: "4 good = 5 started − 1 scrapped. Final yield 80% · first-pass yield 60%."
- [ ] **I4.** **Complete order**. Street Complete at OREM +4. Into stock + scrap cost = parts cost; scrap cost = 1 × cost per board.
- [ ] **I5.** Production report, today to today: 1 job, 5 started, 4 good, final yield 80.0%, first-pass yield 60.0%, scrap rate 20.0%. Scrap by reason lists Cracked deck (scrapped) and Grip tape misapplied (reworked).
- [ ] **I6.** Production report, last 365 days: a year of jobs, yields below 100%, all four scrap reasons.
- [ ] **I7. Too big.** New order quantity 500 → Save and issue: refused, "Not enough stock", nothing moves (the order stays Planned). **Cancel order** on it.

## J. Planning: reorder points, EOQ, periodic review, settings

*What it shows: the ordering rules are calculated from history and the editable settings.*

- [ ] **J1.** Due for Review → "All items", "Parts". Pick one row and check by calculator: Reorder point = d × L + 1.65 × σ × √L, using that row's Daily usage (d), Std dev (σ) and Lead time (L).
- [ ] **J2.** "At or below reorder point" lists only rows marked "Reorder now".
- [ ] **J3.** Tick one part → **Mark ticked as reviewed**: its next review moves 30 days out and it leaves the "Due for review" list.
- [ ] **J4.** Tick a part at its reorder point → **Create draft POs for ticked parts**: a draft PO for its supplier appears in Purchasing with the EOQ as quantity. (Cancel that PO afterwards.)
- [ ] **J5. EOQ responds.** Settings → Ordering cost per PO 25 → **100** → Save. Due for Review: every EOQ is **doubled** (√4 = 2). **Put it back to 25.**
- [ ] **J6. Service level.** Settings → Service level z 1.65 → **2.33**. Safety stock rises by 2.33 ÷ 1.65 ≈ 1.41×, reorder points rise. **Put it back to 1.65.**
- [ ] **J7. Tax.** Settings → tax 0.0725 → 0.08. A new POS sale uses 8%; an old receipt still shows 7.25%. **Put it back to 0.0725.**

## K. MRP

*What it shows: boards are planned first, then exploded through the BOM into parts, week by week.*

- [ ] **K1.** MRP → **Weekly plan**: weeks 1–4 starting today. Each item has gross need, scheduled receipts, planned order/build, order by, projected stock.
- [ ] **K2.** Longboard Complete (`WBC-2004`) shows the 12-unit Provo Board Rentals order (from the history) and the 12-unit planned production order.
- [ ] **K3.** Place a sales order for **10 Cruiser Complete** with a requested date **two weeks from today**. Weekly plan: the Cruiser's gross need rises in that week, and so do its parts (Cruiser Deck, Soft Cruiser Wheels, …) in the same week.
- [ ] **K4.** A part with "Overdue · do it today" has an order-by date already past (its lead time is longer than the time left).
- [ ] **K5.** **Order now** tab: Step 1 boards to build; Step 2 parts to buy. Change 30 → 60 days: needs grow.
- [ ] **K6.** Click **Create production order** on a board with a net need: its net drops by that amount and its parts move from "For boards to build" to "For planned jobs".
- [ ] **K7.** Tick parts → **Create draft POs for ticked parts**: one draft per supplier. Drafts do **not** reduce the need until they are sent. (Cancel them afterwards.)

## L. Financials

*What it shows: the P&L, valuation and turnover are all calculated and update live.*

- [ ] **L1.** Last 365 days P&L: Net sales = Revenue − Refunds; Gross profit = Net sales − COGS + Cost put back; Profit = Gross profit − Scrap − Written off − Count adjustments. Check with a calculator.
- [ ] **L2.** Monthly table: Jun–Aug higher than winter; December higher than November (Starter Kits and helmets).
- [ ] **L3.** "Last 30 days": every number changes. Today's sales and returns from E and G are in it.
- [ ] **L4.** Turnover cards: Turnover = COGS ÷ Average inventory value (check by dividing).
- [ ] **L5.** Valuation: All locations total = Dashboard "Inventory value". By item: value = total units × average cost.

## M. Reports

*What it shows: the reports the spec asks for.*

- [ ] **M1.** Sales → group by Day, Week, Month. Orem has no sales (it is the warehouse); Provo and SLC split the revenue.
- [ ] **M2.** Total revenue for the last 365 days = the P&L revenue for the same dates.
- [ ] **M3.** Top sellers: ranked by revenue, with units and margin.
- [ ] **M4.** Low stock: suggested order quantity and an order-by date; "Order needed within 0 days" shows only items due today.
- [ ] **M5.** Inventory by location matches Inventory → On hand.
- [ ] **M6.** Supplier performance matches the Suppliers scorecard: Timberline lowest (Replace), Urethane and GripLine Watch, the others Keep.

## N. Customer portal and Build Your Own Board

*What it shows: a customer login sees live stock, orders for pickup, designs a custom board, and cannot see staff data.*

Use a private window so your staff login stays signed in elsewhere.

- [ ] **N1. Sign up.** Sign-in page → "Create an account" → made-up email + password. You land on the shop and are asked for name, phone and usual store. Fill them in.
- [ ] **N2. Shop.** Stock shows per store and warehouse. Search and category filter work. No costs anywhere.
- [ ] **N3. Cart.** Add 1 Skate Tool and 2 Grip Tape Sheets. Cart: subtotal **$35.00**, tax **$2.54**, total **$37.54**. Pick Provo, **Place order for pickup**.
- [ ] **N4. My orders.** The order shows "Ready for pickup" (or an expected date for anything the store lacks).
- [ ] **N5. Rules.** Build Your Own Board: Cruiser deck → only Soft Cruiser wheels. Longboard deck → only Longboard trucks, wheels and grip.
- [ ] **N6. Price.** Street Deck 8.0", Standard Trucks, Street Wheels, ABEC-7 Bearings, Grip Tape Sheet: box and 1" hardware are added. Parts **$181.00** + $10.00 assembly = **$191.00**. Switch wheels to Soft Cruiser: riser pads and 1.25" hardware replace the 1" hardware.
- [ ] **N7.** Order the Street 8.0" build for Provo. My orders: "Custom Board", the chosen parts, "Workshop: waiting to be built".
- [ ] **N8. Staff side.** Sales Orders shows both portal orders. MRP → Order now: the build's parts appear under "For planned jobs". Production: a planned "Custom Board" order with those 7 parts.
- [ ] **N9.** Issue it, complete it with no scrap: the Custom Board is received **at Provo**. Fulfil and close the sales order. Customer's My orders → Refresh: "Picked up".
- [ ] **N10. Cancel.** Customer places another small order and cancels it from My orders: Cancelled.
- [ ] **N11. Security.** As the customer, open `…/dashboard.html`, `…/financials.html`, `…/items.html`: each says "Staff access needed".

## O. Multi-user and realtime

*What it shows: changes made by one user appear for everyone within a few seconds, without reloading.*

Use two staff windows side by side (B = watching, A = acting).

- [ ] **O1.** B: Inventory, Provo. A: POS sale at Provo. B's quantities change by themselves.
- [ ] **O2.** B: Purchasing list. A: send a draft PO. B's status changes.
- [ ] **O3.** B: Production. A: issue or complete an order. B updates.
- [ ] **O4.** B: Sales Orders. A (or the customer): place an order. It appears on B.
- [ ] **O5.** B: Financials. A: POS sale. Revenue rises on B.
- [ ] **O6.** Customer window on the shop. A: POS sale at Provo. The customer's Provo stock drops.

## P. The year of history

*What it shows: the generated data looks like a real business and went through the same ledger.*

- [ ] **P1.** Inventory ledger check passes (C2).
- [ ] **P2.** Purchasing: hundreds of POs. Timberline's are mostly late; Urethane's are short (fill under 100%).
- [ ] **P3.** Production report over the year: dozens of jobs, scrap rate around 3% and about 6% of boards reworked.
- [ ] **P4.** Reports → Sales by month: summer peak for cruisers and longboards (Top sellers for Jun–Aug vs. Jan–Feb), December spike, Black Friday week visible by day.

---

## Results log

| Section | Tested by | Date | Pass / fail | Notes (page, what happened, exact message) |
| --- | --- | --- | --- | --- |
| A | | | | |
| B | | | | |
| C | | | | |
| D | | | | |
| E | | | | |
| F | | | | |
| G | | | | |
| H | | | | |
| I | | | | |
| J | | | | |
| K | | | | |
| L | | | | |
| M | | | | |
| N | | | | |
| O | | | | |
| P | | | | |

## After testing

The tests leave extra orders, returns and stock moves in the database. That is fine for the demo. If you want a clean year again the evening before the demo, run `sql/10_history.sql` in Supabase: it erases **every** transaction and rebuilds the history. Then re-check C2 and the open orders used in [DEMO.md](DEMO.md).
