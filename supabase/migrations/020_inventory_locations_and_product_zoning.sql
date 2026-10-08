begin;

create table if not exists public.inventory_locations(
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  branch_id uuid not null references public.branches(id) on delete cascade,
  parent_location_id uuid references public.inventory_locations(id) on delete set null,
  name text not null,
  code text not null,
  location_type text not null check(location_type in('zone','aisle','shelf','rack','refrigerator','freezer','stockroom')),
  active boolean not null default true,
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(branch_id,code)
);

create table if not exists public.product_locations(
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  branch_id uuid not null references public.branches(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  location_id uuid not null references public.inventory_locations(id) on delete cascade,
  is_primary boolean not null default false,
  notes text,
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(product_id,location_id)
);

create unique index if not exists product_locations_one_primary on public.product_locations(product_id,branch_id) where is_primary;
alter table public.inventory_locations enable row level security;
alter table public.product_locations enable row level security;
drop policy if exists inventory_locations_tenant_read on public.inventory_locations;
create policy inventory_locations_tenant_read on public.inventory_locations for select to authenticated using(public.current_user_belongs_to_organization(organization_id) or public.current_user_is_platform_administrator());
drop policy if exists product_locations_tenant_read on public.product_locations;
create policy product_locations_tenant_read on public.product_locations for select to authenticated using(public.current_user_belongs_to_organization(organization_id) or public.current_user_is_platform_administrator());

create or replace function public.require_zoning_access(p_organization_id uuid)
returns void language plpgsql stable security definer set search_path=public as $$
begin
  if not public.current_user_can_manage_inventory(p_organization_id) then raise exception 'Inventory manager access required'; end if;
  if not exists(select 1 from public.organizations where id=p_organization_id and active and product_zoning_enabled) then raise exception 'Product zoning is not enabled for this organization'; end if;
end; $$;

create or replace function public.create_inventory_location(p_organization_id uuid,p_branch_id uuid,p_name text,p_code text,p_location_type text,p_parent_location_id uuid)
returns uuid language plpgsql security definer set search_path=public as $$
declare new_id uuid;
begin
  perform public.require_zoning_access(p_organization_id);
  if nullif(trim(p_name),'') is null then raise exception 'Location name is required'; end if;
  if upper(trim(p_code)) !~ '^[A-Z0-9-]+$' then raise exception 'Location code may contain letters, numbers, and hyphens only'; end if;
  if p_location_type not in('zone','aisle','shelf','rack','refrigerator','freezer','stockroom') then raise exception 'Invalid location type'; end if;
  if not exists(select 1 from public.branches where id=p_branch_id and organization_id=p_organization_id and active) then raise exception 'Invalid branch'; end if;
  if p_parent_location_id is not null and not exists(select 1 from public.inventory_locations where id=p_parent_location_id and organization_id=p_organization_id and branch_id=p_branch_id and active) then raise exception 'Invalid parent location'; end if;
  insert into public.inventory_locations(organization_id,branch_id,parent_location_id,name,code,location_type,created_by)
    values(p_organization_id,p_branch_id,p_parent_location_id,trim(p_name),upper(trim(p_code)),p_location_type,auth.uid()) returning id into new_id;
  return new_id;
exception when unique_violation then raise exception 'That location code is already used in this branch';
end; $$;

create or replace function public.assign_product_location(p_organization_id uuid,p_branch_id uuid,p_product_id uuid,p_location_id uuid,p_is_primary boolean,p_notes text)
returns uuid language plpgsql security definer set search_path=public as $$
declare assignment_id uuid;
begin
  perform public.require_zoning_access(p_organization_id);
  if not exists(select 1 from public.products where id=p_product_id and organization_id=p_organization_id and active) then raise exception 'Invalid product'; end if;
  if not exists(select 1 from public.branch_products where product_id=p_product_id and branch_id=p_branch_id and active) then raise exception 'Product is not active in this branch'; end if;
  if not exists(select 1 from public.inventory_locations where id=p_location_id and organization_id=p_organization_id and branch_id=p_branch_id and active) then raise exception 'Invalid location'; end if;
  if p_is_primary then update public.product_locations set is_primary=false,updated_at=now() where product_id=p_product_id and branch_id=p_branch_id and is_primary; end if;
  insert into public.product_locations(organization_id,branch_id,product_id,location_id,is_primary,notes,created_by)
    values(p_organization_id,p_branch_id,p_product_id,p_location_id,p_is_primary,nullif(trim(p_notes),''),auth.uid())
    on conflict(product_id,location_id) do update set is_primary=excluded.is_primary,notes=excluded.notes,updated_at=now()
    returning id into assignment_id;
  return assignment_id;
end; $$;

create or replace function public.get_inventory_workspace(p_organization_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
begin
  perform public.require_inventory_access(p_organization_id);
  return jsonb_build_object(
    'categories',coalesce((select jsonb_agg(to_jsonb(c) order by c.name) from public.product_categories c where c.organization_id=p_organization_id and c.active),'[]'::jsonb),
    'products',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'sku',p.sku,'barcode',p.barcode,'description',p.description,'image_path',p.image_path,'unit',p.unit,'active',p.active,'category_id',p.category_id,'category_name',c.name,
      'branches',coalesce((select jsonb_agg(jsonb_build_object('branch_id',bp.branch_id,'branch_name',b.name,'selling_price',bp.selling_price,'quantity',bp.quantity,'low_stock_threshold',bp.low_stock_threshold,'active',bp.active) order by b.name) from public.branch_products bp join public.branches b on b.id=bp.branch_id where bp.product_id=p.id),'[]'::jsonb)) order by p.name) from public.products p left join public.product_categories c on c.id=p.category_id where p.organization_id=p_organization_id),'[]'::jsonb),
    'movements',coalesce((select jsonb_agg(jsonb_build_object('id',m.id,'product_name',p.name,'sku',p.sku,'branch_name',b.name,'movement_type',m.movement_type,'quantity_delta',m.quantity_delta,'quantity_after',m.quantity_after,'reason',m.reason,'created_at',m.created_at) order by m.created_at desc) from (select * from public.inventory_movements where organization_id=p_organization_id order by created_at desc limit 100) m join public.products p on p.id=m.product_id join public.branches b on b.id=m.branch_id),'[]'::jsonb),
    'locations',coalesce((select jsonb_agg(jsonb_build_object('id',l.id,'branch_id',l.branch_id,'name',l.name,'code',l.code,'location_type',l.location_type,'parent_location_id',l.parent_location_id,'parent_name',parent.name,'active',l.active,'product_count',(select count(*) from public.product_locations pl where pl.location_id=l.id)) order by l.location_type,l.name) from public.inventory_locations l left join public.inventory_locations parent on parent.id=l.parent_location_id where l.organization_id=p_organization_id),'[]'::jsonb),
    'product_locations',coalesce((select jsonb_agg(jsonb_build_object('id',pl.id,'branch_id',pl.branch_id,'product_id',p.id,'product_name',p.name,'sku',p.sku,'location_id',l.id,'location_name',l.name,'location_code',l.code,'is_primary',pl.is_primary,'notes',pl.notes) order by p.name,pl.is_primary desc,l.name) from public.product_locations pl join public.products p on p.id=pl.product_id join public.inventory_locations l on l.id=pl.location_id where pl.organization_id=p_organization_id),'[]'::jsonb)
  );
end; $$;

revoke all on function public.require_zoning_access(uuid),public.create_inventory_location(uuid,uuid,text,text,text,uuid),public.assign_product_location(uuid,uuid,uuid,uuid,boolean,text) from public;
grant execute on function public.create_inventory_location(uuid,uuid,text,text,text,uuid),public.assign_product_location(uuid,uuid,uuid,uuid,boolean,text) to authenticated;
notify pgrst,'reload schema';
commit;
