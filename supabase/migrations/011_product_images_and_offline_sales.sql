begin;

alter table public.products add column if not exists image_path text;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('product-images', 'product-images', true, 5242880, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists product_images_insert on storage.objects;
create policy product_images_insert on storage.objects for insert to authenticated
with check (
  bucket_id = 'product-images'
  and public.current_user_can_manage_inventory(((storage.foldername(name))[1])::uuid)
);

drop policy if exists product_images_delete on storage.objects;
create policy product_images_delete on storage.objects for delete to authenticated
using (
  bucket_id = 'product-images'
  and public.current_user_can_manage_inventory(((storage.foldername(name))[1])::uuid)
);

create or replace function public.set_product_image(p_product_id uuid, p_image_path text)
returns void language plpgsql security definer set search_path=public as $$
declare product_record public.products;
begin
  select * into product_record from public.products where id=p_product_id;
  if product_record.id is null then raise exception 'Product not found'; end if;
  if not public.current_user_can_manage_inventory(product_record.organization_id) then raise exception 'Inventory manager access required'; end if;
  if p_image_path not like product_record.organization_id::text||'/'||product_record.id::text||'/%' then raise exception 'Invalid product image path'; end if;
  update public.products set image_path=p_image_path,updated_at=now() where id=p_product_id;
end; $$;

create or replace function public.get_inventory_workspace(p_organization_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
begin
  perform public.require_inventory_access(p_organization_id);
  return jsonb_build_object(
    'categories',coalesce((select jsonb_agg(to_jsonb(c) order by c.name) from public.product_categories c where c.organization_id=p_organization_id and c.active),'[]'::jsonb),
    'products',coalesce((select jsonb_agg(jsonb_build_object(
      'id',p.id,'name',p.name,'sku',p.sku,'barcode',p.barcode,'description',p.description,'image_path',p.image_path,'unit',p.unit,'active',p.active,'category_id',p.category_id,'category_name',c.name,
      'branches',coalesce((select jsonb_agg(jsonb_build_object('branch_id',bp.branch_id,'branch_name',b.name,'selling_price',bp.selling_price,'quantity',bp.quantity,'low_stock_threshold',bp.low_stock_threshold,'active',bp.active) order by b.name) from public.branch_products bp join public.branches b on b.id=bp.branch_id where bp.product_id=p.id),'[]'::jsonb)
    ) order by p.name) from public.products p left join public.product_categories c on c.id=p.category_id where p.organization_id=p_organization_id),'[]'::jsonb),
    'movements',coalesce((select jsonb_agg(jsonb_build_object('id',m.id,'product_name',p.name,'sku',p.sku,'branch_name',b.name,'movement_type',m.movement_type,'quantity_delta',m.quantity_delta,'quantity_after',m.quantity_after,'reason',m.reason,'created_at',m.created_at) order by m.created_at desc) from (select * from public.inventory_movements where organization_id=p_organization_id order by created_at desc limit 100) m join public.products p on p.id=m.product_id join public.branches b on b.id=m.branch_id),'[]'::jsonb)
  );
end; $$;

create or replace function public.get_pos_workspace(p_organization_id uuid,p_branch_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare controls jsonb;
begin
  if not public.current_user_can_use_branch(p_branch_id) or not exists(select 1 from public.branches where id=p_branch_id and organization_id=p_organization_id and active) then raise exception 'Branch access required'; end if;
  select enabled_modules into controls from public.organizations where id=p_organization_id and active;
  if coalesce((controls->>'pos')::boolean,false)=false then raise exception 'Point of Sale is not enabled for this organization'; end if;
  return jsonb_build_object(
    'products',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'sku',p.sku,'barcode',p.barcode,'image_path',p.image_path,'unit',p.unit,'price',bp.selling_price,'quantity',bp.quantity) order by p.name) from public.branch_products bp join public.products p on p.id=bp.product_id where bp.branch_id=p_branch_id and bp.active and p.active),'[]'::jsonb),
    'sales',coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'receipt_number',s.receipt_number,'status',s.status,'total',s.total,'payment_method',s.payment_method,'cashier_name',p.full_name,'created_at',s.created_at,'items',(select jsonb_agg(jsonb_build_object('product_name',si.product_name,'sku',si.sku,'quantity',si.quantity,'unit_price',si.unit_price,'line_total',si.line_total)) from public.sale_items si where si.sale_id=s.id)) order by s.created_at desc) from (select * from public.sales where organization_id=p_organization_id and branch_id=p_branch_id order by created_at desc limit 50) s join public.profiles p on p.id=s.cashier_id),'[]'::jsonb)
  );
end; $$;

revoke all on function public.set_product_image(uuid,text) from public;
grant execute on function public.set_product_image(uuid,text) to authenticated;

commit;
