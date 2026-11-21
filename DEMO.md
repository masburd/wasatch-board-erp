# Demo script: Wasatch Board Co. ERP (Dec 2, 2026)

A walk-through that touches all 12 required capabilities, about 20 minutes. Rehearse it at least once end to end with the people and devices you will use on the day. Times are a guide.

## Before the demo (the day before)

- [ ] Print a sheet of barcode labels (Stock → **Barcode labels** → "1 of each shown" → Print). Scan two of them on the **Test a label** box, with the USB scanner and with the phone camera.
- [ ] Decide who drives each part. You need three screens:
  - **Laptop A (staff, on the projector):** signed in as staff.
  - **Laptop B (staff):** a second staff login, to show realtime.
  - **Phone or laptop C (customer):** a customer account made on the sign-up page, home store Provo.
- [ ] Check stock: Inventory shows the ledger check passing, and Provo has at least 1 Street Complete (`WBC-2001`), 1 Skate Tool (`WBC-1603`) and 1 Helmet (`WBC-1602`). Transfer some from Orem if not.
- [ ] **Refresh the history on the evening of Dec 1:** run `sql/10_history.sql` in Supabase. The year of history then runs up to Nov 30 (including Black Friday), and every test order is wiped. It erases **every** transaction, so do this only after all testing is finished. Items, prices, suppliers, customers, settings, logins and the test checklist results are kept. Afterwards check the ledger (Inventory) and that the two open sales orders and the planned production order are there.
- [ ] Open every page once on Laptop A so nothing is slow the first time.
- [ ] Know the backup: if the scanner fails, type the SKU into the scan box and press Enter; if the camera fails, the USB scanner or typing does the same thing.

## 1. The big picture (2 min) — Dashboard, About

- Open **Dashboard**: today's sales, stock value, POs on the way, items at reorder point. Every card is calculated from stored transactions.
- Say the one rule: **every stock change is a row in one ledger**, and on-hand is the sum of that ledger. Costs use weighted average cost.
- Point to **About this system** for where each requirement lives.

## 2. A sale with barcodes and realtime (3 min) — capabilities 1, 3, 12

1. On Laptop B open **Inventory**, location Provo, and leave it on screen.
2. On Laptop A open **Point of Sale**, location Provo. Scan the `WBC-2001` label and the `WBC-1603` label (USB scanner). Scan the Helmet label with the **phone camera** (Use camera).
3. Add a 10% discount, show subtotal, tax 7.25%, total. Complete the sale and show the receipt.
4. Laptop B: the Provo quantities drop within a few seconds without reloading. That is realtime.
5. Inventory → Movement history: three "Sale" rows, each with the cost taken out.

## 3. Customer orders online (3 min) — capability 11, then 4 and 2

1. On device C (customer) open the shop. Show stock by store, live.
2. Add an item that **Provo does not have** (check the Provo column), place the order for pickup at Provo.
3. **My orders** shows "Being prepared" with an expected date.
4. Laptop A → **Sales Orders**: the portal order is there, in the Backorders panel, with "Transfer from another location" and its date.
5. Inventory → Transfer it from Orem to Provo. Back on the order: **Fulfil**, then **Close**. Device C → My orders → Refresh: "Picked up".

## 4. Build Your Own Board (3 min) — wow factor, capability 6

1. Device C → **Build Your Own Board**. Pick the Cruiser deck: only soft wheels are offered. Pick Longboard: only longboard trucks and wheels. Point out the box, hardware and riser pads added automatically, and the price = parts + $10 assembly.
2. Order a Street 8.0" build for Provo.
3. Laptop A → **MRP → Order now**: its parts now count under "For planned jobs".
4. **Production**: the planned Custom Board order with the chosen parts. **Issue parts** (parts leave Orem stock), then **Complete** with 0 scrap. The board is received at Provo at the cost of the parts used.
5. **Sales Orders**: fulfil and close it.

## 5. Production quality (2 min) — capability 6

1. **Production → New production order**: `WBC-2001`, quantity 5. The parts table shows what is needed and whether Orem has enough. **Save and issue parts now**.
2. Complete it with 1 scrapped (Cracked deck) and 1 reworked (Grip tape misapplied): 4 good, final yield 80%, first-pass yield 60%. The scrapped board's parts become scrap cost.
3. **Production report** tab, last 365 days: yields, scrap rate, scrap by reason, build time.

## 6. Purchasing and suppliers (3 min) — capability 7

1. **Due for Review**: reorder point, EOQ and safety stock for each part, with the formula at the bottom. Filter "At or below reorder point", tick a part, **Create draft POs**.
2. **Purchasing**: open the draft and **Mark as sent** with a sent date 30 days ago (expected date = sent date + quoted lead time, so it is already past). **Receive** it today: the PO shows how many days late, stock goes up and the part's average cost is re-averaged.
3. **Suppliers → scorecard**: Timberline is late (Replace), Urethane ships short (Watch), the rest Keep.

## 7. Professor changes an input (2 min) — "everything is calculated"

Let the professor pick one, or do both:
- **Settings → Ordering cost per PO** from 25 to 100 → **Due for Review**: every EOQ doubles.
- **Settings → Service level z** from 1.65 to 2.33 → reorder points and safety stock rise.

Put the values back afterwards.

## 8. Planning and money (3 min) — capabilities 8, 9, 10

1. **MRP → Weekly plan**: four weeks; for each item gross need, scheduled receipts, planned order, order-by date and projected stock. Boards are planned first and drive the parts below them.
2. **Financials**: P&L for the last 365 days (revenue → net sales → gross profit → profit after scrap, write-offs and count losses), monthly table with the summer peak and the December spike, inventory valuation by location, turnover. Switch to "Last 30 days".
3. Optional realtime proof: keep Financials open on Laptop B and ring up one more POS sale on Laptop A; revenue goes up.
4. **Reports**: sales by week, top sellers, low stock with order-by dates.

## 9. Return (1 min) — capability 5

**Returns & Exchanges**: find the sale from part 2, return the helmet as "Defective". The refund is shown with tax, the helmet does not go back into stock, and its cost appears as a write-off on the P&L.

## If something goes wrong

- A page shows an error: read it out (they are written in plain language, for example "Not enough stock") and explain the rule that stopped it.
- A screen does not update by itself: press reload; realtime may have dropped on venue Wi-Fi.
- Scanner does nothing: click into the scan box first; a scanner types wherever the cursor is.

## Questions to be ready for

- *Where does cost of goods sold come from?* Each sale line stores the item's average cost at the moment the stock left.
- *How is a complete board's cost decided?* The parts issued to its production order, at their average cost, divided by boards started.
- *What happens to a defective return?* Refund and cost reversal, no restock, cost written off.
- *How do you stop customers seeing costs?* The database security rules; the shop only calls functions that return prices.
- *Where did a year of data come from?* A generator script that posts every event through the same ledger, so on-hand still equals the ledger.
