begin;

create table public.product_categories (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  name text not null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (organization_id, name)
);

create table public.products (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  category_id uuid references public.product_categories(id),
  name text not null,
  sku text not null,
  barcode text,
  description text,
  unit text not null default 'piece',
  active boolean not null default true,
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, sku)
);

create unique index products_barcode_per_organization
  on public.products (organization_id, barcode) where barcode is not null;

create table public.branch_products (
  branch_id uuid not null references public.branches(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  selling_price numeric(14,2) not null default 0 check (selling_price >= 0),
  quantity numeric(14,3) not null default 0,
  low_stock_threshold numeric(14,3) not null default 0 check (low_stock_threshold >= 0),
  active boolean not null default true,
  updated_at timestamptz not null default now(),
  primary key (branch_id, product_id)
);

create table public.inventory_movements (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  branch_id uuid not null references public.branches(id),
  product_id uuid not null references public.products(id),
  movement_type text not null check (movement_type in ('opening','adjustment','sale','return','transfer_in','transfer_out','purchase','disposal','stocktake')),
  quantity_delta numeric(14,3) not null check (quantity_delta <> 0),
  quantity_after numeric(14,3) not null,
  reason text,
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now()
);

alter table public.product_categories enable row level security;
alter table public.products enable row level security;
alter table public.branch_products enable row level security;
alter table public.inventory_movements enable row level security;

create policy product_categories_tenant_read on public.product_categories for select to authenticated using (public.current_user_belongs_to_organization(organization_id) or public.current_user_is_platform_administrator());
create policy products_tenant_read on public.products for select to authenticated using (public.current_user_belongs_to_organization(organization_id) or public.current_user_is_platform_administrator());
create policy branch_products_tenant_read on public.branch_products for select to authenticated using (exists(select 1 from public.branches b where b.id=branch_id and (public.current_user_belongs_to_organization(b.organization_id) or public.current_user_is_platform_administrator())));
create policy inventory_movements_tenant_read on public.inventory_movements for select to authenticated using (public.current_user_belongs_to_organization(organization_id) or public.current_user_is_platform_administrator());

create or replace function public.current_user_can_manage_inventory(p_organization_id uuid)
returns boolean language sql stable security definer set search_path=public as $$
  select public.current_user_is_platform_administrator() or exists (
    select 1 from public.organization_memberships
    where organization_id=p_organization_id and user_id=auth.uid() and active and role in ('owner','administrator','manager')
  );
$$;

create or replace function public.require_inventory_access(p_organization_id uuid)
returns void language plpgsql stable security definer set search_path=public as $$
declare controls jsonb; org_active boolean;
begin
  select enabled_modules,active into controls,org_active from public.organizations where id=p_organization_id;
  if not coalesce(org_active,false) then raise exception 'Organization is inactive'; end if;
  if not public.current_user_belongs_to_organization(p_organization_id) and not public.current_user_is_platform_administrator() then raise exception 'Organization access required'; end if;
  if coalesce((controls->>'products')::boolean,false)=false or coalesce((controls->>'inventory')::boolean,false)=false then raise exception 'Products and Inventory are not enabled for this organization'; end if;
end; $$;

create or replace function public.get_inventory_workspace(p_organization_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
begin
  perform public.require_inventory_access(p_organization_id);
  return jsonb_build_object(
    'categories',coalesce((select jsonb_agg(to_jsonb(c) order by c.name) from public.product_categories c where c.organization_id=p_organization_id and c.active),'[]'::jsonb),
    'products',coalesce((select jsonb_agg(jsonb_build_object(
      'id',p.id,'name',p.name,'sku',p.sku,'barcode',p.barcode,'description',p.description,'unit',p.unit,'active',p.active,'category_id',p.category_id,'category_name',c.name,
      'branches',coalesce((select jsonb_agg(jsonb_build_object('branch_id',bp.branch_id,'branch_name',b.name,'selling_price',bp.selling_price,'quantity',bp.quantity,'low_stock_threshold',bp.low_stock_threshold,'active',bp.active) order by b.name) from public.branch_products bp join public.branches b on b.id=bp.branch_id where bp.product_id=p.id),'[]'::jsonb)
    ) order by p.name) from public.products p left join public.product_categories c on c.id=p.category_id where p.organization_id=p_organization_id),'[]'::jsonb),
    'movements',coalesce((select jsonb_agg(jsonb_build_object('id',m.id,'product_name',p.name,'sku',p.sku,'branch_name',b.name,'movement_type',m.movement_type,'quantity_delta',m.quantity_delta,'quantity_after',m.quantity_after,'reason',m.reason,'created_at',m.created_at) order by m.created_at desc) from (select * from public.inventory_movements where organization_id=p_organization_id order by created_at desc limit 100) m join public.products p on p.id=m.product_id join public.branches b on b.id=m.branch_id),'[]'::jsonb)
  );
end; $$;

create or replace function public.create_product_category(p_organization_id uuid,p_name text)
returns uuid language plpgsql security definer set search_path=public as $$
declare new_id uuid;
begin
  perform public.require_inventory_access(p_organization_id);
  if not public.current_user_can_manage_inventory(p_organization_id) then raise exception 'Inventory manager access required'; end if;
  insert into public.product_categories(organization_id,name) values(p_organization_id,trim(p_name)) returning id into new_id;
  return new_id;
exception when unique_violation then raise exception 'That category already exists';
end; $$;

create or replace function public.create_inventory_product(
  p_organization_id uuid,p_category_id uuid,p_name text,p_sku text,p_barcode text,p_description text,p_unit text,
  p_branch_id uuid,p_selling_price numeric,p_opening_quantity numeric,p_low_stock_threshold numeric
) returns uuid language plpgsql security definer set search_path=public as $$
declare new_id uuid;
begin
  perform public.require_inventory_access(p_organization_id);
  if not public.current_user_can_manage_inventory(p_organization_id) then raise exception 'Inventory manager access required'; end if;
  if not exists(select 1 from public.branches where id=p_branch_id and organization_id=p_organization_id and active) then raise exception 'Invalid branch'; end if;
  if p_category_id is not null and not exists(select 1 from public.product_categories where id=p_category_id and organization_id=p_organization_id) then raise exception 'Invalid category'; end if;
  insert into public.products(organization_id,category_id,name,sku,barcode,description,unit,created_by)
  values(p_organization_id,p_category_id,trim(p_name),upper(trim(p_sku)),nullif(trim(p_barcode),''),nullif(trim(p_description),''),coalesce(nullif(trim(p_unit),''),'piece'),auth.uid()) returning id into new_id;
  insert into public.branch_products(branch_id,product_id,selling_price,quantity,low_stock_threshold) values(p_branch_id,new_id,p_selling_price,p_opening_quantity,p_low_stock_threshold);
  if p_opening_quantity<>0 then insert into public.inventory_movements(organization_id,branch_id,product_id,movement_type,quantity_delta,quantity_after,reason,created_by) values(p_organization_id,p_branch_id,new_id,'opening',p_opening_quantity,p_opening_quantity,'Opening inventory',auth.uid()); end if;
  return new_id;
exception when unique_violation then raise exception 'SKU or barcode is already in use';
end; $$;

create or replace function public.adjust_inventory_stock(p_organization_id uuid,p_branch_id uuid,p_product_id uuid,p_quantity_delta numeric,p_reason text)
returns numeric language plpgsql security definer set search_path=public as $$
declare new_quantity numeric;
begin
  perform public.require_inventory_access(p_organization_id);
  if not public.current_user_can_manage_inventory(p_organization_id) then raise exception 'Inventory manager access required'; end if;
  update public.branch_products bp set quantity=bp.quantity+p_quantity_delta,updated_at=now()
  where bp.branch_id=p_branch_id and bp.product_id=p_product_id and exists(select 1 from public.branches b where b.id=bp.branch_id and b.organization_id=p_organization_id)
  returning quantity into new_quantity;
  if new_quantity is null then raise exception 'Product is not configured for this branch'; end if;
  if new_quantity<0 then raise exception 'Adjustment would create negative stock'; end if;
  insert into public.inventory_movements(organization_id,branch_id,product_id,movement_type,quantity_delta,quantity_after,reason,created_by) values(p_organization_id,p_branch_id,p_product_id,'adjustment',p_quantity_delta,new_quantity,nullif(trim(p_reason),''),auth.uid());
  return new_quantity;
end; $$;

revoke all on function public.current_user_can_manage_inventory(uuid) from public;
revoke all on function public.require_inventory_access(uuid) from public;
revoke all on function public.get_inventory_workspace(uuid) from public;
revoke all on function public.create_product_category(uuid,text) from public;
revoke all on function public.create_inventory_product(uuid,uuid,text,text,text,text,text,uuid,numeric,numeric,numeric) from public;
revoke all on function public.adjust_inventory_stock(uuid,uuid,uuid,numeric,text) from public;
grant execute on function public.current_user_can_manage_inventory(uuid),public.require_inventory_access(uuid),public.get_inventory_workspace(uuid),public.create_product_category(uuid,text),public.create_inventory_product(uuid,uuid,text,text,text,text,text,uuid,numeric,numeric,numeric),public.adjust_inventory_stock(uuid,uuid,uuid,numeric,text) to authenticated;

commit;
