-- =====================================================================
-- Wasatch Board Co. ERP — 02: master data seed
-- Run AFTER 01_master_schema.sql. Safe to run more than once: rows that
-- already exist are skipped, so edits you made in the app are kept.
-- =====================================================================

-- Locations ------------------------------------------------------------
insert into public.locations (code, name, type) values
  ('OREM',  'Orem Warehouse & Assembly Shop',      'warehouse'),
  ('PROVO', 'Provo Store (near BYU)',              'store'),
  ('SLC',   'Salt Lake City Store (Sugar House)',  'store')
on conflict (code) do nothing;

-- Suppliers (contact details are invented) -----------------------------
insert into public.suppliers (name, contact_name, email, phone, quoted_lead_time_days, payment_terms_days) values
  ('Timberline Deck Works',  'Hank Sorensen',   'orders@timberlinedeckworks.example', '801-555-0121', 21, 30),
  ('Ridgeline Truck Co.',    'Maria Castillo',  'sales@ridgelinetruck.example',       '801-555-0134', 14, 30),
  ('Urethane Labs',          'Devon Park',      'devon@urethanelabs.example',         '385-555-0147', 10, 45),
  ('Precision Spin Supply',  'Alice Nakamura',  'alice@precisionspin.example',        '801-555-0158',  7, 15),
  ('GripLine Accessories',   'Tyler Jensen',    'tyler@gripline.example',             '435-555-0163',  5, 30),
  ('Beehive Packaging',      'Ruth Olsen',      'ruth@beehivepackaging.example',      '801-555-0172',  3, 15)
on conflict (name) do nothing;

-- Items: 20 parts -------------------------------------------------------
-- The barcode value is the SKU. avg_cost starts at standard_cost (set by
-- the trigger in file 01).
insert into public.items (sku, barcode, name, item_type, category, supplier_id, lead_time_days, standard_cost, price)
select v.sku, v.sku, v.name, 'part', v.category, s.id, v.lead_time, v.cost, v.price
from (values
  ('WBC-1001', 'Street Deck 8.0"',                    'deck',      'Timberline Deck Works', 21, 22.00,  60.00),
  ('WBC-1002', 'Street Deck 8.5"',                    'deck',      'Timberline Deck Works', 21, 24.00,  65.00),
  ('WBC-1003', 'Cruiser Deck',                        'deck',      'Timberline Deck Works', 21, 28.00,  70.00),
  ('WBC-1004', 'Longboard Deck',                      'deck',      'Timberline Deck Works', 21, 45.00, 110.00),
  ('WBC-1005', 'Mini Deck 7.5"',                      'deck',      'Timberline Deck Works', 21, 18.00,  45.00),
  ('WBC-1101', 'Standard Trucks (pair)',              'trucks',    'Ridgeline Truck Co.',   14, 20.00,  50.00),
  ('WBC-1102', 'Longboard Trucks (pair)',             'trucks',    'Ridgeline Truck Co.',   14, 30.00,  70.00),
  ('WBC-1201', 'Street Wheels 52mm (set of 4)',       'wheels',    'Urethane Labs',         10, 14.00,  35.00),
  ('WBC-1202', 'Soft Cruiser Wheels 60mm (set of 4)', 'wheels',    'Urethane Labs',         10, 16.00,  40.00),
  ('WBC-1203', 'Longboard Wheels 70mm (set of 4)',    'wheels',    'Urethane Labs',         10, 22.00,  55.00),
  ('WBC-1301', 'ABEC-7 Bearings (set of 8)',          'bearings',  'Precision Spin Supply',  7,  6.00,  18.00),
  ('WBC-1302', 'Ceramic Bearings (set of 8)',         'bearings',  'Precision Spin Supply',  7, 20.00,  50.00),
  ('WBC-1401', 'Hardware Kit 1"',                     'hardware',  'Precision Spin Supply',  7,  1.50,   5.00),
  ('WBC-1402', 'Hardware Kit 1.25"',                  'hardware',  'Precision Spin Supply',  7,  1.75,   5.00),
  ('WBC-1501', 'Grip Tape Sheet',                     'grip',      'GripLine Accessories',   5,  3.00,  10.00),
  ('WBC-1502', 'Longboard Grip Tape',                 'grip',      'GripLine Accessories',   5,  5.00,  15.00),
  ('WBC-1601', 'Riser Pads (pair)',                   'accessory', 'GripLine Accessories',   5,  2.00,   8.00),
  ('WBC-1602', 'Helmet',                              'accessory', 'GripLine Accessories',   5, 18.00,  45.00),
  ('WBC-1603', 'Skate Tool',                          'accessory', 'GripLine Accessories',   5,  5.00,  15.00),
  ('WBC-1701', 'Shipping Box',                        'packaging', 'Beehive Packaging',      3,  2.50,   3.00)
) as v (sku, name, category, supplier, lead_time, cost, price)
join public.suppliers s on s.name = v.supplier
on conflict (sku) do nothing;

