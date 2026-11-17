-- =====================================================================
-- Wasatch Board Co. ERP — 09: production orders and production metrics
-- Run AFTER file 08. Safe to run more than once.
-- =====================================================================

-- ---------------------------------------------------------------------
-- production_orders: one row per job to assemble boards at the warehouse.
--   planned     = written down, nothing has moved yet
--   in_progress = parts have been issued (taken out of stock)
--   completed   = finished boards have been received into stock
--   cancelled   = dropped before any parts were issued
-- qty_started  = how many boards the job is for
-- qty_good     = boards that passed (this INCLUDES reworked boards)
-- qty_scrapped = boards thrown away
-- qty_reworked = boards that failed first time but were fixed
-- So: qty_started = qty_good + qty_scrapped, always.
-- The last two columns are for custom builds (build step 11).
-- ---------------------------------------------------------------------
create table if not exists public.production_orders (
  id                       bigint generated always as identity primary key,
  item_id                  bigint not null references public.items (id),
  location_id              bigint not null references public.locations (id),
  status                   text not null default 'planned'
                             check (status in ('planned', 'in_progress', 'completed', 'cancelled')),
  qty_started              numeric(12,2) not null check (qty_started > 0),
  qty_good                 numeric(12,2) not null default 0 check (qty_good >= 0),
  qty_scrapped             numeric(12,2) not null default 0 check (qty_scrapped >= 0),
  qty_reworked             numeric(12,2) not null default 0 check (qty_reworked >= 0),
  started_at               timestamptz,
  finished_at              timestamptz,
  sales_order_line_id      bigint references public.sales_order_lines (id),
  destination_location_id  bigint references public.locations (id),
  note                     text,
  created_by               uuid references auth.users (id) on delete set null,
  created_at               timestamptz not null default now(),
  check (qty_reworked <= qty_good),
  check (finished_at is null or started_at is null or finished_at >= started_at)
);

-- ---------------------------------------------------------------------
-- production_order_components: the parts a job actually used.
-- Filled in when the job is issued: a copy of the BOM x quantity, with
-- each part's average cost at that moment. This is what the finished
-- board's cost is rolled up from.
-- ---------------------------------------------------------------------
create table if not exists public.production_order_components (
  id                   bigint generated always as identity primary key,
  production_order_id  bigint not null references public.production_orders (id) on delete cascade,
  item_id              bigint not null references public.items (id),
  qty_issued           numeric(12,2) not null check (qty_issued > 0),
  unit_cost            numeric(12,4),
  unique (production_order_id, item_id)
);

-- ---------------------------------------------------------------------
-- production_scrap: quality problems found on a job.
--   disposition 'scrap'  = the board was thrown away
--   disposition 'rework' = the board was fixed and counts as good
-- Each row has a reason code, so we can report scrap rate by reason.
-- ---------------------------------------------------------------------
create table if not exists public.production_scrap (
  id                   bigint generated always as identity primary key,
  production_order_id  bigint not null references public.production_orders (id) on delete cascade,
  qty                  numeric(12,2) not null check (qty > 0),
  reason_code          text not null references public.reason_codes (code),
  disposition          text not null check (disposition in ('scrap', 'rework'))
);

create index if not exists production_orders_status_idx   on public.production_orders (status);
create index if not exists production_orders_finished_idx on public.production_orders (finished_at);
create index if not exists production_components_order_idx on public.production_order_components (production_order_id);
create index if not exists production_scrap_order_idx      on public.production_scrap (production_order_id);

-- =====================================================================
-- Functions
-- =====================================================================

-- create_production_order: write down a job. Nothing moves yet.
-- The location is always the warehouse (the only place boards are built).
-- Returns the new order's id.
create or replace function public.create_production_order(
  p_item_id  bigint,
  p_qty      numeric,
  p_note     text default null
)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_location  bigint;
  v_id        bigint;
begin
  if not is_staff() then
    raise exception 'Only staff can create production orders';
  end if;
  if p_qty is null or p_qty <= 0 or p_qty <> trunc(p_qty) then
    raise exception 'Enter a whole quantity above zero';
  end if;
  if not exists (select 1 from items
                 where id = p_item_id and item_type = 'complete' and is_active) then
    raise exception 'Choose a complete board to build';
  end if;
  if not exists (select 1 from bom_lines where parent_item_id = p_item_id) then
    raise exception 'This board has no bill of materials, so it cannot be built';
  end if;

  select id into v_location from locations where type = 'warehouse' order by id limit 1;
  if v_location is null then
    raise exception 'No warehouse location exists';
  end if;

  insert into production_orders (item_id, location_id, qty_started, note, created_by)
  values (p_item_id, v_location, p_qty, p_note, auth.uid())
  returning id into v_id;
  return v_id;
