# Wasatch Board Co. — ERP Build Spec

School project (GSCM 401, Dr. Wright): a working mini-ERP for a fictional small business, demoed live on Dec 2. The team must understand and explain every part of it. Every number the system displays must be computed from stored data (never static entry) — the professor may change an input during the demo and ask to see the result update.

## Tech stack

- Frontend: plain HTML + JavaScript (no build step), hosted on GitHub Pages (public repo `wasatch-board-erp`)
- Database, auth and realtime: Supabase
- Code written with Claude Code
- The app must include an "About this system" page documenting the AI tools, database and hosting used

## Company

Wasatch Board Co. is a small Utah skateboard company. It sells 20 individual parts and assembles 5 complete skateboards in-house (retail with light manufacturing / kitting). Wow factor: a "Build Your Own Board" configurator with compatibility rules.

## Required capabilities (all 12 must work and be integrated)

1. **Point of Sale** — multi-line sales, simple tax and discounts, a basic receipt. A sale reduces inventory at that location and records revenue and cost of goods sold.
2. **Inventory Management** — on-hand quantity by item and location (3 locations), transfers between locations, adjustments for cycle counts or damage with a reason code, backorders, and an estimated available date based on supplier lead time.
3. **Barcode Support** — each item has a barcode value. "Scan to add" in POS and "scan to receive/adjust" in inventory. Must work with printed barcodes (USB scanner acting as keyboard input and/or phone camera scanning).
4. **Sales Orders** — customer, location, items and quantities; status Order Placed → Fulfilled → Closed / Cancelled.
5. **Returns and Exchanges** — process a return and an exchange, put items back into inventory, use reason codes (including quality failure), and reverse or adjust revenue and COGS.
6. **Production Orders** — item, quantity, location. Issuing the order consumes components per the BOM; completing it receives the finished item at a cost rolled up from components. Record quantity started, completed good, and scrapped/reworked (with reason code), plus start and finish times. Compute at least 3 production/quality metrics and show a production report over a date range.
7. **Purchase Orders and Suppliers** — supplier CRUD (contact info, quoted lead time, payment terms); create/send POs; receive against a PO into a chosen location with date and quantities; status Order Sent → Received → Closed. Each PO has an expected receipt date from the supplier's lead time, and actual vs. expected is compared. Ordering rules: reorder points with lead-time demand, periodic manual review, and EOQ from average usage in sales history, using ordering and holding cost stored as editable settings. Supplier scorecard computed from PO history: on-time rate, average actual vs. quoted lead time, fill rate, amounts owed and due dates; overall rating on one screen (keep / watch / replace).
8. **MRP** — 5 parent items with single-level BOMs. Making or selling a parent consumes components. Take parent quantities on confirmed sales orders, explode through the BOMs, subtract on-hand and open PO quantities, and show suggested order quantity plus order-by date (requirement date minus component lead time). Weekly view over the next 4 weeks.
9. **Financial Reporting** — P&L, inventory valuation (weighted average cost), inventory turnover; all update live.
10. **Reporting** — e.g. sales by day/week, top sellers, low stock with suggested order quantity and order-by date, inventory by location, supplier performance.
11. **Customer-Facing ERP** — customer login, see available inventory and which location has it, place an order for pickup.
12. **Multi-user** — staff logins; changes made by one user show up for every other user in real time (Supabase realtime).

## Locations

| Location | Role |
| --- | --- |
| Orem Warehouse & Assembly Shop | Receives all POs, holds most parts, runs all production orders, transfers stock to stores |
| Provo Store (near BYU) | POS, returns/exchanges, customer pickup; busier Sept–Apr |
| Salt Lake City Store (Sugar House) | POS, returns/exchanges, customer pickup; steady all year |

Production orders can only be created at the warehouse.

## Suppliers

