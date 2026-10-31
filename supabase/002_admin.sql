-- Transfer Defteri — yönetici paneli, plaka ile hesap açma, abonelik ve ödeme takibi
create extension if not exists pgcrypto with schema extensions;

alter table companies add column if not exists paid_until timestamptz;
alter table companies add column if not exists status text not null default 'active'; -- active | suspended
alter table companies add column if not exists owner_email text;
alter table companies add column if not exists contact_name text;
alter table companies add column if not exists username text;
alter table companies add column if not exists plate text;
alter table companies add column if not exists notes text;
create unique index if not exists companies_username_key on companies(username) where username is not null;

create table if not exists payments (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references companies(id) on delete cascade,
  amount numeric(12,2) not null default 0,
  currency text not null default 'TRY',
  plan text not null,
  months int not null default 1,
  period_start timestamptz not null,
  period_end timestamptz not null,
  note text,
  created_by uuid,
  created_at timestamptz not null default now()
);
alter table payments enable row level security;
revoke all on payments from anon, authenticated;
grant all on payments to service_role;

create table if not exists platform_admins (user_id uuid primary key references auth.users(id) on delete cascade, created_at timestamptz not null default now());
alter table platform_admins enable row level security;
revoke all on platform_admins from anon, authenticated;
grant all on platform_admins to service_role;

create table if not exists platform_settings (key text primary key, value text);
alter table platform_settings enable row level security;
revoke all on platform_settings from anon, authenticated;
grant all on platform_settings to service_role;
insert into platform_settings(key, value) values
  ('support_whatsapp',''),('price_monthly','250'),('price_yearly','3000'),('trial_days','30'),('iban',''),('iban_name',''),('app_url','https://transferdefteri.net')
on conflict (key) do nothing;

insert into platform_admins(user_id) select id from auth.users where email = 'kenzcn0@gmail.com' on conflict do nothing;
update companies c set owner_email = u.email from members m join auth.users u on u.id = m.user_id where m.company_id = c.id and c.owner_email is null;

create or replace function is_platform_admin() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from platform_admins where user_id = auth.uid())
$$;
grant execute on function is_platform_admin() to authenticated;

create or replace function handle_new_user() returns trigger language plpgsql security definer set search_path = public as $$
declare cid uuid; s text; base text; tdays int;
begin
  select coalesce(nullif(value,'')::int, 30) into tdays from platform_settings where key = 'trial_days';
  base := lower(regexp_replace(translate(coalesce(nullif(new.raw_user_meta_data->>'username',''), new.raw_user_meta_data->>'company', split_part(new.email,'@',1)), 'çğıöşüÇĞİÖŞÜ ', 'cgiosucgiosu'), '[^a-z0-9]+', '-', 'g'));
  base := trim(both '-' from base); if base = '' then base := 'firma'; end if;
  base := left(base, 24); s := base;
  if exists (select 1 from companies where slug = s) then s := base || '-' || substr(replace(gen_random_uuid()::text,'-',''),1,4); end if;
  insert into companies(name, slug, whatsapp, owner_email, contact_name, username, plate, trial_ends_at, plan, status)
  values (coalesce(nullif(new.raw_user_meta_data->>'company',''), nullif(new.raw_user_meta_data->>'username',''), 'Firmam'), s,
          nullif(new.raw_user_meta_data->>'whatsapp',''), coalesce(nullif(new.raw_user_meta_data->>'contact_email',''), new.email),
          nullif(new.raw_user_meta_data->>'contact',''), nullif(new.raw_user_meta_data->>'username',''), nullif(new.raw_user_meta_data->>'plate',''),
          now() + make_interval(days => coalesce(tdays,30)), 'trial', 'active')
  returning id into cid;
  insert into members(user_id, company_id, role) values (new.id, cid, 'owner');
  insert into settings(company_id, places_reviewed_at) values (cid, now());
  return new;
end $$;

-- kullanıcı adı -> giriş e-postası (deterministik)
create or replace function username_email(p_user text) returns text language sql immutable as $$
  select lower(regexp_replace(translate(p_user, 'çğıöşüÇĞİÖŞÜ', 'cgiosucgiosu'), '[^A-Za-z0-9._-]', '', 'g')) || '@firma.transferdefteri.net'
$$;
grant execute on function username_email(text) to anon, authenticated;

create or replace function my_access() returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'status', c.status, 'plan', c.plan, 'trial_ends_at', c.trial_ends_at, 'paid_until', c.paid_until, 'username', c.username, 'plate', c.plate,
    'access', (c.status = 'active' and (case when c.plan = 'trial' then coalesce(c.trial_ends_at, now()) > now() when c.plan = 'lifetime' then true else coalesce(c.paid_until, now()) > now() end)),
    'support_whatsapp', (select value from platform_settings where key = 'support_whatsapp'),
    'price_monthly', (select value from platform_settings where key = 'price_monthly'),
    'price_yearly', (select value from platform_settings where key = 'price_yearly'),
    'iban', (select value from platform_settings where key = 'iban'),
    'iban_name', (select value from platform_settings where key = 'iban_name'),
    'is_admin', is_platform_admin()
  ) from companies c where c.id = my_company_id()