-- Items: 5 complete boards. No cost is entered: it is rolled up from the BOM.
insert into public.items (sku, barcode, name, item_type, category, price) values
  ('WBC-2001', 'WBC-2001', 'Street Complete 8.0"',  'complete', 'complete', 140.00),
  ('WBC-2002', 'WBC-2002', 'Pro Complete 8.5"',     'complete', 'complete', 180.00),
  ('WBC-2003', 'WBC-2003', 'Cruiser Complete',      'complete', 'complete', 150.00),
  ('WBC-2004', 'WBC-2004', 'Longboard Complete',    'complete', 'complete', 220.00),
  ('WBC-2005', 'WBC-2005', 'Beginner Starter Kit',  'complete', 'complete', 150.00)
on conflict (sku) do nothing;

-- Item: the generic SKU used for Build Your Own Board orders.
-- Its price and cost come from the parts chosen on each order.
insert into public.items (sku, barcode, name, item_type, category) values
  ('WBC-3000', 'WBC-3000', 'Custom Board', 'custom', 'custom')
on conflict (sku) do nothing;

-- Bills of materials: qty 1 of each component per board -----------------
insert into public.bom_lines (parent_item_id, component_item_id, qty)
select p.id, c.id, 1
from (values
  -- Street Complete 8.0"
  ('WBC-2001', 'WBC-1001'), ('WBC-2001', 'WBC-1101'), ('WBC-2001', 'WBC-1201'), ('WBC-2001', 'WBC-1301'),
  ('WBC-2001', 'WBC-1501'), ('WBC-2001', 'WBC-1401'), ('WBC-2001', 'WBC-1701'),
  -- Pro Complete 8.5"
  ('WBC-2002', 'WBC-1002'), ('WBC-2002', 'WBC-1101'), ('WBC-2002', 'WBC-1201'), ('WBC-2002', 'WBC-1302'),
  ('WBC-2002', 'WBC-1501'), ('WBC-2002', 'WBC-1401'), ('WBC-2002', 'WBC-1701'),
  -- Cruiser Complete
  ('WBC-2003', 'WBC-1003'), ('WBC-2003', 'WBC-1101'), ('WBC-2003', 'WBC-1202'), ('WBC-2003', 'WBC-1301'),
  ('WBC-2003', 'WBC-1501'), ('WBC-2003', 'WBC-1402'), ('WBC-2003', 'WBC-1601'), ('WBC-2003', 'WBC-1701'),
  -- Longboard Complete
  ('WBC-2004', 'WBC-1004'), ('WBC-2004', 'WBC-1102'), ('WBC-2004', 'WBC-1203'), ('WBC-2004', 'WBC-1301'),
  ('WBC-2004', 'WBC-1502'), ('WBC-2004', 'WBC-1402'), ('WBC-2004', 'WBC-1601'), ('WBC-2004', 'WBC-1701'),
  -- Beginner Starter Kit
  ('WBC-2005', 'WBC-1005'), ('WBC-2005', 'WBC-1101'), ('WBC-2005', 'WBC-1202'), ('WBC-2005', 'WBC-1301'),
  ('WBC-2005', 'WBC-1501'), ('WBC-2005', 'WBC-1401'), ('WBC-2005', 'WBC-1602'), ('WBC-2005', 'WBC-1701')
) as v (parent_sku, component_sku)
join public.items p on p.sku = v.parent_sku
join public.items c on c.sku = v.component_sku
on conflict (parent_item_id, component_item_id) do nothing;

