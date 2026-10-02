-- 047: Doctor Dashboard (OPD) -- one request per screen load and per click.
--
-- Before: opening the dashboard made 3 browser requests (7 DB queries,
-- incl. 200 history rows nobody had asked for yet); every 15s poll made 2;
-- each button (Call Next / Call / Mark Ready / Call Directly) was one
-- request running 3-7 DB steps one after another, followed by 2 more
-- requests to refresh; opening a Post-op Review made a lookup request
-- (2 serial queries) before anything showed.
--
-- Now:
--   ui_doctor_dashboard()           read-only, everything the screen shows,
--                                   ONE DB call (incl. post-op episode id
--                                   for Post-operative Review entries).
--   doctor_queue_action(action,id)  the four queue buttons: does the change,
--                                   writes the journey event, and returns
--                                   the refreshed dashboard -- ONE request,
--                                   ONE DB call, no follow-up refresh.
-- Both SECURITY INVOKER (RLS applies exactly as before). The queue page's
-- own server actions (app/(main)/queue/actions.js) are untouched.

-- Token "D-12" -> 12 (same as tokenNum() in queue/actions.js; tolerant of
-- odd formats instead of erroring).
create or replace function public.queue_token_num(p_token text)
returns integer
language sql
immutable
set search_path to 'public'
as $function$
  select nullif(regexp_replace(split_part(coalesce(p_token, ''), '-', 2), '\D', '', 'g'), '')::integer;
$function$;

-- The same post-op lookup as getOpenPostOpEpisodeForPatient()
-- (ot-postop/actions.js): latest discharged, not-yet-closed recovery
-- episode for this patient.
create or replace function public.ui_open_postop_episode(p_patient_id uuid)
returns uuid
language sql
stable
set search_path to 'public'
as $function$
  select re.id
  from recovery_episodes re
  join surgical_cases sc on sc.id = re.surgical_case_id
  where sc.patient_id = p_patient_id
    and re.closure_status is null
    and re.discharge_date is not null
  order by re.created_at desc
  limit 1;
$function$;

create or replace function public.ui_doctor_dashboard()
returns jsonb
language sql
stable
set search_path to 'public'
as $function$
  with b as (
    select (ist_date(now())::timestamp at time zone 'Asia/Kolkata') as day_start, ist_date(now()) as today
  ),
  q as (
    select q.*,
      to_jsonb(q) || jsonb_build_object(
        'visits', case when v.id is null then null else jsonb_build_object(
          'id', v.id, 'visit_type', v.visit_type,
          'patients', case when pt.id is null then null else jsonb_build_object(
            'id', pt.id, 'first_name', pt.first_name, 'salutation', pt.salutation, 'last_name', pt.last_name,
            'uhid', pt.uhid, 'age', pt.age, 'gender', pt.gender) end) end,
        'postop_episode_id', case when v.visit_type = 'Post-operative Review' and pt.id is not null
                                  then ui_open_postop_episode(pt.id) end
      ) as j
    from queue_entries q
    left join visits v on v.id = q.visit_id
    left join patients pt on pt.id = v.patient_id
    where q.issued_at >= (select day_start from b)
      and q.department in ('Doctor', 'Optometry')
  )
  select jsonb_build_object(
    'active', coalesce((select jsonb_agg(j order by issued_at) from q
                        where department = 'Doctor' and status in ('Waiting', 'Ready for Review', 'In Consultation')), '[]'::jsonb),
    -- compound statuses ("Awaiting Investigation & Biometry") -- same ilike match as before
    'intermediate', coalesce((select jsonb_agg(j order by sent_out_at) from q
                        where department = 'Doctor' and (status ilike '%Dilation%' or status ilike '%Investigation%' or status ilike '%Biometry%')), '[]'::jsonb),
    'completed', coalesce((select jsonb_agg(j order by completed_at desc) from q
                        where department = 'Doctor' and status = 'Done'), '[]'::jsonb),
    'optometryWaiting', coalesce((select jsonb_agg(j order by issued_at) from q
                        where department = 'Optometry' and status in ('Waiting', 'Calling')), '[]'::jsonb),
    'visitTypeCounts', coalesce((select jsonb_object_agg(coalesce(t.visit_type, 'null'), t.n)
                        from (select visit_type, count(*) n from visits where created_at >= (select day_start from b) group by visit_type) t), '{}'::jsonb),
    'totalVisitsToday', (select count(*) from visits where created_at >= (select day_start from b)),
    'proceduresDueToday', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', pp.id, 'name', pp.name, 'eye', pp.eye, 'notes', pp.notes, 'scheduled_date', pp.scheduled_date,
               'encounters', jsonb_build_object('visit_id', e.visit_id, 'visits', jsonb_build_object('patients', jsonb_build_object(
                 'id', pt.id, 'first_name', pt.first_name, 'salutation', pt.salutation, 'last_name', pt.last_name, 'uhid', pt.uhid, 'mobile', pt.mobile))))
             order by pp.created_at)
      from plan_procedures pp
      join encounters e on e.id = pp.encounter_id
      join visits v on v.id = e.visit_id
      join patients pt on pt.id = v.patient_id
      where pp.status = 'Planned' and pp.scheduled_date = (select today from b)), '[]'::jsonb)
  );
