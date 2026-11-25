-- U-ETDS: onaylanınca otomatik sıraya al, iptal/silinince iptal bildirimi için sıraya al

create or replace function uetds_auto() returns trigger language plpgsql set search_path = public as $$
-- security invoker: current_user gerçek çağıranı gösterir
declare a_enabled boolean; a_auto boolean; privileged boolean := current_user in ('postgres','service_role','supabase_admin');
begin
  -- firma uygulaması "gönderildi/gönderiliyor" durumunu kendisi yazamaz
  if not privileged and tg_op = 'UPDATE' and new.uetds_status is distinct from old.uetds_status
     and new.uetds_status not in ('', 'queued', 'cancel_queued') then
    new.uetds_status := old.uetds_status; new.uetds_ref := old.uetds_ref; new.uetds_msg := old.uetds_msg;
  end if;
  if not privileged and tg_op = 'UPDATE' then new.uetds_ref := old.uetds_ref; end if;
  if not privileged and tg_op = 'INSERT' then new.uetds_status := ''; new.uetds_ref := null; new.uetds_msg := null; end if;

  select enabled, auto_send into a_enabled, a_auto from uetds_accounts where company_id = new.company_id;
  if not coalesce(a_enabled,false) then return new; end if;

  -- iptal edildi ya da silindi: bildirilmiş seferi iptal et
  if tg_op = 'UPDATE' and old.uetds_status = 'sent'
     and ((new.status = 'cancelled' and old.status is distinct from 'cancelled') or (new.deleted_at is not null and old.deleted_at is null)) then
    new.uetds_status := 'cancel_queued';
    return new;
  end if;

  -- onaylandı: otomatik gönderim açıksa sıraya al
  if coalesce(a_auto,false) and new.status = 'confirmed' and new.deleted_at is null and coalesce(new.uetds_status,'') = ''
     and (tg_op = 'INSERT' or old.status is distinct from 'confirmed') then
    new.uetds_status := 'queued'; new.uetds_msg := null;
  end if;
  return new;
end $$;

drop trigger if exists bookings_uetds_auto on bookings;
create trigger bookings_uetds_auto before insert or update on bookings for each row execute function uetds_auto();

-- gönderici program: gönderilecek ve iptal edilecek işleri al
create or replace function uetds_claim(n int default 10)
returns setof bookings language plpgsql security definer set search_path = public as $$
begin
  return query
  update bookings b set uetds_status = case when b.uetds_status = 'queued' then 'sending' else 'cancelling' end, uetds_at = now()
  where b.id in (select id from bookings
                 where (uetds_status = 'queued' and deleted_at is null) or uetds_status = 'cancel_queued'
                 order by updated_at limit n for update skip locked)
  returning b.*;
end $$;
revoke all on function uetds_claim(int) from public, anon, authenticated;

-- takılı kalanları geri al (program yarıda kapanırsa)
create or replace function uetds_unstick() returns int language sql security definer set search_path = public as $$
  with u as (update bookings set uetds_status = case when uetds_status = 'sending' then 'queued' else 'cancel_queued' end
             where uetds_status in ('sending','cancelling') and uetds_at < now() - interval '10 minutes' returning 1)
  select count(*)::int from u
$$;
revoke all on function uetds_unstick() from public, anon, authenticated;

select 'ok' as durum;
