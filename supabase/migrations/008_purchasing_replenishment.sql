begin;

create table public.suppliers (
  id uuid primary key default gen_random_uuid(), organization_id uuid not null references public.organizations(id) on delete cascade,
  name text not null, contact_name text, email text, phone text, address text, active boolean not null default true,
  created_by uuid not null references public.profiles(id), created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  unique(organization_id,name)
);
create table public.purchase_orders (
  id uuid primary key default gen_random_uuid(), organization_id uuid not null references public.organizations(id) on delete cascade,
  branch_id uuid not null references public.branches(id), supplier_id uuid not null references public.suppliers(id), po_number text not null,
  status text not null default 'ordered' check(status in('ordered','partially_received','received','cancelled')),
  notes text, ordered_by uuid not null references public.profiles(id), ordered_at timestamptz not null default now(), received_at timestamptz,
  unique(organization_id,po_number)
);
create table public.purchase_order_items (
  id uuid primary key default gen_random_uuid(), purchase_order_id uuid not null references public.purchase_orders(id) on delete cascade,
  product_id uuid not null references public.products(id), quantity_ordered numeric(14,3) not null check(quantity_ordered>0),
  quantity_received numeric(14,3) not null default 0 check(quantity_received>=0), unit_cost numeric(14,2) not null default 0 check(unit_cost>=0)
);
alter table public.suppliers enable row level security; alter table public.purchase_orders enable row level security; alter table public.purchase_order_items enable row level security;
create policy suppliers_read on public.suppliers for select to authenticated using(public.current_user_belongs_to_organization(organization_id) or public.current_user_is_platform_administrator());
create policy purchase_orders_read on public.purchase_orders for select to authenticated using(public.current_user_belongs_to_organization(organization_id) or public.current_user_is_platform_administrator());
create policy purchase_order_items_read on public.purchase_order_items for select to authenticated using(exists(select 1 from public.purchase_orders po where po.id=purchase_order_id and(public.current_user_belongs_to_organization(po.organization_id) or public.current_user_is_platform_administrator())));

create or replace function public.require_purchasing_access(p_organization_id uuid)
returns void language plpgsql stable security definer set search_path=public as $$ declare controls jsonb; begin
  if not public.current_user_can_manage_inventory(p_organization_id) then raise exception 'Inventory manager access required'; end if;
  select enabled_modules into controls from public.organizations where id=p_organization_id and active;
  if coalesce((controls->>'purchasing')::boolean,false)=false then raise exception 'Purchasing is not enabled for this organization'; end if;
end; $$;

create or replace function public.get_purchasing_workspace(p_organization_id uuid,p_branch_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$ begin
  perform public.require_purchasing_access(p_organization_id);
  if not exists(select 1 from public.branches where id=p_branch_id and organization_id=p_organization_id) then raise exception 'Invalid branch'; end if;
  return jsonb_build_object(
    'suppliers',coalesce((select jsonb_agg(to_jsonb(s) order by s.name) from public.suppliers s where s.organization_id=p_organization_id and s.active),'[]'::jsonb),
    'products',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'sku',p.sku,'quantity',bp.quantity,'threshold',bp.low_stock_threshold) order by p.name) from public.branch_products bp join public.products p on p.id=bp.product_id where bp.branch_id=p_branch_id and bp.active and p.active),'[]'::jsonb),
    'reorder_suggestions',coalesce((select jsonb_agg(jsonb_build_object('product_id',p.id,'name',p.name,'sku',p.sku,'quantity',bp.quantity,'threshold',bp.low_stock_threshold,'suggested_quantity',greatest(bp.low_stock_threshold*2-bp.quantity,1)) order by p.name) from public.branch_products bp join public.products p on p.id=bp.product_id where bp.branch_id=p_branch_id and bp.active and p.active and bp.quantity<=bp.low_stock_threshold),'[]'::jsonb),
    'purchase_orders',coalesce((select jsonb_agg(jsonb_build_object('id',po.id,'po_number',po.po_number,'status',po.status,'supplier_name',s.name,'ordered_at',po.ordered_at,'notes',po.notes,'items',(select jsonb_agg(jsonb_build_object('id',i.id,'product_id',i.product_id,'product_name',p.name,'sku',p.sku,'quantity_ordered',i.quantity_ordered,'quantity_received',i.quantity_received,'unit_cost',i.unit_cost)) from public.purchase_order_items i join public.products p on p.id=i.product_id where i.purchase_order_id=po.id)) order by po.ordered_at desc) from public.purchase_orders po join public.suppliers s on s.id=po.supplier_id where po.organization_id=p_organization_id and po.branch_id=p_branch_id),'[]'::jsonb)
  );
end; $$;

