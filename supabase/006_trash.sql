-- Silinenler (çöp kutusu): silinen kayıt 30 gün saklanır, sonra kalıcı silinir
alter table bookings add column if not exists deleted_at timestamptz;
create index if not exists bookings_company_deleted on bookings(company_id, deleted_at) where deleted_at is not null;

-- her gece 03:00 (TR) 30 günü geçen silinenleri kalıcı sil (fotoğrafları uygulama açılışta temizler; bu yedek temizliktir)
create extension if not exists pg_cron;
select cron.unschedule(jobid) from cron.job where jobname = 'td_purge_trash';
select cron.schedule('td_purge_trash', '0 0 * * *', $$delete from public.bookings where deleted_at < now() - interval '30 days'$$);

select jobname, schedule from cron.job where jobname = 'td_purge_trash';
