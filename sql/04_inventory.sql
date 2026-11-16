-- =====================================================================
-- Wasatch Board Co. ERP — 04: inventory ledger, levels, adjustments, transfers
-- Run AFTER files 01 and 02. Safe to run more than once.
-- =====================================================================

-- ---------------------------------------------------------------------
-- inventory_movements: THE LEDGER. One row every time stock physically
-- changes: + for stock coming in, - for stock going out. Rows are only
-- ever added. Everything about stock is calculated from this table.
-- ---------------------------------------------------------------------
create table if not exists public.inventory_movements (
  id             bigint generated always as identity primary key,
  occurred_at    timestamptz not null default now(),
  item_id        bigint not null references public.items (id),
  location_id    bigint not null references public.locations (id),
  qty_change     numeric(12,2) not null check (qty_change <> 0),
  unit_cost      numeric(12,4) not null,          -- cost per unit at the time of the movement
  movement_type  text not null check (movement_type in (
                   'opening', 'adjustment', 'transfer_out', 'transfer_in',
                   'po_receipt', 'sale', 'return',
                   'production_issue', 'production_receipt')),
  reason_code    text references public.reason_codes (code),
  source_type    text,                            -- which document caused it: 'transfer', 'sales_order', ...
  source_id      bigint,                          -- that document's id
  note           text,
  created_by     uuid references auth.users (id) on delete set null,
  created_at     timestamptz not null default now()
);

create index if not exists inventory_movements_item_idx
  on public.inventory_movements (item_id, location_id);
create index if not exists inventory_movements_date_idx
  on public.inventory_movements (occurred_at);

-- ---------------------------------------------------------------------
-- inventory_levels: the running total per item per location. Nobody
-- writes to this table directly; the trigger below keeps it in step
-- with the ledger. It exists so screens can read on-hand instantly and
-- get realtime updates.
-- ---------------------------------------------------------------------
create table if not exists public.inventory_levels (
  item_id      bigint not null references public.items (id),
  location_id  bigint not null references public.locations (id),
  qty_on_hand  numeric(12,2) not null default 0,
  updated_at   timestamptz not null default now(),
  primary key (item_id, location_id)
);

-- Every new ledger row updates the running total. If the total would go
-- below zero the whole transaction is refused, so stock can never be negative.
create or replace function public.inventory_apply_movement()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_new numeric;
begin
  insert into inventory_levels (item_id, location_id, qty_on_hand)
  values (new.item_id, new.location_id, new.qty_change)
  on conflict (item_id, location_id) do update
    set qty_on_hand = inventory_levels.qty_on_hand + excluded.qty_on_hand,
        updated_at  = now()
  returning qty_on_hand into v_new;

  if v_new < 0 then
    raise exception 'Not enough stock: % at % would go to %',
      (select sku from items where id = new.item_id),
      (select code from locations where id = new.location_id),
      v_new;
  end if;
  return new;
end;
$$;

drop trigger if exists inventory_apply_movement on public.inventory_movements;
create trigger inventory_apply_movement
  after insert on public.inventory_movements
  for each row execute function public.inventory_apply_movement();

-- The ledger is append-only: a mistake is fixed with a new correcting
-- row, never by editing or deleting history.
create or replace function public.inventory_movements_locked()
returns trigger
language plpgsql
as $$
begin
  raise exception 'Ledger rows cannot be changed or deleted. Post a correcting movement instead.';
end;
$$;

drop trigger if exists inventory_movements_locked on public.inventory_movements;
create trigger inventory_movements_locked
  before update or delete on public.inventory_movements
  for each row execute function public.inventory_movements_locked();

-- ---------------------------------------------------------------------
-- transfers + transfer_lines: the paperwork for moving stock between
-- locations. Posting a transfer writes two ledger rows per line.
-- ---------------------------------------------------------------------
create table if not exists public.transfers (
  id                bigint generated always as identity primary key,
  from_location_id  bigint not null references public.locations (id),
  to_location_id    bigint not null references public.locations (id),
  transferred_at    timestamptz not null default now(),
  note              text,
  created_by        uuid references auth.users (id) on delete set null,
  check (from_location_id <> to_location_id)
);

create table if not exists public.transfer_lines (
  id           bigint generated always as identity primary key,
  transfer_id  bigint not null references public.transfers (id) on delete cascade,
  item_id      bigint not null references public.items (id),
  qty          numeric(12,2) not null check (qty > 0)
);

-- =====================================================================
-- Functions
-- =====================================================================