-- Settings ---------------------------------------------------------------
insert into public.settings (key, value, label, unit) values
  ('ordering_cost',     25,     'Ordering cost per PO',            'dollars'),
  ('holding_rate',      0.25,   'Annual holding cost rate',        'fraction of unit cost'),
  ('service_level_z',   1.65,   'Service level z (95%)',           'z-score'),
  ('tax_rate',          0.0725, 'Sales tax rate',                  'fraction'),
  ('assembly_fee',      10,     'Custom build assembly fee',       'dollars')
on conflict (key) do nothing;

-- Reason codes -----------------------------------------------------------
-- Returns: SPEC says defective items never go back into sellable stock.
-- "Damaged in transit" is also set to not restock, since the item is damaged.
insert into public.reason_codes (code, label, kind, restock) values
  ('cycle_count',         'Cycle count correction',  'adjustment', true),
  ('damaged',             'Damaged in store',        'adjustment', true),
  ('shrinkage',           'Lost or stolen',          'adjustment', true),
  ('defective',           'Defective (quality failure)', 'return', false),
  ('wrong_size',          'Wrong size',              'return',     true),
  ('changed_mind',        'Changed mind',            'return',     true),
  ('damaged_in_transit',  'Damaged in transit',      'return',     false),
  ('cracked_deck',        'Cracked deck',            'scrap',      true),
  ('stripped_hardware',   'Stripped hardware',       'scrap',      true),
  ('bad_bearing',         'Bad bearing',             'scrap',      true),
  ('grip_misapplied',     'Grip tape misapplied',    'scrap',      true)
on conflict (code) do nothing;

-- Customers (invented) ----------------------------------------------------
insert into public.customers (customer_no, name, customer_type, email, phone, home_location_id)
select v.customer_no, v.name, v.customer_type, v.email, v.phone, l.id
from (values
  ('C-000', 'Walk-in Customer',            'walk_in',    null,                               null,           null),
  ('C-001', 'Jake Petersen',               'individual', 'jake.petersen@example.com',        '801-555-0201', 'PROVO'),
  ('C-002', 'Emma Christensen',            'individual', 'emma.christensen@example.com',     '801-555-0202', 'PROVO'),
  ('C-003', 'Mateo Alvarez',               'individual', 'mateo.alvarez@example.com',        '801-555-0203', 'PROVO'),
  ('C-004', 'Sophie Nguyen',               'individual', 'sophie.nguyen@example.com',        '385-555-0204', 'PROVO'),
  ('C-005', 'Caleb Hansen',                'individual', 'caleb.hansen@example.com',         '801-555-0205', 'PROVO'),
  ('C-006', 'Aisha Rahman',                'individual', 'aisha.rahman@example.com',         '385-555-0206', 'SLC'),
  ('C-007', 'Noah Barlow',                 'individual', 'noah.barlow@example.com',          '801-555-0207', 'SLC'),
  ('C-008', 'Lily Tanaka',                 'individual', 'lily.tanaka@example.com',          '385-555-0208', 'SLC'),
  ('C-009', 'Owen McAllister',             'individual', 'owen.mcallister@example.com',      '801-555-0209', 'SLC'),
  ('C-101', 'Wasatch Front Skate School',  'business',   'office@wfskateschool.example',     '801-555-0301', 'SLC'),
  ('C-102', 'Timp Summer Youth Camp',      'business',   'director@timpyouthcamp.example',   '801-555-0302', 'PROVO'),
  ('C-103', 'Provo Board Rentals',         'business',   'shop@provoboardrentals.example',   '801-555-0303', 'PROVO')
) as v (customer_no, name, customer_type, email, phone, home_code)
left join public.locations l on l.code = v.home_code
on conflict (customer_no) do nothing;

