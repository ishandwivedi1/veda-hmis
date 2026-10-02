-- 048: Optometry -- one request per screen load and per click.
--
-- Before (audit):
--   Dashboard load / 15s refresh: 1 request, 2 DB stages one after the
--     other (queues, then the doctor-status lookup).
--   Returning from the Workspace: the dashboard was fetched TWICE.
--   Call Next / Call: 1 request of 3-4 serial DB steps (+ a login check
--     against the auth server), then a 2nd request to refresh.
--   History tab: 1 request, 4 DB stages one after another (assessments,
--     IOP readings, override check, queue entries), every column of every
--     assessment.
--   Opening the Workspace: 1 request of ~8 serial steps (2 auth-server
--     login checks) + 3 more requests (IOP methods, all services, history
--     options). Save Draft / Save Changes: the save, then a 2nd request
--     to reload.
--
-- Now:
--   ui_optometry_dashboard()             read-only, ONE DB call.
--   optometry_queue_action(action, id)   Call Next / Call: the change +
--                                        journey event + refreshed
--                                        dashboard in ONE DB call.
--   ui_optometry_history(status)         read-only, ONE DB call, only the
--                                        columns the History table shows.
--   optometry_open_workspace(entry_id)   everything the Workspace needs,
--                                        incl. IOP methods, investigation
--                                        list and history chip options, in
--                                        ONE DB call (creates the draft
--                                        assessment / encounter on first
--                                        open, exactly as before).
-- All SECURITY INVOKER: RLS applies as before (audit log stays admin-only,
-- doctor-override lines visible to all). queue/actions.js untouched.

create or replace function public.ui_optometry_dashboard()
returns jsonb
language sql
stable
set search_path to 'public'
as $function$
  with b as (select (ist_date(now())::timestamp at time zone 'Asia/Kolkata') as day_start),
  q as (
    select q.*,
      to_jsonb(q) || jsonb_build_object(
        'visits', case when v.id is null then null else jsonb_build_object(
          'id', v.id,
          'patients', case when pt.id is null then null else jsonb_build_object(
            'first_name', pt.first_name, 'salutation', pt.salutation, 'last_name', pt.last_name,
            'uhid', pt.uhid, 'age', pt.age, 'gender', pt.gender) end) end
      ) as j
    from queue_entries q
    left join visits v on v.id = q.visit_id
    left join patients pt on pt.id = v.patient_id
    where q.department = 'Optometry' and q.issued_at >= (select day_start from b)
  )
  select jsonb_build_object(
    'active', coalesce((select jsonb_agg(j order by issued_at) from q where status in ('Waiting', 'Calling')), '[]'::jsonb),
    -- completed readings stay editable until the doctor opens (or finishes) the consultation
    'completed', coalesce((
      select jsonb_agg(q.j || jsonb_build_object('doctorStatus', d.status,
                                                 'locked', coalesce(d.status in ('In Consultation', 'Done'), false))
                       order by q.completed_at desc)
      from q
      left join lateral (select status from queue_entries de
                         where de.visit_id = q.visit_id and de.department = 'Doctor'
                         order by de.issued_at desc limit 1) d on true
      where q.status = 'Done'), '[]'::jsonb)
  );
$function$;

-- Call Next / Call -- same as optometryCallNext / optometryCallSpecific in
-- queue/actions.js: only one patient "Calling" at a time.
create or replace function public.optometry_queue_action(p_action text, p_id uuid default null)
returns jsonb
language plpgsql
volatile
set search_path to 'public'
as $function$
declare
  v_id uuid := p_id;
  v_visit uuid;
