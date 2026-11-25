-- U-ETDS bildirimi: yolcu kimlik bilgileri, plaka, bildirim durumu, firma U-ETDS hesabı

-- 1) Rezervasyon alanları
alter table bookings add column if not exists plate text;
alter table bookings add column if not exists uetds_status text not null default '';   -- '' | queued | sending | sent | error
alter table bookings add column if not exists uetds_ref text;                          -- U-ETDS sefer referans no
alter table bookings add column if not exists uetds_msg text;                          -- son hata / bilgi mesajı
alter table bookings add column if not exists uetds_at timestamptz;

-- 2) Firma U-ETDS hesabı (web servis şifresi uygulamaya geri okunmaz)
create table if not exists uetds_accounts (
  company_id uuid primary key references companies(id) on delete cascade,
  enabled boolean not null default false,
  auto_send boolean not null default true,
  test_mode boolean not null default true,
  ws_user text,
  ws_pass text,
  has_pass boolean generated always as (coalesce(ws_pass,'') <> '') stored,
  start_il int,          -- kalkış il plaka kodu (örn. 7)
  start_ilce int,        -- kalkış ilçe U-ETDS kodu
  start_place text,      -- örn. Antalya Havalimanı
  updated_at timestamptz not null default now()
);
alter table uetds_accounts enable row level security;
drop policy if exists uetds_acc_read on uetds_accounts;
create policy uetds_acc_read on uetds_accounts for select to authenticated using (company_id = my_company_id());
revoke all on uetds_accounts from anon, authenticated;
grant select (company_id, enabled, auto_send, test_mode, ws_user, has_pass, start_il, start_ilce, start_place, updated_at)
  on uetds_accounts to authenticated;

-- Kaydetme: şifre boş gelirse eskisi kalır
create or replace function uetds_save(p jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare cid uuid := my_company_id();
begin
  if cid is null then raise exception 'no company'; end if;
  insert into uetds_accounts(company_id, enabled, auto_send, test_mode, ws_user, ws_pass, start_il, start_ilce, start_place, updated_at)
  values (cid, coalesce((p->>'enabled')::boolean,false), coalesce((p->>'auto_send')::boolean,true), coalesce((p->>'test_mode')::boolean,true),
          nullif(left(trim(coalesce(p->>'ws_user','')),60),''), nullif(left(coalesce(p->>'ws_pass',''),120),''),
          nullif(p->>'start_il','')::int, nullif(p->>'start_ilce','')::int, nullif(left(trim(coalesce(p->>'start_place','')),120),''), now())
  on conflict (company_id) do update set
    enabled = excluded.enabled, auto_send = excluded.auto_send, test_mode = excluded.test_mode, ws_user = excluded.ws_user,
    ws_pass = coalesce(excluded.ws_pass, uetds_accounts.ws_pass),
    start_il = excluded.start_il, start_ilce = excluded.start_ilce, start_place = excluded.start_place, updated_at = now();
end $$;
revoke all on function uetds_save(jsonb) from public, anon;
grant execute on function uetds_save(jsonb) to authenticated;

-- 3) Gönderici program için: sıradaki işleri al (yalnızca service_role)
create or replace function uetds_claim(n int default 10)
returns setof bookings language plpgsql security definer set search_path = public as $$
begin
  return query
  update bookings b set uetds_status = 'sending', uetds_at = now()
  where b.id in (select id from bookings where uetds_status = 'queued' and deleted_at is null order by updated_at limit n for update skip locked)
  returning b.*;
end $$;
revoke all on function uetds_claim(int) from public, anon, authenticated;

-- 4) Müşteri formu: firma U-ETDS kullanıyorsa kimlik alanlarını göstersin
drop function if exists public_company(text);
create function public_company(p_slug text)
returns table(id uuid, name text, logo_url text, whatsapp text, meeting jsonb, uetds boolean)
language sql stable security definer set search_path = public as $$
  select c.id, c.name, c.logo_url, c.whatsapp, c.meeting, coalesce(u.enabled,false)
  from companies c left join uetds_accounts u on u.company_id = c.id where c.slug = p_slug
$$;
grant execute on function public_company(text) to anon, authenticated;

-- 5) Müşteri formundan gelen yolcu kimlik alanları (uyruk, cinsiyet, belge no)
create or replace function submit_booking(p_slug text, p jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare cid uuid; bid uuid;
begin
  select c.id into cid from companies c where c.slug = p_slug;
  if cid is null then raise exception 'company not found'; end if;
  if coalesce(p->>'first_name','') = '' or coalesce(p->>'date','') = '' then raise exception 'missing fields'; end if;
  insert into bookings(company_id, date, time, flight, return_date, return_time, return_flight,
    first_name, last_name, phone, email, language, adults, children, child_ages, infants, baby_seat, booster, luggage,
    hotel, area, from_place, to_place, customer_note, source, status, passengers, reminder_min, agent)
  values (cid, (p->>'date')::date, nullif(p->>'time','')::time, p->>'flight',
    nullif(p->>'return_date','')::date, nullif(p->>'return_time','')::time, p->>'return_flight',
    left(p->>'first_name',80), left(p->>'last_name',80), left(p->>'phone',40), left(p->>'email',120), left(p->>'language',5),
    least(coalesce((p->>'adults')::int,0),30), least(coalesce((p->>'children')::int,0),20),
    (select coalesce(array_agg(least(greatest(x::int,0),17)), '{}') from jsonb_array_elements_text(coalesce(p->'child_ages','[]'::jsonb)) x),
    least(coalesce((p->>'infants')::int,0),10), coalesce((p->>'baby_seat')::boolean,false), coalesce((p->>'booster')::boolean,false), nullif(p->>'luggage','')::int,
    left(p->>'hotel',120), left(p->>'area',80), left(p->>'from_place',120), left(p->>'to_place',120), left(p->>'customer_note',1000),
    'link', 'pending',
    (select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object('type', left(coalesce(x->>'type','adult'),10), 'name', left(coalesce(x->>'name',''),80),
        'age', case when coalesce(x->>'age','') ~ '^[0-9]{1,2}$' then (x->>'age')::int else null end,
        'nat', case when upper(coalesce(x->>'nat','')) ~ '^[A-Z]{2}$' then upper(x->>'nat') else null end,
        'sex', case when upper(coalesce(x->>'sex','')) in ('E','K') then upper(x->>'sex') else null end,
        'doc', nullif(left(regexp_replace(upper(coalesce(x->>'doc','')),'[^A-Z0-9]','','g'),20),''))) order by i), '[]'::jsonb)
       from jsonb_array_elements(case when jsonb_typeof(p->'passengers')='array' then p->'passengers' else '[]'::jsonb end) with ordinality t(x,i) where i <= 60),
    120, nullif(left(trim(coalesce(p->>'agent','')),60),''))
  returning id into bid;
  return bid;
end $$;

select 'ok' as durum;
