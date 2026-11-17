-- =====================================================================
-- Wasatch Board Co. ERP — 14: customer portal and Build Your Own Board
-- Run AFTER file 13 (and after re-running files 11 and 13, which were
-- changed for this step). Safe to run more than once. Adds no tables.
--
-- How customers are kept away from staff data:
--   * Customers cannot read items, costs, orders or settings directly.
--   * Everything the portal shows comes from the "portal_" functions
--     below, which return only safe columns (never a cost) and only the
--     signed-in customer's own orders.
--   * The one table customers may read is inventory_levels (a quantity
--     per item per location, nothing secret), so stock can update live.
-- =====================================================================

-- Customer numbers for people who sign up themselves: P-001, P-002, ...
create sequence if not exists public.portal_customer_seq start 1;

-- Any signed-in user may read stock quantities.
drop policy if exists customer_read on public.inventory_levels;
create policy customer_read on public.inventory_levels
  for select to authenticated using (true);

-- ---------------------------------------------------------------------
-- portal_register: called once after a customer signs up. Creates their
-- customer record and links it to their login. Returns the customer id.
-- ---------------------------------------------------------------------
create or replace function public.portal_register(
  p_name              text,
  p_phone             text default null,
  p_home_location_id  bigint default null
)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id     bigint;
  v_email  text;
begin
  if auth.uid() is null then
    raise exception 'Sign in first';
  end if;
  select id into v_id from customers where auth_user_id = auth.uid();
  if v_id is not null then
    return v_id;                      -- already registered
  end if;
  if coalesce(trim(p_name), '') = '' then
    raise exception 'Enter your name';
  end if;
  if p_home_location_id is not null
     and not exists (select 1 from locations where id = p_home_location_id and type = 'store') then
    raise exception 'Choose a store';
  end if;

  select email into v_email from profiles where id = auth.uid();

  insert into customers (customer_no, name, customer_type, email, phone, home_location_id, auth_user_id)
  values ('P-' || lpad(nextval('portal_customer_seq')::text, 3, '0'),
          trim(p_name), 'individual', v_email, nullif(trim(p_phone), ''), p_home_location_id, auth.uid())
  returning id into v_id;

  update profiles set full_name = trim(p_name) where id = auth.uid() and full_name is null;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- portal_setup: everything the portal needs that does not change from
-- minute to minute, in one answer:
--   tax_rate, assembly_fee, the locations, the items for sale (with
--   price, never cost), and the Build Your Own Board rules.
-- ---------------------------------------------------------------------
create or replace function public.portal_setup()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'tax_rate',     (select value from settings where key = 'tax_rate'),
    'assembly_fee', (select value from settings where key = 'assembly_fee'),
    'locations',    (select jsonb_agg(jsonb_build_object(
                        'id', l.id, 'code', l.code, 'name', l.name, 'type', l.type) order by l.id)
                     from locations l),
    'items',        (select jsonb_agg(jsonb_build_object(
                        'id', i.id, 'sku', i.sku, 'name', i.name, 'item_type', i.item_type,
                        'category', i.category, 'price', i.price) order by i.sku)
                     from items i
                     where i.is_active and i.item_type in ('part', 'complete') and i.price is not null),
    'build_options', (select jsonb_agg(jsonb_build_object(
                        'deck_item_id', b.deck_item_id, 'slot', b.slot, 'item_id', b.item_id))
                      from build_options b),
    'build_auto_adds', (select jsonb_agg(jsonb_build_object(
                        'deck_item_id', a.deck_item_id, 'wheel_item_id', a.wheel_item_id, 'item_id', a.item_id))
                      from build_auto_adds a)
  );
$$;

-- ---------------------------------------------------------------------
-- portal_place_order: a customer orders stock items for store pickup.
-- p_lines looks like [{"item_id": 3, "qty": 1}, ...]
-- The order is created as "placed" with prices read from the items
-- table. No stock moves until staff fulfil it on the Sales Orders page.
-- Returns the order id.
-- ---------------------------------------------------------------------
create or replace function public.portal_place_order(
  p_location_id     bigint,
  p_lines           jsonb,
  p_requested_date  date default null,
  p_note            text default null
)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_customer  bigint;
  v_order_id  bigint;
  v_tax       numeric;
  v_line      record;
  v_price     numeric;
  v_count     integer := 0;
