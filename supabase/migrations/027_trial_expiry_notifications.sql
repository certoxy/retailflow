begin;

create table if not exists public.subscription_notification_log (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  notification_type text not null check (notification_type in ('trial_10_day')),
  trial_ends_at timestamptz not null,
  recipients text[] not null default '{}',
  cc_recipients text[] not null default '{}',
  status text not null default 'pending' check (status in ('pending','sent','failed')),
  provider_message_id text,
  error_message text,
  sent_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, notification_type, trial_ends_at)
);

alter table public.subscription_notification_log enable row level security;

create policy subscription_notification_log_platform_read
on public.subscription_notification_log for select
using (public.current_user_is_platform_administrator());

revoke all on table public.subscription_notification_log from public, anon, authenticated;
grant select on table public.subscription_notification_log to authenticated;

comment on table public.subscription_notification_log is
  'Idempotent delivery log for subscription and free-trial notifications.';

notify pgrst, 'reload schema';
commit;
