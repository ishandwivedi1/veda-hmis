-- 049: Front Office Dashboard -- one database call per screen load.
--
-- Before (audit): the page could not show until 8 database queries had
-- run, PLUS a 9th after them (invoices of today's visits, which waited on
-- the visits query) -- incl. every Pending/Partial invoice ever, sent back
-- row by row just to add them up, and a walk-in count the screen never
-- shows. Check In then made a 2nd request to reload the page.
--
-- Now ui_front_office_dashboard() returns everything the screen shows in
-- ONE call: stat counts and the outstanding total are added up in the
-- database; each visit carries its billing summary (count of non-cancelled
-- invoices, amount due, all-paid flag) -- same rules as before. "Today" is
-- the IST day. SECURITY INVOKER (RLS as before); read-only.

create or replace function public.ui_front_office_dashboard()
returns jsonb
language sql
stable
set search_path to 'public'
as $function$
  with b as (
    select (ist_date(now())::timestamp at time zone 'Asia/Kolkata') as day_start, ist_date(now()) as today
  ),
  pend as (
    select count(*) as n, coalesce(sum(net - paid), 0) as outstanding
    from invoices where status in ('Pending', 'Partial')
  )
  select jsonb_build_object(
    'dayOpen', exists (select 1 from day_openings where opening_date = (select today from b)),
    'registrationsToday', (select count(*) from patients where created_at >= (select day_start from b)),
    'pendingInvoiceCount', (select n from pend),
    'outstandingTotal', (select outstanding from pend),
    'surgicalPendingWorkup', (select count(*) from surgical_cases where status = 'Pending Workup'),

    -- everyone still in a queue today, oldest arrival first
    'queueEntries', coalesce((
      select jsonb_agg(to_jsonb(q) || jsonb_build_object('visits', jsonb_build_object('patients',
               (select jsonb_build_object('first_name', pt.first_name, 'salutation', pt.salutation, 'last_name', pt.last_name, 'age', pt.age)
                from visits v join patients pt on pt.id = v.patient_id where v.id = q.visit_id)))
             order by q.issued_at)
      from queue_entries q
      where q.issued_at >= (select day_start from b) and q.status <> 'Done' and q.status <> 'Cancelled'), '[]'::jsonb),

    -- today's visits, oldest first, with doctor and billing summary
    'todaysVisits', coalesce((
      select jsonb_agg(to_jsonb(v) || jsonb_build_object(
               'patients', case when pt.id is null then null else jsonb_build_object(
                 'id', pt.id, 'first_name', pt.first_name, 'salutation', pt.salutation, 'last_name', pt.last_name, 'uhid', pt.uhid, 'age', pt.age) end,
               'profiles', case when d.id is null then null else jsonb_build_object('full_name', d.full_name) end,
               'billing', (select jsonb_build_object(
                             'count', count(*),
                             'outstanding', coalesce(sum(greatest(0, i.net - i.paid)), 0),
                             'allPaid', count(*) > 0 and bool_and(i.status = 'Paid'))
                           from invoices i where i.visit_id = v.id and i.status <> 'Cancelled'))
             order by v.created_at)
      from visits v
      left join patients pt on pt.id = v.patient_id
      left join profiles d on d.id = v.doctor_id
      where v.created_at >= (select day_start from b)), '[]'::jsonb),

    -- today's appointments by time
    'todaysAppointments', coalesce((
      select jsonb_agg(to_jsonb(a) || jsonb_build_object(
               'patients', case when pt.id is null then null else jsonb_build_object(
                 'first_name', pt.first_name, 'salutation', pt.salutation, 'last_name', pt.last_name, 'uhid', pt.uhid, 'mobile', pt.mobile, 'age', pt.age) end,
               'profiles', case when d.id is null then null else jsonb_build_object('full_name', d.full_name) end)
             order by a.appointment_time)
      from appointments a
      left join patients pt on pt.id = a.patient_id
      left join profiles d on d.id = a.doctor_id
      where a.appointment_date = (select today from b)), '[]'::jsonb)
  );
$function$;