begin
  select id into v_customer from customers where auth_user_id = auth.uid();
  if v_customer is null then
    raise exception 'Finish setting up your customer account first';
  end if;
  if not exists (select 1 from locations where id = p_location_id and type = 'store') then
    raise exception 'Choose a store to pick up from';
  end if;
  if p_requested_date is not null and p_requested_date < wbc_today() then
    raise exception 'The pickup date cannot be in the past';
  end if;
  select value into v_tax from settings where key = 'tax_rate';

  insert into sales_orders
    (customer_id, location_id, channel, status, requested_date, discount_pct, tax_rate, note, created_by)
  values
    (v_customer, p_location_id, 'portal', 'placed', p_requested_date, 0, v_tax,
     nullif(trim(p_note), ''), auth.uid())
  returning id into v_order_id;

  for v_line in
    select x.item_id, sum(x.qty) as qty
    from jsonb_to_recordset(coalesce(p_lines, '[]'::jsonb)) as x (item_id bigint, qty numeric)
    group by x.item_id
  loop
    if v_line.qty is null or v_line.qty <= 0 or v_line.qty <> trunc(v_line.qty) or v_line.qty > 99 then
      raise exception 'Every line needs a whole quantity between 1 and 99';
    end if;
    select price into v_price from items
    where id = v_line.item_id and item_type in ('part', 'complete') and is_active;
    if not found or v_price is null then
      raise exception 'One of the items is not for sale';
    end if;
    insert into sales_order_lines (order_id, item_id, qty, unit_price)
    values (v_order_id, v_line.item_id, v_line.qty, v_price);
    v_count := v_count + 1;
  end loop;

  if v_count = 0 then
    raise exception 'Your cart is empty';
  end if;
  return v_order_id;
end;
$$;

-- ---------------------------------------------------------------------
-- portal_place_custom_order: Build Your Own Board.
-- The customer picks a deck, trucks, wheels, bearings and grip tape.
--   1. Every choice is checked against the build_options rules.
--   2. The box, hardware and riser pads are added from build_auto_adds.
--   3. Price = the parts' prices added up + the assembly fee setting.
--   4. A sales order is created with one line of the generic item
--      WBC-3000 "Custom Board" at that price.
--   5. A planned production order is created at the warehouse with this
--      build's own parts list. When staff complete it, the board is
--      received at the pickup store, ready to be handed over.
-- Returns the sales order id.
-- ---------------------------------------------------------------------
create or replace function public.portal_place_custom_order(
  p_location_id  bigint,
  p_deck_id      bigint,
  p_trucks_id    bigint,
  p_wheels_id    bigint,
  p_bearings_id  bigint,
  p_grip_id      bigint,
  p_note         text default null
)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_customer   bigint;
  v_custom     bigint;
  v_warehouse  bigint;
  v_tax        numeric;
  v_fee        numeric;
  v_parts      bigint[];
  v_price      numeric;
  v_order_id   bigint;
  v_line_id    bigint;
  v_job_id     bigint;
  v_store      text;
begin
  select id into v_customer from customers where auth_user_id = auth.uid();
  if v_customer is null then
    raise exception 'Finish setting up your customer account first';
  end if;
  select code into v_store from locations where id = p_location_id and type = 'store';
  if v_store is null then
    raise exception 'Choose a store to pick up from';
  end if;

  -- The compatibility rules: each choice must be allowed for this deck.
  if not exists (select 1 from build_options where deck_item_id = p_deck_id) then
    raise exception 'Choose a deck';
  end if;
  if not exists (select 1 from build_options where deck_item_id = p_deck_id and slot = 'trucks'   and item_id = p_trucks_id)
  or not exists (select 1 from build_options where deck_item_id = p_deck_id and slot = 'wheels'   and item_id = p_wheels_id)
  or not exists (select 1 from build_options where deck_item_id = p_deck_id and slot = 'bearings' and item_id = p_bearings_id)
  or not exists (select 1 from build_options where deck_item_id = p_deck_id and slot = 'grip'     and item_id = p_grip_id) then
    raise exception 'Those parts do not fit that deck';
  end if;

  -- The full parts list: the five choices plus the automatic extras.
  select array[p_deck_id, p_trucks_id, p_wheels_id, p_bearings_id, p_grip_id]
         || coalesce(array_agg(a.item_id), '{}')
  into v_parts
  from build_auto_adds a
  where a.deck_item_id = p_deck_id and a.wheel_item_id = p_wheels_id;

  select value into v_tax from settings where key = 'tax_rate';
  select coalesce(value, 0) into v_fee from settings where key = 'assembly_fee';
  select sum(i.price) + coalesce(v_fee, 0) into v_price from items i where i.id = any (v_parts);

  select id into v_custom from items where item_type = 'custom' order by id limit 1;
  select id into v_warehouse from locations where type = 'warehouse' order by id limit 1;
  if v_custom is null or v_warehouse is null then
    raise exception 'Custom builds are not set up';
  end if;

  insert into sales_orders
    (customer_id, location_id, channel, status, discount_pct, tax_rate, note, created_by)
  values
    (v_customer, p_location_id, 'portal', 'placed', 0, v_tax, nullif(trim(p_note), ''), auth.uid())
  returning id into v_order_id;

  insert into sales_order_lines (order_id, item_id, qty, unit_price)
  values (v_order_id, v_custom, 1, v_price)
  returning id into v_line_id;

  insert into production_orders
    (item_id, location_id, status, qty_started, sales_order_line_id, destination_location_id, note, created_by)
  values
    (v_custom, v_warehouse, 'planned', 1, v_line_id, p_location_id,
     'Custom build for SO-' || lpad(v_order_id::text, 5, '0') || ', pickup at ' || v_store, auth.uid())
  returning id into v_job_id;

  insert into production_order_components (production_order_id, item_id, qty_issued)
  select v_job_id, part_id, 1 from unnest(v_parts) as part_id;

  return v_order_id;