end;
$$;

-- issue_production_order: start the job.
--   1. works out the parts needed (BOM x quantity),
--   2. takes each part out of warehouse stock with a - ledger row,
--   3. records what was used and what it cost,
--   4. stamps the start time and sets the order to in_progress.
-- If any part is short, the ledger refuses and nothing at all is issued.
create or replace function public.issue_production_order(
  p_order_id    bigint,
  p_started_at  timestamptz default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order  production_orders%rowtype;
  v_start  timestamptz := coalesce(p_started_at, now());
  v_comp   record;
  v_cost   numeric;
  v_count  integer := 0;
begin
  if not is_staff() then
    raise exception 'Only staff can issue production orders';
  end if;

  select * into v_order from production_orders where id = p_order_id for update;
  if not found then
    raise exception 'Production order not found';
  end if;
  if v_order.status <> 'planned' then
    raise exception 'Only a planned production order can be issued';
  end if;
  if v_start > now() + interval '5 minutes' then
    raise exception 'The start time cannot be in the future';
  end if;

  -- A standard board has no component rows yet: copy them from the BOM.
  -- (A custom build, step 11, arrives with its own one-time list.)
  if not exists (select 1 from production_order_components where production_order_id = p_order_id) then
    insert into production_order_components (production_order_id, item_id, qty_issued)
    select p_order_id, b.component_item_id, b.qty * v_order.qty_started
    from bom_lines b
    where b.parent_item_id = v_order.item_id;
  end if;

  for v_comp in
    select id, item_id, qty_issued
    from production_order_components
    where production_order_id = p_order_id
    order by item_id
  loop
    select avg_cost into v_cost from items where id = v_comp.item_id;
    update production_order_components set unit_cost = v_cost where id = v_comp.id;

    perform wbc_post_movement(
      v_comp.item_id, v_order.location_id, -v_comp.qty_issued, v_cost,
      'production_issue', null, 'production_order', p_order_id,
      'MO-' || lpad(p_order_id::text, 5, '0'), v_start);
    v_count := v_count + 1;
  end loop;

  if v_count = 0 then
    raise exception 'This production order has no components to issue';
  end if;

  update production_orders
  set status = 'in_progress', started_at = v_start
  where id = p_order_id;
end;
$$;

-- complete_production_order: finish the job.
-- p_events lists the quality problems, for example
--   [{"reason_code": "cracked_deck", "qty": 1, "disposition": "scrap"},
--    {"reason_code": "grip_misapplied", "qty": 2, "disposition": "rework"}]
-- (an empty list means every board passed first time).
--   good boards   = started - scrapped        (never typed in)
--   cost per board = cost of all parts issued / boards started
--   1. records the scrap and rework rows,
--   2. receives the good boards into stock with a + ledger row at that
--      cost, and re-averages the board's average cost,
--   3. stamps the finish time and sets the order to completed.
-- The parts used on scrapped boards never come back into stock: their
-- cost is the job's scrap expense (see production_order_summary).
-- Returns the number of good boards received.
create or replace function public.complete_production_order(
  p_order_id     bigint,
  p_events       jsonb default '[]'::jsonb,
  p_finished_at  timestamptz default null
)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order     production_orders%rowtype;
  v_finish    timestamptz := coalesce(p_finished_at, now());
  v_event     record;
  v_scrapped  numeric := 0;
  v_reworked  numeric := 0;
  v_good      numeric;
  v_total     numeric;
  v_unit      numeric;
begin
  if not is_staff() then
    raise exception 'Only staff can complete production orders';
  end if;

  select * into v_order from production_orders where id = p_order_id for update;
  if not found then
    raise exception 'Production order not found';
  end if;
  if v_order.status <> 'in_progress' then
    raise exception 'Only a production order that is in progress can be completed';
  end if;
  if v_finish > now() + interval '5 minutes' then
    raise exception 'The finish time cannot be in the future';
  end if;
  -- The screen's time box only has minutes, so compare to the minute.
  if v_finish < date_trunc('minute', v_order.started_at) then
    raise exception 'The finish time cannot be before the start time';
  end if;
  v_finish := greatest(v_finish, v_order.started_at);

  for v_event in
    select x.reason_code, x.disposition, sum(x.qty) as qty
    from jsonb_to_recordset(coalesce(p_events, '[]'::jsonb))
           as x (reason_code text, qty numeric, disposition text)
    group by x.reason_code, x.disposition
  loop
    if v_event.qty is null or v_event.qty <= 0 or v_event.qty <> trunc(v_event.qty) then
      raise exception 'Every scrap or rework line needs a whole quantity above zero';
    end if;
    if v_event.disposition is null or v_event.disposition not in ('scrap', 'rework') then
      raise exception 'Each line must be marked scrap or rework';
    end if;
    if not exists (select 1 from reason_codes
                   where code = v_event.reason_code and kind = 'scrap' and is_active) then
      raise exception 'Choose a reason code for every scrap or rework line';
    end if;

    insert into production_scrap (production_order_id, qty, reason_code, disposition)
    values (p_order_id, v_event.qty, v_event.reason_code, v_event.disposition);

    if v_event.disposition = 'scrap' then
      v_scrapped := v_scrapped + v_event.qty;
    else
      v_reworked := v_reworked + v_event.qty;
    end if;
  end loop;

  v_good := v_order.qty_started - v_scrapped;
  if v_good < 0 then
    raise exception 'Scrapped (%) is more than the % boards started', v_scrapped, v_order.qty_started;
  end if;
  if v_reworked > v_good then
    raise exception 'Reworked (%) is more than the % good boards', v_reworked, v_good;
  end if;

  -- Roll the cost up from the parts that were issued.
  select coalesce(sum(qty_issued * unit_cost), 0) into v_total
  from production_order_components where production_order_id = p_order_id;
  v_unit := round(v_total / v_order.qty_started, 4);

  if v_good > 0 then
    perform wbc_post_movement(
      v_order.item_id, coalesce(v_order.destination_location_id, v_order.location_id),
      v_good, v_unit,
      'production_receipt', null, 'production_order', p_order_id,
      'MO-' || lpad(p_order_id::text, 5, '0'), v_finish, true);
  end if;

  update production_orders
  set status = 'completed', finished_at = v_finish,
      qty_good = v_good, qty_scrapped = v_scrapped, qty_reworked = v_reworked
  where id = p_order_id;

  return v_good;
end;
$$;

-- cancel_production_order: drop a job that has not been issued yet.
create or replace function public.cancel_production_order(p_order_id bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_status text;
begin
  if not is_staff() then
    raise exception 'Only staff can cancel production orders';
  end if;
  select status into v_status from production_orders where id = p_order_id for update;
  if not found then
    raise exception 'Production order not found';
  end if;
  if v_status <> 'planned' then
    raise exception 'Parts have already been issued, so this order cannot be cancelled. Complete it instead.';
  end if;
  update production_orders set status = 'cancelled' where id = p_order_id;
end;
$$;

revoke execute on function public.create_production_order(bigint, numeric, text)          from public, anon;
revoke execute on function public.issue_production_order(bigint, timestamptz)             from public, anon;
revoke execute on function public.complete_production_order(bigint, jsonb, timestamptz)   from public, anon;
revoke execute on function public.cancel_production_order(bigint)                         from public, anon;
grant execute on function public.create_production_order(bigint, numeric, text)           to authenticated;
grant execute on function public.issue_production_order(bigint, timestamptz)              to authenticated;
grant execute on function public.complete_production_order(bigint, jsonb, timestamptz)    to authenticated;
grant execute on function public.cancel_production_order(bigint)                          to authenticated;

-- =====================================================================
-- Views and reports (calculated, never stored)
-- =====================================================================

-- production_order_summary: one row per job with its costs and metrics.
--   planned_cost     = what the job would cost at today's part costs (BOM rollup x qty)
--   component_cost   = what the issued parts actually cost
--   unit_cost        = component_cost / boards started
--   good_value       = good boards x unit_cost  (went into stock)
--   scrap_cost       = the rest of the component cost (scrap expense)
--   final_yield      = good / started
--   first_pass_yield = (good - reworked) / started
--   build_hours      = finish time - start time
--   finished_date    = the Mountain-time day the job finished (for date filters)
create or replace view public.production_order_summary
with (security_invoker = true) as
select
  o.id as order_id,
  o.item_id,
  i.sku,
  i.name as item_name,
  o.location_id,
  o.status,
  o.qty_started,
  o.qty_good,
  o.qty_scrapped,
  o.qty_reworked,
  o.started_at,
  o.finished_at,
  (o.finished_at at time zone 'America/Denver')::date     as finished_date,
  o.note,
  o.created_at,
  round(o.qty_started * coalesce(ic.current_cost, 0), 2)  as planned_cost,
  round(coalesce(c.component_cost, 0), 2)                 as component_cost,
  round(coalesce(c.component_cost, 0) / o.qty_started, 4) as unit_cost,
  case when o.status = 'completed'
       then round(o.qty_good * round(coalesce(c.component_cost, 0) / o.qty_started, 4), 2) end as good_value,
  case when o.status = 'completed'
       then round(coalesce(c.component_cost, 0), 2)
            - round(o.qty_good * round(coalesce(c.component_cost, 0) / o.qty_started, 4), 2) end as scrap_cost,
  case when o.status = 'completed' then o.qty_good / o.qty_started end                    as final_yield,
  case when o.status = 'completed' then (o.qty_good - o.qty_reworked) / o.qty_started end as first_pass_yield,
  case when o.finished_at is not null
       then round(extract(epoch from (o.finished_at - o.started_at)) / 3600.0, 2) end     as build_hours
from public.production_orders o
join public.items i on i.id = o.item_id
left join public.item_costs ic on ic.item_id = o.item_id
left join (
  select production_order_id, sum(qty_issued * unit_cost) as component_cost
  from public.production_order_components
  group by production_order_id
) c on c.production_order_id = o.id;

-- production_report: the totals for jobs FINISHED between two dates
-- (Mountain time). One row. This is what the Production report shows.
--   scrap_rate        = scrapped / started
--   avg_build_hours   = average job length
--   minutes_per_board = total build time / boards started
drop function if exists public.production_report(date, date);
create function public.production_report(p_from date, p_to date)
returns table (
  orders             bigint,
  units_started      numeric,
  units_good         numeric,
  units_scrapped     numeric,
  units_reworked     numeric,
  final_yield        numeric,
  first_pass_yield   numeric,
  scrap_rate         numeric,
  avg_build_hours    numeric,
  minutes_per_board  numeric,
  good_value         numeric,
  scrap_cost         numeric
)
language sql
stable
set search_path = public
as $$
  select
    count(*),
    coalesce(sum(qty_started), 0),
    coalesce(sum(qty_good), 0),
    coalesce(sum(qty_scrapped), 0),
    coalesce(sum(qty_reworked), 0),
    sum(qty_good) / nullif(sum(qty_started), 0),
    sum(qty_good - qty_reworked) / nullif(sum(qty_started), 0),
    sum(qty_scrapped) / nullif(sum(qty_started), 0),
    round(avg(build_hours), 2),
    round(sum(build_hours) * 60 / nullif(sum(qty_started), 0), 1),
    coalesce(sum(good_value), 0),
    coalesce(sum(scrap_cost), 0)
  from production_order_summary
  where status = 'completed'
    and finished_date between p_from and p_to;
$$;

-- production_scrap_report: scrap and rework by reason for the same
-- date range. rate = units for that reason / all boards started in the range.
drop function if exists public.production_scrap_report(date, date);
create function public.production_scrap_report(p_from date, p_to date)
returns table (
  reason_code  text,
  reason       text,
  disposition  text,
  qty          numeric,
  rate         numeric,
  cost         numeric
)
language sql
stable
set search_path = public
as $$
  with done as (
    select order_id, qty_started, unit_cost
    from production_order_summary
    where status = 'completed'
      and finished_date between p_from and p_to
  )
  select
    s.reason_code,
    r.label,
    s.disposition,
    sum(s.qty),
    sum(s.qty) / nullif((select sum(qty_started) from done), 0),
    -- Only scrapped boards cost money here; reworked boards went into stock.
    round(sum(case when s.disposition = 'scrap' then s.qty * d.unit_cost else 0 end), 2)
  from production_scrap s
  join done d on d.order_id = s.production_order_id
  join reason_codes r on r.code = s.reason_code
  group by s.reason_code, r.label, s.disposition
  order by s.disposition desc, sum(s.qty) desc, r.label;
$$;

revoke execute on function public.production_report(date, date)       from public, anon;
revoke execute on function public.production_scrap_report(date, date) from public, anon;
grant execute on function public.production_report(date, date)        to authenticated;
grant execute on function public.production_scrap_report(date, date)  to authenticated;

-- =====================================================================
-- Security: staff can read; all writes go through the functions above.
-- =====================================================================
alter table public.production_orders           enable row level security;
alter table public.production_order_components enable row level security;
alter table public.production_scrap            enable row level security;

do $$
declare
  t text;
begin
  foreach t in array array['production_orders', 'production_order_components', 'production_scrap'] loop
    execute format('drop policy if exists staff_read on public.%I', t);
    execute format(
      'create policy staff_read on public.%I for select to authenticated using (public.is_staff())', t);
    execute format('revoke insert, update, delete on public.%I from anon, authenticated', t);
  end loop;
end;
$$;

-- Realtime on production orders.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'production_orders'
  ) then
    alter publication supabase_realtime add table public.production_orders;
  end if;
end;
$$;

-- Result shown after running: the 3 new tables.
select table_name
from information_schema.tables
where table_schema = 'public'
  and table_name in ('production_orders', 'production_order_components', 'production_scrap')
order by table_name;
