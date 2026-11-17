-- =====================================================================
-- Wasatch Board Co. ERP — 10: twelve months of history
-- Run AFTER file 09.
--
-- !! THIS FILE ERASES EVERY TRANSACTION AND REBUILDS THEM !!
-- It empties the ledger, stock levels, purchase orders, sales, returns,
-- transfers and production orders, then replays one year of business
-- (16 Nov 2025 to yesterday), one day at a time.
-- It does NOT touch items, BOMs, suppliers, customers, settings or logins.
-- Running it again erases and rebuilds again (same numbers each time).
--
-- Every stock change goes through wbc_post_movement, starting with
-- opening balances, so on-hand always equals the sum of the ledger.
-- This replaces the temporary starter stock from file 05.
-- =====================================================================

create or replace function public.wbc_generate_history(p_seed double precision default 0.42)
returns text
language plpgsql
security definer
set search_path = public
as $$
#variable_conflict use_column
declare
  v_start     date := date '2025-11-16';      -- opening balances are dated this day
  v_end       date := wbc_today() - 1;        -- history stops yesterday
  v_day       date;
  v_mon       int;
  v_orem      bigint;
  v_walkin    bigint;
  v_tax       numeric;
  v_reasons   text[] := array['cracked_deck', 'stripped_hardware', 'bad_bearing', 'grip_misapplied'];
  v_return_reasons text[] := array['changed_mind', 'changed_mind', 'changed_mind', 'defective', 'defective',
                                   'defective', 'wrong_size', 'wrong_size', 'wrong_size', 'damaged_in_transit'];
  v_adj_reasons text[] := array['shrinkage', 'damaged', 'cycle_count'];
  -- the day's conditions
  v_weekend   numeric;
  v_provo     numeric;    -- Provo's share of the day's store sales
  v_share     numeric;
  v_event     numeric;    -- sales multiplier for a sale event
  v_disc      numeric;    -- discount % during a sale event
  v_bf        date;       -- Black Friday of that year
  -- scratch
  r           record;
  r2          record;
  st          record;
  v_id        bigint;
  v_id2       bigint;
  v_line_id   bigint;
  v_qty       numeric;
  v_have      numeric;
  v_orem_have numeric;
  v_pos       numeric;
  v_cost      numeric;
  v_total     numeric;
  v_unit      numeric;
  v_n         int;
  v_i         int;
  v_lam       numeric;
  v_late      int;
  v_fill      numeric;
  v_when      timestamptz;
  v_clock     timestamp;
  v_finish    timestamp;
  v_scrap     int[];
  v_rework    int[];
  v_scrapped  int;
  v_reworked  int;
  v_roll      double precision;
  v_lines     int;
  v_customer  bigint;
  v_reason    text;
  v_restock   boolean;
  v_target    numeric;
  v_sku       text;
  v_lost      int := 0;
