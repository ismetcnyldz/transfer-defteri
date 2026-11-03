alter table bookings add column if not exists booster boolean not null default false;
create or replace function submit_booking(p_slug text, p jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare cid uuid; bid uuid;
begin
  select c.id into cid from companies c where c.slug = p_slug;
  if cid is null then raise exception 'company not found'; end if;
  if coalesce(p->>'first_name','') = '' or coalesce(p->>'date','') = '' then raise exception 'missing fields'; end if;
  insert into bookings(company_id, date, time, flight, return_date, return_time, return_flight,
    first_name, last_name, phone, email, language, adults, children, child_ages, infants, baby_seat, booster, luggage,
    hotel, area, from_place, to_place, customer_note, source, status)
  values (cid, (p->>'date')::date, nullif(p->>'time','')::time, p->>'flight',
    nullif(p->>'return_date','')::date, nullif(p->>'return_time','')::time, p->>'return_flight',
    left(p->>'first_name',80), left(p->>'last_name',80), left(p->>'phone',40), left(p->>'email',120), left(p->>'language',5),
    least(coalesce((p->>'adults')::int,0),30), least(coalesce((p->>'children')::int,0),20),
    (select coalesce(array_agg(least(greatest(x::int,0),17)), '{}') from jsonb_array_elements_text(coalesce(p->'child_ages','[]'::jsonb)) x),
    least(coalesce((p->>'infants')::int,0),10), coalesce((p->>'baby_seat')::boolean,false), coalesce((p->>'booster')::boolean,false), nullif(p->>'luggage','')::int,
    left(p->>'hotel',120), left(p->>'area',80), left(p->>'from_place',120), left(p->>'to_place',120), left(p->>'customer_note',1000),
    'link', 'pending')
  returning id into bid;
  return bid;
end $$;
select 'ok';