| Supplier | Supplies | Quoted lead time (days) | Terms | Behavior to build into PO history |
| --- | --- | --- | --- | --- |
| Timberline Deck Works | All 5 decks | 21 | Net 30 | Often late (actual ~26 days) |
| Ridgeline Truck Co. | Trucks | 14 | Net 30 | On time, full quantities |
| Urethane Labs | Wheels | 10 | Net 45 | On time but ships short (~88% fill rate) |
| Precision Spin Supply | Bearings, hardware | 7 | Net 15 | On time, full quantities |
| GripLine Accessories | Grip tape, riser pads, helmet, skate tool | 5 | Net 30 | Occasionally a few days late |
| Beehive Packaging | Boxes | 3 | Net 15 | Excellent |

Invent contact names, emails and phone numbers.

## Items — 20 parts

| SKU / barcode | Part | Supplier | Lead time (days) | Cost ($) | Price ($) |
| --- | --- | --- | --- | --- | --- |
| WBC-1001 | Street Deck 8.0" | Timberline Deck Works | 21 | 22.00 | 60.00 |
| WBC-1002 | Street Deck 8.5" | Timberline Deck Works | 21 | 24.00 | 65.00 |
| WBC-1003 | Cruiser Deck | Timberline Deck Works | 21 | 28.00 | 70.00 |
| WBC-1004 | Longboard Deck | Timberline Deck Works | 21 | 45.00 | 110.00 |
| WBC-1005 | Mini Deck 7.5" | Timberline Deck Works | 21 | 18.00 | 45.00 |
| WBC-1101 | Standard Trucks (pair) | Ridgeline Truck Co. | 14 | 20.00 | 50.00 |
| WBC-1102 | Longboard Trucks (pair) | Ridgeline Truck Co. | 14 | 30.00 | 70.00 |
| WBC-1201 | Street Wheels 52mm (set of 4) | Urethane Labs | 10 | 14.00 | 35.00 |
| WBC-1202 | Soft Cruiser Wheels 60mm (set of 4) | Urethane Labs | 10 | 16.00 | 40.00 |
| WBC-1203 | Longboard Wheels 70mm (set of 4) | Urethane Labs | 10 | 22.00 | 55.00 |
| WBC-1301 | ABEC-7 Bearings (set of 8) | Precision Spin Supply | 7 | 6.00 | 18.00 |
| WBC-1302 | Ceramic Bearings (set of 8) | Precision Spin Supply | 7 | 20.00 | 50.00 |
| WBC-1401 | Hardware Kit 1" | Precision Spin Supply | 7 | 1.50 | 5.00 |
| WBC-1402 | Hardware Kit 1.25" | Precision Spin Supply | 7 | 1.75 | 5.00 |
| WBC-1501 | Grip Tape Sheet | GripLine Accessories | 5 | 3.00 | 10.00 |
| WBC-1502 | Longboard Grip Tape | GripLine Accessories | 5 | 5.00 | 15.00 |
| WBC-1601 | Riser Pads (pair) | GripLine Accessories | 5 | 2.00 | 8.00 |
| WBC-1602 | Helmet | GripLine Accessories | 5 | 18.00 | 45.00 |
| WBC-1603 | Skate Tool | GripLine Accessories | 5 | 5.00 | 15.00 |
| WBC-1701 | Shipping Box | Beehive Packaging | 3 | 2.50 | 3.00 |

## Parent items — 5 complete boards (qty 1 of each component per board)

