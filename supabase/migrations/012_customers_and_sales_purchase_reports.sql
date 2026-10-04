begin;

create table public.customers (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  name text not null check (length(trim(name)) > 0),
  phone text,
  email text,
  address text,
  active boolean not null default true,
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.customers enable row level security;
create policy customers_tenant_read on public.customers for select to authenticated
using (public.current_user_belongs_to_organization(organization_id) or public.current_user_is_platform_administrator());

alter table public.sales add column customer_id uuid references public.customers(id) on delete set null;
create index customers_organization_name_idx on public.customers(organization_id, name);
create index sales_customer_idx on public.sales(customer_id);

create or replace function public.create_customer(p_organization_id uuid,p_name text,p_phone text default null,p_email text default null,p_address text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare new_customer public.customers;
begin
  if not public.current_user_belongs_to_organization(p_organization_id) then raise exception 'Organization access required'; end if;
  if nullif(trim(p_name),'') is null then raise exception 'Customer name is required'; end if;
  insert into public.customers(organization_id,name,phone,email,address,created_by)
  values(p_organization_id,trim(p_name),nullif(trim(p_phone),''),nullif(lower(trim(p_email)),''),nullif(trim(p_address),''),auth.uid())
  returning * into new_customer;
  return jsonb_build_object('id',new_customer.id,'name',new_customer.name,'phone',new_customer.phone,'email',new_customer.email,'address',new_customer.address);
end; $$;

create or replace function public.get_pos_workspace(p_organization_id uuid,p_branch_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare controls jsonb;
begin
  if not public.current_user_can_use_branch(p_branch_id) or not exists(select 1 from public.branches where id=p_branch_id and organization_id=p_organization_id and active) then raise exception 'Branch access required'; end if;
  select enabled_modules into controls from public.organizations where id=p_organization_id and active;
  if coalesce((controls->>'pos')::boolean,false)=false then raise exception 'Point of Sale is not enabled for this organization'; end if;
  return jsonb_build_object(
    'customers',coalesce((select jsonb_agg(jsonb_build_object('id',c.id,'name',c.name,'phone',c.phone,'email',c.email,'address',c.address) order by c.name) from public.customers c where c.organization_id=p_organization_id and c.active),'[]'::jsonb),
    'products',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'sku',p.sku,'barcode',p.barcode,'image_path',p.image_path,'unit',p.unit,'price',bp.selling_price,'quantity',bp.quantity) order by p.name) from public.branch_products bp join public.products p on p.id=bp.product_id where bp.branch_id=p_branch_id and bp.active and p.active),'[]'::jsonb),
    'sales',coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'receipt_number',s.receipt_number,'status',s.status,'total',s.total,'payment_method',s.payment_method,'cashier_name',p.full_name,'customer_id',s.customer_id,'customer_name',c.name,'created_at',s.created_at,'items',(select jsonb_agg(jsonb_build_object('product_name',si.product_name,'sku',si.sku,'quantity',si.quantity,'unit_price',si.unit_price,'line_total',si.line_total)) from public.sale_items si where si.sale_id=s.id)) order by s.created_at desc) from (select * from public.sales where organization_id=p_organization_id and branch_id=p_branch_id order by created_at desc limit 50) s join public.profiles p on p.id=s.cashier_id left join public.customers c on c.id=s.customer_id),'[]'::jsonb)
  );
end; $$;

