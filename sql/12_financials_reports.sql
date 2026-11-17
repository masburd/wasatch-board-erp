-- =====================================================================
-- Wasatch Board Co. ERP — 12: financials and reports
-- Run AFTER file 11. Safe to run more than once. It adds no tables:
-- every number is calculated from sales, returns, production and the
-- inventory ledger. There is no general ledger.
-- =====================================================================

-- ---------------------------------------------------------------------
-- sales_facts: one row per sales line with the date and place it counts.
--   sale_date = the Mountain-time day the goods were handed over
--               (for a till sale that is the moment of the sale)
--   units, revenue and cogs count handed-over units only.
-- Every sales report below reads from this one view.
-- ---------------------------------------------------------------------
create or replace view public.sales_facts
with (security_invoker = true) as
select
  t.line_id,
  t.order_id,
  t.item_id,
  o.location_id,
  o.customer_id,
  o.channel,
  (coalesce(o.fulfilled_at, o.order_date) at time zone 'America/Denver')::date as sale_date,
  t.qty_fulfilled as units,
  t.revenue,
  t.cogs
from public.sales_line_totals t
join public.sales_orders o on o.id = t.order_id
where t.qty_fulfilled > 0;

-- ---------------------------------------------------------------------
-- pnl: the profit and loss statement for a date range.
-- p_by = 'total' gives one row; p_by = 'month' gives one row per month.
--   revenue          sales after discount, before tax
--   refunds          refunds given on returns (before tax)
--   net_sales        revenue - refunds
--   cogs_sold        cost of the units sold
--   cogs_returned    cost taken back off when units were returned
--   cogs             cogs_sold - cogs_returned
--   gross_profit     net_sales - cogs
--   scrap            parts used on boards scrapped in production
--   write_offs       returned units too damaged to restock
--   adjustments      stock count losses (a gain shows as a negative)
--   profit           gross_profit - scrap - write_offs - adjustments
--   tax_collected    sales tax taken less tax refunded (owed to the
--                    state; it is not revenue)
-- ---------------------------------------------------------------------
drop function if exists public.pnl(date, date, text);
create function public.pnl(p_from date, p_to date, p_by text default 'total')
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
  order by g.period_start;
$$;

-- ---------------------------------------------------------------------
-- inventory_turnover: how many times stock "turned over" in a date range.
--   avg_inventory_value = the average of each day's closing stock value.
--       A day's stock value is the running total of the ledger
--       (quantity change x unit cost of every movement up to that day).
--   turnover            = COGS in the range / avg_inventory_value
--   annual_turnover     = turnover scaled to a 365-day year
--   days_of_inventory   = days in the range / turnover
-- ---------------------------------------------------------------------
drop function if exists public.inventory_turnover(date, date);
create function public.inventory_turnover(p_from date, p_to date)
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
  from totals t cross join cost c;
$$;

-- ---------------------------------------------------------------------
-- Inventory valuation views (weighted average cost).
--   inventory_value_detail      = one row per item per location
--   inventory_value_by_location = totals per location
-- value = quantity on hand x the item's current average cost.
-- ---------------------------------------------------------------------
create or replace view public.inventory_value_detail
with (security_invoker = true) as
select
  v.item_id, i.sku, i.name, i.item_type, i.category,
  v.location_id, l.code as location_code,
  v.qty_on_hand, v.unit_cost, round(v.value, 2) as value
from public.inventory_value v
join public.items i on i.id = v.item_id
join public.locations l on l.id = v.location_id;

create or replace view public.inventory_value_by_location
with (security_invoker = true) as
select
  l.id as location_id, l.code, l.name,
  coalesce(sum(v.qty_on_hand), 0)                                        as units,
  round(coalesce(sum(v.value), 0), 2)                                    as value,
  round(coalesce(sum(v.value) filter (where i.item_type = 'part'), 0), 2)     as parts_value,
  round(coalesce(sum(v.value) filter (where i.item_type = 'complete'), 0), 2) as boards_value
from public.locations l
left join public.inventory_value v on v.location_id = l.id
left join public.items i on i.id = v.item_id
group by l.id, l.code, l.name;

-- ---------------------------------------------------------------------
-- report_sales: sales grouped by day, week (starting Monday) or month.
-- Returns are not taken off here; the P&L does that.
-- ---------------------------------------------------------------------
drop function if exists public.report_sales(date, date, text);
create function public.report_sales(p_from date, p_to date, p_grain text default 'day')
returns table (
  period_start  date,
  orders        bigint,
  units         numeric,
  revenue       numeric,
  cogs          numeric,
  gross_profit  numeric
)
language sql
stable
set search_path = public
as $$
  select
    date_trunc(case when p_grain in ('week', 'month') then p_grain else 'day' end, f.sale_date)::date,
    count(distinct f.order_id),
    sum(f.units),
    round(sum(f.revenue), 2),
    round(sum(f.cogs), 2),
    round(sum(f.revenue) - sum(f.cogs), 2)
  from sales_facts f
  where f.sale_date between p_from and p_to
  group by 1
  order by 1;