-- wbc_post_movement: the ONE place that writes to the ledger. Every
-- transaction (adjustment, transfer, and later sale, receipt, build,
-- return) calls this. It cannot be called from the browser.
--   p_unit_cost null  -> use the item's current average cost
--   p_reaverage true  -> stock is arriving at a new cost (PO receipt,
--                        production, opening balance), so recalculate
--                        the weighted average:
--                        (qty on hand x old avg + qty in x cost in) / new qty
drop function if exists public.wbc_post_movement(bigint, bigint, numeric, numeric, text, text, text, bigint, text, timestamptz, boolean);
create function public.wbc_post_movement(
  p_item_id      bigint,
  p_location_id  bigint,
  p_qty          numeric,
  p_unit_cost    numeric,
  p_type         text,
  p_reason_code  text default null,
  p_source_type  text default null,
  p_source_id    bigint default null,
  p_note         text default null,
  p_occurred_at  timestamptz default now(),
  p_reaverage    boolean default false
)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_avg    numeric;
  v_total  numeric;
  v_cost   numeric;
  v_id     bigint;
begin
  if p_qty is null or p_qty = 0 then
    raise exception 'Quantity cannot be zero';
  end if;

  -- Lock the item so two receipts at the same moment cannot both re-average.
  select avg_cost into v_avg from items where id = p_item_id for update;
  if not found then
    raise exception 'Item % not found', p_item_id;
  end if;

  v_cost := coalesce(p_unit_cost, v_avg);

  if p_reaverage and p_qty > 0 then
    select coalesce(sum(qty_on_hand), 0) into v_total
    from inventory_levels where item_id = p_item_id;   -- company-wide, all locations

    if v_total <= 0 then
      v_avg := v_cost;
    else
      v_avg := (v_total * v_avg + p_qty * v_cost) / (v_total + p_qty);
    end if;
    update items set avg_cost = round(v_avg, 4) where id = p_item_id;
  end if;

  insert into inventory_movements
    (occurred_at, item_id, location_id, qty_change, unit_cost, movement_type,
     reason_code, source_type, source_id, note, created_by)
  values
    (coalesce(p_occurred_at, now()), p_item_id, p_location_id, p_qty, v_cost, p_type,
     p_reason_code, p_source_type, p_source_id, p_note, auth.uid())
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function public.wbc_post_movement(bigint, bigint, numeric, numeric, text, text, text, bigint, text, timestamptz, boolean)
  from public, anon, authenticated;

-- post_adjustment: a cycle count or damage write-off, called from the
-- Inventory page.
--   p_is_count = false -> p_qty is the change (+3 or -2)
--   p_is_count = true  -> p_qty is what was counted on the shelf; the
--                         function works out the difference itself
-- Returns the change that was posted.
create or replace function public.post_adjustment(
  p_item_id      bigint,
  p_location_id  bigint,
  p_qty          numeric,
  p_is_count     boolean,
  p_reason_code  text,
  p_note         text default null
)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  v_on_hand  numeric;
  v_delta    numeric;
begin
  if not is_staff() then
    raise exception 'Only staff can adjust inventory';
  end if;
  if p_qty is null then
    raise exception 'Enter a quantity';
  end if;
  if not exists (select 1 from reason_codes
                 where code = p_reason_code and kind = 'adjustment' and is_active) then
    raise exception 'Choose a reason code for the adjustment';
  end if;
  if not exists (select 1 from items where id = p_item_id and item_type in ('part', 'complete')) then
    raise exception 'This item cannot be adjusted';
  end if;
  if not exists (select 1 from locations where id = p_location_id) then
    raise exception 'Choose a location';
  end if;

  if p_is_count then
    if p_qty < 0 then
      raise exception 'A counted quantity cannot be negative';
    end if;
    select qty_on_hand into v_on_hand
    from inventory_levels
    where item_id = p_item_id and location_id = p_location_id
    for update;
    v_delta := p_qty - coalesce(v_on_hand, 0);
  else
    v_delta := p_qty;
  end if;

  if v_delta = 0 then
    return 0;   -- count matched the system: nothing to post
  end if;

  perform wbc_post_movement(p_item_id, p_location_id, v_delta, null, 'adjustment',
                            p_reason_code, null, null, p_note);
  return v_delta;
end;
$$;

