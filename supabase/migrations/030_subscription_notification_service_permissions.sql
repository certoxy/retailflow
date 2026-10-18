begin;

grant select on table public.organization_memberships to service_role;
grant select on table public.organizations to service_role;
grant select on table public.profiles to service_role;
grant select on table public.platform_administrators to service_role;
grant select, insert, update on table public.subscription_notification_log to service_role;

commit;
