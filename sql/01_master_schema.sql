-- =====================================================================
-- Wasatch Board Co. ERP — 01: master data tables
-- Paste this whole file into the Supabase SQL Editor and click Run.
-- Safe to run more than once.
-- =====================================================================

-- ---------------------------------------------------------------------
-- locations: the 3 places stock can physically be.
-- ---------------------------------------------------------------------
create table if not exists public.locations (
  id    bigint generated always as identity primary key,
  code  text not null unique,                 -- short name used on screens: OREM, PROVO, SLC
  name  text not null,
  type  text not null check (type in ('warehouse', 'store'))
);

-- ---------------------------------------------------------------------
-- suppliers: who we buy parts from, and what they promised us.
-- quoted_lead_time_days is the promise; the scorecard later compares it
-- with what actually happened on purchase orders.
-- ---------------------------------------------------------------------
create table if not exists public.suppliers (
  id                     bigint generated always as identity primary key,
  name                   text not null unique,
  contact_name           text,
  email                  text,
  phone                  text,
  quoted_lead_time_days  integer not null check (quoted_lead_time_days >= 0),
  payment_terms_days     integer not null check (payment_terms_days >= 0),  -- "Net 30" = 30
  is_active              boolean not null default true
);

-- ---------------------------------------------------------------------
-- items: every SKU. 20 parts we buy, 5 complete boards we assemble,
-- and 1 generic "Custom Board" SKU for Build Your Own Board orders.
--   standard_cost = the supplier's quoted price (default price on a PO)
--   avg_cost      = weighted average cost, maintained by the system
-- ---------------------------------------------------------------------
create table if not exists public.items (
  id                    bigint generated always as identity primary key,
  sku                   text not null unique,
  barcode               text not null unique,
  name                  text not null,
  item_type             text not null check (item_type in ('part', 'complete', 'custom')),
  category              text not null,
  supplier_id           bigint references public.suppliers (id),
  lead_time_days        integer check (lead_time_days >= 0),
  price                 numeric(10,2) check (price >= 0),
  standard_cost         numeric(10,2) check (standard_cost >= 0),
  avg_cost              numeric(12,4) not null default 0,
  review_interval_days  integer not null default 30 check (review_interval_days > 0),
  last_reviewed_at      timestamptz,
  is_active             boolean not null default true
);

-- A brand-new item has no purchase history, so its average cost starts at
-- the supplier's quoted cost. The first receipt re-averages it.
create or replace function public.items_set_initial_cost()
returns trigger
language plpgsql
as $$
begin
  new.avg_cost := coalesce(new.standard_cost, 0);
  return new;
end;
$$;

drop trigger if exists items_set_initial_cost on public.items;
create trigger items_set_initial_cost
  before insert on public.items
  for each row execute function public.items_set_initial_cost();

-- ---------------------------------------------------------------------
-- bom_lines: the bill of materials ("recipe"). One row per component of
-- each complete board.
-- ---------------------------------------------------------------------
create table if not exists public.bom_lines (
  id                 bigint generated always as identity primary key,
  parent_item_id     bigint not null references public.items (id) on delete cascade,
  component_item_id  bigint not null references public.items (id),
  qty                numeric(10,2) not null default 1 check (qty > 0),
  unique (parent_item_id, component_item_id),
  check (parent_item_id <> component_item_id)
);

-- ---------------------------------------------------------------------
-- customers: who we sell to. auth_user_id links a customer to a portal
-- login (filled in when the customer portal is built).
-- ---------------------------------------------------------------------
create table if not exists public.customers (
  id                bigint generated always as identity primary key,
  customer_no       text not null unique,
  name              text not null,
  customer_type     text not null check (customer_type in ('individual', 'business', 'walk_in')),
  email             text,
  phone             text,
  home_location_id  bigint references public.locations (id),
  auth_user_id      uuid unique references auth.users (id) on delete set null
);

-- ---------------------------------------------------------------------
-- profiles: one row per login, saying whether it is staff or a customer.
-- Supabase stores logins in its own auth.users table; this table adds
-- the role on top.
-- ---------------------------------------------------------------------
create table if not exists public.profiles (
  id                   uuid primary key references auth.users (id) on delete cascade,
  email                text,
  full_name            text,
  role                 text not null default 'customer' check (role in ('staff', 'customer')),
  default_location_id  bigint references public.locations (id),
  created_at           timestamptz not null default now()
);

-- Every new login automatically gets a profile with the safe default role
-- (customer). Staff are promoted by hand (see 03_make_me_staff.sql).
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, email)
  values (new.id, new.email)
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Catch any logins created before this file was run.
insert into public.profiles (id, email)
select id, email from auth.users
on conflict (id) do nothing;

-- ---------------------------------------------------------------------
-- settings: the editable numbers used in calculations (tax rate, EOQ
-- inputs, assembly fee). Stored once here so no page hard-codes them.
-- ---------------------------------------------------------------------
create table if not exists public.settings (
  key    text primary key,
  value  numeric not null,
  label  text not null,
  unit   text
);

