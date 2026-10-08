begin;

create table if not exists public.product_change_log(
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  action text not null check(action in('created','updated')),
  changed_fields text[] not null default '{}',
  before_values jsonb,
  after_values jsonb not null,
  changed_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);

create index if not exists product_change_log_product_date on public.product_change_log(product_id,created_at desc);
alter table public.product_change_log enable row level security;
drop policy if exists product_change_log_tenant_read on public.product_change_log;
create policy product_change_log_tenant_read on public.product_change_log for select to authenticated
  using(public.current_user_belongs_to_organization(organization_id) or public.current_user_is_platform_administrator());

insert into public.product_change_log(organization_id,product_id,action,changed_fields,after_values,changed_by,created_at)
select p.organization_id,p.id,'created',array['name','sku','barcode','category','unit','description','status'],
  jsonb_build_object('name',p.name,'sku',p.sku,'barcode',p.barcode,'category_id',p.category_id,'unit',p.unit,'description',p.description,'active',p.active,'image_path',p.image_path),
  p.created_by,p.created_at
from public.products p
where not exists(select 1 from public.product_change_log l where l.product_id=p.id and l.action='created');

create or replace function public.record_product_change()
returns trigger language plpgsql security definer set search_path=public as $$
declare fields text[];before_data jsonb;after_data jsonb;
begin
  after_data:=jsonb_build_object('name',new.name,'sku',new.sku,'barcode',new.barcode,'category_id',new.category_id,'unit',new.unit,'description',new.description,'active',new.active,'image_path',new.image_path);
  if tg_op='INSERT' then
    insert into public.product_change_log(organization_id,product_id,action,changed_fields,after_values,changed_by,created_at)
      values(new.organization_id,new.id,'created',array['name','sku','barcode','category','unit','description','status'],after_data,coalesce(auth.uid(),new.created_by),new.created_at);
  else
    fields:=array_remove(array[
      case when old.name is distinct from new.name then 'name' end,
      case when old.sku is distinct from new.sku then 'sku' end,
      case when old.barcode is distinct from new.barcode then 'barcode' end,
      case when old.category_id is distinct from new.category_id then 'category' end,
      case when old.unit is distinct from new.unit then 'unit' end,
      case when old.description is distinct from new.description then 'description' end,
      case when old.active is distinct from new.active then 'status' end,
      case when old.image_path is distinct from new.image_path then 'image' end
    ],null);
    if cardinality(fields)>0 then
      before_data:=jsonb_build_object('name',old.name,'sku',old.sku,'barcode',old.barcode,'category_id',old.category_id,'unit',old.unit,'description',old.description,'active',old.active,'image_path',old.image_path);
      insert into public.product_change_log(organization_id,product_id,action,changed_fields,before_values,after_values,changed_by)
        values(new.organization_id,new.id,'updated',fields,before_data,after_data,auth.uid());
    end if;
  end if;
  return new;
end; $$;

drop trigger if exists product_change_log_trigger on public.products;
create trigger product_change_log_trigger after insert or update on public.products for each row execute function public.record_product_change();

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
    'product_locations',coalesce((select jsonb_agg(jsonb_build_object('id',pl.id,'branch_id',pl.branch_id,'product_id',p.id,'product_name',p.name,'sku',p.sku,'location_id',l.id,'location_name',l.name,'location_code',l.code,'is_primary',pl.is_primary,'notes',pl.notes) order by p.name,pl.is_primary desc,l.name) from public.product_locations pl join public.products p on p.id=pl.product_id join public.inventory_locations l on l.id=pl.location_id where pl.organization_id=p_organization_id),'[]'::jsonb),
    'product_change_log',coalesce((select jsonb_agg(jsonb_build_object('id',log.id,'product_id',log.product_id,'action',log.action,'changed_fields',log.changed_fields,'before_values',log.before_values,'after_values',log.after_values,'changed_by_name',profile.full_name,'changed_by_email',profile.email,'created_at',log.created_at) order by log.created_at desc) from (select * from public.product_change_log where organization_id=p_organization_id order by created_at desc limit 500) log left join public.profiles profile on profile.id=log.changed_by),'[]'::jsonb)
  );
end; $$;

notify pgrst,'reload schema';
commit;
