-- =====================================================================
-- Wasatch Board Co. ERP — 08: sales orders, backorders, returns, exchanges
-- Run AFTER file 07. Safe to run more than once.
-- (Sales orders reuse the sales_orders / sales_order_lines tables from 07.)
-- =====================================================================

-- ---------------------------------------------------------------------
-- returns: one row each time a customer brings something back.
--   return_type 'refund'   = money back
--   return_type 'exchange' = swapped for other items; exchange_order_id
--                            points at the new sale for the replacement
-- ---------------------------------------------------------------------
create table if not exists public.returns (
  id                 bigint generated always as identity primary key,
  order_id           bigint not null references public.sales_orders (id),
  location_id        bigint not null references public.locations (id),   -- where it was brought back
  return_date        timestamptz not null default now(),
  return_type        text not null default 'refund' check (return_type in ('refund', 'exchange')),
  exchange_order_id  bigint references public.sales_orders (id),
  note               text,
  created_by         uuid references auth.users (id) on delete set null
);

-- ---------------------------------------------------------------------
-- return_lines: what came back and why.
--   unit_refund = what the customer paid per unit (after discount, before tax)
--   unit_cost   = what the unit cost us when it was sold
--   restocked   = true if it went back into sellable stock; false for
--                 defective/damaged items, whose cost is written off
-- ---------------------------------------------------------------------
create table if not exists public.return_lines (
  id             bigint generated always as identity primary key,
  return_id      bigint not null references public.returns (id) on delete cascade,
  order_line_id  bigint not null references public.sales_order_lines (id),
  item_id        bigint not null references public.items (id),
  qty            numeric(12,2) not null check (qty > 0),
  reason_code    text not null references public.reason_codes (code),
  restocked      boolean not null,
  unit_refund    numeric(10,2) not null,
  unit_cost      numeric(12,4) not null
);

create index if not exists returns_order_idx          on public.returns (order_id);
create index if not exists return_lines_return_idx    on public.return_lines (return_id);
create index if not exists return_lines_orderline_idx on public.return_lines (order_line_id);

-- =====================================================================
-- Sales order functions
-- =====================================================================

-- create_sales_order: status "placed". Nothing leaves stock yet; the
-- order is a promise that MRP and the backorder list can see.
-- p_lines looks like [{"item_id": 21, "qty": 6}, ...]
create or replace function public.create_sales_order(
  p_customer_id     bigint,
  p_location_id     bigint,
  p_lines           jsonb,
  p_requested_date  date default null,
  p_discount_pct    numeric default 0,
  p_note            text default null
)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order_id  bigint;
  v_tax       numeric;
  v_line      record;
  v_price     numeric;
  v_count     integer := 0;
begin
  if not is_staff() then
    raise exception 'Only staff can create sales orders';
  end if;
  if not exists (select 1 from customers where id = p_customer_id) then
    raise exception 'Choose a customer';
  end if;
  if not exists (select 1 from locations where id = p_location_id) then
    raise exception 'Choose a location';
  end if;
  if coalesce(p_discount_pct, 0) < 0 or coalesce(p_discount_pct, 0) > 100 then
    raise exception 'Discount must be between 0 and 100 percent';
  end if;
  if p_requested_date is not null and p_requested_date < wbc_today() then
    raise exception 'The requested date cannot be in the past';
  end if;

  select value into v_tax from settings where key = 'tax_rate';
  if v_tax is null then
    raise exception 'The tax_rate setting is missing';
  end if;

  insert into sales_orders
    (customer_id, location_id, channel, status, requested_date, discount_pct, tax_rate, note, created_by)
  values
    (p_customer_id, p_location_id, 'sales_order', 'placed', coalesce(p_requested_date, wbc_today()),
     coalesce(p_discount_pct, 0), v_tax, p_note, auth.uid())
  returning id into v_order_id;

  for v_line in
    select x.item_id, sum(x.qty) as qty
    from jsonb_to_recordset(coalesce(p_lines, '[]'::jsonb)) as x (item_id bigint, qty numeric)
    group by x.item_id
  loop
    if v_line.qty is null or v_line.qty <= 0 or v_line.qty <> trunc(v_line.qty) then
      raise exception 'Every line needs a whole quantity above zero';
    end if;
    select price into v_price
    from items
    where id = v_line.item_id and item_type in ('part', 'complete') and is_active;
    if not found or v_price is null then
      raise exception 'Item % cannot be sold', v_line.item_id;
    end if;

    insert into sales_order_lines (order_id, item_id, qty, qty_fulfilled, unit_price)
    values (v_order_id, v_line.item_id, v_line.qty, 0, v_price);
    v_count := v_count + 1;
  end loop;

  if v_count = 0 then
    raise exception 'Add at least one item to the order';
  end if;
  return v_order_id;
