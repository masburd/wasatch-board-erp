-- =====================================================================
-- Wasatch Board Co. ERP — 05: TEMPORARY starter stock
-- Gives every location some stock so the Inventory page has something
-- to show while we build. Build step 8 (the 12-month history generator)
-- replaces this with real opening balances and a year of transactions.
--
-- Run AFTER file 04. It only does anything while the ledger is empty,
-- so running it twice will not double the stock.
--
-- Note that even this goes through the ledger: each line of stock is an
-- 'opening' movement, never a number typed into inventory_levels.
-- =====================================================================

do $$
declare
  r record;
begin
  if exists (select 1 from public.inventory_movements) then
    raise notice 'Ledger already has rows: starter stock skipped.';
    return;
  end if;

  for r in
    select i.id as item_id, l.id as location_id, c.current_cost,
           case
             when i.item_type = 'part'     and l.code = 'OREM' then 60
             when i.item_type = 'part'                         then 8
             when i.item_type = 'complete' and l.code = 'OREM' then 6
             else 3
           end as qty
    from public.items i
    cross join public.locations l
    join public.item_costs c on c.item_id = i.id
    where i.item_type in ('part', 'complete')
    order by i.sku, l.id
  loop
    -- Parts come in at their supplier cost, completes at their rolled-up
    -- BOM cost. p_reaverage => true sets the weighted average cost.
    perform public.wbc_post_movement(
      p_item_id     => r.item_id,
      p_location_id => r.location_id,
      p_qty         => r.qty,
      p_unit_cost   => r.current_cost,
      p_type        => 'opening',
      p_note        => 'Temporary starter stock',
      p_reaverage   => true
    );
  end loop;
end;
$$;

-- Result shown after running: units and value by location.
select l.code, sum(v.qty_on_hand) as units, round(sum(v.value), 2) as value
from public.inventory_value v
join public.locations l on l.id = v.location_id
group by l.code
order by l.code;
