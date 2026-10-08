begin;

alter table public.products
  add column if not exists tracks_expiration boolean not null default false,
  add column if not exists default_shelf_life_days integer check(default_shelf_life_days is null or default_shelf_life_days>0);

create table if not exists public.inventory_batches(
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  branch_id uuid not null references public.branches(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  batch_number text not null,
  manufacture_date date,
  expiration_date date,
  received_date date not null default current_date,
  initial_quantity numeric(14,3) not null check(initial_quantity>0),
  remaining_quantity numeric(14,3) not null check(remaining_quantity>=0),
  unit_cost numeric(14,2) check(unit_cost is null or unit_cost>=0),
  purchase_order_item_id uuid references public.purchase_order_items(id) on delete set null,
  notes text,
  status text not null default 'active' check(status in('active','quarantined','depleted')),
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(organization_id,branch_id,product_id,batch_number),
  check(expiration_date is null or manufacture_date is null or expiration_date>=manufacture_date)
);

create table if not exists public.sale_item_batches(
  id uuid primary key default gen_random_uuid(),
  sale_item_id uuid not null references public.sale_items(id) on delete cascade,
  batch_id uuid not null references public.inventory_batches(id),
  quantity numeric(14,3) not null check(quantity>0),
  unique(sale_item_id,batch_id)
);

create index if not exists inventory_batches_branch_expiry on public.inventory_batches(branch_id,expiration_date) where remaining_quantity>0;
create index if not exists inventory_batches_product on public.inventory_batches(product_id,branch_id);
alter table public.inventory_batches enable row level security;
alter table public.sale_item_batches enable row level security;

drop policy if exists inventory_batches_tenant_read on public.inventory_batches;
create policy inventory_batches_tenant_read on public.inventory_batches for select to authenticated
  using(public.current_user_belongs_to_organization(organization_id) or public.current_user_is_platform_administrator());
drop policy if exists sale_item_batches_tenant_read on public.sale_item_batches;
create policy sale_item_batches_tenant_read on public.sale_item_batches for select to authenticated
  using(exists(select 1 from public.sale_items si join public.sales s on s.id=si.sale_id where si.id=sale_item_id and(public.current_user_belongs_to_organization(s.organization_id) or public.current_user_is_platform_administrator())));

create or replace function public.update_product_expiration_settings(p_organization_id uuid,p_product_id uuid,p_tracks_expiration boolean,p_default_shelf_life_days integer)
returns void language plpgsql security definer set search_path=public as $$
begin
  perform public.require_inventory_access(p_organization_id);
  if not public.current_user_can_manage_inventory(p_organization_id) then raise exception 'Inventory manager access required'; end if;
  if coalesce(p_tracks_expiration,false) and not exists(select 1 from public.organizations where id=p_organization_id and inventory_expiration_enabled) then raise exception 'Expiration tracking is not enabled in Organization Settings'; end if;
  if p_default_shelf_life_days is not null and p_default_shelf_life_days<=0 then raise exception 'Shelf life must be greater than zero'; end if;
  update public.products set tracks_expiration=coalesce(p_tracks_expiration,false),default_shelf_life_days=case when p_tracks_expiration then p_default_shelf_life_days else null end,updated_at=now()
  where id=p_product_id and organization_id=p_organization_id;
  if not found then raise exception 'Product not found'; end if;
end; $$;

create or replace function public.create_inventory_batch(
  p_organization_id uuid,p_branch_id uuid,p_product_id uuid,p_batch_number text,p_quantity numeric,
  p_manufacture_date date,p_expiration_date date,p_unit_cost numeric,p_notes text
) returns uuid language plpgsql security definer set search_path=public as $$
declare batch_id uuid;new_quantity numeric;
begin
  perform public.require_inventory_access(p_organization_id);
  if not public.current_user_can_manage_inventory(p_organization_id) then raise exception 'Inventory manager access required'; end if;
  if not exists(select 1 from public.organizations where id=p_organization_id and inventory_expiration_enabled) then raise exception 'Expiration tracking is not enabled in Organization Settings'; end if;
  if nullif(trim(p_batch_number),'') is null then raise exception 'Batch number is required'; end if;
  if coalesce(p_quantity,0)<=0 then raise exception 'Batch quantity must be greater than zero'; end if;
  if p_expiration_date is not null and p_manufacture_date is not null and p_expiration_date<p_manufacture_date then raise exception 'Expiration date cannot be before manufacture date'; end if;
  if not exists(select 1 from public.products where id=p_product_id and organization_id=p_organization_id and active) then raise exception 'Invalid product'; end if;
  if exists(select 1 from public.inventory_batches where organization_id=p_organization_id and branch_id=p_branch_id and product_id=p_product_id and batch_number=upper(trim(p_batch_number)) and status='quarantined') then raise exception 'That batch is quarantined and cannot receive additional stock'; end if;
  update public.branch_products bp set quantity=bp.quantity+p_quantity,updated_at=now()
    where bp.branch_id=p_branch_id and bp.product_id=p_product_id and exists(select 1 from public.branches b where b.id=bp.branch_id and b.organization_id=p_organization_id)
    returning quantity into new_quantity;
  if new_quantity is null then raise exception 'Product is not configured for this branch'; end if;
  update public.products set tracks_expiration=true,updated_at=now() where id=p_product_id;
  insert into public.inventory_batches(organization_id,branch_id,product_id,batch_number,manufacture_date,expiration_date,initial_quantity,remaining_quantity,unit_cost,notes,created_by)
  values(p_organization_id,p_branch_id,p_product_id,upper(trim(p_batch_number)),p_manufacture_date,p_expiration_date,p_quantity,p_quantity,p_unit_cost,nullif(trim(p_notes),''),auth.uid())
  on conflict(organization_id,branch_id,product_id,batch_number) do update set
    initial_quantity=public.inventory_batches.initial_quantity+excluded.initial_quantity,
    remaining_quantity=public.inventory_batches.remaining_quantity+excluded.remaining_quantity,
    manufacture_date=coalesce(public.inventory_batches.manufacture_date,excluded.manufacture_date),
    expiration_date=coalesce(public.inventory_batches.expiration_date,excluded.expiration_date),
    unit_cost=coalesce(excluded.unit_cost,public.inventory_batches.unit_cost),notes=coalesce(excluded.notes,public.inventory_batches.notes),status=case when public.inventory_batches.status='quarantined' then 'quarantined' else 'active' end,updated_at=now()
  returning id into batch_id;
  insert into public.inventory_movements(organization_id,branch_id,product_id,movement_type,quantity_delta,quantity_after,reason,created_by)
  values(p_organization_id,p_branch_id,p_product_id,'adjustment',p_quantity,new_quantity,'Batch '||upper(trim(p_batch_number))||' received',auth.uid());
  return batch_id;
end; $$;

create or replace function public.set_inventory_batch_status(p_batch_id uuid,p_status text)
returns void language plpgsql security definer set search_path=public as $$
declare batch public.inventory_batches;quantity_change numeric;new_quantity numeric;
begin
  select * into batch from public.inventory_batches where id=p_batch_id;
  if batch.id is null then raise exception 'Batch not found'; end if;
  if not public.current_user_can_manage_inventory(batch.organization_id) then raise exception 'Inventory manager access required'; end if;
  if p_status not in('active','quarantined') then raise exception 'Invalid batch status'; end if;
  if batch.remaining_quantity<=0 then raise exception 'A depleted batch cannot be reactivated'; end if;
  if batch.status=p_status then return; end if;
  quantity_change:=case when p_status='quarantined' then -batch.remaining_quantity else batch.remaining_quantity end;
  update public.branch_products set quantity=quantity+quantity_change,updated_at=now() where branch_id=batch.branch_id and product_id=batch.product_id returning quantity into new_quantity;
  if new_quantity is null or new_quantity<0 then raise exception 'Batch status would create an invalid branch balance'; end if;
  update public.inventory_batches set status=p_status,updated_at=now() where id=p_batch_id;
  insert into public.inventory_movements(organization_id,branch_id,product_id,movement_type,quantity_delta,quantity_after,reason,created_by)
  values(batch.organization_id,batch.branch_id,batch.product_id,'adjustment',quantity_change,new_quantity,case when p_status='quarantined' then 'Batch '||batch.batch_number||' quarantined' else 'Batch '||batch.batch_number||' reactivated' end,auth.uid());
end; $$;

create or replace function public.receive_purchase_order(p_purchase_order_id uuid,p_receipts jsonb)
returns void language plpgsql security definer set search_path=public as $$
declare po public.purchase_orders;receipt jsonb;line public.purchase_order_items;qty numeric;new_qty numeric;remaining integer;batch_id uuid;requires_batch boolean;batch_number text;expiry date;manufactured date;
begin
  select * into po from public.purchase_orders where id=p_purchase_order_id for update;
  if po.id is null then raise exception 'Purchase order not found'; end if; perform public.require_purchasing_access(po.organization_id);
  if po.status in('received','cancelled') then raise exception 'Purchase order cannot be received'; end if;
  for receipt in select * from jsonb_array_elements(p_receipts) loop
    qty:=(receipt->>'quantity')::numeric; if qty<=0 then continue; end if;
    select * into line from public.purchase_order_items where id=(receipt->>'item_id')::uuid and purchase_order_id=po.id for update;
    if line.id is null or line.quantity_received+qty>line.quantity_ordered then raise exception 'Received quantity exceeds outstanding quantity'; end if;
    select(o.inventory_expiration_enabled and p.tracks_expiration) into requires_batch from public.organizations o join public.products p on p.organization_id=o.id where o.id=po.organization_id and p.id=line.product_id;
    batch_number:=nullif(trim(receipt->>'batch_number'),'');
    expiry:=nullif(receipt->>'expiration_date','')::date;
    manufactured:=nullif(receipt->>'manufacture_date','')::date;
    if requires_batch and(batch_number is null or expiry is null) then raise exception 'Batch number and expiration date are required for expiration-tracked products'; end if;
    if expiry is not null and manufactured is not null and expiry<manufactured then raise exception 'Expiration date cannot be before manufacture date'; end if;
    if batch_number is not null and exists(select 1 from public.inventory_batches where organization_id=po.organization_id and branch_id=po.branch_id and product_id=line.product_id and batch_number=upper(batch_number) and status='quarantined') then raise exception 'That batch is quarantined and cannot receive additional stock'; end if;
    update public.purchase_order_items set quantity_received=quantity_received+qty where id=line.id;
    update public.branch_products set quantity=quantity+qty,updated_at=now() where branch_id=po.branch_id and product_id=line.product_id returning quantity into new_qty;
    if new_qty is null then raise exception 'Product is not configured for receiving branch'; end if;
    if batch_number is not null then
      insert into public.inventory_batches(organization_id,branch_id,product_id,batch_number,manufacture_date,expiration_date,initial_quantity,remaining_quantity,unit_cost,purchase_order_item_id,notes,created_by)
      values(po.organization_id,po.branch_id,line.product_id,upper(batch_number),manufactured,expiry,qty,qty,line.unit_cost,line.id,'Received '||po.po_number,auth.uid())
      on conflict(organization_id,branch_id,product_id,batch_number) do update set initial_quantity=public.inventory_batches.initial_quantity+excluded.initial_quantity,remaining_quantity=public.inventory_batches.remaining_quantity+excluded.remaining_quantity,unit_cost=excluded.unit_cost,purchase_order_item_id=excluded.purchase_order_item_id,status=case when public.inventory_batches.status='quarantined' then 'quarantined' else 'active' end,updated_at=now()
      returning id into batch_id;
    end if;
    insert into public.inventory_movements(organization_id,branch_id,product_id,movement_type,quantity_delta,quantity_after,reason,created_by) values(po.organization_id,po.branch_id,line.product_id,'purchase',qty,new_qty,'Received '||po.po_number||case when batch_number is null then '' else ' · Batch '||upper(batch_number) end,auth.uid());
  end loop;
  select count(*) into remaining from public.purchase_order_items where purchase_order_id=po.id and quantity_received<quantity_ordered;
  update public.purchase_orders set status=case when remaining=0 then 'received' else 'partially_received' end,received_at=case when remaining=0 then now() else null end where id=po.id;
end; $$;

create or replace function public.allocate_sale_batches(p_sale_item_id uuid,p_organization_id uuid,p_branch_id uuid,p_product_id uuid,p_quantity numeric)
returns void language plpgsql security definer set search_path=public as $$
declare batch record;needed numeric:=p_quantity;take_quantity numeric;
begin
  for batch in select * from public.inventory_batches where organization_id=p_organization_id and branch_id=p_branch_id and product_id=p_product_id and status='active' and remaining_quantity>0 and(expiration_date is null or expiration_date>=current_date) order by expiration_date asc nulls last,received_date,id for update loop
    exit when needed<=0;
    take_quantity:=least(needed,batch.remaining_quantity);
    update public.inventory_batches set remaining_quantity=remaining_quantity-take_quantity,status=case when remaining_quantity-take_quantity<=0 then 'depleted' else status end,updated_at=now() where id=batch.id;
    insert into public.sale_item_batches(sale_item_id,batch_id,quantity) values(p_sale_item_id,batch.id,take_quantity);
    needed:=needed-take_quantity;
  end loop;
end; $$;

drop function if exists public.create_pos_sale(uuid,uuid,jsonb,text,numeric,uuid,uuid);
create function public.create_pos_sale(p_organization_id uuid,p_branch_id uuid,p_items jsonb,p_payment_method text,p_amount_tendered numeric,p_idempotency_key uuid,p_customer_id uuid default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare item jsonb;product_record record;sale_id uuid;sale_item_id uuid;subtotal numeric:=0;line_total numeric;receipt_counter bigint;receipt text;result jsonb;expired_quantity numeric;
begin
  if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'Sale must contain at least one item'; end if;
  if p_payment_method not in('cash','card','ewallet','other') then raise exception 'Invalid payment method'; end if;
  perform public.get_pos_workspace(p_organization_id,p_branch_id);
  if p_customer_id is not null and not exists(select 1 from public.customers where id=p_customer_id and organization_id=p_organization_id and active) then raise exception 'Invalid customer'; end if;
  select jsonb_build_object('id',s.id,'receipt_number',s.receipt_number,'total',s.total,'change_amount',s.change_amount) into result from public.sales s where s.idempotency_key=p_idempotency_key;
  if result is not null then return result; end if;
  for item in select * from jsonb_array_elements(p_items) loop
    if(item->>'quantity')::numeric<=0 then raise exception 'Item quantity must be greater than zero'; end if;
    select p.id,p.name,p.sku,bp.selling_price,bp.quantity into product_record from public.products p join public.branch_products bp on bp.product_id=p.id where p.id=(item->>'product_id')::uuid and p.organization_id=p_organization_id and bp.branch_id=p_branch_id and p.active and bp.active for update of bp;
    if product_record.id is null then raise exception 'Product is unavailable'; end if;
    select coalesce(sum(remaining_quantity),0) into expired_quantity from public.inventory_batches where organization_id=p_organization_id and branch_id=p_branch_id and product_id=product_record.id and status='active' and remaining_quantity>0 and expiration_date<current_date;
    if product_record.quantity-expired_quantity<(item->>'quantity')::numeric then raise exception 'Insufficient non-expired stock for %',product_record.name; end if;
    subtotal:=subtotal+round(product_record.selling_price*(item->>'quantity')::numeric,2);
  end loop;
  if p_payment_method='cash' and p_amount_tendered<subtotal then raise exception 'Amount tendered is less than the total'; end if;
  insert into public.branch_receipt_counters(branch_id,next_number) values(p_branch_id,2) on conflict(branch_id) do update set next_number=public.branch_receipt_counters.next_number+1 returning next_number-1 into receipt_counter;
  select code||'-'||lpad(receipt_counter::text,8,'0') into receipt from public.branches where id=p_branch_id;
  insert into public.sales(organization_id,branch_id,receipt_number,idempotency_key,customer_id,subtotal,total,payment_method,amount_tendered,change_amount,cashier_id) values(p_organization_id,p_branch_id,receipt,p_idempotency_key,p_customer_id,subtotal,subtotal,p_payment_method,case when p_payment_method='cash' then p_amount_tendered else subtotal end,case when p_payment_method='cash' then p_amount_tendered-subtotal else 0 end,auth.uid()) returning id into sale_id;
  for item in select * from jsonb_array_elements(p_items) loop
    select p.id,p.name,p.sku,bp.selling_price,bp.quantity into product_record from public.products p join public.branch_products bp on bp.product_id=p.id where p.id=(item->>'product_id')::uuid and bp.branch_id=p_branch_id for update of bp;
    line_total:=round(product_record.selling_price*(item->>'quantity')::numeric,2);
    insert into public.sale_items(sale_id,product_id,product_name,sku,quantity,unit_price,line_total) values(sale_id,product_record.id,product_record.name,product_record.sku,(item->>'quantity')::numeric,product_record.selling_price,line_total) returning id into sale_item_id;
    perform public.allocate_sale_batches(sale_item_id,p_organization_id,p_branch_id,product_record.id,(item->>'quantity')::numeric);
    update public.branch_products set quantity=quantity-(item->>'quantity')::numeric,updated_at=now() where branch_id=p_branch_id and product_id=product_record.id returning quantity into product_record.quantity;
    insert into public.inventory_movements(organization_id,branch_id,product_id,movement_type,quantity_delta,quantity_after,reason,created_by) values(p_organization_id,p_branch_id,product_record.id,'sale',-(item->>'quantity')::numeric,product_record.quantity,'Sale '||receipt,auth.uid());
  end loop;
  return jsonb_build_object('id',sale_id,'receipt_number',receipt,'total',subtotal,'change_amount',case when p_payment_method='cash' then p_amount_tendered-subtotal else 0 end);
end; $$;

create or replace function public.record_product_change()
returns trigger language plpgsql security definer set search_path=public as $$
declare fields text[];before_data jsonb;after_data jsonb;
begin
  after_data:=jsonb_build_object('name',new.name,'sku',new.sku,'barcode',new.barcode,'category_id',new.category_id,'unit',new.unit,'description',new.description,'active',new.active,'image_path',new.image_path,'tracks_expiration',new.tracks_expiration,'default_shelf_life_days',new.default_shelf_life_days);
  if tg_op='INSERT' then
    insert into public.product_change_log(organization_id,product_id,action,changed_fields,after_values,changed_by,created_at)
      values(new.organization_id,new.id,'created',array['name','sku','barcode','category','unit','description','status','expiration tracking'],after_data,coalesce(auth.uid(),new.created_by),new.created_at);
  else
    fields:=array_remove(array[
      case when old.name is distinct from new.name then 'name' end,case when old.sku is distinct from new.sku then 'sku' end,
      case when old.barcode is distinct from new.barcode then 'barcode' end,case when old.category_id is distinct from new.category_id then 'category' end,
      case when old.unit is distinct from new.unit then 'unit' end,case when old.description is distinct from new.description then 'description' end,
      case when old.active is distinct from new.active then 'status' end,case when old.image_path is distinct from new.image_path then 'image' end,
      case when old.tracks_expiration is distinct from new.tracks_expiration then 'expiration tracking' end,
      case when old.default_shelf_life_days is distinct from new.default_shelf_life_days then 'shelf life' end
    ],null);
    if cardinality(fields)>0 then
      before_data:=jsonb_build_object('name',old.name,'sku',old.sku,'barcode',old.barcode,'category_id',old.category_id,'unit',old.unit,'description',old.description,'active',old.active,'image_path',old.image_path,'tracks_expiration',old.tracks_expiration,'default_shelf_life_days',old.default_shelf_life_days);
      insert into public.product_change_log(organization_id,product_id,action,changed_fields,before_values,after_values,changed_by) values(new.organization_id,new.id,'updated',fields,before_data,after_data,auth.uid());
    end if;
  end if;
  return new;
end; $$;

create or replace function public.void_pos_sale(p_sale_id uuid,p_reason text)
returns void language plpgsql security definer set search_path=public as $$
declare sale_record public.sales;item record;allocation record;new_quantity numeric;
begin
  select * into sale_record from public.sales where id=p_sale_id for update;
  if sale_record.id is null or not public.current_user_can_manage_inventory(sale_record.organization_id) then raise exception 'Manager access required'; end if;
  if sale_record.status='voided' then raise exception 'Sale is already voided'; end if;
  if nullif(trim(p_reason),'') is null then raise exception 'Void reason is required'; end if;
  for item in select * from public.sale_items where sale_id=p_sale_id loop
    for allocation in select * from public.sale_item_batches where sale_item_id=item.id loop
      update public.inventory_batches set remaining_quantity=remaining_quantity+allocation.quantity,status='active',updated_at=now() where id=allocation.batch_id;
    end loop;
    update public.branch_products set quantity=quantity+item.quantity,updated_at=now() where branch_id=sale_record.branch_id and product_id=item.product_id returning quantity into new_quantity;
    insert into public.inventory_movements(organization_id,branch_id,product_id,movement_type,quantity_delta,quantity_after,reason,created_by) values(sale_record.organization_id,sale_record.branch_id,item.product_id,'return',item.quantity,new_quantity,'Void '||sale_record.receipt_number||': '||trim(p_reason),auth.uid());
  end loop;
  update public.sales set status='voided',voided_by=auth.uid(),void_reason=trim(p_reason),voided_at=now() where id=p_sale_id;
end; $$;

create or replace function public.get_purchasing_workspace(p_organization_id uuid,p_branch_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$ begin
  perform public.require_purchasing_access(p_organization_id);
  if not exists(select 1 from public.branches where id=p_branch_id and organization_id=p_organization_id) then raise exception 'Invalid branch'; end if;
  return jsonb_build_object(
    'suppliers',coalesce((select jsonb_agg(to_jsonb(s) order by s.name) from public.suppliers s where s.organization_id=p_organization_id and s.active),'[]'::jsonb),
    'products',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'sku',p.sku,'quantity',bp.quantity,'threshold',bp.low_stock_threshold,'tracks_expiration',p.tracks_expiration,'default_shelf_life_days',p.default_shelf_life_days) order by p.name) from public.branch_products bp join public.products p on p.id=bp.product_id where bp.branch_id=p_branch_id and bp.active and p.active),'[]'::jsonb),
    'reorder_suggestions',coalesce((select jsonb_agg(jsonb_build_object('product_id',p.id,'name',p.name,'sku',p.sku,'quantity',bp.quantity,'threshold',bp.low_stock_threshold,'suggested_quantity',greatest(bp.low_stock_threshold*2-bp.quantity,1)) order by p.name) from public.branch_products bp join public.products p on p.id=bp.product_id where bp.branch_id=p_branch_id and bp.active and p.active and bp.quantity<=bp.low_stock_threshold),'[]'::jsonb),
    'purchase_orders',coalesce((select jsonb_agg(jsonb_build_object('id',po.id,'po_number',po.po_number,'status',po.status,'supplier_name',s.name,'ordered_at',po.ordered_at,'notes',po.notes,'items',(select jsonb_agg(jsonb_build_object('id',i.id,'product_id',i.product_id,'product_name',p.name,'sku',p.sku,'quantity_ordered',i.quantity_ordered,'quantity_received',i.quantity_received,'unit_cost',i.unit_cost,'tracks_expiration',p.tracks_expiration,'default_shelf_life_days',p.default_shelf_life_days)) from public.purchase_order_items i join public.products p on p.id=i.product_id where i.purchase_order_id=po.id)) order by po.ordered_at desc) from public.purchase_orders po join public.suppliers s on s.id=po.supplier_id where po.organization_id=p_organization_id and po.branch_id=p_branch_id),'[]'::jsonb)
  );
