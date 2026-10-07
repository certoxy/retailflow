begin;

alter table public.organizations
  add column if not exists customer_limit integer not null default 2000 check(customer_limit between 1 and 10000000),
  add column if not exists product_limit integer not null default 500 check(product_limit between 1 and 10000000),
  add column if not exists monthly_transaction_limit integer not null default 500 check(monthly_transaction_limit between 1 and 100000000),
  add column if not exists storage_limit_mb integer not null default 1024 check(storage_limit_mb between 1 and 1000000);

update public.organizations set
  customer_limit=case subscription_plan when 'starter' then 2000 when 'growth' then 10000 when 'business' then 50000 else customer_limit end,
  product_limit=case subscription_plan when 'starter' then 500 when 'growth' then 2500 when 'business' then 10000 else product_limit end,
  monthly_transaction_limit=case subscription_plan when 'starter' then 500 when 'growth' then 2500 when 'business' then 12500 else monthly_transaction_limit end,
  storage_limit_mb=case subscription_plan when 'starter' then 1024 when 'growth' then 5120 when 'business' then 20480 else storage_limit_mb end;

create or replace function public.get_platform_admin_dashboard()
returns jsonb language plpgsql stable security definer set search_path=public as $$
begin
  if not public.current_user_is_platform_administrator() then raise exception 'Platform Administrator access required'; end if;
  return jsonb_build_object(
    'organizations',coalesce((select jsonb_agg(jsonb_build_object(
      'id',o.id,'name',o.name,'slug',o.slug,'active',o.active,'user_limit',o.user_limit,'branch_limit',o.branch_limit,
      'member_count',(select count(*) from public.organization_memberships m where m.organization_id=o.id and m.active),
      'branch_count',(select count(*) from public.branches b where b.organization_id=o.id and b.active),
      'product_count',(select count(*) from public.products p where p.organization_id=o.id and p.active),
      'product_limit',o.product_limit,
      'customer_count',(select count(*) from public.customers c where c.organization_id=o.id and c.active),
      'customer_limit',o.customer_limit,
      'monthly_transaction_count',(select count(*) from public.sales s where s.organization_id=o.id and s.status='completed' and s.created_at>=date_trunc('month',now()) and s.created_at<date_trunc('month',now())+interval '1 month'),
      'monthly_transaction_limit',o.monthly_transaction_limit,
      'storage_used_mb',(select round(coalesce(sum(coalesce((so.metadata->>'size')::numeric,0)),0)/1048576,2) from storage.objects so where so.bucket_id='product-images' and (storage.foldername(so.name))[1]=o.id::text),
      'storage_limit_mb',o.storage_limit_mb,
      'enabled_modules',o.enabled_modules,'created_at',o.created_at,'subscription_plan',o.subscription_plan,
      'billing_cycle',o.billing_cycle,'subscription_status',o.subscription_status,'trial_ends_at',o.trial_ends_at,
      'next_billing_at',o.next_billing_at,'subscription_price',o.subscription_price
    ) order by o.name) from public.organizations o),'[]'::jsonb),
    'platform_administrators',coalesce((select jsonb_agg(jsonb_build_object(
      'user_id',pa.user_id,'email',p.email,'full_name',p.full_name,'active',pa.active,'created_at',pa.created_at,
      'has_organization_membership',exists(select 1 from public.organization_memberships m where m.user_id=pa.user_id and m.active)
    ) order by coalesce(p.full_name,p.email)) from public.platform_administrators pa join public.profiles p on p.id=pa.user_id),'[]'::jsonb)
  );
end; $$;

