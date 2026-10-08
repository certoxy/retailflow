begin;

create or replace function public.update_inventory_product(
  p_organization_id uuid,p_product_id uuid,p_category_id uuid,p_name text,p_sku text,p_barcode text,p_description text,p_unit text
) returns void language plpgsql security definer set search_path=public as $$
begin
  perform public.require_inventory_access(p_organization_id);
  if not public.current_user_can_manage_inventory(p_organization_id) then raise exception 'Inventory manager access required'; end if;
  if nullif(trim(p_name),'') is null then raise exception 'Product name is required'; end if;
  if upper(trim(p_sku)) !~ '^[A-Z0-9-]+$' then raise exception 'SKU may contain letters, numbers, and hyphens only'; end if;
  if p_category_id is not null and not exists(select 1 from public.product_categories where id=p_category_id and organization_id=p_organization_id and active) then raise exception 'Invalid category'; end if;
  update public.products set category_id=p_category_id,name=trim(p_name),sku=upper(trim(p_sku)),barcode=nullif(trim(p_barcode),''),
    description=nullif(trim(p_description),''),unit=coalesce(nullif(trim(p_unit),''),'piece'),updated_at=now()
  where id=p_product_id and organization_id=p_organization_id;
  if not found then raise exception 'Product not found'; end if;
exception when unique_violation then raise exception 'SKU or barcode is already in use';
end; $$;

revoke all on function public.update_inventory_product(uuid,uuid,uuid,text,text,text,text,text) from public;
grant execute on function public.update_inventory_product(uuid,uuid,uuid,text,text,text,text,text) to authenticated;
notify pgrst,'reload schema';
commit;
