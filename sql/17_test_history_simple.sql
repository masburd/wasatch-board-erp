-- =====================================================================
-- Wasatch Board Co. ERP — 17: simpler test history
-- Run AFTER file 16. Safe to run more than once.
-- The history now keeps one line per result, for example:
--   Failed — why it failed
--   Passed — how it was fixed
-- Rules:
--   * Pass or Fail on a test whose result is different → a new line.
--   * Clicking the same result again with a new note → that line's note
--     is updated (no new line).
--   * Clear → the test starts over: its result and its lines are removed.
-- It also tidies the lines already saved under the old rules.
-- =====================================================================

create or replace function public.wbc_log_test_result()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Clear: start the test over.
  if tg_op = 'DELETE' then
    delete from public.test_result_history where test_id = old.test_id;
    return old;
  end if;

  -- Same result as before: only correct the note on its latest line.
  if tg_op = 'UPDATE' and old.status = new.status then
    if old.note is distinct from new.note then
      update public.test_result_history
      set note = new.note, tester_name = new.tester_name, changed_at = now()
      where id = (select max(id) from public.test_result_history where test_id = new.test_id);
    end if;
    return new;
  end if;

  -- A new result (first time, or Pass after Fail, or Fail after Pass).
  insert into public.test_result_history (test_id, status, note, tester_name, changed_by)
  values (new.test_id, new.status, new.note, new.tester_name, coalesce(new.tested_by, auth.uid()));
  return new;
end;
$$;

-- ---------------------------------------------------------------------
-- Tidy the lines saved under the old rules.
-- ---------------------------------------------------------------------

-- 1. Old "Cleared" lines, and lines of tests that have no result now.
delete from public.test_result_history h
where h.status = 'cleared'
   or not exists (select 1 from public.test_results r where r.test_id = h.test_id);

-- 2. Several lines in a row with the same result (note edits): keep only
--    the last one of each run.
delete from public.test_result_history h
using (
  select id, status,
         lead(status) over (partition by test_id order by changed_at, id) as next_status
  from public.test_result_history
) x
where h.id = x.id and x.next_status = x.status;

-- 3. The last line of each test shows the note the test has now.
update public.test_result_history h
set note = r.note
from public.test_results r
where h.test_id = r.test_id
  and h.id = (select max(id) from public.test_result_history where test_id = r.test_id)
  and h.note is distinct from r.note;

-- Result shown after running: lines per test that has more than one.
select test_id, count(*) as lines
from public.test_result_history
group by test_id
having count(*) > 1
order by test_id;
