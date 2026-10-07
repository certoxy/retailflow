begin;

update public.organizations set
  monthly_transaction_limit=case subscription_plan
    when 'starter' then 500
    when 'growth' then 2500
    when 'business' then 12500
    else monthly_transaction_limit
  end,
  updated_at=now();

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

revoke all on function public.update_platform_organization_subscription(uuid,text,text,text,timestamptz,timestamptz,numeric) from public;
grant execute on function public.update_platform_organization_subscription(uuid,text,text,text,timestamptz,timestamptz,numeric) to authenticated;
notify pgrst,'reload schema';
commit;
