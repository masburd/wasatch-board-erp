-- =====================================================================
-- Wasatch Board Co. ERP — 18: faster Financials
-- Run AFTER file 17. Safe to run more than once.
-- The P&L and turnover read a year of sales, returns, production and
-- ledger rows. Run as the signed-in user, the security rules were checked
-- on every one of those rows, which could take longer than Supabase
-- allows a browser request (about 8 seconds), so Financials stayed on
-- "Loading…". The two functions now run with the database owner's rights
-- (security definer) and check once, at the end, that the caller is staff.
-- The calculations are exactly the same as in file 12.
-- =====================================================================

create or replace function public.pnl(p_from date, p_to date, p_by text default 'total')
returns table (
  period_start   date,
  revenue        numeric,
  refunds        numeric,
  net_sales      numeric,
  cogs_sold      numeric,
  cogs_returned  numeric,
  cogs           numeric,
  gross_profit   numeric,
  gross_margin   numeric,
  scrap          numeric,
  write_offs     numeric,
  adjustments    numeric,
  profit         numeric,
  tax_collected  numeric
)
language sql
stable
security definer
set search_path = public
as $$
  with events as (
    -- sales
    select (coalesce(o.fulfilled_at, o.order_date) at time zone 'America/Denver')::date as day,
           o.revenue as revenue, 0::numeric as refunds, o.cogs as cogs_sold, 0::numeric as cogs_returned,
           0::numeric as scrap, 0::numeric as write_offs, 0::numeric as adjustments,
           round(o.revenue * o.tax_rate, 2) as tax
    from sales_order_totals o
    union all
    -- returns
    select (r.return_date at time zone 'America/Denver')::date,
           0, r.refund_net, 0, r.cogs_reversed, 0, r.write_off, 0, -r.refund_tax
    from return_totals r
    union all
    -- production scrap
    select p.finished_date, 0, 0, 0, 0, p.scrap_cost, 0, 0, 0
    from production_order_summary p
    where p.status = 'completed'
    union all
    -- stock count adjustments: a loss of stock is a positive cost
    select (m.occurred_at at time zone 'America/Denver')::date,
           0, 0, 0, 0, 0, 0, -(m.qty_change * m.unit_cost), 0
    from inventory_movements m
    where m.movement_type = 'adjustment'
  ),
  grouped as (
    select
      case when p_by = 'month' then date_trunc('month', e.day)::date else p_from end as period_start,
      sum(e.revenue)       as revenue,
      sum(e.refunds)       as refunds,
      sum(e.cogs_sold)     as cogs_sold,
      sum(e.cogs_returned) as cogs_returned,
      sum(e.scrap)         as scrap,
      sum(e.write_offs)    as write_offs,
      sum(e.adjustments)   as adjustments,
      sum(e.tax)           as tax
    from events e
    where e.day between p_from and p_to
    group by 1
  )
  select
    g.period_start,
    round(g.revenue, 2),
    round(g.refunds, 2),
    round(g.revenue - g.refunds, 2),
    round(g.cogs_sold, 2),
    round(g.cogs_returned, 2),
    round(g.cogs_sold - g.cogs_returned, 2),
    round(g.revenue - g.refunds - (g.cogs_sold - g.cogs_returned), 2),
    round((g.revenue - g.refunds - (g.cogs_sold - g.cogs_returned)) / nullif(g.revenue - g.refunds, 0), 4),
    round(g.scrap, 2),
    round(g.write_offs, 2),
    round(g.adjustments, 2),
    round(g.revenue - g.refunds - (g.cogs_sold - g.cogs_returned)
          - g.scrap - g.write_offs - g.adjustments, 2),
    round(g.tax, 2)
  from grouped g
  where public.is_staff()
  order by g.period_start;
$$;

create or replace function public.inventory_turnover(p_from date, p_to date)
returns table (
  days                 integer,
  cogs                 numeric,
  avg_inventory_value  numeric,
  turnover             numeric,
  annual_turnover      numeric,
  days_of_inventory    numeric
)
language sql
stable
security definer
set search_path = public
as $$
  with daily as (
    select (m.occurred_at at time zone 'America/Denver')::date as day,
           sum(m.qty_change * m.unit_cost) as delta
    from inventory_movements m
    group by 1
  ),
  span as (
    select p_from + g as day
    from generate_series(0, least(p_to, wbc_today()) - p_from) as g
  ),
  balance as (
    select s.day,
           (select coalesce(sum(d.delta), 0) from daily d where d.day <= s.day) as value
    from span s
  ),
  totals as (
    select count(*)::int as days, avg(b.value) as avg_value from balance b
  ),
  cost as (
    select coalesce((select p.cogs from pnl(p_from, p_to, 'total') p), 0) as cogs
  )
  select
    t.days,
    c.cogs,
    round(t.avg_value, 2),
    round(c.cogs / nullif(t.avg_value, 0), 2),
    round(c.cogs / nullif(t.avg_value, 0) * 365.0 / nullif(t.days, 0), 2),
    round(t.days / nullif(c.cogs / nullif(t.avg_value, 0), 0), 1)
  from totals t cross join cost c
  where public.is_staff();
$$;

revoke execute on function public.pnl(date, date, text)          from public, anon;
revoke execute on function public.inventory_turnover(date, date) from public, anon;
grant execute on function public.pnl(date, date, text)           to authenticated;
grant execute on function public.inventory_turnover(date, date)  to authenticated;

-- Result shown after running: both functions, now "DEFINER".
-- (The SQL Editor is not a staff login, so calling pnl() here returns no rows.)
select routine_name, security_type
from information_schema.routines
where routine_schema = 'public' and routine_name in ('pnl', 'inventory_turnover');