create or replace function public.update_platform_organization_subscription(
  p_organization_id uuid,p_plan text,p_billing_cycle text,p_status text,p_trial_ends_at timestamptz,
  p_next_billing_at timestamptz,p_subscription_price numeric
) returns void language plpgsql security definer set search_path=public as $$
declare plan_users integer;plan_branches integer;plan_customers integer;plan_products integer;plan_transactions integer;plan_storage integer;plan_modules jsonb;effective_price numeric;
begin
  if not public.current_user_is_platform_administrator() then raise exception 'Platform Administrator access required'; end if;
  if p_plan not in('starter','growth','business','enterprise') then raise exception 'Invalid subscription plan'; end if;
  if p_billing_cycle not in('monthly','annual','complimentary') then raise exception 'Invalid billing cycle'; end if;
  if p_status not in('trial','active','past_due','suspended','cancelled') then raise exception 'Invalid subscription status'; end if;
  if p_subscription_price is not null and p_subscription_price<0 then raise exception 'Subscription price cannot be negative'; end if;
  if p_plan='starter' then plan_users:=3;plan_branches:=1;plan_customers:=2000;plan_products:=500;plan_transactions:=500;plan_storage:=1024;plan_modules:='{"dashboard":true,"branches":true,"staff":true,"products":true,"inventory":true,"pos":true,"returns":true,"operations":false,"purchasing":false,"expenses":false,"reports":true}'::jsonb;
  elsif p_plan='growth' then plan_users:=10;plan_branches:=3;plan_customers:=10000;plan_products:=2500;plan_transactions:=2500;plan_storage:=5120;plan_modules:='{"dashboard":true,"branches":true,"staff":true,"products":true,"inventory":true,"pos":true,"returns":true,"operations":true,"purchasing":true,"expenses":true,"reports":true}'::jsonb;
  elsif p_plan='business' then plan_users:=30;plan_branches:=10;plan_customers:=50000;plan_products:=10000;plan_transactions:=12500;plan_storage:=20480;plan_modules:='{"dashboard":true,"branches":true,"staff":true,"products":true,"inventory":true,"pos":true,"returns":true,"operations":true,"purchasing":true,"expenses":true,"reports":true}'::jsonb;
  else select user_limit,branch_limit,customer_limit,product_limit,monthly_transaction_limit,storage_limit_mb,enabled_modules into plan_users,plan_branches,plan_customers,plan_products,plan_transactions,plan_storage,plan_modules from public.organizations where id=p_organization_id;
  end if;
  effective_price:=p_subscription_price;
  if effective_price is null then
    if p_billing_cycle='complimentary' then effective_price:=0;
    elsif p_plan='starter' then effective_price:=case when p_billing_cycle='annual' then 8149 else 799 end;
    elsif p_plan='growth' then effective_price:=case when p_billing_cycle='annual' then 15289 else 1499 end;
    elsif p_plan='business' then effective_price:=case when p_billing_cycle='annual' then 30589 else 2999 end;
    end if;
  end if;
  update public.organizations set subscription_plan=p_plan,billing_cycle=p_billing_cycle,subscription_status=p_status,
    trial_ends_at=case when p_status='trial' then coalesce(p_trial_ends_at,now()+interval '30 days') else p_trial_ends_at end,
    next_billing_at=p_next_billing_at,subscription_price=effective_price,user_limit=plan_users,branch_limit=plan_branches,
    customer_limit=plan_customers,product_limit=plan_products,monthly_transaction_limit=plan_transactions,storage_limit_mb=plan_storage,
    enabled_modules=plan_modules,active=case when p_status in('suspended','cancelled') then false else active end,updated_at=now()
  where id=p_organization_id;
  if not found then raise exception 'Organization not found'; end if;
end; $$;

revoke all on function public.get_platform_admin_dashboard() from public;
revoke all on function public.update_platform_organization_subscription(uuid,text,text,text,timestamptz,timestamptz,numeric) from public;
grant execute on function public.get_platform_admin_dashboard() to authenticated;
grant execute on function public.update_platform_organization_subscription(uuid,text,text,text,timestamptz,timestamptz,numeric) to authenticated;
notify pgrst,'reload schema';
commit;
