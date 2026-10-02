-- 050: Patients list and Visits list -- one database call per screen load.
--
-- Patients (before): every patient, then a 2nd query sending every patient
-- id back to find their visits (481 ids today; that query is capped at
-- 1,000 rows by the API, so "Last Visit"/"Active Visit" would have started
-- going silently wrong past 1,000 visits). The search text was also pasted
-- into the filter string, so a comma or bracket in it could break search.
-- Now: ui_patients_list(q) -- one call, search passed as a parameter, each
-- patient with last visit time and whether a visit is Open.
--
-- Visits (before): visits, THEN the doctor list, THEN their invoices -- three
-- steps one after another; the Billing badge took whichever invoice happened
-- to come back last when a visit had several.
-- Now: ui_visits_list(tab) -- one call incl. the doctor list; Billing badge
-- summarises all of a visit's invoices (see below).
--
-- Both read-only, SECURITY INVOKER (RLS as before). "Today" = IST day.

create or replace function public.ui_patients_list(p_q text default null)
returns jsonb
language sql
stable
set search_path to 'public'
as $function$
  with q as (select nullif(trim(coalesce(p_q, '')), '') as term)
  select coalesce(jsonb_agg(to_jsonb(p) || jsonb_build_object(
           'lastVisit', (select max(v.created_at) from visits v where v.patient_id = p.id),
           'hasActive', exists (select 1 from visits v where v.patient_id = p.id and v.status = 'Open'))
         order by p.created_at desc), '[]'::jsonb)
  from patients p, q
  where q.term is null
     or p.uhid ilike '%' || q.term || '%'
     or p.mobile ilike '%' || q.term || '%'
     or p.first_name ilike '%' || q.term || '%'
     or p.last_name ilike '%' || q.term || '%';
$function$;

create or replace function public.ui_visits_list(p_tab text default 'today')
returns jsonb
language sql
stable
set search_path to 'public'
as $function$
  with b as (select (ist_date(now())::timestamp at time zone 'Asia/Kolkata') as day_start),
  vs as (
    select v.* from visits v
    where p_tab = 'all' or v.created_at >= (select day_start from b)
    order by v.created_at desc
    limit case when p_tab = 'all' then 100 else null end
  )
  select jsonb_build_object(
    'visits', coalesce((
      select jsonb_agg(to_jsonb(v) || jsonb_build_object(
               'patients', case when pt.id is null then null else jsonb_build_object(
                 'first_name', pt.first_name, 'salutation', pt.salutation, 'last_name', pt.last_name, 'uhid', pt.uhid, 'mobile', pt.mobile) end,
               'profiles', case when d.id is null then null else jsonb_build_object('full_name', d.full_name) end,
               -- Billing badge across ALL the visit's invoices (cancelled ones ignored):
               -- none -> null ('--'), all Paid -> Paid, anything paid so far -> Partial, else Pending
               'billingStatus', (select case
                                   when count(*) = 0 then null
                                   when bool_and(i.status = 'Paid') then 'Paid'
                                   when bool_or(i.status in ('Paid', 'Partial') or coalesce(i.paid, 0) > 0) then 'Partial'
                                   else 'Pending' end
                                 from invoices i where i.visit_id = v.id and i.status <> 'Cancelled'))
             order by v.created_at desc)
      from vs v
      left join patients pt on pt.id = v.patient_id
      left join profiles d on d.id = v.doctor_id), '[]'::jsonb),
    'doctors', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'full_name', full_name) order by full_name)
                         from profiles where designation = 'Doctor' and status = 'Active'), '[]'::jsonb)
  );
$function$;