$$;
grant execute on function my_access() to authenticated;

create or replace function admin_overview() returns table(
  id uuid, name text, slug text, username text, plate text, owner_email text, contact_name text, whatsapp text, plan text, status text,
  trial_ends_at timestamptz, paid_until timestamptz, notes text, created_at timestamptz,
  owner_user_id uuid, login_email text, last_sign_in_at timestamptz, must_change boolean,
  bookings_count bigint, link_bookings_count bigint, last_booking_at timestamptz, total_paid numeric
) language sql stable security definer set search_path = public as $$
  select c.id, c.name, c.slug, c.username, c.plate, c.owner_email, c.contact_name, c.whatsapp, c.plan, c.status, c.trial_ends_at, c.paid_until, c.notes, c.created_at,
    m.user_id, u.email, u.last_sign_in_at, coalesce((u.raw_user_meta_data->>'must_change')::boolean, false),
    (select count(*) from bookings b where b.company_id = c.id),
    (select count(*) from bookings b where b.company_id = c.id and b.source = 'link'),
    (select max(b.created_at) from bookings b where b.company_id = c.id),
    coalesce((select sum(p.amount) from payments p where p.company_id = c.id), 0)
  from companies c
  left join members m on m.company_id = c.id and m.role = 'owner'
  left join auth.users u on u.id = m.user_id
  where is_platform_admin() order by c.created_at desc
$$;
grant execute on function admin_overview() to authenticated;

create or replace function admin_payments(p_company uuid) returns setof payments language sql stable security definer set search_path = public as $$
  select * from payments where company_id = p_company and is_platform_admin() order by created_at desc
$$;
grant execute on function admin_payments(uuid) to authenticated;

-- yönetici: kullanıcı adı + şifre ile firma oluştur
create or replace function admin_create_company(p jsonb) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid; em text; un text; cid uuid;
begin
  if not is_platform_admin() then raise exception 'not allowed'; end if;
  un := lower(regexp_replace(translate(coalesce(p->>'username',''), 'çğıöşüÇĞİÖŞÜ ', 'cgiosucgiosu'), '[^A-Za-z0-9._-]', '', 'g'));
  if length(un) < 3 then raise exception 'Kullanıcı adı en az 3 karakter olmalı (harf ve rakam)'; end if;
  if length(coalesce(p->>'password','')) < 6 then raise exception 'Şifre en az 6 karakter olmalı'; end if;
  em := username_email(un);
  if exists (select 1 from auth.users where email = em) or exists (select 1 from companies where username = un) then raise exception 'Bu kullanıcı adı zaten kayıtlı'; end if;
  uid := gen_random_uuid();
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at, confirmation_token, recovery_token, email_change_token_new, email_change)
  values ('00000000-0000-0000-0000-000000000000', uid, 'authenticated', 'authenticated', em, extensions.crypt(p->>'password', extensions.gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    jsonb_build_object('username', un, 'plate', nullif(upper(regexp_replace(coalesce(p->>'plate',''), '\s+', '', 'g')),''), 'company', coalesce(nullif(p->>'company',''), un), 'contact', p->>'contact', 'whatsapp', p->>'whatsapp', 'contact_email', p->>'email', 'must_change', true),
    now(), now(), '', '', '', '');
  insert into auth.identities (id, user_id, provider_id, provider, identity_data, last_sign_in_at, created_at, updated_at)
  values (gen_random_uuid(), uid, uid::text, 'email', jsonb_build_object('sub', uid::text, 'email', em, 'email_verified', true), now(), now(), now());
  select company_id into cid from members where user_id = uid;
  return jsonb_build_object('user_id', uid, 'company_id', cid, 'login_email', em, 'username', un);
end $$;
grant execute on function admin_create_company(jsonb) to authenticated;

-- yönetici: geçici şifre ata (ilk girişte değiştirmesi istenir)
create or replace function admin_set_password(p_user uuid, p_pass text) returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  if not is_platform_admin() then raise exception 'not allowed'; end if;
  if length(coalesce(p_pass,'')) < 6 then raise exception 'Şifre en az 6 karakter olmalı'; end if;
  update auth.users set encrypted_password = extensions.crypt(p_pass, extensions.gen_salt('bf')),
    raw_user_meta_data = coalesce(raw_user_meta_data,'{}'::jsonb) || '{"must_change": true}'::jsonb, updated_at = now()
  where id = p_user;
end $$;
grant execute on function admin_set_password(uuid, text) to authenticated;

create or replace function admin_set_company(p_id uuid, p jsonb) returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_platform_admin() then raise exception 'not allowed'; end if;
  update companies set
    name = coalesce(p->>'name', name), contact_name = coalesce(p->>'contact_name', contact_name),
    whatsapp = coalesce(p->>'whatsapp', whatsapp), owner_email = coalesce(p->>'owner_email', owner_email), plate = case when p ? 'plate' then nullif(p->>'plate','') else plate end,
    slug = coalesce(nullif(p->>'slug',''), slug), status = coalesce(p->>'status', status), plan = coalesce(p->>'plan', plan),
    trial_ends_at = case when p ? 'trial_ends_at' then nullif(p->>'trial_ends_at','')::timestamptz else trial_ends_at end,
    paid_until = case when p ? 'paid_until' then nullif(p->>'paid_until','')::timestamptz else paid_until end,
    notes = coalesce(p->>'notes', notes)
  where id = p_id;
end $$;
grant execute on function admin_set_company(uuid, jsonb) to authenticated;

create or replace function admin_add_payment(p_company uuid, p_amount numeric, p_plan text, p_months int, p_note text default null)
returns timestamptz language plpgsql security definer set search_path = public as $$
declare s timestamptz; e timestamptz;
begin
  if not is_platform_admin() then raise exception 'not allowed'; end if;
  select greatest(now(), coalesce(paid_until, now()), case when plan = 'trial' then coalesce(trial_ends_at, now()) else now() end) into s from companies where id = p_company;
  e := s + make_interval(months => greatest(p_months,1));
  insert into payments(company_id, amount, plan, months, period_start, period_end, note, created_by)
  values (p_company, coalesce(p_amount,0), p_plan, greatest(p_months,1), s, e, p_note, auth.uid());
  update companies set paid_until = e, plan = p_plan, status = 'active' where id = p_company;
  return e;
end $$;
grant execute on function admin_add_payment(uuid, numeric, text, int, text) to authenticated;

create or replace function admin_delete_company(p_id uuid) returns void language plpgsql security definer set search_path = public as $$
declare u uuid;
begin
  if not is_platform_admin() then raise exception 'not allowed'; end if;
  if exists (select 1 from platform_admins pa join members m on m.user_id = pa.user_id where m.company_id = p_id) then raise exception 'Yönetici firması silinemez'; end if;
  for u in select user_id from members where company_id = p_id loop delete from auth.users where id = u; end loop;
  delete from companies where id = p_id;
end $$;
grant execute on function admin_delete_company(uuid) to authenticated;

create or replace function admin_set_setting(p_key text, p_value text) returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_platform_admin() then raise exception 'not allowed'; end if;
  insert into platform_settings(key, value) values (p_key, p_value) on conflict (key) do update set value = excluded.value;
end $$;
grant execute on function admin_set_setting(text, text) to authenticated;

create or replace function admin_settings() returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) from platform_settings where is_platform_admin()
$$;
grant execute on function admin_settings() to authenticated;

