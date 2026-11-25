-- =====================================================================
-- Wasatch Board Co. ERP — 16: history for the test checklist
-- Run AFTER file 15. Safe to run more than once.
-- Every time a test is marked Pass or Fail, its note is changed, or it
-- is cleared, a row is added here. Rows are never changed or deleted,
-- so a test that failed and was fixed still shows the failure.
-- =====================================================================

create table if not exists public.test_result_history (
  id           bigint generated always as identity primary key,
  test_id      text not null,
  status       text not null check (status in ('pass', 'fail', 'cleared')),
  note         text,
  tester_name  text,
  changed_by   uuid references auth.users (id) on delete set null,
  changed_at   timestamptz not null default now()
);

create index if not exists test_result_history_test_idx
  on public.test_result_history (test_id, changed_at);

-- Staff can read the history. There is no insert, update or delete
-- policy, so the browser cannot change it; only the trigger below writes.
alter table public.test_result_history enable row level security;
drop policy if exists staff_read on public.test_result_history;
create policy staff_read on public.test_result_history
  for select to authenticated
  using (public.is_staff());

-- ---------------------------------------------------------------------
-- The trigger: copies each change on test_results into the history.
-- 'security definer' lets it write even though the browser cannot.
-- ---------------------------------------------------------------------
create or replace function public.wbc_log_test_result()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'DELETE' then
    insert into public.test_result_history (test_id, status, note, tester_name, changed_by)
    values (old.test_id, 'cleared', null,
            (select coalesce(full_name, email) from public.profiles where id = auth.uid()),
            auth.uid());
    return old;
  end if;

  -- Saving the same status and note again is not a change.
  if tg_op = 'UPDATE'
     and old.status is not distinct from new.status
     and old.note   is not distinct from new.note then
    return new;
  end if;

  insert into public.test_result_history (test_id, status, note, tester_name, changed_by)
  values (new.test_id, new.status, new.note, new.tester_name, coalesce(new.tested_by, auth.uid()));
  return new;
end;
$$;

drop trigger if exists log_test_result on public.test_results;
create trigger log_test_result
  after insert or update or delete on public.test_results
  for each row execute function public.wbc_log_test_result();

-- Results marked before this file was run: copy them in once, so
-- failures already recorded are not lost.
insert into public.test_result_history (test_id, status, note, tester_name, changed_by, changed_at)
select r.test_id, r.status, r.note, r.tester_name, r.tested_by, r.updated_at
from public.test_results r
where not exists (select 1 from public.test_result_history h where h.test_id = r.test_id);

-- Result shown after running: how many history rows there are.
select count(*) as history_rows from public.test_result_history;
