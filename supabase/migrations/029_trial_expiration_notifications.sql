begin;

alter table public.subscription_notification_log
  drop constraint if exists subscription_notification_log_notification_type_check;

alter table public.subscription_notification_log
  add constraint subscription_notification_log_notification_type_check
  check (notification_type in ('trial_10_day', 'trial_expired'));

comment on column public.subscription_notification_log.notification_type is
  'Notification milestone: ten-day trial reminder or expiration-day notice.';

notify pgrst, 'reload schema';
commit;
