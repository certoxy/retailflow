begin;

alter table public.organizations
  add column if not exists subscription_plan text not null default 'starter' check (subscription_plan in ('starter','growth','business','enterprise')),
  add column if not exists billing_cycle text not null default 'monthly' check (billing_cycle in ('monthly','annual','complimentary')),
  add column if not exists subscription_status text not null default 'trial' check (subscription_status in ('trial','active','past_due','suspended','cancelled')),
  add column if not exists trial_ends_at timestamptz default (now()+interval '30 days'),
  add column if not exists next_billing_at timestamptz,
  add column if not exists subscription_price numeric(12,2),
  add column if not exists branch_limit integer not null default 1 check(branch_limit between 1 and 10000);

-- Protect existing customers from a surprise trial or bill when subscriptions launch.
update public.organizations set subscription_plan='business',billing_cycle='complimentary',subscription_status='active',trial_ends_at=null,subscription_price=0,branch_limit=greatest(branch_limit,10),user_limit=greatest(user_limit,30);

create or replace function public.get_platform_admin_dashboard()
returns jsonb language plpgsql stable security definer set search_path=public as $$
begin
  if not public.current_user_is_platform_administrator() then raise exception 'Platform Administrator access required'; end if;
  return jsonb_build_object(
    'organizations',coalesce((select jsonb_agg(jsonb_build_object(
      'id',o.id,'name',o.name,'slug',o.slug,'active',o.active,'user_limit',o.user_limit,'branch_limit',o.branch_limit,
      'member_count',(select count(*) from public.organization_memberships m where m.organization_id=o.id and m.active),
      'branch_count',(select count(*) from public.branches b where b.organization_id=o.id and b.active),
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
declare plan_users integer; plan_branches integer; plan_modules jsonb; effective_price numeric;
begin
  if not public.current_user_is_platform_administrator() then raise exception 'Platform Administrator access required'; end if;
  if p_plan not in('starter','growth','business','enterprise') then raise exception 'Invalid subscription plan'; end if;
  if p_billing_cycle not in('monthly','annual','complimentary') then raise exception 'Invalid billing cycle'; end if;
  if p_status not in('trial','active','past_due','suspended','cancelled') then raise exception 'Invalid subscription status'; end if;
  if p_subscription_price is not null and p_subscription_price<0 then raise exception 'Subscription price cannot be negative'; end if;
  if p_plan='starter' then plan_users:=3;plan_branches:=1;plan_modules:='{"dashboard":true,"branches":true,"staff":true,"products":true,"inventory":true,"pos":true,"returns":true,"operations":false,"purchasing":false,"expenses":false,"reports":true}'::jsonb;
  elsif p_plan='growth' then plan_users:=10;plan_branches:=3;plan_modules:='{"dashboard":true,"branches":true,"staff":true,"products":true,"inventory":true,"pos":true,"returns":true,"operations":true,"purchasing":true,"expenses":true,"reports":true}'::jsonb;
  elsif p_plan='business' then plan_users:=30;plan_branches:=10;plan_modules:='{"dashboard":true,"branches":true,"staff":true,"products":true,"inventory":true,"pos":true,"returns":true,"operations":true,"purchasing":true,"expenses":true,"reports":true}'::jsonb;
  else select user_limit,branch_limit,enabled_modules into plan_users,plan_branches,plan_modules from public.organizations where id=p_organization_id;
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
    enabled_modules=plan_modules,active=case when p_status in('suspended','cancelled') then false else active end,updated_at=now()
  where id=p_organization_id;
  if not found then raise exception 'Organization not found'; end if;
end; $$;

create or replace function public.create_organization_branch(p_organization_id uuid,p_name text,p_code text)
returns uuid language plpgsql security definer set search_path=public as $$
declare new_id uuid;current_branches integer;allowed_branches integer;
begin
  if not public.current_user_administers_organization(p_organization_id) then raise exception 'Organization administrator access required'; end if;
  if nullif(trim(p_name),'') is null then raise exception 'Branch name is required'; end if;
  if upper(trim(p_code)) !~ '^[A-Z0-9-]+$' then raise exception 'Branch code may contain letters, numbers, and hyphens only'; end if;
  select branch_limit into allowed_branches from public.organizations where id=p_organization_id and active;
  select count(*) into current_branches from public.branches where organization_id=p_organization_id and active;
  if allowed_branches is null then raise exception 'Organization is inactive'; end if;
  if current_branches>=allowed_branches then raise exception 'Organization branch limit reached. Upgrade the plan or contact PAOTechs.'; end if;
  insert into public.branches(organization_id,name,code,created_by) values(p_organization_id,trim(p_name),upper(trim(p_code)),auth.uid()) returning id into new_id;
  insert into public.branch_memberships(branch_id,organization_membership_id) select new_id,id from public.organization_memberships where organization_id=p_organization_id and user_id=auth.uid() and active on conflict do nothing;
  return new_id;
exception when unique_violation then raise exception 'That branch code is already in use';
end; $$;

revoke all on function public.update_platform_organization_subscription(uuid,text,text,text,timestamptz,timestamptz,numeric) from public;
grant execute on function public.update_platform_organization_subscription(uuid,text,text,text,timestamptz,timestamptz,numeric) to authenticated;
notify pgrst,'reload schema';
commit;
