-- =====================================================================
-- Wasatch Board Co. ERP — 06: purchase orders and receiving
-- Run AFTER file 04. Safe to run more than once.
-- =====================================================================

-- "Today" for the business. The database clock runs on UTC; the company
-- is in Utah, so dates are worked out in Mountain time.
create or replace function public.wbc_today()
returns date
language sql
stable
as $$
  select (now() at time zone 'America/Denver')::date;
$$;

-- ---------------------------------------------------------------------
-- purchase_orders: one row per order placed with a supplier.
--   draft -> sent -> received -> closed     (or cancelled)
--   expected_date = sent_date + the supplier's quoted lead time
--   received_date = the date the order was finished being received
--   paid_at       = the date we paid; paying is what closes the PO
-- ---------------------------------------------------------------------
create table if not exists public.purchase_orders (
  id             bigint generated always as identity primary key,
  supplier_id    bigint not null references public.suppliers (id),
  status         text not null default 'draft'
                   check (status in ('draft', 'sent', 'received', 'closed', 'cancelled')),
  sent_date      date,
  expected_date  date,
  received_date  date,
  paid_at        date,
  note           text,
  created_by     uuid references auth.users (id) on delete set null,
  created_at     timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- purchase_order_lines: what we asked for, and the price agreed.
-- unit_cost here is what the stock is received at, and so what feeds
-- the weighted average cost.
-- ---------------------------------------------------------------------
create table if not exists public.purchase_order_lines (
  id           bigint generated always as identity primary key,
  po_id        bigint not null references public.purchase_orders (id) on delete cascade,
  item_id      bigint not null references public.items (id),
  qty_ordered  numeric(12,2) not null check (qty_ordered > 0),
  unit_cost    numeric(12,4) not null check (unit_cost >= 0),
  unique (po_id, item_id)
);

-- ---------------------------------------------------------------------
-- po_receipts + po_receipt_lines: what actually arrived, where and when.
-- Kept separate from the order so that late deliveries and short
-- shipments can be measured (one PO can have several receipts).
-- ---------------------------------------------------------------------
create table if not exists public.po_receipts (
  id             bigint generated always as identity primary key,
  po_id          bigint not null references public.purchase_orders (id),
  location_id    bigint not null references public.locations (id),
  received_date  date not null,
  note           text,
  created_by     uuid references auth.users (id) on delete set null,
  created_at     timestamptz not null default now()
);

create table if not exists public.po_receipt_lines (
  id            bigint generated always as identity primary key,
  receipt_id    bigint not null references public.po_receipts (id) on delete cascade,
  po_line_id    bigint not null references public.purchase_order_lines (id),
  qty_received  numeric(12,2) not null check (qty_received > 0)
);

create index if not exists purchase_order_lines_po_idx on public.purchase_order_lines (po_id);
create index if not exists po_receipts_po_idx          on public.po_receipts (po_id);
create index if not exists po_receipt_lines_line_idx   on public.po_receipt_lines (po_line_id);

-- =====================================================================
-- Functions (each one is a whole transaction: all of it happens or none)
-- =====================================================================

-- create_purchase_order: makes a draft PO.
-- p_lines looks like [{"item_id": 3, "qty": 40, "unit_cost": 22.00}, ...]
-- unit_cost may be left out; it then defaults to the supplier's quoted cost.
create or replace function public.create_purchase_order(
  p_supplier_id  bigint,
  p_lines        jsonb,
  p_note         text default null
)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_po_id     bigint;
  v_line      record;
  v_standard  numeric;
  v_count     integer := 0;
begin
  if not is_staff() then
    raise exception 'Only staff can create purchase orders';
  end if;
  if not exists (select 1 from suppliers where id = p_supplier_id and is_active) then
    raise exception 'Choose an active supplier';
  end if;

  insert into purchase_orders (supplier_id, note, created_by)
  values (p_supplier_id, p_note, auth.uid())
  returning id into v_po_id;

  for v_line in
    select x.item_id, sum(x.qty) as qty, max(x.unit_cost) as unit_cost
    from jsonb_to_recordset(coalesce(p_lines, '[]'::jsonb))
           as x (item_id bigint, qty numeric, unit_cost numeric)
    group by x.item_id
  loop
    if v_line.qty is null or v_line.qty <= 0 then
      raise exception 'Every line needs a quantity above zero';
    end if;

    -- A PO can only contain parts that this supplier supplies.
    select standard_cost into v_standard
    from items
    where id = v_line.item_id and supplier_id = p_supplier_id and item_type = 'part';
    if not found then
      raise exception 'Item % is not supplied by this supplier', v_line.item_id;
    end if;
    if coalesce(v_line.unit_cost, v_standard) is null then
      raise exception 'Item % needs a unit cost', v_line.item_id;
    end if;

    insert into purchase_order_lines (po_id, item_id, qty_ordered, unit_cost)
    values (v_po_id, v_line.item_id, v_line.qty, coalesce(v_line.unit_cost, v_standard));
    v_count := v_count + 1;
  end loop;

  if v_count = 0 then
    raise exception 'Add at least one item to the purchase order';
  end if;
  return v_po_id;
end;
$$;

-- send_purchase_order: draft -> sent. Stamps the sent date and works out
-- the expected receipt date from the supplier's quoted lead time.
create or replace function public.send_purchase_order(
  p_po_id      bigint,
  p_sent_date  date default null
)
returns date
language plpgsql
security definer
set search_path = public
as $$
declare
  v_status    text;
  v_supplier  bigint;
  v_sent      date := coalesce(p_sent_date, wbc_today());
  v_expected  date;
begin
  if not is_staff() then
    raise exception 'Only staff can send purchase orders';
  end if;

  select status, supplier_id into v_status, v_supplier
  from purchase_orders where id = p_po_id for update;
  if not found then
    raise exception 'Purchase order not found';
  end if;
  if v_status <> 'draft' then
    raise exception 'Only a draft purchase order can be sent';
  end if;
  if v_sent > wbc_today() then
    raise exception 'The sent date cannot be in the future';
  end if;

  select v_sent + quoted_lead_time_days into v_expected
  from suppliers where id = v_supplier;

  update purchase_orders
  set status = 'sent', sent_date = v_sent, expected_date = v_expected
  where id = p_po_id;

  return v_expected;
end;
$$;

-- receive_purchase_order: stock arrives.
-- p_lines looks like [{"po_line_id": 12, "qty": 40}, ...]
-- For every line received this:
--   1. records the receipt,
--   2. adds a + row to the inventory ledger at the PO's unit cost,
--   3. re-averages the item's weighted average cost.
-- The PO becomes "received" when every line is complete, or when
-- p_close_short is true (the supplier will not ship the rest).
create or replace function public.receive_purchase_order(
  p_po_id          bigint,
  p_location_id    bigint,
  p_received_date  date,
  p_lines          jsonb,
  p_close_short    boolean default false,
  p_note           text default null
)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_status      text;
  v_sent        date;
  v_date        date := coalesce(p_received_date, wbc_today());
  v_when        timestamptz;
  v_receipt_id  bigint;
  v_line        record;
  v_po_line     record;
  v_count       integer := 0;
begin
  if not is_staff() then
    raise exception 'Only staff can receive purchase orders';
  end if;

  select status, sent_date into v_status, v_sent
  from purchase_orders where id = p_po_id for update;
  if not found then
    raise exception 'Purchase order not found';
  end if;
  if v_status <> 'sent' then
    raise exception 'Only a sent purchase order can be received';
  end if;
  if not exists (select 1 from locations where id = p_location_id) then
    raise exception 'Choose a location to receive into';
  end if;
  if v_date < v_sent then
    raise exception 'The received date cannot be before the PO was sent';
  end if;
  if v_date > wbc_today() then
    raise exception 'The received date cannot be in the future';
  end if;

  -- The ledger row is dated when the stock arrived.
  if v_date = wbc_today() then
    v_when := now();
  else
    v_when := (v_date + time '12:00') at time zone 'America/Denver';
  end if;

  insert into po_receipts (po_id, location_id, received_date, note, created_by)
  values (p_po_id, p_location_id, v_date, p_note, auth.uid())
  returning id into v_receipt_id;

  for v_line in
    select x.po_line_id, sum(x.qty) as qty
    from jsonb_to_recordset(coalesce(p_lines, '[]'::jsonb)) as x (po_line_id bigint, qty numeric)
    where coalesce(x.qty, 0) <> 0
    group by x.po_line_id
  loop
    if v_line.qty < 0 then
      raise exception 'A received quantity cannot be negative';
    end if;

    select l.item_id, l.unit_cost,
           l.qty_ordered - coalesce((select sum(rl.qty_received)
                                     from po_receipt_lines rl
                                     where rl.po_line_id = l.id), 0) as remaining
    into v_po_line
    from purchase_order_lines l
    where l.id = v_line.po_line_id and l.po_id = p_po_id;
    if not found then
      raise exception 'Line % is not on this purchase order', v_line.po_line_id;
    end if;
    if v_line.qty > v_po_line.remaining then
      raise exception 'Cannot receive % of %: only % still open',
        v_line.qty, (select sku from items where id = v_po_line.item_id), v_po_line.remaining;
    end if;

    insert into po_receipt_lines (receipt_id, po_line_id, qty_received)
    values (v_receipt_id, v_line.po_line_id, v_line.qty);

    perform wbc_post_movement(
      v_po_line.item_id, p_location_id, v_line.qty, v_po_line.unit_cost,
      'po_receipt', null, 'po_receipt', v_receipt_id,
      'PO-' || lpad(p_po_id::text, 5, '0'), v_when, true);

    v_count := v_count + 1;
  end loop;

  if v_count = 0 then
    if not p_close_short then
      raise exception 'Enter at least one received quantity';
    end if;
    -- Closing a PO short with nothing arriving: no receipt to keep.
    delete from po_receipts where id = v_receipt_id;
    v_receipt_id := null;
  end if;

  if p_close_short or not exists (
    select 1
    from purchase_order_lines l
    where l.po_id = p_po_id
      and l.qty_ordered > coalesce((select sum(rl.qty_received)
                                    from po_receipt_lines rl
                                    where rl.po_line_id = l.id), 0)
  ) then
    update purchase_orders
    set status = 'received', received_date = v_date
    where id = p_po_id;
  end if;

  return v_receipt_id;
end;
$$;

-- mark_po_paid: received -> closed.
create or replace function public.mark_po_paid(
  p_po_id      bigint,
  p_paid_date  date default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_status    text;
  v_received  date;
  v_paid      date := coalesce(p_paid_date, wbc_today());
begin
  if not is_staff() then
    raise exception 'Only staff can mark purchase orders paid';
  end if;
  select status, received_date into v_status, v_received
  from purchase_orders where id = p_po_id for update;
  if not found then
    raise exception 'Purchase order not found';
  end if;
  if v_status <> 'received' then
    raise exception 'Only a received purchase order can be marked paid';
  end if;
  if v_paid < v_received then
    raise exception 'The paid date cannot be before the goods were received';
  end if;
  update purchase_orders set status = 'closed', paid_at = v_paid where id = p_po_id;
end;
$$;

-- cancel_purchase_order: only before anything has been received.
create or replace function public.cancel_purchase_order(p_po_id bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_status text;
begin
  if not is_staff() then
    raise exception 'Only staff can cancel purchase orders';
  end if;
  select status into v_status from purchase_orders where id = p_po_id for update;
  if not found then
    raise exception 'Purchase order not found';
  end if;
  if v_status not in ('draft', 'sent') then
    raise exception 'This purchase order can no longer be cancelled';
  end if;
  if exists (select 1 from po_receipts where po_id = p_po_id) then
    raise exception 'Stock has already been received on this PO. Receive and close it short instead.';
  end if;
  update purchase_orders set status = 'cancelled' where id = p_po_id;
end;
$$;

revoke execute on function public.create_purchase_order(bigint, jsonb, text) from public, anon;
revoke execute on function public.send_purchase_order(bigint, date) from public, anon;
revoke execute on function public.receive_purchase_order(bigint, bigint, date, jsonb, boolean, text) from public, anon;
revoke execute on function public.mark_po_paid(bigint, date) from public, anon;
revoke execute on function public.cancel_purchase_order(bigint) from public, anon;
grant execute on function public.create_purchase_order(bigint, jsonb, text) to authenticated;
grant execute on function public.send_purchase_order(bigint, date) to authenticated;
grant execute on function public.receive_purchase_order(bigint, bigint, date, jsonb, boolean, text) to authenticated;
grant execute on function public.mark_po_paid(bigint, date) to authenticated;
grant execute on function public.cancel_purchase_order(bigint) to authenticated;

-- =====================================================================
-- Views (calculated, never stored)
-- =====================================================================

-- po_line_status: ordered vs received for every PO line.
-- qty_open is what is still on its way (only while the PO is "sent").
create or replace view public.po_line_status
with (security_invoker = true) as
select
  l.id        as po_line_id,
  l.po_id,
  l.item_id,
  l.qty_ordered,
  l.unit_cost,
  coalesce(r.qty_received, 0) as qty_received,
  case when p.status = 'sent'
       then l.qty_ordered - coalesce(r.qty_received, 0)
       else 0 end             as qty_open,
  l.qty_ordered * l.unit_cost                 as ordered_value,
  coalesce(r.qty_received, 0) * l.unit_cost   as received_value
from public.purchase_order_lines l
join public.purchase_orders p on p.id = l.po_id
left join (
  select po_line_id, sum(qty_received) as qty_received
  from public.po_receipt_lines
  group by po_line_id
) r on r.po_line_id = l.id;

-- po_summary: one row per PO with everything the screens and the
-- supplier scorecard need.
--   fill_rate             = units received / units ordered
--   actual_lead_time_days = received date - sent date
--   days_late             = received date - expected date (negative = early);
--                           for a PO still on its way, days overdue so far
--   payment_due_date      = received date + the supplier's payment terms
--   amount_owed           = value received and not yet paid
create or replace view public.po_summary
with (security_invoker = true) as
select
  p.id as po_id,
  p.supplier_id,
  s.name as supplier_name,
  p.status,
  p.sent_date,
  p.expected_date,
  p.received_date,
  p.paid_at,
  p.note,
  p.created_at,
  s.quoted_lead_time_days,
  s.payment_terms_days,
  coalesce(t.qty_ordered, 0)    as qty_ordered,
  coalesce(t.qty_received, 0)   as qty_received,
  coalesce(t.ordered_value, 0)  as ordered_value,
  coalesce(t.received_value, 0) as received_value,
  case when t.qty_ordered > 0 then t.qty_received / t.qty_ordered end as fill_rate,
  p.received_date - p.sent_date as actual_lead_time_days,
  case
    when p.received_date is not null then p.received_date - p.expected_date
    when p.status = 'sent' then greatest(public.wbc_today() - p.expected_date, 0)
  end as days_late,
  p.received_date + s.payment_terms_days as payment_due_date,
  case when p.status = 'received' then coalesce(t.received_value, 0) else 0 end as amount_owed
from public.purchase_orders p
join public.suppliers s on s.id = p.supplier_id
left join (
  select po_id,
         sum(qty_ordered)    as qty_ordered,
         sum(qty_received)   as qty_received,
         sum(ordered_value)  as ordered_value,
         sum(received_value) as received_value
  from public.po_line_status
  group by po_id
) t on t.po_id = p.id;

-- =====================================================================
-- Security: staff can read; all writes go through the functions above.
-- =====================================================================
alter table public.purchase_orders      enable row level security;
alter table public.purchase_order_lines enable row level security;
alter table public.po_receipts          enable row level security;
alter table public.po_receipt_lines     enable row level security;

do $$
declare
  t text;
begin
  foreach t in array array['purchase_orders', 'purchase_order_lines', 'po_receipts', 'po_receipt_lines'] loop
    execute format('drop policy if exists staff_read on public.%I', t);
    execute format(
      'create policy staff_read on public.%I for select to authenticated using (public.is_staff())', t);
    execute format('revoke insert, update, delete on public.%I from anon, authenticated', t);
  end loop;
end;
$$;

-- Realtime on purchase orders and suppliers.
do $$
declare
  t text;
begin
  foreach t in array array['purchase_orders', 'suppliers'] loop
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t
    ) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end;
$$;

-- Result shown after running: the 4 new tables.
select table_name
from information_schema.tables
where table_schema = 'public'
  and table_name in ('purchase_orders', 'purchase_order_lines', 'po_receipts', 'po_receipt_lines')
order by table_name;
