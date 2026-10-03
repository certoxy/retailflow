begin;

alter table public.organizations
  add column business_address text,
  add column phone text,
  add column email text,
  add column website text,
  add column receipt_footer text;

create or replace function public.get_organization_admin_data(p_organization_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.current_user_belongs_to_organization(p_organization_id)
     and not public.current_user_is_platform_administrator() then
    raise exception 'Organization access required';
  end if;
  return jsonb_build_object(
    'organization', (select to_jsonb(o) from public.organizations o where o.id = p_organization_id),
    'branches', coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'name', b.name, 'code', b.code, 'active', b.active) order by b.name) from public.branches b where b.organization_id = p_organization_id), '[]'::jsonb),
    'members', coalesce((select jsonb_agg(jsonb_build_object(
      'membership_id', m.id, 'user_id', p.id, 'email', p.email, 'full_name', p.full_name,
      'role', m.role, 'active', m.active,
      'branch_names', coalesce((select jsonb_agg(b.name order by b.name) from public.branch_memberships bm join public.branches b on b.id = bm.branch_id where bm.organization_membership_id = m.id), '[]'::jsonb)
    ) order by coalesce(p.full_name, p.email)) from public.organization_memberships m join public.profiles p on p.id = m.user_id where m.organization_id = p_organization_id), '[]'::jsonb)
  );
end; $$;

create or replace function public.create_organization_branch(p_organization_id uuid, p_name text, p_code text)
returns uuid language plpgsql security definer set search_path = public as $$
declare new_id uuid;
begin
  if not public.current_user_administers_organization(p_organization_id) then raise exception 'Organization administrator access required'; end if;
  if nullif(trim(p_name), '') is null then raise exception 'Branch name is required'; end if;
  if upper(trim(p_code)) !~ '^[A-Z0-9-]+$' then raise exception 'Branch code may contain letters, numbers, and hyphens only'; end if;
  insert into public.branches (organization_id, name, code, created_by)
  values (p_organization_id, trim(p_name), upper(trim(p_code)), auth.uid()) returning id into new_id;
  insert into public.branch_memberships (branch_id, organization_membership_id)
  select new_id, id from public.organization_memberships where organization_id = p_organization_id and user_id = auth.uid() and active
  on conflict do nothing;
  return new_id;
exception when unique_violation then raise exception 'That branch code is already in use';
end; $$;

create or replace function public.update_organization_business_profile(
  p_organization_id uuid, p_name text, p_address text, p_phone text,
  p_email text, p_website text, p_receipt_footer text
) returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.current_user_administers_organization(p_organization_id) then raise exception 'Organization administrator access required'; end if;
  if nullif(trim(p_name), '') is null then raise exception 'Organization name is required'; end if;
  update public.organizations set
    name = trim(p_name), business_address = nullif(trim(p_address), ''), phone = nullif(trim(p_phone), ''),
    email = nullif(trim(p_email), ''), website = nullif(trim(p_website), ''),
    receipt_footer = nullif(trim(p_receipt_footer), ''), updated_at = now()
  where id = p_organization_id;
end; $$;

revoke all on function public.get_organization_admin_data(uuid) from public;
revoke all on function public.create_organization_branch(uuid, text, text) from public;
revoke all on function public.update_organization_business_profile(uuid, text, text, text, text, text, text) from public;
grant execute on function public.get_organization_admin_data(uuid) to authenticated;
grant execute on function public.create_organization_branch(uuid, text, text) to authenticated;
grant execute on function public.update_organization_business_profile(uuid, text, text, text, text, text, text) to authenticated;

commit;
