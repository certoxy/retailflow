begin;

create or replace function public.get_platform_admin_dashboard()
returns jsonb language plpgsql stable security definer set search_path=public as $$
begin
  if not public.current_user_is_platform_administrator() then raise exception 'Platform Administrator access required'; end if;
  return jsonb_build_object(
    'organizations',coalesce((select jsonb_agg(jsonb_build_object(
      'id',o.id,'name',o.name,'slug',o.slug,'business_type',o.business_type,'active',o.active,'user_limit',o.user_limit,'branch_limit',o.branch_limit,
      'member_count',(select count(*) from public.organization_memberships m where m.organization_id=o.id and m.active),
      'branch_count',(select count(*) from public.branches b where b.organization_id=o.id and b.active),
      'owner_details',coalesce((select jsonb_agg(jsonb_build_object('user_id',p.id,'full_name',p.full_name,'email',p.email,'active',m.active) order by coalesce(p.full_name,p.email)) from public.organization_memberships m join public.profiles p on p.id=m.user_id where m.organization_id=o.id and m.role='owner'),'[]'::jsonb),
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

revoke all on function public.get_platform_admin_dashboard() from public;
grant execute on function public.get_platform_admin_dashboard() to authenticated;
notify pgrst,'reload schema';

commit;
