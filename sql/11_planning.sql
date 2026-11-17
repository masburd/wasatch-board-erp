-- =====================================================================
-- Wasatch Board Co. ERP — 11: planning
--   reorder point, EOQ, due for review, MRP and the supplier scorecard
-- Run AFTER file 10. Safe to run more than once. It adds no tables:
-- everything here is calculated from the transactions already stored.
-- =====================================================================

-- Two more settings, editable on the Settings page.
insert into public.settings (key, value, label, unit) values
  ('usage_window_days', 90, 'Days of history used for average usage', 'days'),
  ('mrp_horizon_days',  30, 'MRP planning horizon',                   'days')
on conflict (key) do nothing;

-- ---------------------------------------------------------------------
-- item_usage_stats: how fast each item is used, straight from the ledger.
--   usage = units sold + units issued to production   (SPEC: part usage)
--   sales = units sold only
-- It looks at the last N full days (N = the usage_window_days setting,
-- ending yesterday) and counts days with no usage as zero.
--   avg_daily_usage = average units per day in the window      (d)
--   sd_daily_usage  = standard deviation of units per day      (sigma)
--   avg_daily_sales = average units SOLD per day (used by MRP)
--   annual_usage    = total usage in the last 365 days         (D)
-- ---------------------------------------------------------------------
create or replace view public.item_usage_stats
with (security_invoker = true) as
with win as (
  select coalesce((select value from public.settings where key = 'usage_window_days'), 90)::int as days
),
days as (
  select public.wbc_today() - g as day
  from generate_series(1, (select days from win)) as g
),
used as (
  select m.item_id,
         (m.occurred_at at time zone 'America/Denver')::date as day,
         sum(-m.qty_change)                                              as usage,
         sum(case when m.movement_type = 'sale' then -m.qty_change else 0 end) as sales
  from public.inventory_movements m
  where m.movement_type in ('sale', 'production_issue')
    and m.occurred_at >= (public.wbc_today() - 366)::timestamp at time zone 'America/Denver'
  group by m.item_id, (m.occurred_at at time zone 'America/Denver')::date
),
per_day as (
  select i.id as item_id, d.day,
         coalesce(u.usage, 0) as usage,
         coalesce(u.sales, 0) as sales
  from public.items i
  cross join days d
  left join used u on u.item_id = i.id and u.day = d.day
  where i.item_type in ('part', 'complete')
)
select
  p.item_id,
  (select days from win)                    as window_days,
  round(avg(p.usage), 4)                    as avg_daily_usage,
  round(coalesce(stddev_samp(p.usage), 0), 4) as sd_daily_usage,
  round(avg(p.sales), 4)                    as avg_daily_sales,
  coalesce((select sum(u.usage) from used u
            where u.item_id = p.item_id
              and u.day between public.wbc_today() - 365 and public.wbc_today() - 1), 0) as annual_usage
from per_day p
group by p.item_id;

-- ---------------------------------------------------------------------
-- item_planning: one row per part or board with its planning numbers.
--   lead_time_days = supplier lead time for a part; 1 day to build a board
--   on_order       = still coming on sent purchase orders (parts), or
--                    on planned / in-progress production orders (boards)
--   safety_stock   = z x sigma x sqrt(L)
--   reorder_point  = d x L + safety_stock
--   eoq            = sqrt(2 x D x S / H),  H = holding rate x unit cost
--   position       = on_hand + on_order
--   needs_reorder  = position has fallen to the reorder point
--   next_review_date / review_due = the periodic manual review
-- z, S and the holding rate come from the settings table.
-- ---------------------------------------------------------------------
create or replace view public.item_planning
with (security_invoker = true) as
with s as (
  select
    (select value from public.settings where key = 'service_level_z') as z,
    (select value from public.settings where key = 'ordering_cost')   as ordering_cost,
    (select value from public.settings where key = 'holding_rate')    as holding_rate
),
base as (
  select
    i.id as item_id, i.sku, i.name, i.item_type, i.category, i.supplier_id,
    case when i.item_type = 'part' then coalesce(i.lead_time_days, 0) else 1 end as lead_time_days,
    i.standard_cost,
    coalesce(c.current_cost, 0) as unit_cost,
    i.review_interval_days,
    i.last_reviewed_at,
    coalesce((select sum(l.qty_on_hand) from public.inventory_levels l where l.item_id = i.id), 0) as on_hand,
    case when i.item_type = 'part'
      then coalesce((select sum(p.qty_open) from public.po_line_status p where p.item_id = i.id), 0)
      else coalesce((select sum(o.qty_started) from public.production_orders o
                     where o.item_id = i.id and o.status in ('planned', 'in_progress')), 0)
    end as on_order,
    coalesce(u.avg_daily_usage, 0) as avg_daily_usage,
    coalesce(u.sd_daily_usage, 0)  as sd_daily_usage,
    coalesce(u.avg_daily_sales, 0) as avg_daily_sales,
    coalesce(u.annual_usage, 0)    as annual_usage,
    u.window_days
  from public.items i
  left join public.item_costs c on c.item_id = i.id
  left join public.item_usage_stats u on u.item_id = i.id
  where i.item_type in ('part', 'complete') and i.is_active
),
calc as (
  select
    b.*,
    round(s.z * b.sd_daily_usage * sqrt(b.lead_time_days::numeric), 2) as safety_stock,
    round(b.avg_daily_usage * b.lead_time_days
          + s.z * b.sd_daily_usage * sqrt(b.lead_time_days::numeric), 2) as reorder_point,
    case when b.unit_cost > 0 and s.holding_rate > 0
      then round(sqrt(2 * b.annual_usage * s.ordering_cost / (s.holding_rate * b.unit_cost)), 2)
    end as eoq,
    coalesce((b.last_reviewed_at at time zone 'America/Denver')::date + b.review_interval_days,
             public.wbc_today()) as next_review_date
  from base b cross join s
)
select
  c.*,
  c.on_hand + c.on_order                         as position,
  (c.on_hand + c.on_order <= c.reorder_point)    as needs_reorder,
  ceil(coalesce(c.eoq, 0))                       as suggested_qty,
  (c.next_review_date <= public.wbc_today())     as review_due,
  case when c.avg_daily_usage > 0
       then round(c.on_hand / c.avg_daily_usage, 1) end as days_of_stock