-- Build Your Own Board: allowed choices per deck --------------------------
insert into public.build_options (deck_item_id, slot, item_id)
select d.id, v.slot, i.id
from (values
  -- Street 8.0"
  ('WBC-1001', 'trucks', 'WBC-1101'), ('WBC-1001', 'wheels', 'WBC-1201'), ('WBC-1001', 'wheels', 'WBC-1202'),
  ('WBC-1001', 'grip',   'WBC-1501'), ('WBC-1001', 'bearings', 'WBC-1301'), ('WBC-1001', 'bearings', 'WBC-1302'),
  -- Street 8.5"
  ('WBC-1002', 'trucks', 'WBC-1101'), ('WBC-1002', 'wheels', 'WBC-1201'), ('WBC-1002', 'wheels', 'WBC-1202'),
  ('WBC-1002', 'grip',   'WBC-1501'), ('WBC-1002', 'bearings', 'WBC-1301'), ('WBC-1002', 'bearings', 'WBC-1302'),
  -- Cruiser
  ('WBC-1003', 'trucks', 'WBC-1101'), ('WBC-1003', 'wheels', 'WBC-1202'),
  ('WBC-1003', 'grip',   'WBC-1501'), ('WBC-1003', 'bearings', 'WBC-1301'), ('WBC-1003', 'bearings', 'WBC-1302'),
  -- Longboard
  ('WBC-1004', 'trucks', 'WBC-1102'), ('WBC-1004', 'wheels', 'WBC-1203'),
  ('WBC-1004', 'grip',   'WBC-1502'), ('WBC-1004', 'bearings', 'WBC-1301'), ('WBC-1004', 'bearings', 'WBC-1302'),
  -- Mini 7.5"
  ('WBC-1005', 'trucks', 'WBC-1101'), ('WBC-1005', 'wheels', 'WBC-1201'), ('WBC-1005', 'wheels', 'WBC-1202'),
  ('WBC-1005', 'grip',   'WBC-1501'), ('WBC-1005', 'bearings', 'WBC-1301'), ('WBC-1005', 'bearings', 'WBC-1302')
) as v (deck_sku, slot, item_sku)
join public.items d on d.sku = v.deck_sku
join public.items i on i.sku = v.item_sku
on conflict (deck_item_id, slot, item_id) do nothing;

-- Build Your Own Board: parts added automatically for a deck + wheels ------
insert into public.build_auto_adds (deck_item_id, wheel_item_id, item_id)
select d.id, w.id, i.id
from (values
  -- Street / Mini with street wheels: box + 1" hardware
  ('WBC-1001', 'WBC-1201', 'WBC-1701'), ('WBC-1001', 'WBC-1201', 'WBC-1401'),
  ('WBC-1002', 'WBC-1201', 'WBC-1701'), ('WBC-1002', 'WBC-1201', 'WBC-1401'),
  ('WBC-1005', 'WBC-1201', 'WBC-1701'), ('WBC-1005', 'WBC-1201', 'WBC-1401'),
  -- Street / Mini with soft wheels: box + riser pads + 1.25" hardware
  ('WBC-1001', 'WBC-1202', 'WBC-1701'), ('WBC-1001', 'WBC-1202', 'WBC-1601'), ('WBC-1001', 'WBC-1202', 'WBC-1402'),
  ('WBC-1002', 'WBC-1202', 'WBC-1701'), ('WBC-1002', 'WBC-1202', 'WBC-1601'), ('WBC-1002', 'WBC-1202', 'WBC-1402'),
  ('WBC-1005', 'WBC-1202', 'WBC-1701'), ('WBC-1005', 'WBC-1202', 'WBC-1601'), ('WBC-1005', 'WBC-1202', 'WBC-1402'),
  -- Cruiser (soft wheels only): box + riser pads + 1.25" hardware
  ('WBC-1003', 'WBC-1202', 'WBC-1701'), ('WBC-1003', 'WBC-1202', 'WBC-1601'), ('WBC-1003', 'WBC-1202', 'WBC-1402'),
  -- Longboard (longboard wheels only): box + riser pads + 1.25" hardware
  ('WBC-1004', 'WBC-1203', 'WBC-1701'), ('WBC-1004', 'WBC-1203', 'WBC-1601'), ('WBC-1004', 'WBC-1203', 'WBC-1402')
) as v (deck_sku, wheel_sku, item_sku)
join public.items d on d.sku = v.deck_sku
join public.items w on w.sku = v.wheel_sku
join public.items i on i.sku = v.item_sku
on conflict (deck_item_id, wheel_item_id, item_id) do nothing;

-- Check: the rolled-up cost of each complete, calculated from its BOM.
-- Expected from SPEC.md: 69.00, 85.00, 79.25, 114.25, 85.00
select i.sku, i.name, c.current_cost as rolled_up_cost, i.price
from public.items i
join public.item_costs c on c.item_id = i.id
where i.item_type = 'complete'
order by i.sku;
