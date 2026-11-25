-- Siteden kendi kendine üyelik: kullanıcı adı + şifre, 30 gün deneme (platform_settings.trial_days)
create or replace function public_signup(p jsonb) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid; em text; un text; cid uuid; ph text; co text;
begin
  -- kötüye kullanıma karşı: son 1 saatte en fazla 30 yeni kayıt
  if (select count(*) from companies where created_at > now() - interval '1 hour') >= 30 then
    raise exception 'Şu an çok fazla kayıt var, lütfen biraz sonra tekrar deneyin';
  end if;
  co := trim(coalesce(p->>'company',''));
  ph := trim(coalesce(p->>'whatsapp',''));
  if length(co) < 2 then raise exception 'Firma adı gerekli'; end if;
  if length(regexp_replace(ph, '[^0-9]', '', 'g')) < 10 then raise exception 'Geçerli bir WhatsApp numarası yazın'; end if;
  un := lower(regexp_replace(translate(coalesce(p->>'username',''), 'çğıöşüÇĞİÖŞÜ ', 'cgiosucgiosu'), '[^A-Za-z0-9._-]', '', 'g'));
  if length(un) < 3 or length(un) > 30 then raise exception 'Kullanıcı adı 3–30 karakter olmalı (harf, rakam)'; end if;
  if length(coalesce(p->>'password','')) < 6 then raise exception 'Şifre en az 6 karakter olmalı'; end if;
  em := username_email(un);
  if exists (select 1 from auth.users where email = em) or exists (select 1 from companies where username = un) then
    raise exception 'Bu kullanıcı adı alınmış, başka bir tane deneyin';
  end if;
  uid := gen_random_uuid();
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at, confirmation_token, recovery_token, email_change_token_new, email_change)
  values ('00000000-0000-0000-0000-000000000000', uid, 'authenticated', 'authenticated', em, extensions.crypt(p->>'password', extensions.gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    jsonb_build_object('username', un, 'company', co, 'contact', nullif(trim(coalesce(p->>'contact','')),''), 'whatsapp', ph,
                       'contact_email', nullif(trim(coalesce(p->>'email','')),''), 'self_signup', true),
    now(), now(), '', '', '', '');
  insert into auth.identities (id, user_id, provider_id, provider, identity_data, last_sign_in_at, created_at, updated_at)
  values (gen_random_uuid(), uid, uid::text, 'email', jsonb_build_object('sub', uid::text, 'email', em, 'email_verified', true), now(), now(), now());
  select company_id into cid from members where user_id = uid;
  update companies set notes = trim(coalesce(notes,'') || ' [siteden kayıt]') where id = cid;
  return jsonb_build_object('username', un, 'login_email', em);
end $$;
revoke all on function public_signup(jsonb) from public;
grant execute on function public_signup(jsonb) to anon, authenticated;
select 'ok' as durum;
