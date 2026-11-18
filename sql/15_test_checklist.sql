-- =====================================================================
-- Wasatch Board Co. ERP — 15: shared test checklist
-- Run AFTER file 14. Safe to run more than once.
-- Not part of the business system: it stores the team's results for
-- the tests in TESTING.md, so everyone sees the same ticks.
-- =====================================================================

-- ---------------------------------------------------------------------
-- test_results: one row per test that someone has marked.
--   test_id     = the test's number in TESTING.md, for example 'H5'
--   status      = 'pass' or 'fail'
--   note        = what happened (especially for a failure)
--   tester_name = who marked it, copied from their login
-- A test with no row has not been tested yet.
-- ---------------------------------------------------------------------
create table if not exists public.test_results (
  test_id      text primary key,
  status       text not null check (status in ('pass', 'fail')),
  note         text,
  tester_name  text,
  tested_by    uuid references auth.users (id) on delete set null default auth.uid(),
  updated_at   timestamptz not null default now()
);

-- Staff can read and change results directly (it is a single table, so
-- no database function is needed). Customers cannot see it.
alter table public.test_results enable row level security;
drop policy if exists staff_all on public.test_results;
create policy staff_all on public.test_results
  for all to authenticated
  using (public.is_staff()) with check (public.is_staff());

-- Realtime, so a tick made by one teammate shows on everyone's screen.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'test_results'
  ) then
    alter publication supabase_realtime add table public.test_results;
  end if;
end;
$$;

-- Result shown after running: the new table.
select table_name from information_schema.tables
where table_schema = 'public' and table_name = 'test_results';