$function$;

-- The four Doctor Dashboard queue buttons in one DB call each. Same
-- status changes and journey events as doctorCallNext / doctorCallSpecific
-- / doctorMarkReady / doctorCallDirect in queue/actions.js.
-- Returns { error } on a business error (nothing is changed), otherwise
-- { dashboard: ui_doctor_dashboard() } so the screen needs no refresh call.
create or replace function public.doctor_queue_action(p_action text, p_id uuid default null)
returns jsonb
language plpgsql
volatile
set search_path to 'public'
as $function$
declare
  v_id uuid := p_id;
  v_visit uuid;
  v_event text;
begin
  if p_action = 'call_next' then
    -- lowest token among today's waiting / ready patients (the ones on screen)
    select id into v_id from queue_entries
    where department = 'Doctor' and status in ('Waiting', 'Ready for Review')
      and issued_at >= (ist_date(now())::timestamp at time zone 'Asia/Kolkata')
    order by queue_token_num(token) nulls last, issued_at
    limit 1
    for update skip locked;
    if v_id is null then return jsonb_build_object('error', 'No one available to call.'); end if;
    p_action := 'call';

  elsif p_action = 'call_direct' then
    -- pull straight out of Optometry: same handoff Optometry itself uses
    select visit_id into v_visit from queue_entries where id = p_id and department = 'Optometry';
    if not found then return jsonb_build_object('error', 'Queue entry not found in Optometry.'); end if;
    perform optometry_complete(p_id);
    begin
      insert into visit_journey_events (visit_id, event_type, created_by) values (v_visit, 'optometry_completed', auth.uid());
    exception when others then null; -- journey log must never block the click (same as logJourneyEvent)
    end;
    select id into v_id from queue_entries
    where visit_id = v_visit and department = 'Doctor'
    order by issued_at desc limit 1;
    if v_id is null then return jsonb_build_object('error', 'Could not route patient to Doctor queue.'); end if;
    p_action := 'call';
  end if;

  if p_action = 'call' then
    update queue_entries set status = 'In Consultation', called_at = now() where id = v_id returning visit_id into v_visit;
    v_event := 'doctor_called';
  elsif p_action = 'mark_ready' then
    update queue_entries set status = 'Ready for Review' where id = v_id returning visit_id into v_visit;
    v_event := 'ready_for_doctor_review';
  else
    return jsonb_build_object('error', 'Unknown action.');
  end if;

  if not found then return jsonb_build_object('error', 'Queue entry not found.'); end if;

  if v_visit is not null then
    begin
      insert into visit_journey_events (visit_id, event_type, created_by) values (v_visit, v_event, auth.uid());
    exception when others then null;
    end;
  end if;

  return jsonb_build_object('dashboard', ui_doctor_dashboard());
end;
$function$;
