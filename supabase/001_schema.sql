-- Transfer Defteri — şema v1
create extension if not exists pgcrypto;

-- Firmalar (çok firmalı yapıya hazır; şimdilik tek firma)
create table if not exists companies (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  slug text unique not null,            -- müşteri linkinde kullanılır: /r/<slug>
  phone text,
  whatsapp text,
  logo_url text,
  default_currency text not null default 'EUR',
  trial_ends_at timestamptz,
  plan text not null default 'trial',   -- trial | monthly | yearly | cancelled
  created_at timestamptz not null default now()
);

-- Firma kullanıcıları (auth.users ile eşleşir)
create table if not exists members (
  user_id uuid primary key references auth.users(id) on delete cascade,
  company_id uuid not null references companies(id) on delete cascade,
  role text not null default 'owner',   -- owner | staff
  created_at timestamptz not null default now()
);

-- Rezervasyonlar
create table if not exists bookings (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references companies(id) on delete cascade,
  date date not null,
  time time,
  flight text,
  return_date date,
  return_time time,
  return_flight text,
  first_name text,
  last_name text,
  phone text,
  email text,
  language text,                        -- müşterinin seçtiği dil: tr/en/ru/de
  adults int not null default 0,
  children int not null default 0,
  child_ages int[] default '{}',
  infants int not null default 0,
  baby_seat boolean not null default false,
  luggage int,
  hotel text,
  area text,
  from_place text,
  to_place text,
  vehicle text,
  receive_amount numeric(12,2) default 0,
  receive_cur text default 'EUR',
  pay_amount numeric(12,2) default 0,
  pay_cur text default 'EUR',
  pay_to text,
  received boolean not null default false,
  paid boolean not null default false,
  status text not null default 'pending',  -- pending | confirmed | done | cancelled
  reminder_min int not null default 0,
  note text,
  customer_note text,
  photos jsonb not null default '[]',
  source text not null default 'manual',   -- manual | link
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists bookings_company_date on bookings(company_id, date, time);

-- Oteller / yerler (firma ekledikleri ve kapattıkları)
create table if not exists places (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references companies(id) on delete cascade,
  type text not null default 'hotel',
  name text not null,
  area text,
  status text not null default 'open',   -- open | closed
  created_at timestamptz not null default now()
);

-- Firma ayarları / meta (son otel kontrolü vb.)
create table if not exists settings (
  company_id uuid primary key references companies(id) on delete cascade,
  places_reviewed_at timestamptz,
  data jsonb not null default '{}'
);

-- updated_at tetikleyici
create or replace function set_updated_at() returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;
drop trigger if exists bookings_updated_at on bookings;
create trigger bookings_updated_at before update on bookings for each row execute function set_updated_at();

-- Yardımcı: giriş yapan kullanıcının firması
create or replace function my_company_id() returns uuid language sql stable security definer set search_path = public as $$
  select company_id from members where user_id = auth.uid()
$$;

-- RLS
alter table companies enable row level security;
alter table members   enable row level security;
alter table bookings  enable row level security;
alter table places    enable row level security;
alter table settings  enable row level security;

drop policy if exists companies_select on companies;
create policy companies_select on companies for select to authenticated using (id = my_company_id());
drop policy if exists companies_update on companies;
create policy companies_update on companies for update to authenticated using (id = my_company_id());

drop policy if exists members_select on members;
create policy members_select on members for select to authenticated using (user_id = auth.uid());

drop policy if exists bookings_all on bookings;
create policy bookings_all on bookings for all to authenticated using (company_id = my_company_id()) with check (company_id = my_company_id());

drop policy if exists places_all on places;
create policy places_all on places for all to authenticated using (company_id = my_company_id()) with check (company_id = my_company_id());

drop policy if exists settings_all on settings;
create policy settings_all on settings for all to authenticated using (company_id = my_company_id()) with check (company_id = my_company_id());

-- Müşteri formu: anonim kullanıcı firma adını slug ile görür ve rezervasyon GÖNDERİR (okuyamaz)
create or replace function public_company(p_slug text)
returns table(id uuid, name text, logo_url text, whatsapp text)
language sql stable security definer set search_path = public as $$
  select id, name, logo_url, whatsapp from companies where slug = p_slug
$$;
grant execute on function public_company(text) to anon, authenticated;

create or replace function submit_booking(p_slug text, p jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare cid uuid; bid uuid;
begin
  select c.id into cid from companies c where c.slug = p_slug;
  if cid is null then raise exception 'company not found'; end if;
  if coalesce(p->>'first_name','') = '' or coalesce(p->>'date','') = '' then raise exception 'missing fields'; end if;
  insert into bookings(company_id, date, time, flight, return_date, return_time, return_flight,
    first_name, last_name, phone, email, language, adults, children, child_ages, infants, baby_seat, luggage,
    hotel, area, from_place, to_place, customer_note, source, status)
  values (cid, (p->>'date')::date, nullif(p->>'time','')::time, p->>'flight',
    nullif(p->>'return_date','')::date, nullif(p->>'return_time','')::time, p->>'return_flight',
    left(p->>'first_name',80), left(p->>'last_name',80), left(p->>'phone',40), left(p->>'email',120), left(p->>'language',5),
    least(coalesce((p->>'adults')::int,0),30), least(coalesce((p->>'children')::int,0),20),
    (select coalesce(array_agg(least(greatest(x::int,0),17)), '{}') from jsonb_array_elements_text(coalesce(p->'child_ages','[]'::jsonb)) x),
    least(coalesce((p->>'infants')::int,0),10), coalesce((p->>'baby_seat')::boolean,false), nullif(p->>'luggage','')::int,
    left(p->>'hotel',120), left(p->>'area',80), left(p->>'from_place',120), left(p->>'to_place',120), left(p->>'customer_note',1000),
    'link', 'pending')
  returning id into bid;
  return bid;
end $$;
grant execute on function submit_booking(text, jsonb) to anon, authenticated;

-- Anonim kullanıcı tablolara doğrudan erişemesin
revoke all on bookings, places, settings, members, companies from anon;

-- Otel öneri listesi: müşteri formu firmanın açık otellerini görebilsin
create or replace function public_places(p_slug text)
returns table(name text, area text, type text)
language sql stable security definer set search_path = public as $$
  select pl.name, pl.area, pl.type from places pl join companies c on c.id = pl.company_id
  where c.slug = p_slug and pl.status = 'open'
$$;
grant execute on function public_places(text) to anon, authenticated;

-- Yeni kullanıcı kaydolunca otomatik firma + üyelik (14 gün deneme)
create or replace function handle_new_user() returns trigger language plpgsql security definer set search_path = public as $$
declare cid uuid; s text;
begin
  s := lower(regexp_replace(coalesce(new.raw_user_meta_data->>'company', split_part(new.email,'@',1)), '[^a-z0-9]+', '-', 'g'));
  s := trim(both '-' from s); if s = '' then s := 'firma'; end if;
  s := s || '-' || substr(replace(gen_random_uuid()::text,'-',''),1,4);
  insert into companies(name, slug, trial_ends_at) values (coalesce(new.raw_user_meta_data->>'company', 'Firmam'), s, now() + interval '14 days') returning id into cid;
  insert into members(user_id, company_id, role) values (new.id, cid, 'owner');
  insert into settings(company_id, places_reviewed_at) values (cid, now());
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute function handle_new_user();

-- Fotoğraflar için depo
insert into storage.buckets (id, name, public) values ('photos','photos', false) on conflict (id) do nothing;
drop policy if exists photos_rw on storage.objects;
create policy photos_rw on storage.objects for all to authenticated
  using (bucket_id = 'photos' and (storage.foldername(name))[1] = my_company_id()::text)
  with check (bucket_id = 'photos' and (storage.foldername(name))[1] = my_company_id()::text);