$$;

-- report_sales_by_location: the same totals split by location.
drop function if exists public.report_sales_by_location(date, date);
create function public.report_sales_by_location(p_from date, p_to date)
returns table (
  location_code  text,
  location_name  text,
  orders         bigint,
  units          numeric,
  revenue        numeric,
  gross_profit   numeric,
  revenue_share  numeric
)
language sql
stable
set search_path = public
as $$
  select
    l.code, l.name,
    count(distinct f.order_id),
    coalesce(sum(f.units), 0),
    round(coalesce(sum(f.revenue), 0), 2),
    round(coalesce(sum(f.revenue) - sum(f.cogs), 0), 2),
    round(coalesce(sum(f.revenue), 0) / nullif(sum(sum(f.revenue)) over (), 0), 4)
  from locations l
  left join sales_facts f on f.location_id = l.id and f.sale_date between p_from and p_to
  group by l.id, l.code, l.name
  order by l.id;
$$;

-- report_top_sellers: items ranked by revenue in the date range.
drop function if exists public.report_top_sellers(date, date, integer);
create function public.report_top_sellers(p_from date, p_to date, p_limit integer default 10)
returns table (
  item_id       bigint,
  sku           text,
  name          text,
  units         numeric,
  revenue       numeric,
  gross_profit  numeric,
  gross_margin  numeric
)
language sql
stable
set search_path = public
as $$
  select
    i.id, i.sku, i.name,
    sum(f.units),
    round(sum(f.revenue), 2),
    round(sum(f.revenue) - sum(f.cogs), 2),
    round((sum(f.revenue) - sum(f.cogs)) / nullif(sum(f.revenue), 0), 4)
  from sales_facts f
  join items i on i.id = f.item_id
  where f.sale_date between p_from and p_to
  group by i.id, i.sku, i.name
  order by sum(f.revenue) desc, i.sku
  limit greatest(coalesce(p_limit, 10), 1);
$$;

-- ---------------------------------------------------------------------
-- low_stock_report: parts with the date an order has to be placed.
--   days_until_reorder = (stock + on order - reorder point) / daily usage
--   order_by_date      = today + that many days (today if already below)
-- The reorder point already allows for the supplier's lead time, so
-- ordering by this date means the stock arrives before it runs out.
-- ---------------------------------------------------------------------
create or replace view public.low_stock_report
with (security_invoker = true) as
select
  p.item_id, p.sku, p.name, p.supplier_id, s.name as supplier_name,
  p.on_hand, p.on_order, p.position, p.reorder_point, p.avg_daily_usage,
  p.lead_time_days, p.suggested_qty, p.needs_reorder, p.days_of_stock,
  case
    when p.needs_reorder then 0
    when p.avg_daily_usage > 0 then floor((p.position - p.reorder_point) / p.avg_daily_usage)
  end as days_until_reorder,
  case
    when p.needs_reorder then public.wbc_today()
    when p.avg_daily_usage > 0
      then public.wbc_today() + floor((p.position - p.reorder_point) / p.avg_daily_usage)::int
  end as order_by_date
from public.item_planning p
left join public.suppliers s on s.id = p.supplier_id
where p.item_type = 'part';

revoke execute on function public.pnl(date, date, text)                        from public, anon;
revoke execute on function public.inventory_turnover(date, date)               from public, anon;
revoke execute on function public.report_sales(date, date, text)               from public, anon;
revoke execute on function public.report_sales_by_location(date, date)         from public, anon;
revoke execute on function public.report_top_sellers(date, date, integer)      from public, anon;
grant execute on function public.pnl(date, date, text)                         to authenticated;
grant execute on function public.inventory_turnover(date, date)                to authenticated;
grant execute on function public.report_sales(date, date, text)                to authenticated;
grant execute on function public.report_sales_by_location(date, date)          to authenticated;
grant execute on function public.report_top_sellers(date, date, integer)       to authenticated;

-- Result shown after running: the P&L for the last 365 days.
select revenue, refunds, net_sales, cogs, gross_profit, gross_margin,
       scrap, write_offs, adjustments, profit
from public.pnl(public.wbc_today() - 365, public.wbc_today(), 'total');