from calc c;

-- ---------------------------------------------------------------------
-- MRP, level 1: the boards.
--   forecast      = average boards sold per day x the horizon
--   open_orders   = boards on placed sales orders not yet handed over
--   gross         = forecast + open_orders
--   net           = gross - finished boards on hand - open production orders
--                   (never below zero). This is how many to build.
-- ---------------------------------------------------------------------
drop function if exists public.mrp_components(integer);
drop function if exists public.mrp_parents(integer);
create function public.mrp_parents(p_days integer)
returns table (
  item_id          bigint,
  sku              text,
  name             text,
  avg_daily_sales  numeric,
  forecast         numeric,
  open_orders      numeric,
  gross            numeric,
  on_hand          numeric,
  open_production  numeric,
  net              numeric
)
language sql
stable
set search_path = public
as $$
  select
    p.item_id, p.sku, p.name, p.avg_daily_sales,
    ceil(p.avg_daily_sales * p_days),
    coalesce(o.qty_open, 0),
    ceil(p.avg_daily_sales * p_days) + coalesce(o.qty_open, 0),
    p.on_hand,
    p.on_order,
    greatest(0, ceil(p.avg_daily_sales * p_days) + coalesce(o.qty_open, 0) - p.on_hand - p.on_order)
  from item_planning p
  left join (
    select l.item_id, sum(l.qty - l.qty_fulfilled) as qty_open
    from sales_order_lines l
    join sales_orders so on so.id = l.order_id
    where so.status = 'placed'
    group by l.item_id
  ) o on o.item_id = p.item_id
  where p.item_type = 'complete'
  order by p.sku;
$$;

-- ---------------------------------------------------------------------
-- MRP, level 2: the parts.
--   for_builds      = boards to build (net, from level 1) x BOM quantity
--   for_planned     = parts that planned production orders will take
--                     when they are issued (BOM x quantity)
--   forecast        = average parts sold on their own per day x the horizon
--   open_orders     = parts on placed sales orders not yet handed over
--   gross           = the four added together
--   net             = gross - parts on hand - still coming on purchase orders
--   suggested_order = if net is above zero: the larger of net and the EOQ
-- ---------------------------------------------------------------------
create function public.mrp_components(p_days integer)
returns table (
  item_id          bigint,
  sku              text,
  name             text,
  supplier_id      bigint,
  lead_time_days   integer,
  unit_cost        numeric,
  for_builds       numeric,
  for_planned      numeric,
  forecast         numeric,
  open_orders      numeric,
  gross            numeric,
  on_hand          numeric,
  on_order         numeric,
  net              numeric,
  eoq              numeric,
  suggested_order  numeric
)
language sql
stable
set search_path = public
as $$
  with builds as (
    select b.component_item_id as item_id, sum(m.net * b.qty) as qty
    from mrp_parents(p_days) m
    join bom_lines b on b.parent_item_id = m.item_id
    group by b.component_item_id
  ),
  planned as (
    select b.component_item_id as item_id, sum(o.qty_started * b.qty) as qty
    from production_orders o
    join bom_lines b on b.parent_item_id = o.item_id
    where o.status = 'planned'
    group by b.component_item_id
  ),
  ordered as (
    select l.item_id, sum(l.qty - l.qty_fulfilled) as qty
    from sales_order_lines l
    join sales_orders so on so.id = l.order_id
    where so.status = 'placed'
    group by l.item_id
  ),
  need as (
    select
      p.item_id, p.sku, p.name, p.supplier_id, p.lead_time_days, p.standard_cost, p.eoq,
      coalesce(b.qty, 0)                as for_builds,
      coalesce(pl.qty, 0)               as for_planned,
      ceil(p.avg_daily_sales * p_days)  as forecast,
      coalesce(o.qty, 0)                as open_orders,
      p.on_hand, p.on_order
    from item_planning p
    left join builds b   on b.item_id = p.item_id
    left join planned pl on pl.item_id = p.item_id
    left join ordered o  on o.item_id = p.item_id
    where p.item_type = 'part'
  )
  select
    n.item_id, n.sku, n.name, n.supplier_id, n.lead_time_days, n.standard_cost,
    n.for_builds, n.for_planned, n.forecast, n.open_orders,
    n.for_builds + n.for_planned + n.forecast + n.open_orders,
    n.on_hand, n.on_order,
    greatest(0, n.for_builds + n.for_planned + n.forecast + n.open_orders - n.on_hand - n.on_order),
    n.eoq,
    case when n.for_builds + n.for_planned + n.forecast + n.open_orders - n.on_hand - n.on_order > 0
         then greatest(n.for_builds + n.for_planned + n.forecast + n.open_orders - n.on_hand - n.on_order,
                       ceil(coalesce(n.eoq, 0)))
         else 0 end
  from need n
  order by n.sku;