begin
  if p_action = 'call_next' then
    -- lowest token among today's waiting patients (the ones on screen)
    select id into v_id from queue_entries
    where department = 'Optometry' and status = 'Waiting'
      and issued_at >= (ist_date(now())::timestamp at time zone 'Asia/Kolkata')
    order by queue_token_num(token) nulls last, issued_at
    limit 1
    for update skip locked;
    if v_id is null then return jsonb_build_object('error', 'No one waiting in Optometry.'); end if;
  elsif p_action <> 'call' then
    return jsonb_build_object('error', 'Unknown action.');
  end if;

  update queue_entries set status = 'Waiting'
  where department = 'Optometry' and status = 'Calling' and id <> v_id;

  update queue_entries set status = 'Calling', called_at = now()
  where id = v_id returning visit_id into v_visit;
  if not found then return jsonb_build_object('error', 'Queue entry not found.'); end if;

  if v_visit is not null then
    begin
      insert into visit_journey_events (visit_id, event_type, created_by) values (v_visit, 'optometry_called', auth.uid());
    exception when others then null; -- journey log never blocks the click (same as logJourneyEvent)
    end;
  end if;

  return jsonb_build_object('dashboard', ui_optometry_dashboard());
end;
$function$;

-- History tab: the columns the table shows, latest IOP per eye, the
-- doctor-correction flag and the Optometry queue entry to reopen.
create or replace function public.ui_optometry_history(p_status text default null)
returns jsonb
language sql
stable
set search_path to 'public'
as $function$
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', a.id, 'visit_id', a.visit_id, 'status', a.status,
      'created_at', a.created_at, 'updated_at', a.updated_at, 'completed_at', a.completed_at,
      're_dist_unaided', a.re_dist_unaided, 'le_dist_unaided', a.le_dist_unaided,
      'visits', case when v.id is null then null else jsonb_build_object('visit_number', v.visit_number,
                  'patients', case when pt.id is null then null else jsonb_build_object(
                    'first_name', pt.first_name, 'salutation', pt.salutation, 'last_name', pt.last_name, 'uhid', pt.uhid) end) end,
      'recorded_by_profile', case when rp.id is null then null else jsonb_build_object('full_name', rp.full_name) end,
      'completed_by_profile', case when cp.id is null then null else jsonb_build_object('full_name', cp.full_name) end,
      'iopRe', (select r.value from optometry_iop_readings r where r.assessment_id = a.id and r.eye = 'RE' order by r.recorded_at desc limit 1),
      'iopLe', (select r.value from optometry_iop_readings r where r.assessment_id = a.id and r.eye = 'LE' order by r.recorded_at desc limit 1),
      -- staff RLS on the audit log exposes exactly the 'Doctor override' lines
      'hasDoctorCorrection', exists (select 1 from optometry_audit_log l where l.assessment_id = a.id and l.message like 'Doctor override%'),
      'queueEntryId', (select qe.id from queue_entries qe where qe.visit_id = a.visit_id and qe.department = 'Optometry' order by qe.issued_at desc limit 1)
    ) order by a.created_at desc), '[]'::jsonb)
  from optometry_assessments a
  left join visits v on v.id = a.visit_id
  left join patients pt on pt.id = v.patient_id
  left join profiles rp on rp.id = a.recorded_by
  left join profiles cp on cp.id = a.completed_by
  where p_status is null or a.status = p_status;
$function$;

