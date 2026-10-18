begin;

create or replace function public.update_branch_product_price(p_organization_id uuid,p_branch_id uuid,p_product_id uuid,p_selling_price numeric)
returns void language plpgsql security definer set search_path=public as $$
declare previous_price numeric;
begin
  perform public.require_inventory_access(p_organization_id);
  if not public.current_user_can_manage_inventory(p_organization_id) then raise exception 'Inventory manager access required'; end if;
  if p_selling_price is null or p_selling_price<0 then raise exception 'Selling price must be zero or greater'; end if;
  select bp.selling_price into previous_price
  from public.branch_products bp join public.branches b on b.id=bp.branch_id join public.products p on p.id=bp.product_id
  where bp.branch_id=p_branch_id and bp.product_id=p_product_id and b.organization_id=p_organization_id and p.organization_id=p_organization_id
  for update of bp;
  if previous_price is null then raise exception 'Product is not configured for this branch'; end if;
  if previous_price is distinct from p_selling_price then
    update public.branch_products set selling_price=p_selling_price,updated_at=now() where branch_id=p_branch_id and product_id=p_product_id;
    insert into public.product_change_log(organization_id,product_id,action,changed_fields,before_values,after_values,changed_by)
    values(p_organization_id,p_product_id,'updated',array['selling price'],jsonb_build_object('branch_id',p_branch_id,'selling_price',previous_price),jsonb_build_object('branch_id',p_branch_id,'selling_price',p_selling_price),auth.uid());
  end if;
end; $$;

revoke all on function public.update_branch_product_price(uuid,uuid,uuid,numeric) from public;
grant execute on function public.update_branch_product_price(uuid,uuid,uuid,numeric) to authenticated;
notify pgrst,'reload schema';
commit;
