begin;

create or replace function public.get_platform_admin_dashboard()
returns jsonb language plpgsql stable security definer set search_path=public as $$
begin
  if not public.current_user_is_platform_administrator() then
    raise exception 'Platform Administrator access required';
  end if;

  return jsonb_build_object(
    'organizations',coalesce((select jsonb_agg(jsonb_build_object(
      'id',o.id,
      'name',o.name,
      'slug',o.slug,
      'active',o.active,
      'user_limit',o.user_limit,
      'branch_limit',o.branch_limit,
      'member_count',(select count(*) from public.organization_memberships m where m.organization_id=o.id and m.active),
      'branch_count',(select count(*) from public.branches b where b.organization_id=o.id and b.active),
      'product_count',(select count(*) from public.products p where p.organization_id=o.id and p.active),
      'archived_product_count',(select count(*) from public.products p where p.organization_id=o.id and not p.active),
      'customer_count',(select count(*) from public.customers c where c.organization_id=o.id and c.active),
      'archived_customer_count',(select count(*) from public.customers c where c.organization_id=o.id and not c.active),
      'sales_30d_count',(select count(*) from public.sales s where s.organization_id=o.id and s.status='completed' and s.created_at>=now()-interval '30 days'),
      'sales_30d_total',(select coalesce(sum(s.total),0) from public.sales s where s.organization_id=o.id and s.status='completed' and s.created_at>=now()-interval '30 days'),
      'purchases_30d_count',(select count(*) from public.purchase_orders po where po.organization_id=o.id and po.status<>'cancelled' and po.ordered_at>=now()-interval '30 days'),
      'purchases_30d_total',(select coalesce(sum(i.quantity_ordered*i.unit_cost),0) from public.purchase_orders po join public.purchase_order_items i on i.purchase_order_id=po.id where po.organization_id=o.id and po.status<>'cancelled' and po.ordered_at>=now()-interval '30 days'),
      'last_sale_at',(select max(s.created_at) from public.sales s where s.organization_id=o.id and s.status='completed'),
      'enabled_modules',o.enabled_modules,
      'created_at',o.created_at,
      'subscription_plan',o.subscription_plan,
      'billing_cycle',o.billing_cycle,
      'subscription_status',o.subscription_status,
      'trial_ends_at',o.trial_ends_at,
      'next_billing_at',o.next_billing_at,
      'subscription_price',o.subscription_price
    ) order by o.name) from public.organizations o),'[]'::jsonb),
    'platform_administrators',coalesce((select jsonb_agg(jsonb_build_object(
      'user_id',pa.user_id,
      'email',p.email,
      'full_name',p.full_name,
      'active',pa.active,
      'created_at',pa.created_at,
      'has_organization_membership',exists(select 1 from public.organization_memberships m where m.user_id=pa.user_id and m.active)
    ) order by coalesce(p.full_name,p.email)) from public.platform_administrators pa join public.profiles p on p.id=pa.user_id),'[]'::jsonb)
  );
end; $$;

revoke all on function public.get_platform_admin_dashboard() from public;
grant execute on function public.get_platform_admin_dashboard() to authenticated;
notify pgrst,'reload schema';
commit;