-- Everything the Optometry Workspace needs in one call. Same rules as
-- getAssessmentWorkspaceData(): creates the Draft assessment and the
-- encounter on first open (with the same audit lines), audit log only
-- for Administrators, doctor-override lines for everyone, lock once the
-- doctor has taken over (or, viewed from the doctor's own entry, once Done).
create or replace function public.optometry_open_workspace(p_queue_entry_id uuid)
returns jsonb
language plpgsql
volatile
set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_entry queue_entries;
  v_visit visits;
  v_assessment optometry_assessments;
  v_encounter encounters;
  v_is_admin boolean;
  v_locked boolean := false;
  v_doctor_status text;
begin
  select * into v_entry from queue_entries where id = p_queue_entry_id;
  if not found then return jsonb_build_object('error', 'Queue entry not found.'); end if;
  select * into v_visit from visits where id = v_entry.visit_id;

  select * into v_assessment from optometry_assessments where visit_id = v_entry.visit_id;
  if not found then
    insert into optometry_assessments (visit_id, recorded_by) values (v_entry.visit_id, v_uid)
    on conflict (visit_id) do nothing
    returning * into v_assessment;
    if v_assessment.id is not null then
      insert into optometry_audit_log (assessment_id, message, created_by) values (v_assessment.id, 'Assessment started', v_uid);
    else
      -- someone else opened it at the same moment
      select * into v_assessment from optometry_assessments where visit_id = v_entry.visit_id;
    end if;
  end if;

  select * into v_encounter from encounters where visit_id = v_entry.visit_id order by started_at desc limit 1;
  if not found then
    insert into encounters (visit_id, doctor_id) values (v_entry.visit_id, v_visit.doctor_id) returning * into v_encounter;
    insert into encounter_audit_log (encounter_id, message, created_by) values (v_encounter.id, 'Encounter started (from Optometry)', v_uid);
  end if;

  v_is_admin := coalesce((select designation = 'Administrator' from profiles where id = v_uid), false);

  if v_assessment.status = 'Completed' then
    select status into v_doctor_status from queue_entries
    where visit_id = v_entry.visit_id and department = 'Doctor'
    order by issued_at desc limit 1;
    v_locked := coalesce(v_doctor_status = 'Done'
                         or (v_entry.department <> 'Doctor' and v_doctor_status = 'In Consultation'), false);
  end if;

  return jsonb_build_object(
    'entry', to_jsonb(v_entry) || jsonb_build_object('visits', case when v_visit.id is null then null else jsonb_build_object(
               'id', v_visit.id, 'doctor_id', v_visit.doctor_id,
               'patients', (select jsonb_build_object('first_name', pt.first_name, 'salutation', pt.salutation, 'last_name', pt.last_name,
                                                      'uhid', pt.uhid, 'age', pt.age, 'gender', pt.gender)
                            from patients pt where pt.id = v_visit.patient_id)) end),
    'assessment', to_jsonb(v_assessment),
    'encounter', to_jsonb(v_encounter),
    'iopReadings', coalesce((select jsonb_agg(to_jsonb(r) order by r.recorded_at) from optometry_iop_readings r where r.assessment_id = v_assessment.id), '[]'::jsonb),
    'auditLog', case when v_is_admin then coalesce((select jsonb_agg(to_jsonb(l) order by l.created_at desc)
                                                    from optometry_audit_log l where l.assessment_id = v_assessment.id), '[]'::jsonb)
                     else '[]'::jsonb end,
    'doctorOverrides', coalesce((select jsonb_agg(to_jsonb(l) order by l.created_at desc) from optometry_audit_log l
                                 where l.assessment_id = v_assessment.id and l.message ilike 'Doctor override%'), '[]'::jsonb),
    'locked', v_locked,
    'isAdmin', v_is_admin,
    -- pick-lists the Workspace used to fetch separately
    'iopMethods', coalesce((select jsonb_agg(to_jsonb(m) order by m.name) from master_iop_methods m where m.status = 'Active'), '[]'::jsonb),
    'investigationOptions', coalesce((select jsonb_agg(to_jsonb(s) order by s.name) from master_services s
                                      where s.status = 'Active' and s.dept = 'Investigation'), '[]'::jsonb),
    'historyOptions', (
      select jsonb_build_object(
        'chief_complaint', coalesce(jsonb_agg(h.name order by h.name) filter (where h.category = 'chief_complaint'), '[]'::jsonb),
        'ocular_history',  coalesce(jsonb_agg(h.name order by h.name) filter (where h.category = 'ocular_history'), '[]'::jsonb),
        'medical_history', coalesce(jsonb_agg(h.name order by h.name) filter (where h.category = 'medical_history'), '[]'::jsonb),
        'family_history',  coalesce(jsonb_agg(h.name order by h.name) filter (where h.category = 'family_history'), '[]'::jsonb),
        'drug_history',    coalesce(jsonb_agg(h.name order by h.name) filter (where h.category = 'drug_history'), '[]'::jsonb),
        'allergy',         coalesce(jsonb_agg(h.name order by h.name) filter (where h.category = 'allergy'), '[]'::jsonb))
      from master_history_options h where h.status = 'Active')
  );
end;
$function$;