$$;

revoke execute on function public.mrp_parents(integer)    from public, anon;
revoke execute on function public.mrp_components(integer) from public, anon;
grant execute on function public.mrp_parents(integer)     to authenticated;
grant execute on function public.mrp_components(integer)  to authenticated;

-- ---------------------------------------------------------------------
-- supplier_scorecard: how each supplier really performs, from the
-- purchase orders that have been received.
--   on_time_rate      = share of received POs that arrived on or before
--                       the expected date
--   avg_actual_lead   = average days from sent to received
--   avg_days_late     = average days past the expected date (early = negative)
--   fill_rate         = units received / units ordered
--   payables          = received but not yet paid
-- The score (0 to 100) combines three parts:
--   40% on-time rate
--   40% fill score     = 1 - 4 x (shortfall), so 88% filled scores 52%
--   20% lead-time score = 1 - (average days over the quoted lead time / quoted)
-- Grade: A 90+, B 80+, C 70+, D 60+, F below 60.
-- Recommendation: A = Keep, B or C = Watch, D or F = Replace.
-- ---------------------------------------------------------------------
create or replace view public.supplier_scorecard
with (security_invoker = true) as
with stats as (
  select
    s.id as supplier_id, s.name, s.is_active, s.quoted_lead_time_days, s.payment_terms_days,
    count(p.po_id) filter (where p.received_date is not null)                     as pos_received,
    count(p.po_id) filter (where p.status = 'sent')                               as pos_open,
    avg(case when p.days_late <= 0 then 1.0 else 0.0 end)
      filter (where p.received_date is not null)                                  as on_time_rate,
    avg(p.actual_lead_time_days) filter (where p.received_date is not null)       as avg_actual_lead,
    avg(p.days_late) filter (where p.received_date is not null)                   as avg_days_late,
    sum(p.qty_received) filter (where p.received_date is not null)
      / nullif(sum(p.qty_ordered) filter (where p.received_date is not null), 0)  as fill_rate,
    coalesce(sum(p.received_value), 0)                                            as received_value,
    coalesce(sum(p.amount_owed), 0)                                               as payables
  from public.suppliers s
  left join public.po_summary p on p.supplier_id = s.id
  group by s.id, s.name, s.is_active, s.quoted_lead_time_days, s.payment_terms_days
),
scored as (
  select
    st.*,
    case when st.pos_received > 0 then round(100 * (
        0.4 * st.on_time_rate
      + 0.4 * greatest(0, 1 - 4 * (1 - coalesce(st.fill_rate, 0)))
      + 0.2 * greatest(0, 1 - greatest(0, st.avg_actual_lead - st.quoted_lead_time_days)
                              / nullif(st.quoted_lead_time_days, 0))
    ), 1) end as score
  from stats st
)
select
  sc.supplier_id, sc.name, sc.is_active, sc.quoted_lead_time_days, sc.payment_terms_days,
  sc.pos_received, sc.pos_open,
  round(sc.on_time_rate, 4)    as on_time_rate,
  round(sc.avg_actual_lead, 1) as avg_actual_lead,
  round(sc.avg_days_late, 1)   as avg_days_late,
  round(sc.fill_rate, 4)       as fill_rate,
  round(sc.received_value, 2)  as received_value,
  round(sc.payables, 2)        as payables,
  sc.score,
  case when sc.score is null then null
       when sc.score >= 90 then 'A' when sc.score >= 80 then 'B'
       when sc.score >= 70 then 'C' when sc.score >= 60 then 'D' else 'F' end as grade,
  case when sc.score is null then null
       when sc.score >= 90 then 'Keep'
       when sc.score >= 70 then 'Watch'
       else 'Replace' end as recommendation
from scored sc;

-- Result shown after running: the scorecard.
select name, pos_received, on_time_rate, avg_actual_lead, fill_rate, score, grade, recommendation
from public.supplier_scorecard
order by name;