end;
$$;

-- fulfill_sales_order: hand over whatever is in stock at the order's
-- location. For each line it ships min(still open, on hand), writes the
-- - ledger row and records the cost (COGS). Anything it cannot ship stays
-- open as a backorder; when every line is complete the order becomes
-- "fulfilled". Returns the number of units shipped.
create or replace function public.fulfill_sales_order(p_order_id bigint)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  v_status    text;
  v_location  bigint;
  v_line      record;
  v_avail     numeric;
  v_ship      numeric;
  v_cost      numeric;
  v_total     numeric := 0;
begin
  if not is_staff() then
    raise exception 'Only staff can fulfil sales orders';
  end if;

  select status, location_id into v_status, v_location
  from sales_orders where id = p_order_id for update;
  if not found then
    raise exception 'Sales order not found';
  end if;
  if v_status <> 'placed' then
    raise exception 'Only an order with status Order Placed can be fulfilled';
  end if;

  for v_line in
    select id, item_id, qty, qty_fulfilled
    from sales_order_lines
    where order_id = p_order_id and qty > qty_fulfilled
    order by id
  loop
    v_avail := null;
    select qty_on_hand into v_avail
    from inventory_levels
    where item_id = v_line.item_id and location_id = v_location
    for update;

    v_ship := least(v_line.qty - v_line.qty_fulfilled, floor(coalesce(v_avail, 0)));

    if v_ship > 0 then
      select avg_cost into v_cost from items where id = v_line.item_id;

      -- If a line is shipped in two parts at two costs, keep the blended cost.
      update sales_order_lines
      set unit_cost = round((qty_fulfilled * coalesce(unit_cost, 0) + v_ship * v_cost)
                            / (qty_fulfilled + v_ship), 4),
          qty_fulfilled = qty_fulfilled + v_ship
      where id = v_line.id;

      perform wbc_post_movement(
        v_line.item_id, v_location, -v_ship, v_cost,
        'sale', null, 'sales_order', p_order_id,
        'SO-' || lpad(p_order_id::text, 5, '0'));

      v_total := v_total + v_ship;
    end if;
  end loop;

  if v_total = 0 then
    raise exception 'Nothing on this order is in stock at this location yet';
  end if;

  if not exists (select 1 from sales_order_lines
                 where order_id = p_order_id and qty > qty_fulfilled) then
    update sales_orders set status = 'fulfilled', fulfilled_at = now() where id = p_order_id;
  end if;

  return v_total;
end;
$$;

