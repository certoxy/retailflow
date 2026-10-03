begin;

create table public.organization_invitations (
  id uuid primary key default gen_random_uuid(),
  token uuid not null unique default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  email text not null,
  role public.organization_role not null default 'staff',
  branch_ids uuid[] not null default '{}',
  status text not null default 'pending' check (status in ('pending', 'accepted', 'revoked')),
  invited_by uuid not null references public.profiles(id),
  expires_at timestamptz not null default (now() + interval '7 days'),
  accepted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index organization_invitations_pending_email
  on public.organization_invitations (organization_id, lower(email))
  where status = 'pending';

alter table public.organization_invitations enable row level security;

create policy organization_invitations_admin_read
on public.organization_invitations for select to authenticated
using (
  public.current_user_administers_organization(organization_id)
  or public.current_user_is_platform_administrator()
  or lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))
);

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
      'branch_ids', coalesce((select jsonb_agg(b.id) from public.branch_memberships bm join public.branches b on b.id = bm.branch_id where bm.organization_membership_id = m.id), '[]'::jsonb),
      'branch_names', coalesce((select jsonb_agg(b.name order by b.name) from public.branch_memberships bm join public.branches b on b.id = bm.branch_id where bm.organization_membership_id = m.id), '[]'::jsonb)
    ) order by coalesce(p.full_name, p.email)) from public.organization_memberships m join public.profiles p on p.id = m.user_id where m.organization_id = p_organization_id), '[]'::jsonb),
    'invitations', coalesce((select jsonb_agg(jsonb_build_object(
      'id', i.id, 'token', i.token, 'email', i.email, 'role', i.role,
      'branch_ids', i.branch_ids, 'status', i.status, 'expires_at', i.expires_at
    ) order by i.created_at desc) from public.organization_invitations i where i.organization_id = p_organization_id and i.status = 'pending'), '[]'::jsonb)
  );
end; $$;

create or replace function public.create_organization_invitation(
  p_organization_id uuid, p_email text, p_role public.organization_role, p_branch_ids uuid[]
) returns uuid language plpgsql security definer set search_path = public as $$
declare new_token uuid; seats integer; seat_limit integer;
begin
  if not public.current_user_administers_organization(p_organization_id) then raise exception 'Organization administrator access required'; end if;
  if p_role = 'owner' then raise exception 'Owner access cannot be assigned by invitation'; end if;
  if nullif(trim(p_email), '') is null then raise exception 'Email is required'; end if;
  if exists (select 1 from unnest(coalesce(p_branch_ids, '{}')) x left join public.branches b on b.id = x and b.organization_id = p_organization_id where b.id is null) then raise exception 'Invalid branch assignment'; end if;
  select user_limit into seat_limit from public.organizations where id = p_organization_id and active;
  if seat_limit is null then raise exception 'Organization is inactive'; end if;
  select (select count(*) from public.organization_memberships where organization_id = p_organization_id and active)
       + (select count(*) from public.organization_invitations where organization_id = p_organization_id and status = 'pending' and expires_at > now()) into seats;
  if seats >= seat_limit then raise exception 'Organization user limit reached'; end if;
  if exists (select 1 from public.organization_memberships m join public.profiles p on p.id=m.user_id where m.organization_id=p_organization_id and lower(p.email)=lower(trim(p_email)) and m.active) then raise exception 'That user already belongs to this organization'; end if;
  update public.organization_invitations set status='revoked', updated_at=now() where organization_id=p_organization_id and lower(email)=lower(trim(p_email)) and status='pending';
  insert into public.organization_invitations (organization_id,email,role,branch_ids,invited_by)
  values (p_organization_id, lower(trim(p_email)), p_role, coalesce(p_branch_ids,'{}'), auth.uid()) returning token into new_token;
  return new_token;
end; $$;

create or replace function public.accept_organization_invitation(p_token uuid)
returns void language plpgsql security definer set search_path = public as $$
declare invitation public.organization_invitations; membership_id uuid; seats integer; seat_limit integer;
begin
  select * into invitation from public.organization_invitations where token=p_token and status='pending' and expires_at>now() for update;
  if invitation.id is null then raise exception 'Invitation is invalid or expired'; end if;
  if lower(invitation.email) <> lower(coalesce(auth.jwt()->>'email','')) then raise exception 'Sign in using the invited email address'; end if;
  select user_limit into seat_limit from public.organizations where id=invitation.organization_id and active;
  select count(*) into seats from public.organization_memberships where organization_id=invitation.organization_id and active;
  if seat_limit is null then raise exception 'Organization is inactive'; end if;
  if seats >= seat_limit then raise exception 'Organization user limit reached'; end if;
  insert into public.organization_memberships (organization_id,user_id,role,active)
  values (invitation.organization_id,auth.uid(),invitation.role,true)
  on conflict (organization_id,user_id) do update set role=excluded.role,active=true,updated_at=now()
  returning id into membership_id;
  delete from public.branch_memberships where organization_membership_id=membership_id;
  insert into public.branch_memberships (branch_id,organization_membership_id)
  select b.id,membership_id from public.branches b where b.organization_id=invitation.organization_id and b.id=any(invitation.branch_ids) on conflict do nothing;
  update public.organization_invitations set status='accepted',accepted_at=now(),updated_at=now() where id=invitation.id;
end; $$;

create or replace function public.revoke_organization_invitation(p_invitation_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare org_id uuid;
begin
  select organization_id into org_id from public.organization_invitations where id=p_invitation_id;
  if org_id is null or not public.current_user_administers_organization(org_id) then raise exception 'Organization administrator access required'; end if;
  update public.organization_invitations set status='revoked',updated_at=now() where id=p_invitation_id and status='pending';
end; $$;

revoke all on function public.create_organization_invitation(uuid,text,public.organization_role,uuid[]) from public;
revoke all on function public.accept_organization_invitation(uuid) from public;
revoke all on function public.revoke_organization_invitation(uuid) from public;
grant execute on function public.create_organization_invitation(uuid,text,public.organization_role,uuid[]) to authenticated;
grant execute on function public.accept_organization_invitation(uuid) to authenticated;
grant execute on function public.revoke_organization_invitation(uuid) to authenticated;

commit;
