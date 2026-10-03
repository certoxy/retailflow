begin;

create or replace function public.create_organization_with_branch(
  p_name text,
  p_slug text,
  p_branch_name text default 'Main Branch'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  new_organization public.organizations;
  new_membership public.organization_memberships;
  new_branch public.branches;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  if nullif(trim(p_name), '') is null then
    raise exception 'Organization name is required';
  end if;

  if p_slug is null or p_slug !~ '^[a-z0-9]+(?:-[a-z0-9]+)*$' then
    raise exception 'Organization URL code must contain lowercase letters, numbers, and hyphens only';
  end if;

  if exists (
    select 1 from public.organization_memberships
    where user_id = auth.uid() and active
  ) then
    raise exception 'This account already belongs to an organization';
  end if;

  insert into public.organizations (name, slug, created_by)
  values (trim(p_name), trim(p_slug), auth.uid())
  returning * into new_organization;

  insert into public.organization_memberships (
    organization_id, user_id, role
  )
  values (new_organization.id, auth.uid(), 'owner')
  returning * into new_membership;

  insert into public.branches (
    organization_id, name, code, created_by
  )
  values (
    new_organization.id,
    coalesce(nullif(trim(p_branch_name), ''), 'Main Branch'),
    'MAIN',
    auth.uid()
  )
  returning * into new_branch;

  insert into public.branch_memberships (branch_id, organization_membership_id)
  values (new_branch.id, new_membership.id);

  return jsonb_build_object(
    'organization_id', new_organization.id,
    'membership_id', new_membership.id,
    'branch_id', new_branch.id
  );
exception
  when unique_violation then
    raise exception 'That organization URL code is already in use';
end;
$$;

create or replace function public.get_my_workspace()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'profile', (
      select jsonb_build_object(
        'email', p.email,
        'full_name', p.full_name
      )
      from public.profiles p
      where p.id = auth.uid() and p.active
    ),
    'is_platform_administrator',
      public.current_user_is_platform_administrator(),
    'memberships', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'membership_id', m.id,
          'role', m.role,
          'organization_id', o.id,
          'organization_name', o.name,
          'organization_slug', o.slug,
          'branches', coalesce((
            select jsonb_agg(
              jsonb_build_object(
                'id', b.id,
                'name', b.name,
                'code', b.code
              ) order by b.name
            )
            from public.branch_memberships bm
            join public.branches b on b.id = bm.branch_id
            where bm.organization_membership_id = m.id
              and b.active
          ), '[]'::jsonb)
        ) order by o.name
      )
      from public.organization_memberships m
      join public.organizations o on o.id = m.organization_id
      where m.user_id = auth.uid()
        and m.active
        and o.active
    ), '[]'::jsonb)
  );
$$;

revoke all on function public.create_organization_with_branch(text, text, text)
  from public;
revoke all on function public.get_my_workspace() from public;

grant execute on function public.create_organization_with_branch(text, text, text)
  to authenticated;
grant execute on function public.get_my_workspace()
  to authenticated;

commit;