end;
$$;

-- ---------------------------------------------------------------------
-- portal_my_orders: the signed-in customer's own orders, newest first,
-- each with its lines. For a line still waiting, availability and
-- est_available_date come from the same open_order_lines view staff use.
-- A custom board line also lists the parts chosen and the build status.
-- ---------------------------------------------------------------------
create or replace function public.portal_my_orders()
returns table (
  order_id        bigint,
  order_date      timestamptz,
  status          text,
  location_code   text,
  location_name   text,
  requested_date  date,
  net             numeric,
  tax             numeric,
  total           numeric,
  order_lines     jsonb
)
language sql
stable
security definer
set search_path = public
as $$
  select
    o.order_id, o.order_date, o.status, l.code, l.name, o.requested_date, o.net, o.tax, o.total,
    (select jsonb_agg(jsonb_build_object(
        'sku', i.sku, 'name', i.name, 'qty', t.qty, 'qty_fulfilled', t.qty_fulfilled,
        'unit_price', t.unit_price, 'line_net', t.line_net,
        'availability', ol.availability, 'est_available_date', ol.est_available_date,
        'build_status', (select po.status from production_orders po
                         where po.sales_order_line_id = t.line_id order by po.id limit 1),
        'build_parts',  (select string_agg(ci.name, ', ' order by ci.sku)
                         from production_orders po
                         join production_order_components pc on pc.production_order_id = po.id
                         join items ci on ci.id = pc.item_id
                         where po.sales_order_line_id = t.line_id)
      ) order by t.line_id)
     from sales_line_totals t
     join items i on i.id = t.item_id
     left join open_order_lines ol on ol.line_id = t.line_id
     where t.order_id = o.order_id)
  from sales_order_totals o
  join locations l on l.id = o.location_id
  where o.customer_id = (select c.id from customers c where c.auth_user_id = auth.uid())
  order by o.order_id desc
  limit 50;
$$;

-- ---------------------------------------------------------------------
-- portal_cancel_order: a customer cancels their own order, as long as
-- nothing has been handed over. A custom board can only be cancelled
-- while its production order is still planned (no parts issued).
-- ---------------------------------------------------------------------
create or replace function public.portal_cancel_order(p_order_id bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_status text;
begin
  select o.status into v_status
  from sales_orders o
  join customers c on c.id = o.customer_id
  where o.id = p_order_id and c.auth_user_id = auth.uid()
  for update of o;
  if not found then
    raise exception 'Order not found';
  end if;
  if v_status <> 'placed'
     or exists (select 1 from sales_order_lines where order_id = p_order_id and qty_fulfilled > 0) then
    raise exception 'This order can no longer be cancelled online. Please contact the store.';
  end if;
  if exists (select 1 from production_orders po
             join sales_order_lines l on l.id = po.sales_order_line_id
             where l.order_id = p_order_id and po.status in ('in_progress', 'completed')) then
    raise exception 'Your custom board is already being built, so it cannot be cancelled online.';
  end if;

  update production_orders po
  set status = 'cancelled'
  from sales_order_lines l
  where l.id = po.sales_order_line_id and l.order_id = p_order_id and po.status = 'planned';

  update sales_orders set status = 'cancelled' where id = p_order_id;
end;
$$;

revoke execute on function public.portal_register(text, text, bigint)                                   from public, anon;
revoke execute on function public.portal_setup()                                                        from public, anon;
revoke execute on function public.portal_place_order(bigint, jsonb, date, text)                         from public, anon;
revoke execute on function public.portal_place_custom_order(bigint, bigint, bigint, bigint, bigint, bigint, text) from public, anon;
revoke execute on function public.portal_my_orders()                                                    from public, anon;
revoke execute on function public.portal_cancel_order(bigint)                                           from public, anon;
grant execute on function public.portal_register(text, text, bigint)                                    to authenticated;
grant execute on function public.portal_setup()                                                         to authenticated;
grant execute on function public.portal_place_order(bigint, jsonb, date, text)                          to authenticated;
grant execute on function public.portal_place_custom_order(bigint, bigint, bigint, bigint, bigint, bigint, text) to authenticated;
grant execute on function public.portal_my_orders()                                                     to authenticated;
grant execute on function public.portal_cancel_order(bigint)                                            to authenticated;

-- Result shown after running: the 6 portal functions.
select routine_name
from information_schema.routines
where routine_schema = 'public' and routine_name like 'portal\_%'
order by routine_name;
