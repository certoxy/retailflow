begin;

create table public.branch_receipt_counters (
  branch_id uuid primary key references public.branches(id) on delete cascade,
  next_number bigint not null default 1 check (next_number > 0)
);

create table public.sales (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  branch_id uuid not null references public.branches(id),
  receipt_number text not null,
  idempotency_key uuid not null unique,
  status text not null default 'completed' check (status in ('completed','voided')),
  subtotal numeric(14,2) not null check (subtotal >= 0),
  total numeric(14,2) not null check (total >= 0),
  payment_method text not null check (payment_method in ('cash','card','ewallet','other')),
  amount_tendered numeric(14,2) not null check (amount_tendered >= 0),
  change_amount numeric(14,2) not null default 0 check (change_amount >= 0),
  cashier_id uuid not null references public.profiles(id),
  voided_by uuid references public.profiles(id),
  void_reason text,
  voided_at timestamptz,
  created_at timestamptz not null default now(),
  unique (branch_id, receipt_number)
);

create table public.sale_items (
  id uuid primary key default gen_random_uuid(),
  sale_id uuid not null references public.sales(id) on delete cascade,
  product_id uuid not null references public.products(id),
  product_name text not null,
  sku text not null,
  quantity numeric(14,3) not null check (quantity > 0),
  unit_price numeric(14,2) not null check (unit_price >= 0),
  line_total numeric(14,2) not null check (line_total >= 0)
);

alter table public.branch_receipt_counters enable row level security;
alter table public.sales enable row level security;
alter table public.sale_items enable row level security;

create policy sales_tenant_read on public.sales for select to authenticated using (public.current_user_belongs_to_organization(organization_id) or public.current_user_is_platform_administrator());
create policy sale_items_tenant_read on public.sale_items for select to authenticated using (exists(select 1 from public.sales s where s.id=sale_id and (public.current_user_belongs_to_organization(s.organization_id) or public.current_user_is_platform_administrator())));

create or replace function public.current_user_can_use_branch(p_branch_id uuid)
returns boolean language sql stable security definer set search_path=public as $$
  select public.current_user_is_platform_administrator()
    or exists(select 1 from public.branches b where b.id=p_branch_id and public.current_user_administers_organization(b.organization_id))
    or exists(select 1 from public.branch_memberships bm join public.organization_memberships m on m.id=bm.organization_membership_id where bm.branch_id=p_branch_id and m.user_id=auth.uid() and m.active);
$$;

create or replace function public.get_pos_workspace(p_organization_id uuid,p_branch_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare controls jsonb;
begin
  if not public.current_user_can_use_branch(p_branch_id) or not exists(select 1 from public.branches where id=p_branch_id and organization_id=p_organization_id and active) then raise exception 'Branch access required'; end if;
  select enabled_modules into controls from public.organizations where id=p_organization_id and active;
  if coalesce((controls->>'pos')::boolean,false)=false then raise exception 'Point of Sale is not enabled for this organization'; end if;
  return jsonb_build_object(
    'products',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'sku',p.sku,'barcode',p.barcode,'unit',p.unit,'price',bp.selling_price,'quantity',bp.quantity) order by p.name) from public.branch_products bp join public.products p on p.id=bp.product_id where bp.branch_id=p_branch_id and bp.active and p.active),'[]'::jsonb),
    'sales',coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'receipt_number',s.receipt_number,'status',s.status,'total',s.total,'payment_method',s.payment_method,'cashier_name',p.full_name,'created_at',s.created_at,'items',(select jsonb_agg(jsonb_build_object('product_name',si.product_name,'sku',si.sku,'quantity',si.quantity,'unit_price',si.unit_price,'line_total',si.line_total)) from public.sale_items si where si.sale_id=s.id)) order by s.created_at desc) from (select * from public.sales where organization_id=p_organization_id and branch_id=p_branch_id order by created_at desc limit 50) s join public.profiles p on p.id=s.cashier_id),'[]'::jsonb)
  );
end; $$;

