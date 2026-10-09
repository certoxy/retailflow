begin;

create or replace function public.receive_purchase_order(p_purchase_order_id uuid,p_receipts jsonb)
returns void language plpgsql security definer set search_path=public as $$
declare po public.purchase_orders;receipt jsonb;line public.purchase_order_items;qty numeric;new_qty numeric;remaining integer;batch_id uuid;requires_batch boolean;v_batch_number text;expiry date;manufactured date;
begin
  select * into po from public.purchase_orders where id=p_purchase_order_id for update;
  if po.id is null then raise exception 'Purchase order not found'; end if; perform public.require_purchasing_access(po.organization_id);
  if po.status in('received','cancelled') then raise exception 'Purchase order cannot be received'; end if;
  for receipt in select * from jsonb_array_elements(p_receipts) loop
    qty:=(receipt->>'quantity')::numeric; if qty<=0 then continue; end if;
    select * into line from public.purchase_order_items where id=(receipt->>'item_id')::uuid and purchase_order_id=po.id for update;
    if line.id is null or line.quantity_received+qty>line.quantity_ordered then raise exception 'Received quantity exceeds outstanding quantity'; end if;
    select(o.inventory_expiration_enabled and p.tracks_expiration) into requires_batch from public.organizations o join public.products p on p.organization_id=o.id where o.id=po.organization_id and p.id=line.product_id;
    v_batch_number:=nullif(trim(receipt->>'batch_number'),'');
    expiry:=nullif(receipt->>'expiration_date','')::date;
    manufactured:=nullif(receipt->>'manufacture_date','')::date;
    if requires_batch and(v_batch_number is null or expiry is null) then raise exception 'Batch number and expiration date are required for expiration-tracked products'; end if;
    if expiry is not null and manufactured is not null and expiry<manufactured then raise exception 'Expiration date cannot be before manufacture date'; end if;
    if v_batch_number is not null and exists(select 1 from public.inventory_batches ib where ib.organization_id=po.organization_id and ib.branch_id=po.branch_id and ib.product_id=line.product_id and ib.batch_number=upper(v_batch_number) and ib.status='quarantined') then raise exception 'That batch is quarantined and cannot receive additional stock'; end if;
    update public.purchase_order_items set quantity_received=quantity_received+qty where id=line.id;
    update public.branch_products set quantity=quantity+qty,updated_at=now() where branch_id=po.branch_id and product_id=line.product_id returning quantity into new_qty;
    if new_qty is null then raise exception 'Product is not configured for receiving branch'; end if;
    if v_batch_number is not null then
      insert into public.inventory_batches(organization_id,branch_id,product_id,batch_number,manufacture_date,expiration_date,initial_quantity,remaining_quantity,unit_cost,purchase_order_item_id,notes,created_by)
      values(po.organization_id,po.branch_id,line.product_id,upper(v_batch_number),manufactured,expiry,qty,qty,line.unit_cost,line.id,'Received '||po.po_number,auth.uid())
      on conflict(organization_id,branch_id,product_id,batch_number) do update set initial_quantity=public.inventory_batches.initial_quantity+excluded.initial_quantity,remaining_quantity=public.inventory_batches.remaining_quantity+excluded.remaining_quantity,unit_cost=excluded.unit_cost,purchase_order_item_id=excluded.purchase_order_item_id,status=case when public.inventory_batches.status='quarantined' then 'quarantined' else 'active' end,updated_at=now()
      returning id into batch_id;
    end if;
    insert into public.inventory_movements(organization_id,branch_id,product_id,movement_type,quantity_delta,quantity_after,reason,created_by) values(po.organization_id,po.branch_id,line.product_id,'purchase',qty,new_qty,'Received '||po.po_number||case when v_batch_number is null then '' else ' · Batch '||upper(v_batch_number) end,auth.uid());
  end loop;
  select count(*) into remaining from public.purchase_order_items where purchase_order_id=po.id and quantity_received<quantity_ordered;
  update public.purchase_orders set status=case when remaining=0 then 'received' else 'partially_received' end,received_at=case when remaining=0 then now() else null end where id=po.id;
end; $$;

revoke all on function public.receive_purchase_order(uuid,jsonb) from public;
grant execute on function public.receive_purchase_order(uuid,jsonb) to authenticated;
notify pgrst,'reload schema';
commit;
