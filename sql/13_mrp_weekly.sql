-- =====================================================================
-- Wasatch Board Co. ERP — 13: weekly MRP (the next 4 weeks)
-- Run AFTER file 12. Safe to run more than once. Adds no tables.
-- =====================================================================

-- ---------------------------------------------------------------------
-- mrp_weekly: a week-by-week material plan.
-- Week 1 starts today; each week is 7 days. One row per item per week.
--
-- For every item and week:
--   forecast   = expected sales that week (average daily sales x 7)
--   orders     = units on placed sales orders wanted that week
--                (an order that is already overdue counts in week 1)
--   dependent  = parts only: boards to build that week x BOM quantity,
--                plus parts for planned production orders (week 1)
--   gross      = forecast + orders + dependent
--   scheduled  = already coming that week:
--                  boards: open production orders (counted in week 1)
--                  parts:  sent purchase orders, in the week of their
--                          expected date (overdue ones count in week 1)
--   net        = what is still short that week after stock on hand and
--                scheduled receipts. This is the planned order quantity.
--   projected  = stock left at the end of the week once the planned
--                order has arrived
--   order_by_date = the week's start date minus the lead time
--                (parts: supplier lead time; boards: 1 day to build),
--                never earlier than today
--   overdue    = parts only: true when that date had already passed,
--                so the part cannot arrive in time even if ordered today
--
-- How the two levels connect: the boards are planned first. Each
-- board's net (boards to build in a week) is multiplied through the
-- bill of materials to become the parts' dependent demand in that week.
-- ---------------------------------------------------------------------
drop function if exists public.mrp_weekly(integer);
create function public.mrp_weekly(p_weeks integer default 4)
returns table (
  level           text,
  item_id         bigint,
  sku             text,
  name            text,
  supplier_id     bigint,
  lead_time_days  integer,
  on_hand         numeric,
  week_no         integer,
  week_start      date,
  forecast        numeric,
  orders          numeric,
  dependent       numeric,
  gross           numeric,
  scheduled       numeric,
  net             numeric,
  projected       numeric,
  order_by_date   date,
  overdue         boolean
)
language sql
stable
set search_path = public
as $$
  with weeks as (
    select g as week_no, wbc_today() + 7 * (g - 1) as week_start
    from generate_series(1, greatest(coalesce(p_weeks, 4), 1)) as g
  ),
  plan as (
    select item_id, sku, name, item_type, supplier_id, lead_time_days, on_hand, avg_daily_sales
    from item_planning
  ),
  -- Open sales order lines, put into the week they are wanted.
  so_week as (
    select l.item_id,
           greatest(1, (coalesce(o.requested_date, wbc_today()) - wbc_today()) / 7 + 1) as week_no,
           sum(l.qty - l.qty_fulfilled) as qty
    from sales_order_lines l
    join sales_orders o on o.id = l.order_id
    where o.status = 'placed'
    group by 1, 2
  ),
  -- Sent purchase orders, put into the week they are expected.
  po_week as (
    select s.item_id,
           greatest(1, (coalesce(po.expected_date, wbc_today()) - wbc_today()) / 7 + 1) as week_no,
           sum(s.qty_open) as qty
    from po_line_status s
    join purchase_orders po on po.id = s.po_id
    where s.qty_open > 0
    group by 1, 2
  ),
  -- Open production orders: finished boards coming, and parts they still need.
  mo_boards as (
    select item_id, sum(qty_started) as qty
    from production_orders where status in ('planned', 'in_progress')
    group by item_id
  ),
  mo_parts as (
    select item_id, qty from planned_job_parts
  ),

  -- ============ level 1: boards ============
  b_rows as (
    select p.item_id, w.week_no, w.week_start, p.on_hand,
           -- rounding the running total keeps slow sellers from rounding up every week
           round(p.avg_daily_sales * 7 * w.week_no) - round(p.avg_daily_sales * 7 * (w.week_no - 1)) as forecast,
           coalesce(so.qty, 0) as orders,
           0::numeric as dependent,
           case when w.week_no = 1 then coalesce(mo.qty, 0) else 0 end as scheduled
    from plan p
    cross join weeks w
    left join so_week so on so.item_id = p.item_id and so.week_no = w.week_no
    left join mo_boards mo on mo.item_id = p.item_id
    where p.item_type = 'complete'
  ),
  b_cum as (
    select r.*,
           sum(r.forecast + r.orders) over (partition by r.item_id order by r.week_no) as cum_gross,
           sum(r.scheduled)           over (partition by r.item_id order by r.week_no) as cum_sched
    from b_rows r
  ),
  b_short as (
    -- the biggest shortfall so far = everything that has had to be planned up to this week
    select c.*,
           greatest(0, max(c.cum_gross - c.on_hand - c.cum_sched)
                         over (partition by c.item_id order by c.week_no)) as cum_planned
    from b_cum c
  ),
  b_net as (
    select s.*,
           s.cum_planned - coalesce(lag(s.cum_planned) over (partition by s.item_id order by s.week_no), 0) as net
    from b_short s
  ),

  -- ============ level 2: parts ============
  builds as (
    select bl.component_item_id as item_id, n.week_no, sum(n.net * bl.qty) as qty
    from b_net n
    join bom_lines bl on bl.parent_item_id = n.item_id
    group by bl.component_item_id, n.week_no
  ),
  c_rows as (
    select p.item_id, w.week_no, w.week_start, p.on_hand,
           round(p.avg_daily_sales * 7 * w.week_no) - round(p.avg_daily_sales * 7 * (w.week_no - 1)) as forecast,
           coalesce(so.qty, 0) as orders,
           coalesce(bd.qty, 0) + case when w.week_no = 1 then coalesce(mp.qty, 0) else 0 end as dependent,
           coalesce(po.qty, 0) as scheduled
    from plan p
    cross join weeks w
    left join so_week so on so.item_id = p.item_id and so.week_no = w.week_no
    left join po_week po on po.item_id = p.item_id and po.week_no = w.week_no
    left join builds bd  on bd.item_id = p.item_id and bd.week_no = w.week_no
    left join mo_parts mp on mp.item_id = p.item_id
    where p.item_type = 'part'
  ),
  c_cum as (
    select r.*,
           sum(r.forecast + r.orders + r.dependent) over (partition by r.item_id order by r.week_no) as cum_gross,
           sum(r.scheduled)                         over (partition by r.item_id order by r.week_no) as cum_sched
    from c_rows r
  ),
  c_short as (
    select c.*,
           greatest(0, max(c.cum_gross - c.on_hand - c.cum_sched)
                         over (partition by c.item_id order by c.week_no)) as cum_planned
    from c_cum c
  ),
  c_net as (
    select s.*,
           s.cum_planned - coalesce(lag(s.cum_planned) over (partition by s.item_id order by s.week_no), 0) as net
    from c_short s
  ),
  both_levels as (
    select 'board' as level, * from b_net
    union all
    select 'part' as level, * from c_net
  )
  select
    x.level, x.item_id, p.sku, p.name, p.supplier_id, p.lead_time_days, x.on_hand,
    x.week_no, x.week_start,
    x.forecast, x.orders, x.dependent,
    x.forecast + x.orders + x.dependent,
    x.scheduled,
    x.net,
    x.on_hand + x.cum_sched + x.cum_planned - x.cum_gross,
    case when x.net > 0 then greatest(wbc_today(), x.week_start - p.lead_time_days) end,
    (x.net > 0 and x.level = 'part' and x.week_start - p.lead_time_days < wbc_today())
  from both_levels x
  join plan p on p.item_id = x.item_id
  order by x.level, p.sku, x.week_no;
$$;

revoke execute on function public.mrp_weekly(integer) from public, anon;
grant execute on function public.mrp_weekly(integer)  to authenticated;

-- Result shown after running: every planned order in the next 4 weeks.
select level, sku, name, week_no, week_start, gross, scheduled, net, order_by_date, overdue
from public.mrp_weekly(4)
where net > 0
order by level, sku, week_no;