| SKU / barcode | Complete | BOM | Rolled-up cost ($) | Price ($) |
| --- | --- | --- | --- | --- |
| WBC-2001 | Street Complete 8.0" | Street Deck 8.0", Standard Trucks, Street Wheels, ABEC-7 Bearings, Grip Tape Sheet, Hardware Kit 1", Shipping Box | 69.00 | 140.00 |
| WBC-2002 | Pro Complete 8.5" | Street Deck 8.5", Standard Trucks, Street Wheels, Ceramic Bearings, Grip Tape Sheet, Hardware Kit 1", Shipping Box | 85.00 | 180.00 |
| WBC-2003 | Cruiser Complete | Cruiser Deck, Standard Trucks, Soft Cruiser Wheels, ABEC-7 Bearings, Grip Tape Sheet, Hardware Kit 1.25", Riser Pads, Shipping Box | 79.25 | 150.00 |
| WBC-2004 | Longboard Complete | Longboard Deck, Longboard Trucks, Longboard Wheels, ABEC-7 Bearings, Longboard Grip Tape, Hardware Kit 1.25", Riser Pads, Shipping Box | 114.25 | 220.00 |
| WBC-2005 | Beginner Starter Kit | Mini Deck 7.5", Standard Trucks, Soft Cruiser Wheels, ABEC-7 Bearings, Grip Tape Sheet, Hardware Kit 1", Helmet, Shipping Box | 85.00 | 150.00 |

Parent cost is never typed in: it is computed from component costs. Completes are make-to-stock, assembled at the warehouse. Production scrap reason codes: cracked deck, stripped hardware, bad bearing, grip tape misapplied.

## Custom builds (wow factor) — assemble-to-order

| Deck | Trucks allowed | Wheels allowed | Grip | Auto-added |
| --- | --- | --- | --- | --- |
| Street 8.0" / 8.5" | Standard | Street or Soft Cruiser | Grip Tape Sheet | Box; Hardware 1" (or Riser Pads + Hardware 1.25" if soft wheels) |
| Cruiser | Standard | Soft Cruiser only | Grip Tape Sheet | Box, Riser Pads, Hardware 1.25" |
| Longboard | Longboard | Longboard only | Longboard Grip Tape | Box, Riser Pads, Hardware 1.25" |
| Mini 7.5" | Standard | Street or Soft Cruiser | Grip Tape Sheet | Same as street |

Either bearing type works with any deck. Price = sum of the chosen parts' prices + assembly fee (setting, $10). Cost = sum of the parts' costs. A custom order creates a warehouse production order with a one-time component list; completing it moves the board to the pickup store. MRP treats custom-build demand as direct component demand.

## Customers and sales history

- 12 customers: 9 individuals (portal logins, home store Provo or SLC) and 3 business accounts (skate school, summer youth camp, Provo board-rental shop) that place larger sales orders. Plus a generic "Walk-in Customer" for POS.
- Generate 12 months of sales history (Nov 2025 – Nov 2026), plus matching PO and production history.
- Seasonality: cruisers and longboards peak hardest in summer (Jun–Aug ~2–2.5× winter); street completes and decks are steady with a moderate summer bump; Starter Kits and helmets spike in December (~3×); replacement parts (wheels, bearings, grip, hardware) are steady all year.
- Weekends ~1.5× weekdays. Provo busier Sept–Apr. Events: July 4th sale, August back-to-school, Black Friday. ~±15% daily noise.
- ~2–3% of sales returned. Return reasons: defective (quality failure), wrong size, changed mind, damaged in transit. Defective items do not go back into sellable stock.

## Settings (editable) and calculations

| Setting | Value |
| --- | --- |
| Ordering cost per PO | $25 |
| Annual holding cost rate | 25% of unit cost |
| Service level | 95% (z = 1.65) |
| Sales tax rate | 7.25% |
| Custom build assembly fee | $10 |

- Reorder point = d × L + z × σ × √L (d = average daily usage, L = lead time in days, σ = std dev of daily usage)
- EOQ = √(2DS / H) (D = annual usage, S = ordering cost, H = holding rate × unit cost)
- Part usage = direct part sales + parts consumed in production
- Inventory valuation: weighted average cost, re-averaged on each receipt
- Production completion receives finished goods at the cost of the components consumed; scrap cost goes to scrap expense
- P&L: revenue − returns = net sales; − COGS = gross profit; − scrap/adjustments
- Inventory turnover = COGS ÷ average inventory value
- Supplier rating: on-time rate, actual vs. quoted lead time, fill rate, payables; combined A–F with Keep / Watch / Replace
- Production metrics: yield (good ÷ started), scrap rate by reason, average build time; production report filterable by date range
