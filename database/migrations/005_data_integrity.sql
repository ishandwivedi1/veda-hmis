-- ============================================================
-- VEDA HMIS -- Migration 5: Data integrity rules
--
-- 1. Mobile numbers must be exactly 10 digits -- enforced at the
--    database level, not just in the UI, so it can never be bypassed.
-- 2. A patient can only have one visit per calendar day -- prevents
--    accidental double-visits (e.g. double-clicking "Create Visit",
--    or checking in an appointment AND creating a separate walk-in
--    for the same person on the same day).
--
-- HOW TO USE: Supabase dashboard -> SQL Editor -> New query -> paste
-- this entire file -> Run.
-- ============================================================

-- 1. Mobile number format, enforced permanently on the patients table.
do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'mobile_ten_digits'
  ) then
    alter table patients add constraint mobile_ten_digits check (mobile ~ '^[0-9]{10}$');
  end if;
end $$;

-- 2. One visit per patient per calendar day -- a hard backstop at the
--    database level (belt-and-suspenders alongside the friendlier
--    checks added to the functions below).
--
-- Postgres won't allow timestamptz::date directly in an index (it
-- depends on session timezone settings, so isn't technically safe to
-- use in an index). This small helper pins the timezone explicitly to
-- India, making it safe to index -- and we use the same helper
-- everywhere "what day is this" matters, so the boundary is consistent.
create or replace function ist_date(ts timestamptz)
returns date
language sql
immutable
as $$
  select (ts at time zone 'Asia/Kolkata')::date;
$$;

create unique index if not exists one_visit_per_patient_per_day
  on visits (patient_id, ist_date(created_at));

-- Updated: check-in now also checks for an existing visit today first,
-- with a clear message, instead of relying on a raw database error.
create or replace function check_in_appointment(p_appointment_id uuid)
returns visits
language plpgsql
as $$
declare
  appt appointments;
  new_visit visits;
  existing_visit_count int;
begin
  select * into appt from appointments where id = p_appointment_id;

  if appt is null then
    raise exception 'Appointment not found';
  end if;

  if appt.patient_id is null then
    raise exception 'This appointment has no registered patient yet -- register the patient first, then check in.';
  end if;

  select count(*) into existing_visit_count
  from visits
  where patient_id = appt.patient_id and ist_date(created_at) = ist_date(now());

  if existing_visit_count > 0 then
    raise exception 'This patient already has a visit today.';
  end if;

  insert into visits (patient_id, appointment_id, doctor_id, visit_type, status)
  values (appt.patient_id, appt.id, appt.doctor_id, appt.visit_type, 'Open')
  returning * into new_visit;

  update appointments set status = 'Checked-in' where id = p_appointment_id;

  perform issue_queue_token(new_visit.id, 'Optometry');

  return new_visit;
end;
$$;

-- Updated: walk-in visit creation now also checks for an existing visit
-- today first, with a clear message.
create or replace function create_walk_in_visit(p_patient_id uuid, p_doctor_id uuid, p_visit_type text)
returns visits
language plpgsql
as $$
declare
  new_visit visits;
  existing_visit_count int;
begin
  select count(*) into existing_visit_count
  from visits
  where patient_id = p_patient_id and ist_date(created_at) = ist_date(now());

  if existing_visit_count > 0 then
    raise exception 'This patient already has a visit today.';
  end if;

  insert into visits (patient_id, doctor_id, visit_type, status)
  values (p_patient_id, p_doctor_id, p_visit_type, 'Open')
  returning * into new_visit;

  perform issue_queue_token(new_visit.id, 'Optometry');

  return new_visit;
end;
$$;

-- Also updates token issuance to use the same consistent day boundary
-- as the checks above (it previously used created_at::date directly,
-- which is timezone-session-dependent -- fine in a plain WHERE clause,
-- but inconsistent with the boundary now used everywhere else).
create or replace function issue_queue_token(p_visit_id uuid, p_department text)
returns queue_entries
language plpgsql
as $$
declare
  today_count int;
  new_token text;
  prefix text;
  new_entry queue_entries;
begin
  prefix := case p_department when 'Optometry' then 'O' when 'Doctor' then 'D' else 'X' end;

  select count(*) into today_count
  from queue_entries
  where department = p_department
    and ist_date(issued_at) = ist_date(now());

  new_token := prefix || '-' || lpad((today_count + 1)::text, 2, '0');

  insert into queue_entries (visit_id, department, token, status)
  values (p_visit_id, p_department, new_token, 'Waiting')
  returning * into new_entry;

  return new_entry;
end;
$$;

-- ============================================================
-- DONE.
-- ============================================================

