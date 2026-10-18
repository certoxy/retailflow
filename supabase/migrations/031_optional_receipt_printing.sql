begin;

alter table public.organizations
  add column if not exists print_receipt_enabled boolean not null default false;

update public.organizations set print_receipt_enabled = false
where print_receipt_enabled is distinct from false;

create or replace function public.update_organization_receipt_printing(
  p_organization_id uuid,
  p_enabled boolean
) returns void language plpgsql security definer set search_path=public as $$
begin
  if not public.current_user_administers_organization(p_organization_id) then
    raise exception 'Organization administrator access required';
  end if;
  update public.organizations
  set print_receipt_enabled=coalesce(p_enabled,false),updated_at=now()
  where id=p_organization_id;
  if not found then raise exception 'Organization not found'; end if;
end; $$;

revoke all on function public.update_organization_receipt_printing(uuid,boolean) from public;
grant execute on function public.update_organization_receipt_printing(uuid,boolean) to authenticated;

notify pgrst,'reload schema';
commit;