drop function public.create_pos_sale(uuid,uuid,jsonb,text,numeric,uuid);
create function public.create_pos_sale(p_organization_id uuid,p_branch_id uuid,p_items jsonb,p_payment_method text,p_amount_tendered numeric,p_idempotency_key uuid,p_customer_id uuid default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare item jsonb; product_record record; sale_id uuid; subtotal numeric:=0; line_total numeric; receipt_counter bigint; receipt text; result jsonb;
begin
  if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'Sale must contain at least one item'; end if;
  if p_payment_method not in ('cash','card','ewallet','other') then raise exception 'Invalid payment method'; end if;
  perform public.get_pos_workspace(p_organization_id,p_branch_id);
  if p_customer_id is not null and not exists(select 1 from public.customers where id=p_customer_id and organization_id=p_organization_id and active) then raise exception 'Invalid customer'; end if;
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
  insert into public.sales(organization_id,branch_id,receipt_number,idempotency_key,customer_id,subtotal,total,payment_method,amount_tendered,change_amount,cashier_id) values(p_organization_id,p_branch_id,receipt,p_idempotency_key,p_customer_id,subtotal,subtotal,p_payment_method,case when p_payment_method='cash' then p_amount_tendered else subtotal end,case when p_payment_method='cash' then p_amount_tendered-subtotal else 0 end,auth.uid()) returning id into sale_id;
  for item in select * from jsonb_array_elements(p_items) loop
    select p.id,p.name,p.sku,bp.selling_price,bp.quantity into product_record from public.products p join public.branch_products bp on bp.product_id=p.id where p.id=(item->>'product_id')::uuid and bp.branch_id=p_branch_id for update of bp;
    line_total:=round(product_record.selling_price*(item->>'quantity')::numeric,2);
    insert into public.sale_items(sale_id,product_id,product_name,sku,quantity,unit_price,line_total) values(sale_id,product_record.id,product_record.name,product_record.sku,(item->>'quantity')::numeric,product_record.selling_price,line_total);
    update public.branch_products set quantity=quantity-(item->>'quantity')::numeric,updated_at=now() where branch_id=p_branch_id and product_id=product_record.id returning quantity into product_record.quantity;
    insert into public.inventory_movements(organization_id,branch_id,product_id,movement_type,quantity_delta,quantity_after,reason,created_by) values(p_organization_id,p_branch_id,product_record.id,'sale',-(item->>'quantity')::numeric,product_record.quantity,'Sale '||receipt,auth.uid());
  end loop;
  return jsonb_build_object('id',sale_id,'receipt_number',receipt,'total',subtotal,'change_amount',case when p_payment_method='cash' then p_amount_tendered-subtotal else 0 end);
end; $$;

create or replace function public.get_sales_purchase_report(p_organization_id uuid,p_branch_id uuid,p_start_date date,p_end_date date)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare result jsonb;
begin
  if p_start_date is null or p_end_date is null or p_start_date>p_end_date then raise exception 'Invalid report date range'; end if;
  if p_end_date-p_start_date>731 then raise exception 'Report range cannot exceed two years'; end if;
  if not public.current_user_can_use_branch(p_branch_id) or not exists(select 1 from public.branches where id=p_branch_id and organization_id=p_organization_id) then raise exception 'Branch access required'; end if;
  with days as (select generate_series(p_start_date,p_end_date,'1 day'::interval)::date as day),
  sales_by_day as (select created_at::date day,sum(total) total,count(*) count from public.sales where organization_id=p_organization_id and branch_id=p_branch_id and status='completed' and created_at>=p_start_date and created_at<p_end_date+1 group by created_at::date),
  purchases_by_day as (select po.ordered_at::date day,sum(i.quantity_ordered*i.unit_cost) total,count(distinct po.id) count from public.purchase_orders po join public.purchase_order_items i on i.purchase_order_id=po.id where po.organization_id=p_organization_id and po.branch_id=p_branch_id and po.status<>'cancelled' and po.ordered_at>=p_start_date and po.ordered_at<p_end_date+1 group by po.ordered_at::date)
  select jsonb_build_object(
    'summary',jsonb_build_object('sales_total',coalesce((select sum(total) from sales_by_day),0),'sales_count',coalesce((select sum(count) from sales_by_day),0),'purchases_total',coalesce((select sum(total) from purchases_by_day),0),'purchase_count',coalesce((select sum(count) from purchases_by_day),0)),
    'daily',coalesce((select jsonb_agg(jsonb_build_object('date',d.day,'sales',coalesce(s.total,0),'sales_count',coalesce(s.count,0),'purchases',coalesce(p.total,0),'purchase_count',coalesce(p.count,0)) order by d.day) from days d left join sales_by_day s on s.day=d.day left join purchases_by_day p on p.day=d.day),'[]'::jsonb),
    'sales',coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'number',s.receipt_number,'date',s.created_at,'customer',coalesce(c.name,'Walk-in customer'),'total',s.total,'status',s.status) order by s.created_at desc) from public.sales s left join public.customers c on c.id=s.customer_id where s.organization_id=p_organization_id and s.branch_id=p_branch_id and s.status='completed' and s.created_at>=p_start_date and s.created_at<p_end_date+1),'[]'::jsonb),
    'purchases',coalesce((select jsonb_agg(jsonb_build_object('id',po.id,'number',po.po_number,'date',po.ordered_at,'supplier',sp.name,'total',(select coalesce(sum(i.quantity_ordered*i.unit_cost),0) from public.purchase_order_items i where i.purchase_order_id=po.id),'status',po.status) order by po.ordered_at desc) from public.purchase_orders po join public.suppliers sp on sp.id=po.supplier_id where po.organization_id=p_organization_id and po.branch_id=p_branch_id and po.status<>'cancelled' and po.ordered_at>=p_start_date and po.ordered_at<p_end_date+1),'[]'::jsonb)
  ) into result;
  return result;
end; $$;

revoke all on function public.create_customer(uuid,text,text,text,text),public.create_pos_sale(uuid,uuid,jsonb,text,numeric,uuid,uuid),public.get_sales_purchase_report(uuid,uuid,date,date) from public;
grant execute on function public.create_customer(uuid,text,text,text,text),public.create_pos_sale(uuid,uuid,jsonb,text,numeric,uuid,uuid),public.get_sales_purchase_report(uuid,uuid,date,date) to authenticated;
notify pgrst, 'reload schema';
commit;
