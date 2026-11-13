-- =====================================================================
-- Wasatch Board Co. ERP — 03: promote a login to staff
-- New logins start as "customer". Run this once per team member AFTER
-- creating their user in Supabase (Authentication > Users > Add user).
-- Replace the email and name in the SQL Editor before running.
-- Do not save real email addresses into this file: the repo is public.
-- =====================================================================

update public.profiles
set role = 'staff',
    full_name = 'Your Name'
where email = 'you@example.com';

-- Result shown after running: every login and its role.
select email, full_name, role from public.profiles order by email;