-- ---------------------------------------------------------------------
-- reason_codes: the allowed "why" for adjustments, returns and scrap.
-- restock = false means a returned item must NOT go back into sellable stock.
-- ---------------------------------------------------------------------
create table if not exists public.reason_codes (
  code       text primary key,
  label      text not null,
  kind       text not null check (kind in ('adjustment', 'return', 'scrap')),
  restock    boolean not null default true,
  is_active  boolean not null default true
);

-- ---------------------------------------------------------------------
-- build_options: Build Your Own Board rules. For each deck, which parts
-- may be chosen in each slot.
-- ---------------------------------------------------------------------
create table if not exists public.build_options (
  id            bigint generated always as identity primary key,
  deck_item_id  bigint not null references public.items (id) on delete cascade,
  slot          text not null check (slot in ('trucks', 'wheels', 'bearings', 'grip')),
  item_id       bigint not null references public.items (id) on delete cascade,
  unique (deck_item_id, slot, item_id)
);

-- ---------------------------------------------------------------------
-- build_auto_adds: parts added automatically once a deck and wheels are
-- chosen (box, hardware, riser pads).
-- ---------------------------------------------------------------------
create table if not exists public.build_auto_adds (
  id             bigint generated always as identity primary key,
  deck_item_id   bigint not null references public.items (id) on delete cascade,
  wheel_item_id  bigint not null references public.items (id) on delete cascade,
  item_id        bigint not null references public.items (id) on delete cascade,
  unique (deck_item_id, wheel_item_id, item_id)
);

-- ---------------------------------------------------------------------
-- item_costs (view): the current cost of every item, always calculated.
--   part     -> its weighted average cost
--   complete -> rolled up from its BOM (sum of component qty x cost)
--   custom   -> no single cost; each custom build carries its own
-- ---------------------------------------------------------------------
create or replace view public.item_costs
with (security_invoker = true) as
select
  i.id as item_id,
  i.sku,
  i.item_type,
  case
    when i.item_type = 'part' then i.avg_cost
    when i.item_type = 'complete' then (
      select coalesce(sum(b.qty * c.avg_cost), 0)
      from public.bom_lines b
      join public.items c on c.id = b.component_item_id
      where b.parent_item_id = i.id
    )
    else null
  end as current_cost
from public.items i;

-- =====================================================================
-- Security. The key in js/config.js is public, so these rules are what
-- actually protect the data.
-- =====================================================================

-- True when the logged-in user is staff.
create or replace function public.is_staff()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and role = 'staff'
  );
$$;

alter table public.locations       enable row level security;
alter table public.suppliers       enable row level security;
alter table public.items           enable row level security;
alter table public.bom_lines       enable row level security;
alter table public.customers       enable row level security;
alter table public.profiles        enable row level security;
alter table public.settings        enable row level security;
alter table public.reason_codes    enable row level security;
alter table public.build_options   enable row level security;
alter table public.build_auto_adds enable row level security;

-- Staff can read and change all master data.
do $$
declare
  t text;
begin
  foreach t in array array[
    'locations', 'suppliers', 'items', 'bom_lines', 'customers',
    'settings', 'reason_codes', 'build_options', 'build_auto_adds'
  ] loop
    execute format('drop policy if exists staff_all on public.%I', t);
    execute format(
      'create policy staff_all on public.%I for all to authenticated
         using (public.is_staff()) with check (public.is_staff())', t);
  end loop;
end;
$$;

-- A customer can read their own customer record.
drop policy if exists customer_reads_self on public.customers;
create policy customer_reads_self on public.customers
  for select to authenticated
  using (auth_user_id = auth.uid());

-- Everyone can read their own profile; staff can read all profiles.
-- There is deliberately no insert/update policy: nobody can change their
-- own role from the browser.
drop policy if exists profile_read on public.profiles;
create policy profile_read on public.profiles
  for select to authenticated
  using (id = auth.uid() or public.is_staff());

-- avg_cost is maintained by the system only. Staff can edit the other
-- item columns, but the browser is not allowed to write avg_cost.
revoke insert, update on public.items from anon, authenticated;
grant insert (sku, barcode, name, item_type, category, supplier_id, lead_time_days,
              price, standard_cost, review_interval_days, last_reviewed_at, is_active)
  on public.items to authenticated;
grant update (sku, barcode, name, item_type, category, supplier_id, lead_time_days,
              price, standard_cost, review_interval_days, last_reviewed_at, is_active)
  on public.items to authenticated;

-- =====================================================================
-- Realtime: broadcast changes on these tables to every open browser.
-- =====================================================================
do $$
declare
  t text;
begin
  foreach t in array array['items', 'bom_lines'] loop
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t
    ) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end;
$$;

-- Result shown after running: the 10 tables that now exist.
select table_name
from information_schema.tables
where table_schema = 'public' and table_type = 'BASE TABLE'
order by table_name;