-- süresi dolmuş / askıdaki firma yeni kayıt ekleyemez (okuma serbest)
create or replace function company_can_write() returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select (c.status = 'active' and (case when c.plan = 'trial' then coalesce(c.trial_ends_at, now()) > now() when c.plan = 'lifetime' then true else coalesce(c.paid_until, now()) > now() end))
    from companies c where c.id = my_company_id()), false)
$$;
drop policy if exists bookings_all on bookings;
drop policy if exists bookings_select on bookings; drop policy if exists bookings_write on bookings; drop policy if exists bookings_update on bookings; drop policy if exists bookings_delete on bookings;
create policy bookings_select on bookings for select to authenticated using (company_id = my_company_id());
create policy bookings_write on bookings for insert to authenticated with check (company_id = my_company_id() and company_can_write());
create policy bookings_update on bookings for update to authenticated using (company_id = my_company_id() and company_can_write());
create policy bookings_delete on bookings for delete to authenticated using (company_id = my_company_id());

-- kurucu firması süresiz
update companies set plan = 'lifetime' where id in (select m.company_id from members m join platform_admins pa on pa.user_id = m.user_id);

select 'ok' as done, (select count(*) from platform_admins) as admins, (select plan from companies limit 1) as owner_plan;

-- Gelir / gider defteri (günlük masraflar, ekstra gelirler)
create table if not exists ledger (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references companies(id) on delete cascade,
  date date not null,
  kind text not null default 'expense',   -- expense | income
  category text,
  amount numeric(12,2) not null default 0,
  currency text not null default 'TRY',
  note text,
  booking_id uuid,
  created_at timestamptz not null default now()
);
create index if not exists ledger_company_date on ledger(company_id, date);
alter table ledger enable row level security;
grant select, insert, update, delete on ledger to authenticated;
grant all on ledger to service_role;
revoke all on ledger from anon;
drop policy if exists ledger_all on ledger;
create policy ledger_all on ledger for all to authenticated using (company_id = my_company_id()) with check (company_id = my_company_id() and company_can_write());