-- close_sales_order: fulfilled -> closed (the customer has collected and paid).
create or replace function public.close_sales_order(p_order_id bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_status text;
begin
  if not is_staff() then
    raise exception 'Only staff can close sales orders';
  end if;
  select status into v_status from sales_orders where id = p_order_id for update;
  if not found then
    raise exception 'Sales order not found';
  end if;
  if v_status <> 'fulfilled' then
    raise exception 'Only a fulfilled order can be closed';
  end if;
  update sales_orders set status = 'closed' where id = p_order_id;
end;
$$;

-- cancel_sales_order: for an order that is still "placed".
--   nothing shipped yet -> the whole order becomes "cancelled"
--   partly shipped      -> the unshipped part is dropped and the order
--                          becomes "fulfilled" for what did ship
-- Returns the new status.
create or replace function public.cancel_sales_order(p_order_id bigint)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_status text;
begin
  if not is_staff() then
    raise exception 'Only staff can cancel sales orders';
  end if;
  select status into v_status from sales_orders where id = p_order_id for update;
  if not found then
    raise exception 'Sales order not found';
  end if;
  if v_status <> 'placed' then
    raise exception 'Only an order with status Order Placed can be cancelled';
  end if;

  if exists (select 1 from sales_order_lines where order_id = p_order_id and qty_fulfilled > 0) then
    delete from sales_order_lines where order_id = p_order_id and qty_fulfilled = 0;
    update sales_order_lines set qty = qty_fulfilled where order_id = p_order_id;
    update sales_orders
    set status = 'fulfilled', fulfilled_at = now(),
        note = concat_ws(' · ', note, 'Unshipped items cancelled')
    where id = p_order_id;
    return 'fulfilled';
  end if;

  update sales_orders set status = 'cancelled' where id = p_order_id;
  return 'cancelled';
end;
$$;

-- =====================================================================
-- post_return: a return, or an exchange, in one transaction.
-- p_lines          [{"line_id": 44, "qty": 1, "reason_code": "wrong_size"}, ...]
-- p_exchange_lines [{"item_id": 2, "qty": 1}, ...]   (leave empty for a refund)
-- For every returned line it:
--   1. checks the quantity was really sold and not already returned,
--   2. records the refund amount and the original cost,
--   3. if the reason allows restocking, puts the unit back in stock at
--      its original cost (a + ledger row); otherwise nothing returns to
--      stock and the cost is written off.
-- For an exchange it then rings up the replacement items as a new sale.
-- Returns the return id.
-- =====================================================================
create or replace function public.post_return(
  p_order_id        bigint,
  p_location_id     bigint,
  p_lines           jsonb,
  p_exchange_lines  jsonb default null,
  p_note            text default null
)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order        record;
  v_return_id    bigint;
  v_line         record;
  v_sold         record;
  v_restock      boolean;
  v_returned     numeric;
  v_exchange_id  bigint;
  v_count        integer := 0;
begin
  if not is_staff() then
    raise exception 'Only staff can process returns';
  end if;

  select id, customer_id, status, discount_pct into v_order
  from sales_orders where id = p_order_id for update;
  if not found then
    raise exception 'Sale not found';
  end if;
  if v_order.status = 'cancelled' then
    raise exception 'A cancelled order has nothing to return';
  end if;
  if not exists (select 1 from locations where id = p_location_id) then
    raise exception 'Choose the location the items came back to';
  end if;

  insert into returns (order_id, location_id, note, created_by)
  values (p_order_id, p_location_id, p_note, auth.uid())
  returning id into v_return_id;

  for v_line in
    select x.line_id, x.qty, x.reason_code
    from jsonb_to_recordset(coalesce(p_lines, '[]'::jsonb))
           as x (line_id bigint, qty numeric, reason_code text)
    where coalesce(x.qty, 0) <> 0
  loop
    if v_line.qty <= 0 or v_line.qty <> trunc(v_line.qty) then
      raise exception 'Every returned quantity must be a whole number above zero';
    end if;

    select restock into v_restock
    from reason_codes
    where code = v_line.reason_code and kind = 'return' and is_active;
    if not found then
      raise exception 'Choose a return reason for every line';
    end if;

    select l.id, l.item_id, l.qty_fulfilled, l.unit_price, coalesce(l.unit_cost, 0) as unit_cost
    into v_sold
    from sales_order_lines l
    where l.id = v_line.line_id and l.order_id = p_order_id;
    if not found then
      raise exception 'Line % is not on this sale', v_line.line_id;
    end if;

    select coalesce(sum(rl.qty), 0) into v_returned
    from return_lines rl where rl.order_line_id = v_sold.id;
    if v_line.qty > v_sold.qty_fulfilled - v_returned then
      raise exception 'Only % of % can still be returned',
        v_sold.qty_fulfilled - v_returned, (select sku from items where id = v_sold.item_id);
    end if;

    insert into return_lines
      (return_id, order_line_id, item_id, qty, reason_code, restocked, unit_refund, unit_cost)
    values
      (v_return_id, v_sold.id, v_sold.item_id, v_line.qty, v_line.reason_code, v_restock,
       round(v_sold.unit_price * (1 - v_order.discount_pct / 100), 2), v_sold.unit_cost);

    if v_restock then
      perform wbc_post_movement(
        v_sold.item_id, p_location_id, v_line.qty, v_sold.unit_cost,
        'return', v_line.reason_code, 'return', v_return_id,
        'Return of SO-' || lpad(p_order_id::text, 5, '0'), now(), true);
    end if;

    v_count := v_count + 1;
  end loop;

  if v_count = 0 then
    raise exception 'Enter a quantity to return on at least one line';
  end if;

  if p_exchange_lines is not null and jsonb_typeof(p_exchange_lines) = 'array'
     and jsonb_array_length(p_exchange_lines) > 0 then
    v_exchange_id := post_pos_sale(
      p_location_id, v_order.customer_id, p_exchange_lines, 0,
      'Exchange for SO-' || lpad(p_order_id::text, 5, '0'));
    update returns
    set return_type = 'exchange', exchange_order_id = v_exchange_id
    where id = v_return_id;
  end if;

  return v_return_id;
end;
$$;

revoke execute on function public.create_sales_order(bigint, bigint, jsonb, date, numeric, text) from public, anon;
revoke execute on function public.fulfill_sales_order(bigint) from public, anon;
revoke execute on function public.close_sales_order(bigint) from public, anon;
revoke execute on function public.cancel_sales_order(bigint) from public, anon;
revoke execute on function public.post_return(bigint, bigint, jsonb, jsonb, text) from public, anon;
grant execute on function public.create_sales_order(bigint, bigint, jsonb, date, numeric, text) to authenticated;
grant execute on function public.fulfill_sales_order(bigint) to authenticated;
grant execute on function public.close_sales_order(bigint) to authenticated;
grant execute on function public.cancel_sales_order(bigint) to authenticated;
grant execute on function public.post_return(bigint, bigint, jsonb, jsonb, text) to authenticated;

-- =====================================================================
-- Views (calculated, never stored)
-- =====================================================================

-- open_order_lines: every line still waiting on a placed order, with
-- whether it can be filled and an estimated available date.
--   ready    = enough in stock at the order's location          -> today
--   transfer = enough in the company, but at another location    -> tomorrow
--   on_order = a part with an open PO                             -> that PO's expected date
--   reorder  = a part with no open PO                             -> today + supplier lead time
--   build    = a complete board that must be assembled            -> tomorrow, plus the longest
--              lead time among components the warehouse is short of
-- A line that is not "ready" is a BACKORDER.
create or replace view public.open_order_lines
with (security_invoker = true) as
select
  l.id as line_id,
  l.order_id,
  o.customer_id,
  c.name as customer_name,
  o.location_id,
  o.requested_date,
  l.item_id,
  l.qty - l.qty_fulfilled       as qty_open,
  coalesce(here.qty_on_hand, 0) as on_hand_here,
  coalesce(everywhere.qty, 0)   as on_hand_all,
  case
    when coalesce(here.qty_on_hand, 0) >= l.qty - l.qty_fulfilled then 'ready'
    when coalesce(everywhere.qty, 0)   >= l.qty - l.qty_fulfilled then 'transfer'
    when i.item_type = 'part' and po.next_po_date is not null     then 'on_order'
    when i.item_type = 'part'                                     then 'reorder'
    else 'build'
  end as availability,
  case
    when coalesce(here.qty_on_hand, 0) >= l.qty - l.qty_fulfilled then public.wbc_today()
    when coalesce(everywhere.qty, 0)   >= l.qty - l.qty_fulfilled then public.wbc_today() + 1
    when i.item_type = 'part' and po.next_po_date is not null
      then greatest(po.next_po_date, public.wbc_today())
    when i.item_type = 'part'
      then public.wbc_today() + coalesce(i.lead_time_days, 0)
    else public.wbc_today() + 1 + coalesce(comp.longest_lead, 0)
  end as est_available_date
from public.sales_order_lines l
join public.sales_orders o on o.id = l.order_id
join public.customers c on c.id = o.customer_id
join public.items i on i.id = l.item_id
left join public.inventory_levels here
  on here.item_id = l.item_id and here.location_id = o.location_id
left join lateral (
  select sum(x.qty_on_hand) as qty
  from public.inventory_levels x
  where x.item_id = l.item_id
) everywhere on true
left join lateral (
  select min(p.expected_date) as next_po_date
  from public.po_line_status s
  join public.purchase_orders p on p.id = s.po_id
  where s.item_id = l.item_id and s.qty_open > 0
) po on true
left join lateral (
  select max(ci.lead_time_days) as longest_lead
  from public.bom_lines b
  join public.items ci on ci.id = b.component_item_id
  left join public.inventory_levels w
    on w.item_id = ci.id
   and w.location_id = (select id from public.locations where type = 'warehouse' order by id limit 1)
  where b.parent_item_id = l.item_id
    and coalesce(w.qty_on_hand, 0) < b.qty * (l.qty - l.qty_fulfilled)
) comp on true
where o.status = 'placed' and l.qty > l.qty_fulfilled;

-- return_line_totals: the money on each returned line.
--   refund_net    = revenue given back (before tax)
--   cogs_reversed = the cost taken back off cost of goods sold
--   write_off     = that same cost, when the item could NOT be restocked
--                   (it becomes a quality loss on the P&L)
create or replace view public.return_line_totals
with (security_invoker = true) as
select
  rl.id as return_line_id,
  rl.return_id,
  rl.order_line_id,
  rl.item_id,
  rl.qty,
  rl.reason_code,
  rl.restocked,
  rl.unit_refund,
  rl.unit_cost,
  round(rl.qty * rl.unit_refund, 2) as refund_net,
  round(rl.qty * rl.unit_cost, 2)   as cogs_reversed,
  case when rl.restocked then 0 else round(rl.qty * rl.unit_cost, 2) end as write_off
from public.return_lines rl;

-- return_totals: one row per return.
--   refund_total   = refund_net + the sales tax on it
--   exchange_total = what the replacement items cost the customer
--   balance_due    = exchange_total - refund_total
--                    (positive: customer pays; negative: customer gets money back)
create or replace view public.return_totals
with (security_invoker = true) as
select
  r.id as return_id,
  r.order_id,
  o.customer_id,
  c.name as customer_name,
  r.location_id,
  r.return_date,
  r.return_type,
  r.exchange_order_id,
  r.note,
  coalesce(t.units, 0)         as units,
  coalesce(t.refund_net, 0)    as refund_net,
  round(coalesce(t.refund_net, 0) * o.tax_rate, 2)                             as refund_tax,
  coalesce(t.refund_net, 0) + round(coalesce(t.refund_net, 0) * o.tax_rate, 2) as refund_total,
  coalesce(t.cogs_reversed, 0) as cogs_reversed,
  coalesce(t.write_off, 0)     as write_off,
  coalesce(x.total, 0)         as exchange_total,
  coalesce(x.total, 0)
    - (coalesce(t.refund_net, 0) + round(coalesce(t.refund_net, 0) * o.tax_rate, 2)) as balance_due
from public.returns r
join public.sales_orders o on o.id = r.order_id
join public.customers c on c.id = o.customer_id
left join (
  select return_id,
         sum(qty)           as units,
         sum(refund_net)    as refund_net,
         sum(cogs_reversed) as cogs_reversed,
         sum(write_off)     as write_off
  from public.return_line_totals
  group by return_id
) t on t.return_id = r.id
left join public.sales_order_totals x on x.order_id = r.exchange_order_id;

-- =====================================================================
-- Security: staff can read; all writes go through the functions above.
-- =====================================================================
alter table public.returns      enable row level security;
alter table public.return_lines enable row level security;

do $$
declare
  t text;
begin
  foreach t in array array['returns', 'return_lines'] loop
    execute format('drop policy if exists staff_read on public.%I', t);
    execute format(
      'create policy staff_read on public.%I for select to authenticated using (public.is_staff())', t);
    execute format('revoke insert, update, delete on public.%I from anon, authenticated', t);
  end loop;
end;
$$;

-- Result shown after running: the 2 new tables.
select table_name
from information_schema.tables
where table_schema = 'public'
  and table_name in ('returns', 'return_lines')
order by table_name;