create or replace function public.create_pos_sale(p_organization_id uuid,p_branch_id uuid,p_items jsonb,p_payment_method text,p_amount_tendered numeric,p_idempotency_key uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare item jsonb; product_record record; sale_id uuid; subtotal numeric:=0; line_total numeric; receipt_counter bigint; receipt text; result jsonb;
begin
  if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'Sale must contain at least one item'; end if;
  if p_payment_method not in ('cash','card','ewallet','other') then raise exception 'Invalid payment method'; end if;
  perform public.get_pos_workspace(p_organization_id,p_branch_id);
  select jsonb_build_object('id',s.id,'receipt_number',s.receipt_number,'total',s.total,'change_amount',s.change_amount) into result from public.sales s where s.idempotency_key=p_idempotency_key;
  if result is not null then return result; end if;
  for item in select * from jsonb_array_elements(p_items) loop
    if (item->>'quantity')::numeric<=0 then raise exception 'Item quantity must be greater than zero'; end if;
    select p.id,p.name,p.sku,bp.selling_price,bp.quantity into product_record from public.products p join public.branch_products bp on bp.product_id=p.id where p.id=(item->>'product_id')::uuid and p.organization_id=p_organization_id and bp.branch_id=p_branch_id and p.active and bp.active for update of bp;
    if product_record.id is null then raise exception 'Product is unavailable'; end if;
    if product_record.quantity<(item->>'quantity')::numeric then raise exception 'Insufficient stock for %',product_record.name; end if;
    subtotal:=subtotal+round(product_record.selling_price*(item->>'quantity')::numeric,2);
  end loop;
  if p_payment_method='cash' and p_amount_tendered<subtotal then raise exception 'Amount tendered is less than the total'; end if;
  insert into public.branch_receipt_counters(branch_id,next_number) values(p_branch_id,2) on conflict(branch_id) do update set next_number=public.branch_receipt_counters.next_number+1 returning next_number-1 into receipt_counter;
  select code||'-'||lpad(receipt_counter::text,8,'0') into receipt from public.branches where id=p_branch_id;
  insert into public.sales(organization_id,branch_id,receipt_number,idempotency_key,subtotal,total,payment_method,amount_tendered,change_amount,cashier_id) values(p_organization_id,p_branch_id,receipt,p_idempotency_key,subtotal,subtotal,p_payment_method,case when p_payment_method='cash' then p_amount_tendered else subtotal end,case when p_payment_method='cash' then p_amount_tendered-subtotal else 0 end,auth.uid()) returning id into sale_id;
  for item in select * from jsonb_array_elements(p_items) loop
    select p.id,p.name,p.sku,bp.selling_price,bp.quantity into product_record from public.products p join public.branch_products bp on bp.product_id=p.id where p.id=(item->>'product_id')::uuid and bp.branch_id=p_branch_id for update of bp;
    line_total:=round(product_record.selling_price*(item->>'quantity')::numeric,2);
    insert into public.sale_items(sale_id,product_id,product_name,sku,quantity,unit_price,line_total) values(sale_id,product_record.id,product_record.name,product_record.sku,(item->>'quantity')::numeric,product_record.selling_price,line_total);
    update public.branch_products set quantity=quantity-(item->>'quantity')::numeric,updated_at=now() where branch_id=p_branch_id and product_id=product_record.id returning quantity into product_record.quantity;
    insert into public.inventory_movements(organization_id,branch_id,product_id,movement_type,quantity_delta,quantity_after,reason,created_by) values(p_organization_id,p_branch_id,product_record.id,'sale',-(item->>'quantity')::numeric,product_record.quantity,'Sale '||receipt,auth.uid());
  end loop;
  return jsonb_build_object('id',sale_id,'receipt_number',receipt,'total',subtotal,'change_amount',case when p_payment_method='cash' then p_amount_tendered-subtotal else 0 end);
end; $$;

create or replace function public.void_pos_sale(p_sale_id uuid,p_reason text)
returns void language plpgsql security definer set search_path=public as $$
declare sale_record public.sales; item record; new_quantity numeric;
begin
  select * into sale_record from public.sales where id=p_sale_id for update;
  if sale_record.id is null or not public.current_user_can_manage_inventory(sale_record.organization_id) then raise exception 'Manager access required'; end if;
  if sale_record.status='voided' then raise exception 'Sale is already voided'; end if;
  if nullif(trim(p_reason),'') is null then raise exception 'Void reason is required'; end if;
  for item in select * from public.sale_items where sale_id=p_sale_id loop
    update public.branch_products set quantity=quantity+item.quantity,updated_at=now() where branch_id=sale_record.branch_id and product_id=item.product_id returning quantity into new_quantity;
    insert into public.inventory_movements(organization_id,branch_id,product_id,movement_type,quantity_delta,quantity_after,reason,created_by) values(sale_record.organization_id,sale_record.branch_id,item.product_id,'return',item.quantity,new_quantity,'Void '||sale_record.receipt_number||': '||trim(p_reason),auth.uid());
  end loop;
  update public.sales set status='voided',voided_by=auth.uid(),void_reason=trim(p_reason),voided_at=now() where id=p_sale_id;
end; $$;

revoke all on function public.current_user_can_use_branch(uuid),public.get_pos_workspace(uuid,uuid),public.create_pos_sale(uuid,uuid,jsonb,text,numeric,uuid),public.void_pos_sale(uuid,text) from public;
grant execute on function public.current_user_can_use_branch(uuid),public.get_pos_workspace(uuid,uuid),public.create_pos_sale(uuid,uuid,jsonb,text,numeric,uuid),public.void_pos_sale(uuid,text) to authenticated;

commit;