begin
  perform setseed(p_seed);    -- same "random" numbers on every run

  select id into v_orem from locations where type = 'warehouse' order by id limit 1;
  select id into v_walkin from customers where customer_type = 'walk_in' order by id limit 1;
  select value into v_tax from settings where key = 'tax_rate';
  if v_orem is null or v_walkin is null or v_tax is null then
    raise exception 'Master data is missing: run files 01 and 02 first';
  end if;

  -- ===================================================================
  -- 1. Erase every transaction. (TRUNCATE is the only way to empty the
  --    ledger: ordinary deletes are blocked by its lock trigger.)
  -- ===================================================================
  truncate table
    return_lines, returns,
    production_scrap, production_order_components, production_orders,
    sales_order_lines, sales_orders,
    po_receipt_lines, po_receipts, purchase_order_lines, purchase_orders,
    transfer_lines, transfers,
    inventory_movements, inventory_levels
    restart identity;

  -- Costs go back to the supplier's quoted price; boards are re-costed
  -- by their opening balance below.
  update items set avg_cost = coalesce(standard_cost, 0);

  -- ===================================================================
  -- 2. The demand model (temporary tables, gone when this finishes)
  -- ===================================================================
  drop table if exists wbc_hist_item, wbc_hist_season, wbc_hist_plan, wbc_hist_biz,
                       wbc_hist_po_due, wbc_hist_returns;

  -- base = units sold per ordinary winter weekday, both stores together.
  -- grp  = which seasonal pattern the item follows.
  create temp table wbc_hist_item on commit drop as
  select i.id as item_id, i.sku, i.item_type, v.grp, v.base::numeric as base
  from (values
    ('WBC-2001', 'street', 0.90), ('WBC-2002', 'street', 0.50), ('WBC-2003', 'cruise', 0.70),
    ('WBC-2004', 'cruise', 0.45), ('WBC-2005', 'gift',   0.50),
    ('WBC-1001', 'street', 0.50), ('WBC-1002', 'street', 0.40), ('WBC-1003', 'cruise', 0.25),
    ('WBC-1004', 'cruise', 0.15), ('WBC-1005', 'street', 0.20),
    ('WBC-1101', 'parts',  0.40), ('WBC-1102', 'parts',  0.12),
    ('WBC-1201', 'parts',  0.80), ('WBC-1202', 'parts',  0.50), ('WBC-1203', 'parts',  0.30),
    ('WBC-1301', 'parts',  0.90), ('WBC-1302', 'parts',  0.25),
    ('WBC-1401', 'parts',  0.70), ('WBC-1402', 'parts',  0.40),
    ('WBC-1501', 'parts',  1.00), ('WBC-1502', 'parts',  0.25),
    ('WBC-1601', 'parts',  0.30), ('WBC-1602', 'gift',   0.50), ('WBC-1603', 'parts',  0.50),
    ('WBC-1701', 'parts',  0.05)
  ) as v (sku, grp, base)
  join items i on i.sku = v.sku;

  -- Seasonal factor for each pattern, January to December.
  --   cruise: cruisers and longboards, strong summer peak
  --   street: steady with a moderate summer bump
  --   gift:   Starter Kits and helmets, spike in December
  --   parts:  replacement parts, steady all year
  create temp table wbc_hist_season (grp text, mon int, f numeric) on commit drop;
  insert into wbc_hist_season
  select 'cruise', t.ord, t.f from unnest(array[0.80, 0.80, 1.00, 1.30, 1.60, 2.00, 2.30, 2.10, 1.40, 1.00, 0.85, 0.90])
    with ordinality as t (f, ord);
  insert into wbc_hist_season
  select 'street', t.ord, t.f from unnest(array[0.90, 0.90, 1.00, 1.05, 1.15, 1.25, 1.30, 1.30, 1.10, 1.00, 0.95, 1.10])
    with ordinality as t (f, ord);
  insert into wbc_hist_season
  select 'gift', t.ord, t.f from unnest(array[1.00, 1.00, 1.00, 1.00, 1.05, 1.10, 1.10, 1.10, 1.00, 1.00, 1.20, 3.00])
    with ordinality as t (f, ord);
  insert into wbc_hist_season
  select 'parts', t.ord, 1.00 from generate_series(1, 12) as t (ord);

  -- Business accounts place a larger sales order on a set day of the month.
  --   mons = which months (null = every month), dom = day of the month
  create temp table wbc_hist_biz (customer_no text, loc_code text, mons int[], dom int,
                                  sku text, qmin int, qmax int) on commit drop;
  insert into wbc_hist_biz values
    -- skate school: starter kits and helmets every month
    ('C-101', 'SLC',   null, 5, 'WBC-2005', 3, 5),
    ('C-101', 'SLC',   null, 5, 'WBC-1602', 3, 5),
    -- summer youth camp: three big orders before and during summer
    ('C-102', 'PROVO', array[5], 20, 'WBC-2003', 8, 12),
    ('C-102', 'PROVO', array[5], 20, 'WBC-2005', 6, 8),
    ('C-102', 'PROVO', array[5], 20, 'WBC-1602', 10, 14),
    ('C-102', 'PROVO', array[6], 15, 'WBC-2003', 8, 12),
    ('C-102', 'PROVO', array[6], 15, 'WBC-2005', 6, 8),
    ('C-102', 'PROVO', array[6], 15, 'WBC-1602', 10, 14),
    ('C-102', 'PROVO', array[7], 13, 'WBC-2003', 8, 12),
    ('C-102', 'PROVO', array[7], 13, 'WBC-2005', 6, 8),
    ('C-102', 'PROVO', array[7], 13, 'WBC-1602', 10, 14),
    -- board rental shop: fleet boards March to September, spares every other month
    ('C-103', 'PROVO', array[3, 4, 5, 6, 7, 8, 9], 12, 'WBC-2003', 4, 6),
    ('C-103', 'PROVO', array[3, 4, 5, 6, 7, 8, 9], 12, 'WBC-2004', 4, 6),
    ('C-103', 'PROVO', array[3, 5, 7, 9], 12, 'WBC-1202', 6, 8),
    ('C-103', 'PROVO', array[3, 5, 7, 9], 12, 'WBC-1301', 6, 8);

  -- What the planner expects to need per day, for each item and month.
  --   direct = store sales of the item itself
  --   daily  = direct + business orders + parts used to build boards
  -- (1.14 is the average of weekdays x 1.0 and weekends x 1.5.)
  create temp table wbc_hist_plan on commit drop as
  select hi.item_id, s.mon, hi.base * s.f * 1.14 as direct, hi.base * s.f * 1.14 as daily
  from wbc_hist_item hi
  join wbc_hist_season s on s.grp = hi.grp;

  update wbc_hist_plan p
  set daily = p.daily + x.per_day
  from (
    select hi.item_id, g.mon, sum((b.qmin + b.qmax) / 2.0) / 30 as per_day
    from wbc_hist_biz b
    join wbc_hist_item hi on hi.sku = b.sku
    cross join generate_series(1, 12) as g (mon)
    where b.mons is null or g.mon = any (b.mons)
    group by hi.item_id, g.mon
  ) x
  where x.item_id = p.item_id and x.mon = p.mon;

  update wbc_hist_plan p
  set daily = p.daily + x.dependent
  from (
    select b.component_item_id as item_id, pp.mon, sum(pp.daily * b.qty) as dependent
    from bom_lines b
    join wbc_hist_plan pp on pp.item_id = b.parent_item_id
    group by b.component_item_id, pp.mon
  ) x
  where x.item_id = p.item_id and x.mon = p.mon;

  -- Purchase orders on their way (arrival date and fill rate are decided
  -- when the PO is sent), and returns waiting for their day.
  create temp table wbc_hist_po_due (po_id bigint, arrive date, fill numeric) on commit drop;
  create temp table wbc_hist_returns (due date, order_id bigint, line_id bigint, item_id bigint,
                                      location_id bigint, unit_refund numeric, unit_cost numeric) on commit drop;

  -- ===================================================================
  -- 3. Opening balances: the first rows in the ledger
  -- ===================================================================
  v_when := (v_start + time '06:00') at time zone 'America/Denver';
  for r in
    select hi.item_id, hi.item_type, p.direct, p.daily, c.current_cost, l.id as location_id, l.code
    from wbc_hist_item hi
    join wbc_hist_plan p on p.item_id = hi.item_id and p.mon = 11
    join item_costs c on c.item_id = hi.item_id
    cross join locations l
    order by hi.item_type desc, hi.sku, l.id      -- parts first, then boards
  loop
    v_qty := case
      when r.location_id = v_orem and r.item_type = 'part' then greatest(20, ceil(r.daily * 40))
      when r.location_id = v_orem                          then greatest(6, ceil(r.daily * 12))
      when r.code = 'PROVO'                                then greatest(3, ceil(r.direct * 0.58 * 9))
      else                                                      greatest(3, ceil(r.direct * 0.42 * 9))
    end;
    perform wbc_post_movement(r.item_id, r.location_id, v_qty, r.current_cost,
                              'opening', null, null, null, 'Opening balance', v_when, true);
  end loop;

  -- ===================================================================
  -- 4. Replay the year, one day at a time
  -- ===================================================================
  v_day := v_start;
  loop
    v_day := v_day + 1;
    exit when v_day > v_end;
    v_mon := extract(month from v_day)::int;

    -- ---------------------------------------------------------------
    -- 4a. Purchase orders arriving today are received at the warehouse.
    --     Stock comes in at the PO price and the average cost is redone.
    -- ---------------------------------------------------------------
    for r in
      select due.po_id, due.fill, s.payment_terms_days
      from wbc_hist_po_due due
      join purchase_orders po on po.id = due.po_id
      join suppliers s on s.id = po.supplier_id
      where due.arrive = v_day
      order by due.po_id
    loop
      v_when := (v_day + time '12:00') at time zone 'America/Denver';
      insert into po_receipts (po_id, location_id, received_date, created_at)
      values (r.po_id, v_orem, v_day, v_when)
      returning id into v_id;

      for r2 in select id, item_id, qty_ordered, unit_cost
                from purchase_order_lines where po_id = r.po_id order by id
      loop
        v_qty := greatest(1, round(r2.qty_ordered * r.fill));
        insert into po_receipt_lines (receipt_id, po_line_id, qty_received) values (v_id, r2.id, v_qty);
        perform wbc_post_movement(r2.item_id, v_orem, v_qty, r2.unit_cost,
                                  'po_receipt', null, 'po_receipt', v_id,
                                  'PO-' || lpad(r.po_id::text, 5, '0'), v_when, true);
      end loop;

      -- Paid on the due date if that has already passed; otherwise still owed.
      update purchase_orders
      set received_date = v_day,
          status  = case when v_day + r.payment_terms_days <= v_end then 'closed' else 'received' end,
          paid_at = case when v_day + r.payment_terms_days <= v_end then v_day + r.payment_terms_days end
      where id = r.po_id;
    end loop;

    -- ---------------------------------------------------------------
    -- 4b. Customer returns that come back today.
    -- ---------------------------------------------------------------
    for r in select * from wbc_hist_returns where due = v_day order by order_id loop
      v_when := (v_day + time '11:00' + make_interval(mins => floor(random() * 420)::int))
                  at time zone 'America/Denver';
      v_reason := v_return_reasons[1 + floor(random() * array_length(v_return_reasons, 1))::int];
      select restock into v_restock from reason_codes where code = v_reason;

      insert into returns (order_id, location_id, return_date, return_type)
      values (r.order_id, r.location_id, v_when, 'refund')
      returning id into v_id;
      insert into return_lines (return_id, order_line_id, item_id, qty, reason_code, restocked, unit_refund, unit_cost)
      values (v_id, r.line_id, r.item_id, 1, v_reason, v_restock, r.unit_refund, r.unit_cost);

      -- Only sellable items go back on the shelf.
      if v_restock then
        perform wbc_post_movement(r.item_id, r.location_id, 1, r.unit_cost,
                                  'return', v_reason, 'return', v_id,
                                  'Return of SO-' || lpad(r.order_id::text, 5, '0'), v_when, true);
      end if;
    end loop;

    -- ---------------------------------------------------------------
    -- 4c. First of the month: a few stock count corrections.
    -- ---------------------------------------------------------------
    if extract(day from v_day) = 1 then
      v_when := (v_day + time '07:30') at time zone 'America/Denver';
      for r in select item_id, location_id from inventory_levels
               where qty_on_hand >= 5 order by random() limit 4
      loop
        perform wbc_post_movement(r.item_id, r.location_id, -(1 + floor(random() * 2))::numeric, null,
                                  'adjustment', v_adj_reasons[1 + floor(random() * 3)::int],
                                  null, null, 'Monthly stock count', v_when);
      end loop;
      for r in select item_id, location_id from inventory_levels
               where qty_on_hand >= 5 order by random() limit 1
      loop
        perform wbc_post_movement(r.item_id, r.location_id, 1, null,
                                  'adjustment', 'cycle_count', null, null, 'Monthly stock count', v_when);
      end loop;
    end if;

    -- ---------------------------------------------------------------
    -- 4d. Production (weekdays): build a board when total stock falls
    --     below 10 days of expected demand, up to 21 days' worth,
    --     limited by the parts on hand. Parts are issued, then the good
    --     boards are received at the cost of those parts.
    -- ---------------------------------------------------------------
    if extract(isodow from v_day) < 6 then
      v_clock := v_day + time '08:00';
      for r in
        select hi.item_id, p.daily
        from wbc_hist_item hi
        join wbc_hist_plan p on p.item_id = hi.item_id and p.mon = extract(month from v_day + 7)::int
        where hi.item_type = 'complete'
        order by hi.sku
      loop
        exit when v_clock::time > time '16:00' or v_clock::date > v_day;

        select coalesce(sum(qty_on_hand), 0) into v_have from inventory_levels where item_id = r.item_id;
        continue when v_have >= r.daily * 10;

        v_qty := least(30, greatest(4, ceil(r.daily * 21 - v_have)));
        select min(floor(coalesce(l.qty_on_hand, 0) / b.qty)) into v_pos
        from bom_lines b
        left join inventory_levels l on l.item_id = b.component_item_id and l.location_id = v_orem
        where b.parent_item_id = r.item_id;
        v_qty := least(v_qty, coalesce(v_pos, 0));
        continue when v_qty < 2;

        -- Quality: each board has a 3% chance of scrap and a 6% chance of rework.
        v_scrap := array[0, 0, 0, 0];
        v_rework := array[0, 0, 0, 0];
        for v_i in 1 .. v_qty::int loop
          v_roll := random();
          v_n := 1 + floor(random() * 4)::int;
          if v_roll < 0.03 then
            v_scrap[v_n] := v_scrap[v_n] + 1;
          elsif v_roll < 0.09 then
            v_rework[v_n] := v_rework[v_n] + 1;
          end if;
        end loop;
        v_scrapped := v_scrap[1] + v_scrap[2] + v_scrap[3] + v_scrap[4];
        v_reworked := v_rework[1] + v_rework[2] + v_rework[3] + v_rework[4];

        -- 9 to 14 minutes a board.
        v_finish := v_clock + make_interval(mins => ceil(v_qty * (9 + random() * 5))::int);

        insert into production_orders
          (item_id, location_id, status, qty_started, qty_good, qty_scrapped, qty_reworked,
           started_at, finished_at, created_at)
        values
          (r.item_id, v_orem, 'completed', v_qty, v_qty - v_scrapped, v_scrapped, v_reworked,
           v_clock at time zone 'America/Denver', v_finish at time zone 'America/Denver',
           v_clock at time zone 'America/Denver')
        returning id into v_id;

        v_total := 0;
        for r2 in select b.component_item_id, b.qty, i.avg_cost
                  from bom_lines b join items i on i.id = b.component_item_id
                  where b.parent_item_id = r.item_id order by b.component_item_id
        loop
          insert into production_order_components (production_order_id, item_id, qty_issued, unit_cost)
          values (v_id, r2.component_item_id, r2.qty * v_qty, r2.avg_cost);
          perform wbc_post_movement(r2.component_item_id, v_orem, -(r2.qty * v_qty), r2.avg_cost,
                                    'production_issue', null, 'production_order', v_id,
                                    'MO-' || lpad(v_id::text, 5, '0'), v_clock at time zone 'America/Denver');
          v_total := v_total + r2.qty * v_qty * r2.avg_cost;
        end loop;

        for v_i in 1 .. 4 loop
          if v_scrap[v_i] > 0 then
            insert into production_scrap (production_order_id, qty, reason_code, disposition)
            values (v_id, v_scrap[v_i], v_reasons[v_i], 'scrap');
          end if;
          if v_rework[v_i] > 0 then
            insert into production_scrap (production_order_id, qty, reason_code, disposition)
            values (v_id, v_rework[v_i], v_reasons[v_i], 'rework');
          end if;
        end loop;

        if v_qty - v_scrapped > 0 then
          perform wbc_post_movement(r.item_id, v_orem, v_qty - v_scrapped, round(v_total / v_qty, 4),
                                    'production_receipt', null, 'production_order', v_id,
                                    'MO-' || lpad(v_id::text, 5, '0'), v_finish at time zone 'America/Denver', true);
        end if;

        v_clock := v_finish + interval '20 minutes';
      end loop;
    end if;

    -- The day's selling conditions.
    v_weekend := case when extract(isodow from v_day) >= 6 then 1.5 else 1.0 end;
    v_provo   := case when v_mon in (9, 10, 11, 12, 1, 2, 3, 4) then 0.58 else 0.45 end;
    v_bf := make_date(extract(year from v_day)::int, 11, 1);
    v_bf := v_bf + ((4 - extract(isodow from v_bf)::int + 7) % 7) + 22;   -- the day after the 4th Thursday
    v_event := 1.0; v_disc := 0;
    if v_day between v_bf and v_bf + 2 then
      v_event := 2.5; v_disc := 20;                                       -- Black Friday weekend
    elsif v_mon = 7 and extract(day from v_day) between 3 and 5 then
      v_event := 1.8; v_disc := 15;                                       -- July 4th sale
    elsif v_mon = 8 and extract(day from v_day) between 10 and 22 then
      v_event := 1.4; v_disc := 10;                                       -- back to school
    end if;

    -- ---------------------------------------------------------------
    -- 4e. Business sales orders due today. Stock is moved from the
    --     warehouse to the pickup store if the store is short, then the
    --     order is fulfilled and closed. Lines are cut to what exists.
    -- ---------------------------------------------------------------
    for st in
      select distinct b.customer_no, b.loc_code, c.id as customer_id, l.id as location_id
      from wbc_hist_biz b
      join customers c on c.customer_no = b.customer_no
      join locations l on l.code = b.loc_code
      where b.dom = extract(day from v_day)::int and (b.mons is null or v_mon = any (b.mons))
      order by b.customer_no
    loop
      insert into sales_orders
        (customer_id, location_id, channel, status, order_date, requested_date, fulfilled_at,
         discount_pct, tax_rate, created_at)
      values
        (st.customer_id, st.location_id, 'sales_order', 'closed',
         (v_day - 3 + time '14:00') at time zone 'America/Denver', v_day,
         (v_day + time '15:00') at time zone 'America/Denver',
         5, v_tax, (v_day - 3 + time '14:00') at time zone 'America/Denver')
      returning id into v_id;
      v_lines := 0;
      v_id2 := null;    -- the transfer, made only if one is needed

      for r in
        select i.id as item_id, i.price, b.qmin, b.qmax
        from wbc_hist_biz b
        join items i on i.sku = b.sku
        where b.customer_no = st.customer_no
          and b.dom = extract(day from v_day)::int and (b.mons is null or v_mon = any (b.mons))
        order by i.sku
      loop
        v_qty := r.qmin + floor(random() * (r.qmax - r.qmin + 1));
        select coalesce(sum(qty_on_hand), 0) into v_have
        from inventory_levels where item_id = r.item_id and location_id = st.location_id;

        if v_have < v_qty then
          select coalesce(sum(qty_on_hand), 0) into v_orem_have
          from inventory_levels where item_id = r.item_id and location_id = v_orem;
          v_pos := least(v_qty - v_have, v_orem_have);
          if v_pos > 0 then
            v_when := (v_day + time '13:00') at time zone 'America/Denver';
            if v_id2 is null then
              insert into transfers (from_location_id, to_location_id, transferred_at, note)
              values (v_orem, st.location_id, v_when, 'For SO-' || lpad(v_id::text, 5, '0'))
              returning id into v_id2;
            end if;
            insert into transfer_lines (transfer_id, item_id, qty) values (v_id2, r.item_id, v_pos);
            perform wbc_post_movement(r.item_id, v_orem, -v_pos, null, 'transfer_out', null,
                                      'transfer', v_id2, 'For SO-' || lpad(v_id::text, 5, '0'), v_when);
            perform wbc_post_movement(r.item_id, st.location_id, v_pos, null, 'transfer_in', null,
                                      'transfer', v_id2, 'For SO-' || lpad(v_id::text, 5, '0'), v_when);
            v_have := v_have + v_pos;
          end if;
        end if;

        v_qty := least(v_qty, v_have);
        continue when v_qty <= 0;
        select avg_cost into v_cost from items where id = r.item_id;
        insert into sales_order_lines (order_id, item_id, qty, qty_fulfilled, unit_price, unit_cost)
        values (v_id, r.item_id, v_qty, v_qty, r.price, v_cost);
        perform wbc_post_movement(r.item_id, st.location_id, -v_qty, v_cost, 'sale', null,
                                  'sales_order', v_id, 'SO-' || lpad(v_id::text, 5, '0'),
                                  (v_day + time '15:00') at time zone 'America/Denver');
        v_lines := v_lines + 1;
      end loop;

      if v_lines = 0 then
        delete from sales_orders where id = v_id;
      end if;
    end loop;

    -- ---------------------------------------------------------------
    -- 4f. Mondays and Thursdays: restock the stores from the warehouse
    --     up to about 9 days of expected sales. The warehouse keeps 5
    --     days of parts back for production.
    -- ---------------------------------------------------------------
    if extract(isodow from v_day) in (1, 4) then
      v_when := (v_day + time '07:00') at time zone 'America/Denver';
      for st in select id, code from locations where type = 'store' order by id loop
        v_share := case when st.code = 'PROVO' then v_provo else 1 - v_provo end;
        v_id := null;
        for r in
          select hi.item_id, hi.item_type, p.direct, p.daily
          from wbc_hist_item hi
          join wbc_hist_plan p on p.item_id = hi.item_id and p.mon = extract(month from v_day + 3)::int
          order by hi.sku
        loop
          v_target := greatest(case when r.item_type = 'complete' then 2 else 3 end,
                               ceil(r.direct * v_share * 9));
          select coalesce(sum(qty_on_hand), 0) into v_have
          from inventory_levels where item_id = r.item_id and location_id = st.id;
          continue when v_target - v_have < greatest(1, ceil(v_target * 0.3));

          select coalesce(sum(qty_on_hand), 0) into v_orem_have
          from inventory_levels where item_id = r.item_id and location_id = v_orem;
          v_qty := least(v_target - v_have,
                         v_orem_have - case when r.item_type = 'part' then ceil((r.daily - r.direct) * 5) else 0 end);
          continue when v_qty <= 0;

          if v_id is null then
            insert into transfers (from_location_id, to_location_id, transferred_at, note)
            values (v_orem, st.id, v_when, 'Store restock')
            returning id into v_id;
          end if;
          insert into transfer_lines (transfer_id, item_id, qty) values (v_id, r.item_id, v_qty);
          perform wbc_post_movement(r.item_id, v_orem, -v_qty, null, 'transfer_out', null,
                                    'transfer', v_id, 'Store restock', v_when);
          perform wbc_post_movement(r.item_id, st.id, v_qty, null, 'transfer_in', null,
                                    'transfer', v_id, 'Store restock', v_when);
        end loop;
      end loop;
    end if;

    -- ---------------------------------------------------------------
    -- 4g. Purchasing (weekdays): one PO per supplier for every part
    --     whose stock + on order has fallen to about (lead time + 10
    --     days) of expected use. Order about 30 days' worth.
    --     The supplier's delivery behaviour is decided here.
    -- ---------------------------------------------------------------
    if extract(isodow from v_day) < 6 then
      for st in select id, name, quoted_lead_time_days as lead from suppliers where is_active order by id loop
        v_id := null;
        for r in
          select i.id as item_id, i.standard_cost, p.daily
          from items i
          join wbc_hist_plan p on p.item_id = i.id and p.mon = extract(month from v_day + st.lead + 10)::int
          where i.supplier_id = st.id and i.item_type = 'part' and i.is_active
          order by i.sku
        loop
          select coalesce(sum(qty_on_hand), 0) into v_have from inventory_levels where item_id = r.item_id;
          select coalesce(sum(l.qty_ordered), 0) into v_pos
          from purchase_order_lines l join purchase_orders o on o.id = l.po_id
          where o.status = 'sent' and l.item_id = r.item_id;
          continue when v_have + v_pos > r.daily * (st.lead + 10);

          if v_id is null then
            insert into purchase_orders (supplier_id, status, sent_date, expected_date, created_at)
            values (st.id, 'sent', v_day, v_day + st.lead, (v_day + time '09:00') at time zone 'America/Denver')
            returning id into v_id;
          end if;
          -- Supplier prices drift a little (-3% to +5%), so average cost really moves.
          insert into purchase_order_lines (po_id, item_id, qty_ordered, unit_cost)
          values (v_id, r.item_id, greatest(10, ceil(r.daily * 30 / 5.0) * 5),
                  round((r.standard_cost * (0.97 + random() * 0.08))::numeric, 2));
        end loop;

        if v_id is not null then
          v_late := 0; v_fill := 1;
          if st.name like 'Timberline%' then                 -- often late, about 5 days
            v_late := case when random() < 0.15 then 0 else 2 + floor(random() * 7)::int end;
          elsif st.name like 'Urethane%' then                -- on time, ships about 88%
            v_fill := 0.80 + random() * 0.16;
          elsif st.name like 'GripLine%' then                -- occasionally a few days late
            v_late := case when random() < 0.25 then 1 + floor(random() * 4)::int else 0 end;
          elsif st.name like 'Beehive%' then                 -- excellent, sometimes a day early
            v_late := case when random() < 0.30 then -1 else 0 end;
          end if;
          insert into wbc_hist_po_due values (v_id, v_day + st.lead + v_late, v_fill);
        end if;
      end loop;
    end if;

    -- ---------------------------------------------------------------
    -- 4h. Store sales at the till. For each store and item:
    --       expected units = base x season x weekend x store share
    --                        x sale event x daily noise (+/-15%)
    --     Each unit is its own sale; if the shelf is empty the sale is lost.
    -- ---------------------------------------------------------------
    for st in select id, code from locations where type = 'store' order by id loop
      v_share := case when st.code = 'PROVO' then v_provo else 1 - v_provo end;
      for r in
        select hi.item_id, hi.item_type, hi.base * s.f as rate, i.price
        from wbc_hist_item hi
        join wbc_hist_season s on s.grp = hi.grp and s.mon = v_mon
        join items i on i.id = hi.item_id
        where i.price is not null
        order by hi.sku
      loop
        v_lam := r.rate * v_weekend * v_share * v_event * (0.85 + random() * 0.30);
        v_n := floor(v_lam)::int + case when random() < v_lam - floor(v_lam) then 1 else 0 end;

        for v_i in 1 .. v_n loop
          select coalesce(sum(qty_on_hand), 0) into v_have
          from inventory_levels where item_id = r.item_id and location_id = st.id;
          if v_have < 1 then
            v_lost := v_lost + (v_n - v_i + 1);
            exit;
          end if;

          -- Four sales in five are walk-ins; the rest are that store's regulars.
          v_customer := v_walkin;
          if random() < 0.2 then
            select id into v_customer from customers
            where customer_type = 'individual' and home_location_id = st.id
            order by random() limit 1;
            v_customer := coalesce(v_customer, v_walkin);
          end if;

          v_when := (v_day + time '10:00' + make_interval(mins => floor(random() * 540)::int))
                      at time zone 'America/Denver';
          insert into sales_orders
            (customer_id, location_id, channel, status, order_date, fulfilled_at, discount_pct, tax_rate, created_at)
          values (v_customer, st.id, 'pos', 'closed', v_when, v_when, v_disc, v_tax, v_when)
          returning id into v_id;

          -- Small parts are sometimes bought two at a time.
          v_qty := case when r.price <= 20 and v_have >= 2 and random() < 0.25 then 2 else 1 end;
          select avg_cost into v_cost from items where id = r.item_id;
          insert into sales_order_lines (order_id, item_id, qty, qty_fulfilled, unit_price, unit_cost)
          values (v_id, r.item_id, v_qty, v_qty, r.price, v_cost)
          returning id into v_line_id;
          perform wbc_post_movement(r.item_id, st.id, -v_qty, v_cost, 'sale', null,
                                    'sales_order', v_id, 'SO-' || lpad(v_id::text, 5, '0'), v_when);

          -- About 2.7% of sales come back 2 to 10 days later.
          if random() < 0.027 then
            insert into wbc_hist_returns
            values (v_day + 2 + floor(random() * 9)::int, v_id, v_line_id, r.item_id, st.id,
                    round(r.price * (1 - v_disc / 100), 2), v_cost);
          end if;

          -- One board buyer in five adds a skate tool or a helmet.
          if r.item_type = 'complete' and random() < 0.2 then
            v_sku := case when random() < 0.6 then 'WBC-1603' else 'WBC-1602' end;
            select i.id, i.price, i.avg_cost into r2
            from items i
            join inventory_levels l on l.item_id = i.id and l.location_id = st.id and l.qty_on_hand >= 1
            where i.sku = v_sku;
            if found then
              insert into sales_order_lines (order_id, item_id, qty, qty_fulfilled, unit_price, unit_cost)
              values (v_id, r2.id, 1, 1, r2.price, r2.avg_cost);
              perform wbc_post_movement(r2.id, st.id, -1, r2.avg_cost, 'sale', null,
                                        'sales_order', v_id, 'SO-' || lpad(v_id::text, 5, '0'), v_when);
            end if;
          end if;
        end loop;
      end loop;
    end loop;
  end loop;

  -- ===================================================================
  -- 5. A little open work, so the screens have something to act on today
  -- ===================================================================
  -- A planned production order (nothing issued yet).
  insert into production_orders (item_id, location_id, status, qty_started, note)
  select id, v_orem, 'planned', 12, 'Planned for next week' from items where sku = 'WBC-2004';

  -- Two sales orders waiting to be fulfilled. The second is larger than
  -- the store usually holds, so it shows up as a backorder.
  insert into sales_orders (customer_id, location_id, channel, status, requested_date, discount_pct, tax_rate)
  select c.id, l.id, 'sales_order', 'placed', wbc_today() + 3, 5, v_tax
  from customers c, locations l where c.customer_no = 'C-101' and l.code = 'SLC'
  returning id into v_id;
  insert into sales_order_lines (order_id, item_id, qty, unit_price)
  select v_id, id, 4, price from items where sku in ('WBC-2005', 'WBC-1602');

  insert into sales_orders (customer_id, location_id, channel, status, requested_date, discount_pct, tax_rate)
  select c.id, l.id, 'sales_order', 'placed', wbc_today() + 10, 5, v_tax
  from customers c, locations l where c.customer_no = 'C-103' and l.code = 'PROVO'
  returning id into v_id;
  insert into sales_order_lines (order_id, item_id, qty, unit_price)
  select v_id, id, 12, price from items where sku = 'WBC-2004';

  return 'History rebuilt from ' || v_start || ' to ' || v_end
      || '. Sales lost to empty shelves: ' || v_lost || ' units.';
end;
$$;

-- Nobody can run this from the website: only from the SQL Editor.
revoke execute on function public.wbc_generate_history(double precision) from public, anon, authenticated;

-- Build the history now.
select public.wbc_generate_history();

-- Result shown after running. ledger_mismatches must be 0.
select
  (select count(*) from public.sales_orders)                          as sales_orders,
  (select round(sum(revenue)) from public.sales_order_totals)         as revenue,
  (select count(*) from public.returns)                               as returns,
  (select count(*) from public.purchase_orders)                       as purchase_orders,
  (select count(*) from public.production_orders)                     as production_orders,
  (select count(*) from public.transfers)                             as transfers,
  (select count(*) from public.inventory_movements)                   as ledger_rows,
  (select round(sum(value)) from public.inventory_value)              as inventory_value,
  (select count(*) from public.ledger_check where not matches)        as ledger_mismatches;
