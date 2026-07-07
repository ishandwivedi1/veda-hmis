-- ============================================================
-- VEDA HMIS -- Migration 2: Patient Registration function
--
-- Adds a safe way to generate the next UHID (e.g. VEH-00001) and
-- register a patient in a single atomic step -- important once more
-- than one receptionist might register patients at the same time.
--
-- HOW TO USE: Supabase dashboard -> SQL Editor -> New query -> paste
-- this entire file -> Run.
-- ============================================================

create sequence if not exists patient_uhid_seq start 1;

create or replace function register_patient(
  p_first_name text,
  p_last_name text,
  p_age int,
  p_gender text,
  p_mobile text,
  p_address text,
  p_blood_group text
)
returns patients
language plpgsql
as $$
declare
  new_uhid text;
  new_patient patients;
begin
  new_uhid := 'VEH-' || lpad(nextval('patient_uhid_seq')::text, 5, '0');

  insert into patients (uhid, first_name, last_name, age, gender, mobile, address, blood_group)
  values (new_uhid, p_first_name, p_last_name, p_age, p_gender, p_mobile, p_address, p_blood_group)
  returning * into new_patient;

  return new_patient;
end;
$$;

-- ============================================================
-- DONE. Test it by running:
--   select * from register_patient('Test','Patient',30,'M','9999999999','Haridwar','O+');
-- You should get back a new row with a real UHID like VEH-00001.
-- ============================================================

