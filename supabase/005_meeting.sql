-- Havalimanı karşılama bilgisi (yazılar, görsel, video) — firma başına
alter table companies add column if not exists meeting jsonb not null default '{}'::jsonb;

drop function if exists public_company(text);
create function public_company(p_slug text)
returns table(id uuid, name text, logo_url text, whatsapp text, meeting jsonb)
language sql stable security definer set search_path = public as $$
  select id, name, logo_url, whatsapp, meeting from companies where slug = p_slug
$$;
grant execute on function public_company(text) to anon, authenticated;

-- herkese açık medya deposu (firma klasörü = firma id)
insert into storage.buckets (id, name, public) values ('media','media', true) on conflict (id) do update set public = true;
drop policy if exists media_read on storage.objects;
create policy media_read on storage.objects for select to anon, authenticated using (bucket_id = 'media');
drop policy if exists media_write on storage.objects;
create policy media_write on storage.objects for insert to authenticated with check (bucket_id = 'media' and (storage.foldername(name))[1] = my_company_id()::text);
drop policy if exists media_update on storage.objects;
create policy media_update on storage.objects for update to authenticated using (bucket_id = 'media' and (storage.foldername(name))[1] = my_company_id()::text);
drop policy if exists media_delete on storage.objects;
create policy media_delete on storage.objects for delete to authenticated using (bucket_id = 'media' and (storage.foldername(name))[1] = my_company_id()::text);

-- Melita Transfer karşılama bilgisi
update companies set meeting = jsonb_build_object(
  'texts', jsonb_build_object(
    'en', $t$This is a reservation confirmation message; your booking is complete. After your flight lands and you exit the terminal with your luggage, turn left; you will see signs arranged alphabetically. Look for the sign marked with the letter "I" that also displays "DB 333." A staff member will be stationed there; even if your name is not displayed, please state your name to them. They will verify your reservation and escort you to your vehicle. If you do not see a staff member at the sign, please do not leave the area; the staff member will return after assisting other passengers with their vehicles. You will not have to wait long—rest assured. Thank you, and have a pleasant journey.✈️🙏🏻$t$,
    'de', $t$Dies ist eine Reservierungsbestätigung; Ihre Buchung ist abgeschlossen. Bitte wenden Sie sich nach der Landung und dem Verlassen des Terminals mit Ihrem Gepäck nach links. Sie werden dort alphabetisch angeordnete Schilder sehen; suchen Sie das Schild mit der Aufschrift „DB 333“, das sich direkt über dem Schild mit dem Buchstaben ( I )befindet. Dort erwartet Sie ein Mitarbeiter; bitte nennen Sie Ihren Namen, auch wenn dieser nicht deutlich angezeigt wird. Der Mitarbeiter überprüft Ihre Reservierung und begleitet Sie zu Ihrem Fahrzeug. Sollten Sie den Mitarbeiter nicht direkt am Schild sehen, verlassen Sie bitte nicht den Bereich; er wird sofort dorthin zurückkehren, nachdem er anderen Fahrgästen beim Einsteigen in ihre Fahrzeuge geholfen hat. Sie müssen nicht lange warten, machen Sie sich also keine Sorgen. Sollten Probleme auftreten, können Sie mich jederzeit unter dieser Nummer erreichen. Vielen Dank und eine angenehme Reise.🙏🏻✈️$t$),
  'photo', 'https://transferdefteri.net/media/melita-transfer/karsilama.jpg',
  'video', 'https://transferdefteri.net/media/melita-transfer/karsilama.mp4',
  'poster', 'https://transferdefteri.net/media/melita-transfer/karsilama-video-kapak.jpg')
where slug = 'melita-transfer';

select slug, jsonb_object_keys(meeting) from companies where slug = 'melita-transfer';
