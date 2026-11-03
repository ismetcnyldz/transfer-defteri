-- Toplu silinen eski rezervasyonların rapor (kasa) özetleri: kayıt silinse de rapor rakamları kalır
create table if not exists report_days (
  company_id uuid not null references companies(id) on delete cascade,
  day date not null,
  data jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  primary key (company_id, day)
);
alter table report_days enable row level security;
grant select, insert, update, delete on report_days to authenticated;
grant all on report_days to service_role;
revoke all on report_days from anon;
drop policy if exists report_days_all on report_days;
create policy report_days_all on report_days for all to authenticated using (company_id = my_company_id()) with check (company_id = my_company_id());
select 'ok' as durum;
