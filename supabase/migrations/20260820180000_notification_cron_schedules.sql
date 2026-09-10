-- Version-controls the pg_cron schedules for all user-facing notification jobs.
--
-- These jobs previously existed only in the live `cron.job` table (created ad hoc
-- via the dashboard) and were never in migrations, so a rebuild would either lose
-- them or re-create them with the wrong times.
--
-- IMPORTANT — TIMEZONE: pg_cron evaluates schedules in the database timezone, which
-- is UTC. Troddr's users are in Jamaica, which is UTC-5 all year (no DST). Every
-- schedule below is therefore written in UTC but chosen so the *local* Jamaica send
-- time is sensible. The original jobs used the hour numbers as if they were local,
-- which pushed notifications out at 3-6 AM Jamaica time. To convert a desired
-- Jamaica hour to the UTC cron hour, ADD 5 (e.g. 10:00 AM Jamaica -> hour 15 UTC).
--
-- cron.schedule(name, ...) upserts by job name, so re-running this migration just
-- refreshes the schedule of the existing named job (the jobid may change).
--
-- Auth uses the vault secrets `project_url` and `service_role_key` so no service-role
-- JWT is committed to the repo. These secrets must exist in Supabase Vault.

create extension if not exists pg_cron;
create extension if not exists pg_net;

do $$
declare
  -- Standard body for an edge-function-invoking cron command. %s = function name.
  tmpl text := $cmd$
  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url')
             || '/functions/v1/%s',
    headers := jsonb_build_object(
      'Content-Type',  'application/json',
      'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'service_role_key')
    ),
    body := '{}'::jsonb
  ) as request_id;
  $cmd$;
begin
  -- Daily user-facing pushes -> 10:00 AM Jamaica (15:00 UTC)
  perform cron.schedule('notify-saved-event',              '0 15 * * *', format(tmpl, 'notify-saved-event'));
  perform cron.schedule('event-notifications',             '0 15 * * *', format(tmpl, 'event-notifications'));
  perform cron.schedule('trip-countdown-notifications',    '0 15 * * *', format(tmpl, 'trip-countdown-notifications'));
  perform cron.schedule('notify-day-pass-feedback-daily',  '0 15 * * *', format(tmpl, 'notify-day-pass-feedback'));
  perform cron.schedule('notify-event-feedback-daily',     '0 15 * * *', format(tmpl, 'notify-event-feedback'));

  -- Weekly reminders -> same weekday, 10:00 AM Jamaica (15:00 UTC)
  perform cron.schedule('notify-rate-reminder',            '0 15 * * 3', format(tmpl, 'notify-rate-reminder'));  -- Wed
  perform cron.schedule('notify-rank-reminder',            '0 15 * * 4', format(tmpl, 'notify-rank-reminder'));  -- Thu
  perform cron.schedule('notify-engagement',               '0 15 * * 5', format(tmpl, 'notify-engagement'));     -- Fri

  -- Time-sensitive event-interest reminders -> hourly, but daytime only:
  -- 8:00 AM - 8:00 PM Jamaica == 13:00-01:00 UTC. No overnight pushes.
  perform cron.schedule('event-interest-reminders-hourly', '5 13-23,0-1 * * *', format(tmpl, 'event-interest-reminders'));
end $$;
