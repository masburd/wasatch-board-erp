-- =====================================================================
-- Wasatch Board Co. ERP — 07: sales tables and the point of sale
-- Run AFTER file 06. Safe to run more than once.
-- =====================================================================

-- ---------------------------------------------------------------------
-- sales_orders: one row per sale, whatever the channel.
--   channel 'pos'         = sold at the till: placed, fulfilled and closed in one step
--   channel 'sales_order' = entered by staff for a customer (build step 6)
--   channel 'portal'      = placed by a customer online (build step 11)
-- discount_pct and tax_rate are copied onto the order when it is made,
-- so changing the tax setting later does not rewrite old sales.
-- ---------------------------------------------------------------------
create table if not exists public.sales_orders (
  id              bigint generated always as identity primary key,
  customer_id     bigint not null references public.customers (id),
  location_id     bigint not null references public.locations (id),
  channel         text not null check (channel in ('pos', 'sales_order', 'portal')),
  status          text not null default 'placed'
                    check (status in ('placed', 'fulfilled', 'closed', 'cancelled')),
  order_date      timestamptz not null default now(),
  requested_date  date,
  fulfilled_at    timestamptz,
  discount_pct    numeric(5,2) not null default 0 check (discount_pct >= 0 and discount_pct <= 100),
  tax_rate        numeric(6,4) not null check (tax_rate >= 0),
  note            text,
  created_by      uuid references auth.users (id) on delete set null,
  created_at      timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- sales_order_lines: what was sold.
--   unit_price = the item's price at the moment of sale
--   unit_cost  = the item's weighted average cost at the moment the
--                stock left. This is what makes cost of goods sold (COGS).
--   qty_fulfilled = how many have actually been handed over
-- ---------------------------------------------------------------------
create table if not exists public.sales_order_lines (
  id             bigint generated always as identity primary key,
  order_id       bigint not null references public.sales_orders (id) on delete cascade,
  item_id        bigint not null references public.items (id),
  qty            numeric(12,2) not null check (qty > 0),
  qty_fulfilled  numeric(12,2) not null default 0 check (qty_fulfilled >= 0),
  unit_price     numeric(10,2) not null check (unit_price >= 0),
  unit_cost      numeric(12,4),
  check (qty_fulfilled <= qty)
);

create index if not exists sales_orders_date_idx      on public.sales_orders (order_date);
create index if not exists sales_orders_location_idx  on public.sales_orders (location_id);
create index if not exists sales_order_lines_order_idx on public.sales_order_lines (order_id);
create index if not exists sales_order_lines_item_idx  on public.sales_order_lines (item_id);

-- =====================================================================
-- post_pos_sale: the whole till sale in one transaction.
-- p_lines looks like [{"item_id": 3, "qty": 1}, {"item_id": 21, "qty": 2}]
--   1. creates the order (already closed) and its lines,
--   2. takes the price from the items table (never from the browser),
--   3. copies each item's average cost onto the line (COGS),
--   4. writes a - row to the inventory ledger at that location.
-- If any item is short of stock, the whole sale is refused.
-- Returns the order id.
-- =====================================================================
create or replace function public.post_pos_sale(
  p_location_id   bigint,
  p_customer_id   bigint,
  p_lines         jsonb,
  p_discount_pct  numeric default 0,
  p_note          text default null
)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order_id  bigint;
  v_customer  bigint;
  v_tax       numeric;
  v_line      record;
  v_price     numeric;
  v_cost      numeric;
  v_count     integer := 0;
begin
  if not is_staff() then
    raise exception 'Only staff can ring up a sale';
  end if;
  if not exists (select 1 from locations where id = p_location_id) then
    raise exception 'Choose a location';
  end if;
  if coalesce(p_discount_pct, 0) < 0 or coalesce(p_discount_pct, 0) > 100 then
    raise exception 'Discount must be between 0 and 100 percent';
  end if;

  select value into v_tax from settings where key = 'tax_rate';
  if v_tax is null then
    raise exception 'The tax_rate setting is missing';
  end if;

  -- No customer chosen means the generic Walk-in Customer.
  v_customer := coalesce(
    p_customer_id,
    (select id from customers where customer_type = 'walk_in' order by id limit 1));
  if v_customer is null or not exists (select 1 from customers where id = v_customer) then
    raise exception 'Choose a customer';
  end if;

  insert into sales_orders
    (customer_id, location_id, channel, status, order_date, fulfilled_at,
     discount_pct, tax_rate, note, created_by)
  values
    (v_customer, p_location_id, 'pos', 'closed', now(), now(),
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

    select price, avg_cost into v_price, v_cost
    from items
    where id = v_line.item_id and item_type in ('part', 'complete') and is_active;
    if not found or v_price is null then
      raise exception 'Item % cannot be sold at the till', v_line.item_id;
    end if;

    insert into sales_order_lines (order_id, item_id, qty, qty_fulfilled, unit_price, unit_cost)
    values (v_order_id, v_line.item_id, v_line.qty, v_line.qty, v_price, v_cost);

    perform wbc_post_movement(
      v_line.item_id, p_location_id, -v_line.qty, v_cost,
      'sale', null, 'sales_order', v_order_id,
      'SO-' || lpad(v_order_id::text, 5, '0'));

    v_count := v_count + 1;
  end loop;

  if v_count = 0 then
    raise exception 'Add at least one item to the sale';
  end if;
  return v_order_id;
end;
$$;

revoke execute on function public.post_pos_sale(bigint, bigint, jsonb, numeric, text) from public, anon;
grant execute on function public.post_pos_sale(bigint, bigint, jsonb, numeric, text) to authenticated;

-- =====================================================================
-- Views (calculated, never stored)
-- =====================================================================

-- sales_line_totals: the money on each line.
--   line_gross = qty x price                      (before discount)
--   line_net   = line_gross less the order discount   (what the receipt shows)
--   revenue    = the same, but only for units actually handed over
--   cogs       = units handed over x their cost
create or replace view public.sales_line_totals
with (security_invoker = true) as
select
  l.id as line_id,
  l.order_id,
  l.item_id,
  l.qty,
  l.qty_fulfilled,
  l.unit_price,
  l.unit_cost,
  o.discount_pct,
  round(l.qty * l.unit_price, 2)                                        as line_gross,
  round(l.qty * l.unit_price * (1 - o.discount_pct / 100), 2)           as line_net,
  round(l.qty_fulfilled * l.unit_price * (1 - o.discount_pct / 100), 2) as revenue,
  round(l.qty_fulfilled * coalesce(l.unit_cost, 0), 2)                  as cogs
from public.sales_order_lines l
join public.sales_orders o on o.id = l.order_id;

-- sales_order_totals: one row per order with its totals.
--   net   = subtotal after discount
--   tax   = net x the order's tax rate (tax is collected, it is not revenue)
--   total = what the customer pays
create or replace view public.sales_order_totals
with (security_invoker = true) as
select
  o.id as order_id,
  o.customer_id,
  c.name as customer_name,
  o.location_id,
  o.channel,
  o.status,
  o.order_date,
  o.requested_date,
  o.fulfilled_at,
  o.discount_pct,
  o.tax_rate,
  o.note,
  o.created_by,
  coalesce(t.units, 0)                                as units,
  coalesce(t.gross, 0)                                as gross,
  coalesce(t.gross, 0) - coalesce(t.net, 0)           as discount_amount,
  coalesce(t.net, 0)                                  as net,
  round(coalesce(t.net, 0) * o.tax_rate, 2)           as tax,
  coalesce(t.net, 0) + round(coalesce(t.net, 0) * o.tax_rate, 2) as total,
  coalesce(t.revenue, 0)                              as revenue,
  coalesce(t.cogs, 0)                                 as cogs
from public.sales_orders o
join public.customers c on c.id = o.customer_id
left join (
  select order_id,
         sum(qty)        as units,
         sum(line_gross) as gross,
         sum(line_net)   as net,
         sum(revenue)    as revenue,
         sum(cogs)       as cogs
  from public.sales_line_totals
  group by order_id
) t on t.order_id = o.id;

-- =====================================================================
-- Security: staff can read; all writes go through functions.
-- (Customers reading their own orders is added with the portal, step 11.)
-- =====================================================================
alter table public.sales_orders      enable row level security;
alter table public.sales_order_lines enable row level security;

do $$
declare
  t text;
begin
  foreach t in array array['sales_orders', 'sales_order_lines'] loop
    execute format('drop policy if exists staff_read on public.%I', t);
    execute format(
      'create policy staff_read on public.%I for select to authenticated using (public.is_staff())', t);
    execute format('revoke insert, update, delete on public.%I from anon, authenticated', t);
  end loop;
end;
$$;

-- Realtime on sales orders.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'sales_orders'
  ) then
    alter publication supabase_realtime add table public.sales_orders;
  end if;
end;
$$;

-- Result shown after running: the 2 new tables.
select table_name
from information_schema.tables
where table_schema = 'public'
  and table_name in ('sales_orders', 'sales_order_lines')
order by table_name;
