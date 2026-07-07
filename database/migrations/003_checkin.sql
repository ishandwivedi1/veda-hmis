-- ============================================================
-- VEDA HMIS -- Migration 3: Check-in function
--
-- Atomically creates a Visit from a booked Appointment, and marks
-- that appointment as "Checked-in" -- both in one step, so we never
-- end up with a visit but a stale "Booked" appointment status (or
-- vice versa) if something fails partway through.
--
-- HOW TO USE: Supabase dashboard -> SQL Editor -> New query -> paste
-- this entire file -> Run.
-- ============================================================

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

  return new_visit;
end;
$$;

-- ============================================================
-- DONE.
-- ============================================================

