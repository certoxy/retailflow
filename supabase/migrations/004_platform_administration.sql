begin;

alter table public.organizations
  add column if not exists user_limit integer not null default 5
    check (user_limit between 1 and 10000),
  add column if not exists enabled_modules jsonb not null default
    '{"dashboard":true,"branches":true,"staff":true,"products":true,"inventory":true,"pos":true,"purchasing":true,"expenses":true,"reports":true}'::jsonb;

create or replace function public.get_platform_admin_dashboard()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.current_user_is_platform_administrator() then
    raise exception 'Platform Administrator access required';
  end if;

  return jsonb_build_object(
    'organizations', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', o.id,
        'name', o.name,
        'slug', o.slug,
        'active', o.active,
        'user_limit', o.user_limit,
        'member_count', (
          select count(*)
          from public.organization_memberships m
          where m.organization_id = o.id and m.active
        ),
        'branch_count', (
          select count(*)
          from public.branches b
          where b.organization_id = o.id and b.active
        ),
        'enabled_modules', o.enabled_modules,
        'created_at', o.created_at
      ) order by o.name)
      from public.organizations o
    ), '[]'::jsonb),
    'platform_administrators', coalesce((
      select jsonb_agg(jsonb_build_object(
        'user_id', pa.user_id,
        'email', p.email,
        'full_name', p.full_name,
        'active', pa.active,
        'created_at', pa.created_at,
        'has_organization_membership', exists (
          select 1 from public.organization_memberships m
          where m.user_id = pa.user_id and m.active
        )
      ) order by coalesce(p.full_name, p.email))
      from public.platform_administrators pa
      join public.profiles p on p.id = pa.user_id
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function public.update_platform_organization_controls(
  p_organization_id uuid,
  p_active boolean,
  p_user_limit integer,
  p_enabled_modules jsonb
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.current_user_is_platform_administrator() then
    raise exception 'Platform Administrator access required';
  end if;
  if p_user_limit is null or p_user_limit < 1 or p_user_limit > 10000 then
    raise exception 'User limit must be between 1 and 10000';
  end if;
  if jsonb_typeof(p_enabled_modules) <> 'object' then
    raise exception 'Enabled modules must be a JSON object';
  end if;

  update public.organizations
  set active = p_active,
      user_limit = p_user_limit,
      enabled_modules = p_enabled_modules,
      updated_at = now()
  where id = p_organization_id;

  if not found then raise exception 'Organization not found'; end if;
end;
$$;

create or replace function public.grant_platform_administrator(p_email text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare target_user_id uuid;
begin
  if not public.current_user_is_platform_administrator() then
    raise exception 'Platform Administrator access required';
  end if;

  select id into target_user_id
  from public.profiles
  where lower(email) = lower(trim(p_email));

  if target_user_id is null then
    raise exception 'The user must create a RetailFlow account before platform access can be granted';
  end if;

  insert into public.platform_administrators (user_id, active, granted_by)
  values (target_user_id, true, auth.uid())
  on conflict (user_id) do update
  set active = true, granted_by = auth.uid(), updated_at = now();
end;
$$;

create or replace function public.set_platform_administrator_active(
  p_user_id uuid,
  p_active boolean
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare active_admin_count integer;
begin
  if not public.current_user_is_platform_administrator() then
    raise exception 'Platform Administrator access required';
  end if;

  if p_user_id = auth.uid() and not p_active then
    raise exception 'You cannot deactivate your own Platform Administrator access';
  end if;

  if not p_active then
    select count(*) into active_admin_count
    from public.platform_administrators where active;
    if active_admin_count <= 1 then
      raise exception 'RetailFlow must retain at least one active Platform Administrator';
    end if;
  end if;

  update public.platform_administrators
  set active = p_active, updated_at = now()
  where user_id = p_user_id;

  if not found then raise exception 'Platform Administrator not found'; end if;
end;
$$;

revoke all on function public.get_platform_admin_dashboard() from public;
revoke all on function public.update_platform_organization_controls(uuid, boolean, integer, jsonb) from public;
revoke all on function public.grant_platform_administrator(text) from public;
revoke all on function public.set_platform_administrator_active(uuid, boolean) from public;

grant execute on function public.get_platform_admin_dashboard() to authenticated;
grant execute on function public.update_platform_organization_controls(uuid, boolean, integer, jsonb) to authenticated;
grant execute on function public.grant_platform_administrator(text) to authenticated;
grant execute on function public.set_platform_administrator_active(uuid, boolean) to authenticated;

commit;