-- post_transfer: move stock from one location to another.
-- p_lines looks like [{"item_id": 3, "qty": 5}, {"item_id": 8, "qty": 2}]
-- Either every line moves or none do. Returns the transfer id.
create or replace function public.post_transfer(
  p_from_location_id  bigint,
  p_to_location_id    bigint,
  p_lines             jsonb,
  p_note              text default null
)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_transfer_id  bigint;
  v_line         record;
  v_count        integer := 0;
begin
  if not is_staff() then
    raise exception 'Only staff can transfer inventory';
  end if;
  if p_from_location_id is null or p_to_location_id is null
     or p_from_location_id = p_to_location_id then
    raise exception 'Choose two different locations';
  end if;

  insert into transfers (from_location_id, to_location_id, note, created_by)
  values (p_from_location_id, p_to_location_id, p_note, auth.uid())
  returning id into v_transfer_id;

  for v_line in
    select x.item_id, sum(x.qty) as qty
    from jsonb_to_recordset(coalesce(p_lines, '[]'::jsonb)) as x (item_id bigint, qty numeric)
    group by x.item_id
  loop
    if v_line.item_id is null or v_line.qty is null or v_line.qty <= 0 then
      raise exception 'Every transfer line needs an item and a quantity above zero';
    end if;

    insert into transfer_lines (transfer_id, item_id, qty)
    values (v_transfer_id, v_line.item_id, v_line.qty);

    -- Out of the sending location, into the receiving one, at the same cost.
    perform wbc_post_movement(v_line.item_id, p_from_location_id, -v_line.qty, null,
                              'transfer_out', null, 'transfer', v_transfer_id, p_note);
    perform wbc_post_movement(v_line.item_id, p_to_location_id, v_line.qty, null,
                              'transfer_in', null, 'transfer', v_transfer_id, p_note);
    v_count := v_count + 1;
  end loop;

  if v_count = 0 then
    raise exception 'Add at least one item to the transfer';
  end if;
  return v_transfer_id;
end;
$$;

revoke execute on function public.post_adjustment(bigint, bigint, numeric, boolean, text, text) from public, anon;
revoke execute on function public.post_transfer(bigint, bigint, jsonb, text) from public, anon;
grant execute on function public.post_adjustment(bigint, bigint, numeric, boolean, text, text) to authenticated;
grant execute on function public.post_transfer(bigint, bigint, jsonb, text) to authenticated;

-- =====================================================================
-- Views (calculated, never stored)
-- =====================================================================

-- inventory_value: on-hand quantity x weighted average cost.
create or replace view public.inventory_value
with (security_invoker = true) as
select
  l.item_id,
  l.location_id,
  l.qty_on_hand,
  i.avg_cost                 as unit_cost,
  l.qty_on_hand * i.avg_cost as value
from public.inventory_levels l
join public.items i on i.id = l.item_id;

-- ledger_check: proof that the running totals equal the sum of the ledger.
-- "matches" should be true on every row.
create or replace view public.ledger_check
with (security_invoker = true) as
select
  l.item_id,
  l.location_id,
  l.qty_on_hand,
  coalesce(m.ledger_qty, 0)                   as ledger_qty,
  (l.qty_on_hand = coalesce(m.ledger_qty, 0)) as matches
from public.inventory_levels l
left join (
  select item_id, location_id, sum(qty_change) as ledger_qty
  from public.inventory_movements
  group by item_id, location_id
) m on m.item_id = l.item_id and m.location_id = l.location_id;

-- =====================================================================
-- Security: staff can read these tables. Nobody can write to them from
-- the browser; all writes go through the functions above.
-- =====================================================================
alter table public.inventory_movements enable row level security;
alter table public.inventory_levels    enable row level security;
alter table public.transfers           enable row level security;
alter table public.transfer_lines      enable row level security;

do $$
declare
  t text;
begin
  foreach t in array array['inventory_movements', 'inventory_levels', 'transfers', 'transfer_lines'] loop
    execute format('drop policy if exists staff_read on public.%I', t);
    execute format(
      'create policy staff_read on public.%I for select to authenticated using (public.is_staff())', t);
    execute format('revoke insert, update, delete on public.%I from anon, authenticated', t);
  end loop;
end;
$$;

-- Realtime on stock levels.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'inventory_levels'
  ) then
    alter publication supabase_realtime add table public.inventory_levels;
  end if;
end;
$$;

-- Result shown after running: the 4 new tables.
select table_name
from information_schema.tables
where table_schema = 'public'
  and table_name in ('inventory_movements', 'inventory_levels', 'transfers', 'transfer_lines')
order by table_name;
