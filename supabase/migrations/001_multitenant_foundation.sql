begin;

create extension if not exists pgcrypto;

create type public.organization_role as enum (
  'owner',
  'administrator',
  'manager',
  'cashier',
  'staff'
);

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  full_name text,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index profiles_email_lower_unique
  on public.profiles (lower(email));

create table public.organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  slug text not null,
  active boolean not null default true,
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint organizations_slug_format
    check (slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$')
);

create unique index organizations_slug_lower_unique
  on public.organizations (lower(slug));

create table public.organization_memberships (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  role public.organization_role not null default 'staff',
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, user_id)
);

create table public.branches (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  name text not null,
  code text not null,
  active boolean not null default true,
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, code)
);

create table public.branch_memberships (
  branch_id uuid not null references public.branches(id) on delete cascade,
  organization_membership_id uuid not null
    references public.organization_memberships(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (branch_id, organization_membership_id)
);

create table public.platform_administrators (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  active boolean not null default true,
  granted_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create or replace function public.current_user_is_platform_administrator()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.platform_administrators
    where user_id = auth.uid()
      and active
  );
$$;

create or replace function public.current_user_belongs_to_organization(
  requested_organization_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.organization_memberships
    where organization_id = requested_organization_id
      and user_id = auth.uid()
      and active
  );
$$;

create or replace function public.current_user_administers_organization(
  requested_organization_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.current_user_is_platform_administrator()
    or exists (
      select 1
      from public.organization_memberships
      where organization_id = requested_organization_id
        and user_id = auth.uid()
        and active
        and role in ('owner', 'administrator')
    );
$$;

create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, email, full_name)
  values (
    new.id,
    coalesce(new.email, new.id::text),
    nullif(new.raw_user_meta_data ->> 'full_name', '')
  )
  on conflict (id) do update
  set email = excluded.email,
      full_name = coalesce(excluded.full_name, public.profiles.full_name),
      updated_at = now();

  return new;
end;
$$;

create trigger on_auth_user_created
after insert or update of email, raw_user_meta_data on auth.users
for each row execute procedure public.handle_new_auth_user();

alter table public.profiles enable row level security;
alter table public.organizations enable row level security;
alter table public.organization_memberships enable row level security;
alter table public.branches enable row level security;
alter table public.branch_memberships enable row level security;
alter table public.platform_administrators enable row level security;

create policy profiles_read_self_or_related
on public.profiles for select
to authenticated
using (
  id = auth.uid()
  or public.current_user_is_platform_administrator()
  or exists (
    select 1
    from public.organization_memberships mine
    join public.organization_memberships theirs
      on theirs.organization_id = mine.organization_id
    where mine.user_id = auth.uid()
      and mine.active
      and theirs.user_id = profiles.id
      and theirs.active
  )
);

create policy profiles_update_self
on public.profiles for update
to authenticated
using (id = auth.uid())
with check (id = auth.uid());

create policy organizations_read_member_or_platform
on public.organizations for select
to authenticated
using (
  public.current_user_is_platform_administrator()
  or public.current_user_belongs_to_organization(id)
);

create policy organizations_update_admin
on public.organizations for update
to authenticated
using (public.current_user_administers_organization(id))
with check (public.current_user_administers_organization(id));

create policy memberships_read_member_or_platform
on public.organization_memberships for select
to authenticated
using (
  public.current_user_is_platform_administrator()
  or public.current_user_belongs_to_organization(organization_id)
);

create policy memberships_manage_admin
on public.organization_memberships for all
to authenticated
using (public.current_user_administers_organization(organization_id))
with check (public.current_user_administers_organization(organization_id));

create policy branches_read_member_or_platform
on public.branches for select
to authenticated
using (
  public.current_user_is_platform_administrator()
  or public.current_user_belongs_to_organization(organization_id)
);

create policy branches_manage_admin
on public.branches for all
to authenticated
using (public.current_user_administers_organization(organization_id))
with check (public.current_user_administers_organization(organization_id));

create policy branch_memberships_read_related
on public.branch_memberships for select
to authenticated
using (
  public.current_user_is_platform_administrator()
  or exists (
    select 1
    from public.branches b
    where b.id = branch_memberships.branch_id
      and public.current_user_belongs_to_organization(b.organization_id)
  )
);

create policy branch_memberships_manage_admin
on public.branch_memberships for all
to authenticated
using (
  public.current_user_is_platform_administrator()
  or exists (
    select 1
    from public.branches b
    where b.id = branch_memberships.branch_id
      and public.current_user_administers_organization(b.organization_id)
  )
)
with check (
  public.current_user_is_platform_administrator()
  or exists (
    select 1
    from public.branches b
    where b.id = branch_memberships.branch_id
      and public.current_user_administers_organization(b.organization_id)
  )
);

create policy platform_administrators_read_platform
on public.platform_administrators for select
to authenticated
using (
  user_id = auth.uid()
  or public.current_user_is_platform_administrator()
);

revoke all on function public.current_user_is_platform_administrator() from public;
revoke all on function public.current_user_belongs_to_organization(uuid) from public;
revoke all on function public.current_user_administers_organization(uuid) from public;

grant execute on function public.current_user_is_platform_administrator()
  to authenticated;
grant execute on function public.current_user_belongs_to_organization(uuid)
  to authenticated;
grant execute on function public.current_user_administers_organization(uuid)
  to authenticated;

commit;
