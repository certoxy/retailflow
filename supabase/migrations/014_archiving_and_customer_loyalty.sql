begin;

alter table public.organizations
  add column if not exists loyalty_enabled boolean not null default false,
  add column if not exists points_per_100 numeric(12,2) not null default 1 check(points_per_100>=0),
  add column if not exists referral_reward_points numeric(12,2) not null default 100 check(referral_reward_points>=0),
  add column if not exists customer_auto_archive_months integer not null default 6 check(customer_auto_archive_months between 1 and 120);

alter table public.customers
  add column if not exists archived_at timestamptz,
  add column if not exists last_transaction_at timestamptz,
  add column if not exists points_balance numeric(14,2) not null default 0 check(points_balance>=0),
  add column if not exists referral_code text,
  add column if not exists referred_by_customer_id uuid references public.customers(id) on delete set null,
  add column if not exists referral_rewarded boolean not null default false;

update public.customers set referral_code=upper(substr(replace(id::text,'-',''),1,8)) where referral_code is null;
create unique index if not exists customers_org_referral_code on public.customers(organization_id,referral_code);

create table if not exists public.customer_points_ledger(
  id uuid primary key default gen_random_uuid(),organization_id uuid not null references public.organizations(id) on delete cascade,
  customer_id uuid not null references public.customers(id) on delete cascade,sale_id uuid references public.sales(id) on delete set null,
  points numeric(14,2) not null,entry_type text not null check(entry_type in('purchase','purchase_reversal','referral','referral_reversal','adjustment')),
  description text not null,created_at timestamptz not null default now()
);
alter table public.customer_points_ledger enable row level security;
drop policy if exists customer_points_tenant_read on public.customer_points_ledger;
create policy customer_points_tenant_read on public.customer_points_ledger for select to authenticated using(public.current_user_belongs_to_organization(organization_id) or public.current_user_is_platform_administrator());
create unique index if not exists customer_points_sale_entry on public.customer_points_ledger(customer_id,sale_id,entry_type) where sale_id is not null;

create or replace function public.apply_sale_loyalty()
returns trigger language plpgsql security definer set search_path=public as $$
declare settings record;earned numeric;referrer uuid;reward numeric;
begin
  if new.customer_id is null then return new; end if;
  select loyalty_enabled,points_per_100,referral_reward_points into settings from public.organizations where id=new.organization_id;
  if not coalesce(settings.loyalty_enabled,false) then
    if tg_op='INSERT' then update public.customers set last_transaction_at=new.created_at,active=true,archived_at=null,updated_at=now() where id=new.customer_id; end if;
    return new;
  end if;
  earned:=round((new.total/100)*settings.points_per_100,2);
  if (tg_op='INSERT' and new.status='completed') then
    update public.customers set last_transaction_at=new.created_at,active=true,archived_at=null,points_balance=points_balance+earned,updated_at=now() where id=new.customer_id;
    if earned>0 then insert into public.customer_points_ledger(organization_id,customer_id,sale_id,points,entry_type,description) values(new.organization_id,new.customer_id,new.id,earned,'purchase','Purchase points for '||new.receipt_number) on conflict do nothing; end if;
    select referred_by_customer_id into referrer from public.customers where id=new.customer_id and not referral_rewarded;
    if referrer is not null and settings.referral_reward_points>0 then
      reward:=settings.referral_reward_points;update public.customers set points_balance=points_balance+reward,updated_at=now() where id=referrer;
      update public.customers set referral_rewarded=true,updated_at=now() where id=new.customer_id;
      insert into public.customer_points_ledger(organization_id,customer_id,sale_id,points,entry_type,description) values(new.organization_id,referrer,new.id,reward,'referral','Referral reward for '||new.receipt_number) on conflict do nothing;
    end if;
  elsif tg_op='UPDATE' and old.status='completed' and new.status='voided' then
    select coalesce(sum(points),0) into earned from public.customer_points_ledger where sale_id=new.id and entry_type='purchase';
    if earned>0 then update public.customers set points_balance=greatest(0,points_balance-earned),updated_at=now() where id=new.customer_id;insert into public.customer_points_ledger(organization_id,customer_id,sale_id,points,entry_type,description) values(new.organization_id,new.customer_id,new.id,-earned,'purchase_reversal','Voided sale '||new.receipt_number) on conflict do nothing;end if;
    select customer_id,coalesce(sum(points),0) into referrer,reward from public.customer_points_ledger where sale_id=new.id and entry_type='referral' group by customer_id;
    if referrer is not null and reward>0 then update public.customers set points_balance=greatest(0,points_balance-reward),updated_at=now() where id=referrer;update public.customers set referral_rewarded=false where id=new.customer_id;insert into public.customer_points_ledger(organization_id,customer_id,sale_id,points,entry_type,description) values(new.organization_id,referrer,new.id,-reward,'referral_reversal','Voided referral sale '||new.receipt_number) on conflict do nothing;end if;
  end if;
  return new;
