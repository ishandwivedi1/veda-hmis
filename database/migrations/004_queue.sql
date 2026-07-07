-- ============================================================
-- VEDA HMIS -- Migration 4: Queue Management
--
-- Adds real token issuance (Optometry + Doctor), and wires it into
-- visit creation so a queue token is issued automatically the moment
-- a visit opens -- no separate manual step needed.
--
-- Tokens reset each day per department (O-01, O-02... / D-01, D-02...).
--
-- HOW TO USE: Supabase dashboard -> SQL Editor -> New query -> paste
-- this entire file -> Run.
-- ============================================================

-- Issues the next token for a department, today, and creates the queue entry.
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
    and issued_at::date = current_date;

  new_token := prefix || '-' || lpad((today_count + 1)::text, 2, '0');

  insert into queue_entries (visit_id, department, token, status)
  values (p_visit_id, p_department, new_token, 'Waiting')
  returning * into new_entry;

  return new_entry;
end;
$$;

-- Updated: check-in now also issues an Optometry token automatically.
create or replace function check_in_appointment(p_appointment_id uuid)
returns visits
language plpgsql
as $$
declare
  appt appointments;
  new_visit visits;
begin
  select * into appt from appointments where id = p_appointment_id;

  if appt is null then
    raise exception 'Appointment not found';
  end if;

  if appt.patient_id is null then
    raise exception 'This appointment has no registered patient yet -- register the patient first, then check in.';
  end if;

  insert into visits (patient_id, appointment_id, doctor_id, visit_type, status)
  values (appt.patient_id, appt.id, appt.doctor_id, appt.visit_type, 'Open')
  returning * into new_visit;

  update appointments set status = 'Checked-in' where id = p_appointment_id;

  perform issue_queue_token(new_visit.id, 'Optometry');

  return new_visit;
end;
$$;

-- New: walk-in visit creation now also issues an Optometry token atomically.
create or replace function create_walk_in_visit(p_patient_id uuid, p_doctor_id uuid, p_visit_type text)
returns visits
language plpgsql
as $$
declare
  new_visit visits;
begin
  insert into visits (patient_id, doctor_id, visit_type, status)
  values (p_patient_id, p_doctor_id, p_visit_type, 'Open')
  returning * into new_visit;

  perform issue_queue_token(new_visit.id, 'Optometry');

  return new_visit;
end;
$$;

-- Completing an Optometry queue entry automatically issues the Doctor token
-- for the same visit -- this is the one place a "single source of truth"
-- rule from the prototype really matters: nobody manually decides when the
-- doctor's queue starts, completing Optometry is what triggers it.
create or replace function optometry_complete(p_queue_entry_id uuid)
returns queue_entries
language plpgsql
as $$
declare
  entry queue_entries;
begin
  update queue_entries set status = 'Done', completed_at = now()
  where id = p_queue_entry_id and department = 'Optometry'
  returning * into entry;

  if entry is null then
    raise exception 'Queue entry not found';
  end if;

  perform issue_queue_token(entry.visit_id, 'Doctor');

  return entry;
end;
$$;

-- ============================================================
-- DONE.
-- ============================================================

