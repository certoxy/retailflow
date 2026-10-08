begin;

alter table public.organizations
  add column if not exists business_type text not null default 'general_retail'
    check(business_type in('dry_goods','convenience_store','general_retail','custom_retail')),
  add column if not exists inventory_expiration_enabled boolean not null default false,
  add column if not exists product_zoning_enabled boolean not null default false;

create or replace function public.apply_organization_business_template(p_organization_id uuid,p_business_type text)
returns void language plpgsql security definer set search_path=public as $$
begin
  if p_business_type not in('dry_goods','convenience_store','general_retail','custom_retail') then raise exception 'Invalid business type'; end if;
  if p_business_type='dry_goods' then
    update public.organizations set business_type=p_business_type,inventory_expiration_enabled=false,product_zoning_enabled=true,
      enabled_modules=enabled_modules||'{"dashboard":true,"branches":true,"staff":true,"products":true,"inventory":true,"pos":true,"returns":true,"operations":true,"purchasing":true,"reports":true}'::jsonb,updated_at=now() where id=p_organization_id;
  elsif p_business_type='convenience_store' then
    update public.organizations set business_type=p_business_type,inventory_expiration_enabled=true,product_zoning_enabled=true,
      enabled_modules=enabled_modules||'{"dashboard":true,"branches":true,"staff":true,"products":true,"inventory":true,"pos":true,"returns":true,"operations":true,"purchasing":true,"reports":true}'::jsonb,updated_at=now() where id=p_organization_id;
  elsif p_business_type='general_retail' then
    update public.organizations set business_type=p_business_type,inventory_expiration_enabled=false,product_zoning_enabled=false,
      enabled_modules=enabled_modules||'{"dashboard":true,"branches":true,"staff":true,"products":true,"inventory":true,"pos":true,"returns":true,"reports":true}'::jsonb,updated_at=now() where id=p_organization_id;
  else
    update public.organizations set business_type=p_business_type,updated_at=now() where id=p_organization_id;
  end if;
  if not found then raise exception 'Organization not found'; end if;
end; $$;

create or replace function public.create_organization_with_branch(p_name text,p_slug text,p_branch_name text,p_business_type text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare new_organization public.organizations;new_membership public.organization_memberships;new_branch public.branches;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if nullif(trim(p_name),'') is null then raise exception 'Organization name is required'; end if;
  if p_slug is null or p_slug !~ '^[a-z0-9]+(?:-[a-z0-9]+)*$' then raise exception 'Organization URL code must contain lowercase letters, numbers, and hyphens only'; end if;
  if p_business_type not in('dry_goods','convenience_store','general_retail','custom_retail') then raise exception 'Select a valid business type'; end if;
  if exists(select 1 from public.organization_memberships where user_id=auth.uid() and active) then raise exception 'This account already belongs to an organization'; end if;
  insert into public.organizations(name,slug,created_by,business_type) values(trim(p_name),trim(p_slug),auth.uid(),p_business_type) returning * into new_organization;
  perform public.apply_organization_business_template(new_organization.id,p_business_type);
  insert into public.organization_memberships(organization_id,user_id,role) values(new_organization.id,auth.uid(),'owner') returning * into new_membership;
  insert into public.branches(organization_id,name,code,created_by) values(new_organization.id,coalesce(nullif(trim(p_branch_name),''),'Main Branch'),'MAIN',auth.uid()) returning * into new_branch;
  insert into public.branch_memberships(branch_id,organization_membership_id) values(new_branch.id,new_membership.id);
  return jsonb_build_object('organization_id',new_organization.id,'membership_id',new_membership.id,'branch_id',new_branch.id);
exception when unique_violation then raise exception 'That organization URL code is already in use';
end; $$;

create or replace function public.update_organization_business_profile(
  p_organization_id uuid,p_name text,p_address text,p_phone text,p_email text,p_website text,p_receipt_footer text,p_business_type text
) returns void language plpgsql security definer set search_path=public as $$
begin
  if not public.current_user_administers_organization(p_organization_id) then raise exception 'Organization administrator access required'; end if;
  if nullif(trim(p_name),'') is null then raise exception 'Organization name is required'; end if;
  perform public.apply_organization_business_template(p_organization_id,p_business_type);
  update public.organizations set name=trim(p_name),business_address=nullif(trim(p_address),''),phone=nullif(trim(p_phone),''),
    email=nullif(trim(p_email),''),website=nullif(trim(p_website),''),receipt_footer=nullif(trim(p_receipt_footer),''),updated_at=now()
  where id=p_organization_id;
end; $$;

create or replace function public.get_platform_admin_dashboard()
returns jsonb language plpgsql stable security definer set search_path=public as $$
begin
  if not public.current_user_is_platform_administrator() then raise exception 'Platform Administrator access required'; end if;
  return jsonb_build_object(
    'organizations',coalesce((select jsonb_agg(jsonb_build_object(
      'id',o.id,'name',o.name,'slug',o.slug,'business_type',o.business_type,'active',o.active,'user_limit',o.user_limit,'branch_limit',o.branch_limit,
      'member_count',(select count(*) from public.organization_memberships m where m.organization_id=o.id and m.active),
      'branch_count',(select count(*) from public.branches b where b.organization_id=o.id and b.active),
      'product_count',(select count(*) from public.products p where p.organization_id=o.id and p.active),'product_limit',o.product_limit,
      'customer_count',(select count(*) from public.customers c where c.organization_id=o.id and c.active),'customer_limit',o.customer_limit,
      'monthly_transaction_count',(select count(*) from public.sales s where s.organization_id=o.id and s.status='completed' and s.created_at>=date_trunc('month',now()) and s.created_at<date_trunc('month',now())+interval '1 month'),'monthly_transaction_limit',o.monthly_transaction_limit,
      'storage_used_mb',(select round(coalesce(sum(coalesce((so.metadata->>'size')::numeric,0)),0)/1048576,2) from storage.objects so where so.bucket_id='product-images' and (storage.foldername(so.name))[1]=o.id::text),'storage_limit_mb',o.storage_limit_mb,
      'enabled_modules',o.enabled_modules,'created_at',o.created_at,'subscription_plan',o.subscription_plan,'billing_cycle',o.billing_cycle,
      'subscription_status',o.subscription_status,'trial_ends_at',o.trial_ends_at,'next_billing_at',o.next_billing_at,'subscription_price',o.subscription_price
    ) order by o.name) from public.organizations o),'[]'::jsonb),
    'platform_administrators',coalesce((select jsonb_agg(jsonb_build_object('user_id',pa.user_id,'email',p.email,'full_name',p.full_name,'active',pa.active,'created_at',pa.created_at,
      'has_organization_membership',exists(select 1 from public.organization_memberships m where m.user_id=pa.user_id and m.active)) order by coalesce(p.full_name,p.email)) from public.platform_administrators pa join public.profiles p on p.id=pa.user_id),'[]'::jsonb)
  );
end; $$;

revoke all on function public.apply_organization_business_template(uuid,text) from public;
revoke all on function public.create_organization_with_branch(text,text,text,text) from public;
revoke all on function public.update_organization_business_profile(uuid,text,text,text,text,text,text,text) from public;
grant execute on function public.create_organization_with_branch(text,text,text,text) to authenticated;
grant execute on function public.update_organization_business_profile(uuid,text,text,text,text,text,text,text) to authenticated;
notify pgrst,'reload schema';
commit;