end; $$;

create or replace function public.get_inventory_workspace(p_organization_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
begin
  perform public.require_inventory_access(p_organization_id);
  return jsonb_build_object(
    'categories',coalesce((select jsonb_agg(to_jsonb(c) order by c.name) from public.product_categories c where c.organization_id=p_organization_id and c.active),'[]'::jsonb),
    'products',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'sku',p.sku,'barcode',p.barcode,'description',p.description,'image_path',p.image_path,'unit',p.unit,'active',p.active,'category_id',p.category_id,'category_name',c.name,'tracks_expiration',p.tracks_expiration,'default_shelf_life_days',p.default_shelf_life_days,
      'branches',coalesce((select jsonb_agg(jsonb_build_object('branch_id',bp.branch_id,'branch_name',b.name,'selling_price',bp.selling_price,'quantity',bp.quantity,'low_stock_threshold',bp.low_stock_threshold,'active',bp.active) order by b.name) from public.branch_products bp join public.branches b on b.id=bp.branch_id where bp.product_id=p.id),'[]'::jsonb)) order by p.name) from public.products p left join public.product_categories c on c.id=p.category_id where p.organization_id=p_organization_id),'[]'::jsonb),
    'movements',coalesce((select jsonb_agg(jsonb_build_object('id',m.id,'product_name',p.name,'sku',p.sku,'branch_name',b.name,'movement_type',m.movement_type,'quantity_delta',m.quantity_delta,'quantity_after',m.quantity_after,'reason',m.reason,'created_at',m.created_at) order by m.created_at desc) from(select * from public.inventory_movements where organization_id=p_organization_id order by created_at desc limit 100)m join public.products p on p.id=m.product_id join public.branches b on b.id=m.branch_id),'[]'::jsonb),
    'locations',coalesce((select jsonb_agg(jsonb_build_object('id',l.id,'branch_id',l.branch_id,'name',l.name,'code',l.code,'location_type',l.location_type,'parent_location_id',l.parent_location_id,'parent_name',parent.name,'active',l.active,'product_count',(select count(*) from public.product_locations pl where pl.location_id=l.id)) order by l.location_type,l.name) from public.inventory_locations l left join public.inventory_locations parent on parent.id=l.parent_location_id where l.organization_id=p_organization_id),'[]'::jsonb),
    'product_locations',coalesce((select jsonb_agg(jsonb_build_object('id',pl.id,'branch_id',pl.branch_id,'product_id',p.id,'product_name',p.name,'sku',p.sku,'location_id',l.id,'location_name',l.name,'location_code',l.code,'is_primary',pl.is_primary,'notes',pl.notes) order by p.name,pl.is_primary desc,l.name) from public.product_locations pl join public.products p on p.id=pl.product_id join public.inventory_locations l on l.id=pl.location_id where pl.organization_id=p_organization_id),'[]'::jsonb),
    'product_change_log',coalesce((select jsonb_agg(jsonb_build_object('id',log.id,'product_id',log.product_id,'action',log.action,'changed_fields',log.changed_fields,'before_values',log.before_values,'after_values',log.after_values,'changed_by_name',profile.full_name,'changed_by_email',profile.email,'created_at',log.created_at) order by log.created_at desc) from(select * from public.product_change_log where organization_id=p_organization_id order by created_at desc limit 500)log left join public.profiles profile on profile.id=log.changed_by),'[]'::jsonb),
    'batches',coalesce((select jsonb_agg(jsonb_build_object('id',batch.id,'branch_id',batch.branch_id,'branch_name',branch.name,'product_id',batch.product_id,'product_name',product.name,'sku',product.sku,'unit',product.unit,'batch_number',batch.batch_number,'manufacture_date',batch.manufacture_date,'expiration_date',batch.expiration_date,'received_date',batch.received_date,'initial_quantity',batch.initial_quantity,'remaining_quantity',batch.remaining_quantity,'unit_cost',batch.unit_cost,'status',batch.status,'notes',batch.notes,'created_at',batch.created_at,'created_by_name',profile.full_name) order by batch.expiration_date asc nulls last,batch.created_at desc) from public.inventory_batches batch join public.products product on product.id=batch.product_id join public.branches branch on branch.id=batch.branch_id left join public.profiles profile on profile.id=batch.created_by where batch.organization_id=p_organization_id),'[]'::jsonb)
  );
end; $$;

revoke all on function public.update_product_expiration_settings(uuid,uuid,boolean,integer),public.create_inventory_batch(uuid,uuid,uuid,text,numeric,date,date,numeric,text),public.set_inventory_batch_status(uuid,text),public.allocate_sale_batches(uuid,uuid,uuid,uuid,numeric) from public;
revoke all on function public.create_pos_sale(uuid,uuid,jsonb,text,numeric,uuid,uuid),public.void_pos_sale(uuid,text),public.receive_purchase_order(uuid,jsonb) from public;
grant execute on function public.update_product_expiration_settings(uuid,uuid,boolean,integer),public.create_inventory_batch(uuid,uuid,uuid,text,numeric,date,date,numeric,text),public.set_inventory_batch_status(uuid,text) to authenticated;
grant execute on function public.create_pos_sale(uuid,uuid,jsonb,text,numeric,uuid,uuid),public.void_pos_sale(uuid,text),public.receive_purchase_order(uuid,jsonb) to authenticated;

notify pgrst,'reload schema';
commit;