end; $$;
drop trigger if exists sales_loyalty_trigger on public.sales;
create trigger sales_loyalty_trigger after insert or update of status on public.sales for each row execute function public.apply_sale_loyalty();

create or replace function public.get_customer_workspace(p_organization_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare months integer;
begin
  if not public.current_user_can_manage_inventory(p_organization_id) then raise exception 'Manager access required'; end if;
  select customer_auto_archive_months into months from public.organizations where id=p_organization_id;
  update public.customers set active=false,archived_at=now(),updated_at=now() where organization_id=p_organization_id and active and coalesce(last_transaction_at,created_at)<now()-(months||' months')::interval;
  return jsonb_build_object(
    'settings',(select jsonb_build_object('loyalty_enabled',loyalty_enabled,'points_per_100',points_per_100,'referral_reward_points',referral_reward_points,'customer_auto_archive_months',customer_auto_archive_months) from public.organizations where id=p_organization_id),
    'customers',coalesce((select jsonb_agg(jsonb_build_object('id',c.id,'name',c.name,'phone',c.phone,'email',c.email,'active',c.active,'last_transaction_at',c.last_transaction_at,'points_balance',c.points_balance,'referral_code',c.referral_code,'referred_by',r.name,'created_at',c.created_at) order by c.active desc,c.name) from public.customers c left join public.customers r on r.id=c.referred_by_customer_id where c.organization_id=p_organization_id),'[]'::jsonb)
  );
end; $$;

create or replace function public.set_customer_active(p_customer_id uuid,p_active boolean)
returns void language plpgsql security definer set search_path=public as $$ declare org uuid;begin select organization_id into org from public.customers where id=p_customer_id;if org is null or not public.current_user_can_manage_inventory(org) then raise exception 'Manager access required';end if;update public.customers set active=p_active,archived_at=case when p_active then null else now() end,updated_at=now() where id=p_customer_id;end;$$;

create or replace function public.create_customer_with_referral(p_organization_id uuid,p_name text,p_phone text,p_email text,p_referral_code text)
returns uuid language plpgsql security definer set search_path=public as $$ declare new_id uuid;referrer uuid;begin if not public.current_user_belongs_to_organization(p_organization_id) then raise exception 'Organization access required';end if;if nullif(trim(p_name),'') is null then raise exception 'Customer name is required';end if;if nullif(trim(p_referral_code),'') is not null then select id into referrer from public.customers where organization_id=p_organization_id and referral_code=upper(trim(p_referral_code)) and active;if referrer is null then raise exception 'Referral code not found';end if;end if;insert into public.customers(organization_id,name,phone,email,created_by,referral_code,referred_by_customer_id) values(p_organization_id,trim(p_name),nullif(trim(p_phone),''),nullif(lower(trim(p_email)),''),auth.uid(),upper(substr(replace(gen_random_uuid()::text,'-',''),1,8)),referrer) returning id into new_id;return new_id;end;$$;

create or replace function public.set_product_active(p_product_id uuid,p_active boolean)
returns void language plpgsql security definer set search_path=public as $$ declare org uuid;begin select organization_id into org from public.products where id=p_product_id;if org is null or not public.current_user_can_manage_inventory(org) then raise exception 'Inventory manager access required';end if;update public.products set active=p_active,updated_at=now() where id=p_product_id;update public.branch_products set active=p_active,updated_at=now() where product_id=p_product_id;end;$$;

create or replace function public.update_loyalty_settings(p_organization_id uuid,p_enabled boolean,p_points_per_100 numeric,p_referral_reward_points numeric,p_auto_archive_months integer)
returns void language plpgsql security definer set search_path=public as $$ begin if not public.current_user_administers_organization(p_organization_id) then raise exception 'Organization administrator access required';end if;if p_points_per_100<0 or p_referral_reward_points<0 or p_auto_archive_months<1 or p_auto_archive_months>120 then raise exception 'Invalid loyalty settings';end if;update public.organizations set loyalty_enabled=p_enabled,points_per_100=p_points_per_100,referral_reward_points=p_referral_reward_points,customer_auto_archive_months=p_auto_archive_months,updated_at=now() where id=p_organization_id;end;$$;

revoke all on function public.get_customer_workspace(uuid),public.set_customer_active(uuid,boolean),public.create_customer_with_referral(uuid,text,text,text,text),public.set_product_active(uuid,boolean),public.update_loyalty_settings(uuid,boolean,numeric,numeric,integer) from public;
grant execute on function public.get_customer_workspace(uuid),public.set_customer_active(uuid,boolean),public.create_customer_with_referral(uuid,text,text,text,text),public.set_product_active(uuid,boolean),public.update_loyalty_settings(uuid,boolean,numeric,numeric,integer) to authenticated;
notify pgrst,'reload schema';
commit;
