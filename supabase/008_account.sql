-- 1) GÜVENLİK: firmalar kendi üyelik alanlarını (plan, bitiş, durum, kullanıcı adı) değiştiremesin
create or replace function protect_company_fields() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if is_platform_admin() or current_setting('td.allow_username', true) = '1' then
    return new;
  end if;
  new.plan := old.plan; new.status := old.status;
  new.trial_ends_at := old.trial_ends_at; new.paid_until := old.paid_until;
  new.username := old.username;
  return new;
end $$;
drop trigger if exists companies_protect on companies;
create trigger companies_protect before update on companies for each row execute function protect_company_fields();

-- 2) Firma bilgileri: adres ve web/instagram
alter table companies add column if not exists address text;
alter table companies add column if not exists website text;

-- 3) Kullanıcı adı değiştirme (giriş e-postası: kullaniciadi@firma.transferdefteri.net)
create or replace function change_username(p_new text) returns text language plpgsql security definer set search_path = public, auth as $$
declare u uuid := auth.uid(); cid uuid; nu text; old_email text; new_email text;
begin
  if u is null then raise exception 'Oturum yok'; end if;
  nu := lower(regexp_replace(translate(trim(coalesce(p_new,'')), 'çğıöşüÇĞİÖŞÜ', 'cgiosucgiosu'), '[^a-zA-Z0-9._-]', '', 'g'));
  if length(nu) < 3 or length(nu) > 30 then raise exception 'Kullanıcı adı 3–30 karakter olmalı (harf, rakam, nokta, tire)'; end if;
  select email into old_email from auth.users where id = u;
  if old_email is null or old_email not like '%@firma.transferdefteri.net' then
    raise exception 'Bu hesap e-posta ile giriş yapıyor; kullanıcı adı değiştirilemez';
  end if;
  new_email := nu || '@firma.transferdefteri.net';
  if new_email = old_email then return nu; end if;
  if exists (select 1 from auth.users where email = new_email) or exists (select 1 from companies where username = nu) then
    raise exception 'Bu kullanıcı adı alınmış, başka bir tane deneyin';
  end if;
  cid := my_company_id();
  update auth.users set email = new_email, updated_at = now() where id = u;
  update auth.identities set identity_data = jsonb_set(identity_data, '{email}', to_jsonb(new_email)), updated_at = now()
    where user_id = u and provider = 'email';
  perform set_config('td.allow_username', '1', true);
  update companies set username = nu where id = cid;
  return nu;
end $$;
revoke all on function change_username(text) from public, anon;
grant execute on function change_username(text) to authenticated;

select 'ok' as durum;