create or replace function public.create_supplier(p_organization_id uuid,p_name text,p_contact_name text,p_email text,p_phone text,p_address text)
returns uuid language plpgsql security definer set search_path=public as $$ declare new_id uuid; begin
  perform public.require_purchasing_access(p_organization_id);
  insert into public.suppliers(organization_id,name,contact_name,email,phone,address,created_by) values(p_organization_id,trim(p_name),nullif(trim(p_contact_name),''),nullif(trim(p_email),''),nullif(trim(p_phone),''),nullif(trim(p_address),''),auth.uid()) returning id into new_id; return new_id;
exception when unique_violation then raise exception 'That supplier already exists'; end; $$;

create or replace function public.create_purchase_order(p_organization_id uuid,p_branch_id uuid,p_supplier_id uuid,p_items jsonb,p_notes text)
returns uuid language plpgsql security definer set search_path=public as $$
declare new_id uuid; item jsonb; po text;
begin
  perform public.require_purchasing_access(p_organization_id);
  if not exists(select 1 from public.branches where id=p_branch_id and organization_id=p_organization_id) then raise exception 'Invalid branch'; end if;
  if not exists(select 1 from public.suppliers where id=p_supplier_id and organization_id=p_organization_id and active) then raise exception 'Invalid supplier'; end if;
  if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'Purchase order requires items'; end if;
  po:='PO-'||to_char(now(),'YYYYMMDD')||'-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,6));
  insert into public.purchase_orders(organization_id,branch_id,supplier_id,po_number,notes,ordered_by) values(p_organization_id,p_branch_id,p_supplier_id,po,nullif(trim(p_notes),''),auth.uid()) returning id into new_id;
  for item in select * from jsonb_array_elements(p_items) loop
    if (item->>'quantity')::numeric<=0 then raise exception 'Ordered quantity must be positive'; end if;
    if not exists(select 1 from public.products where id=(item->>'product_id')::uuid and organization_id=p_organization_id) then raise exception 'Invalid product'; end if;
    insert into public.purchase_order_items(purchase_order_id,product_id,quantity_ordered,unit_cost) values(new_id,(item->>'product_id')::uuid,(item->>'quantity')::numeric,coalesce((item->>'unit_cost')::numeric,0));
  end loop; return new_id;
end; $$;

create or replace function public.receive_purchase_order(p_purchase_order_id uuid,p_receipts jsonb)
returns void language plpgsql security definer set search_path=public as $$
declare po public.purchase_orders; receipt jsonb; line public.purchase_order_items; qty numeric; new_qty numeric; remaining integer;
begin
  select * into po from public.purchase_orders where id=p_purchase_order_id for update;
  if po.id is null then raise exception 'Purchase order not found'; end if; perform public.require_purchasing_access(po.organization_id);
  if po.status in('received','cancelled') then raise exception 'Purchase order cannot be received'; end if;
  for receipt in select * from jsonb_array_elements(p_receipts) loop
    qty:=(receipt->>'quantity')::numeric; if qty<=0 then continue; end if;
    select * into line from public.purchase_order_items where id=(receipt->>'item_id')::uuid and purchase_order_id=po.id for update;
    if line.id is null or line.quantity_received+qty>line.quantity_ordered then raise exception 'Received quantity exceeds outstanding quantity'; end if;
    update public.purchase_order_items set quantity_received=quantity_received+qty where id=line.id;
    update public.branch_products set quantity=quantity+qty,updated_at=now() where branch_id=po.branch_id and product_id=line.product_id returning quantity into new_qty;
    if new_qty is null then raise exception 'Product is not configured for receiving branch'; end if;
    insert into public.inventory_movements(organization_id,branch_id,product_id,movement_type,quantity_delta,quantity_after,reason,created_by) values(po.organization_id,po.branch_id,line.product_id,'purchase',qty,new_qty,'Received '||po.po_number,auth.uid());
  end loop;
  select count(*) into remaining from public.purchase_order_items where purchase_order_id=po.id and quantity_received<quantity_ordered;
  update public.purchase_orders set status=case when remaining=0 then 'received' else 'partially_received' end,received_at=case when remaining=0 then now() else null end where id=po.id;
end; $$;

revoke all on function public.require_purchasing_access(uuid),public.get_purchasing_workspace(uuid,uuid),public.create_supplier(uuid,text,text,text,text,text),public.create_purchase_order(uuid,uuid,uuid,jsonb,text),public.receive_purchase_order(uuid,jsonb) from public;
grant execute on function public.require_purchasing_access(uuid),public.get_purchasing_workspace(uuid,uuid),public.create_supplier(uuid,text,text,text,text,text),public.create_purchase_order(uuid,uuid,uuid,jsonb,text),public.receive_purchase_order(uuid,jsonb) to authenticated;
commit;
