mkdir -p database/migrations database/dev-utils

cat > 'database/README.md' << 'SQLEOF'
# Database

This folder is the permanent record of every change made to the Supabase
database, in the order it was applied. The database itself lives in
Supabase's cloud (not in this repo) -- these files are the source of
truth for *how it got that way*, so it can be reproduced from scratch
if ever needed (a new environment, a second hospital site, disaster
recovery, etc.).

## How to apply these to a brand new Supabase project

1. Create a new Supabase project
2. Go to SQL Editor -> New query
3. Run each file in `migrations/`, **in order by number**, one at a time
4. Do not run anything in `dev-utils/` on a real/production database --
   see below.

## migrations/

| File | What it does |
|---|---|
| 001_initial_schema.sql | Creates all core tables: profiles, patients, appointments, visits, queue_entries, optometry_findings, encounters, diagnoses, prescriptions, investigation_orders, invoices, invoice_line_items, pharmacy_queue, and the master data tables. Sets up basic security (RLS) and auto-creates a staff profile when a new login is created. |
| 002_register_patient.sql | Adds safe, atomic UHID generation (VEH-00001, VEH-00002...) so concurrent registrations never collide. |
| 003_checkin.sql | Adds the function that turns a booked appointment into a real visit, atomically. |
| 004_queue.sql | Adds real token issuance for Optometry/Doctor queues, and wires visit creation to automatically issue the first token. |
| 005_data_integrity.sql | Adds two data rules: mobile numbers must be exactly 10 digits, and a patient can only have one visit per calendar day. Fixes a Postgres immutability quirk with date-based indexes by introducing `ist_date()`, used consistently everywhere a day boundary matters. |

## dev-utils/

`reset_test_data.sql` -- wipes all patients/visits/appointments/queue
entries. **This is a development convenience only.** Never run this
against a database with real patient data -- it is permanently
destructive and does not ask for confirmation.

SQLEOF

cat > 'database/dev-utils/reset_test_data.sql' << 'SQLEOF'
-- ============================================================
-- VEDA HMIS -- Reset test data
--
-- Deletes all test data created so far, in the correct order so
-- foreign keys don't block it (children before parents). Also resets
-- the UHID counter so the next patient registered starts fresh at
-- VEH-00001 again.
--
-- HOW TO USE: Supabase dashboard -> SQL Editor -> New query -> paste
-- this entire file -> Run.
-- ============================================================

delete from queue_entries;
delete from optometry_findings;
delete from visits;
delete from appointments;
delete from patients;

alter sequence patient_uhid_seq restart with 1;

-- ============================================================
-- DONE. Everything is now clean. Re-run Migration 5 next.
-- ============================================================

SQLEOF

cat > 'database/migrations/001_initial_schema.sql' << 'SQLEOF'
-- ============================================================
-- VEDA EYE HOSPITAL HMIS -- Phase 1 Database Schema
-- Covers: Login/Staff, Patients, Appointments, Visits, Queue
--         (Optometry + Doctor), Clinical Encounter, Prescriptions,
--         Investigations, Billing, and core Master Data.
--
-- HOW TO USE:
-- 1. Open your Supabase project -> left sidebar -> "SQL Editor"
-- 2. Click "New query"
-- 3. Paste this entire file
-- 4. Click "Run" (or Ctrl/Cmd + Enter)
-- It's safe to re-run: every statement uses IF NOT EXISTS.
-- ============================================================

-- ─────────────────────────────────────────────
-- 1. STAFF PROFILES (linked to Supabase's built-in login system)
-- ─────────────────────────────────────────────
create table if not exists profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null,
  designation text not null,          -- e.g. 'Optometrist', 'Ophthalmologist', 'Reception Executive'
  department text,                    -- e.g. 'Clinical', 'OT Staff', 'Front Office'
  status text not null default 'Active' check (status in ('Active','Inactive','Locked')),
  created_at timestamptz not null default now()
);

-- ─────────────────────────────────────────────
-- 2. PATIENTS
-- ─────────────────────────────────────────────
create table if not exists patients (
  id uuid primary key default gen_random_uuid(),
  uhid text unique not null,          -- e.g. 'VEH-00123'
  first_name text not null,
  last_name text not null,
  age int,
  gender text check (gender in ('M','F','O')),
  mobile text not null,
  address text,
  blood_group text,
  created_at timestamptz not null default now()
);
create index if not exists idx_patients_mobile on patients(mobile);

-- ─────────────────────────────────────────────
-- 3. APPOINTMENTS
-- ─────────────────────────────────────────────
create table if not exists appointments (
  id uuid primary key default gen_random_uuid(),
  patient_id uuid references patients(id),        -- nullable: phone bookings before registration
  patient_name_temp text,                          -- used only if patient_id is null
  mobile_temp text,
  doctor_id uuid references profiles(id),
  appointment_date date not null,
  appointment_time time not null,
  visit_type text not null default 'New Consultation'
    check (visit_type in ('New Consultation','Follow-up','Investigation Only','Post-operative Review')),
  remarks text,
  status text not null default 'Booked' check (status in ('Booked','Checked-in','Cancelled','No-show')),
  created_at timestamptz not null default now()
);
create index if not exists idx_appt_date on appointments(appointment_date);

-- ─────────────────────────────────────────────
-- 4. VISITS (created at check-in, one per hospital visit)
-- ─────────────────────────────────────────────
create table if not exists visits (
  id uuid primary key default gen_random_uuid(),
  patient_id uuid not null references patients(id),
  appointment_id uuid references appointments(id),
  doctor_id uuid references profiles(id),
  visit_type text not null default 'New Consultation',
  status text not null default 'Open' check (status in ('Open','Closed','Cancelled')),
  created_at timestamptz not null default now(),
  closed_at timestamptz
);
create index if not exists idx_visits_patient on visits(patient_id);

-- ─────────────────────────────────────────────
-- 5. QUEUE ENTRIES (Optometry + Doctor -- single source of truth,
--    replacing the old localStorage-based prototype mechanism)
-- ─────────────────────────────────────────────
create table if not exists queue_entries (
  id uuid primary key default gen_random_uuid(),
  visit_id uuid not null references visits(id),
  department text not null check (department in ('Optometry','Doctor')),
  token text not null,                 -- e.g. 'O-01', 'D-03'
  status text not null default 'Waiting'
    check (status in ('Waiting','Calling','In Consultation','Awaiting Dilation','Awaiting Investigation','Ready for Review','Done')),
  issued_at timestamptz not null default now(),
  called_at timestamptz,
  sent_out_at timestamptz,             -- when sent for dilation/investigation
  completed_at timestamptz
);
create index if not exists idx_queue_visit on queue_entries(visit_id);
create index if not exists idx_queue_dept_status on queue_entries(department, status);

-- ─────────────────────────────────────────────
-- 6. OPTOMETRY FINDINGS
-- ─────────────────────────────────────────────
create table if not exists optometry_findings (
  id uuid primary key default gen_random_uuid(),
  visit_id uuid not null references visits(id),
  re_va text, le_va text,
  re_iop numeric, le_iop numeric,
  re_sph text, le_sph text,
  re_cyl text, le_cyl text,
  recorded_by uuid references profiles(id),
  recorded_at timestamptz not null default now()
);

-- ─────────────────────────────────────────────
-- 7. CLINICAL ENCOUNTER (doctor consultation)
-- ─────────────────────────────────────────────
create table if not exists encounters (
  id uuid primary key default gen_random_uuid(),
  visit_id uuid not null references visits(id),
  doctor_id uuid references profiles(id),
  chief_complaint text,
  status text not null default 'In Consultation'
    check (status in ('In Consultation','Completed')),
  started_at timestamptz not null default now(),
  completed_at timestamptz
);

create table if not exists diagnoses (
  id uuid primary key default gen_random_uuid(),
  encounter_id uuid not null references encounters(id),
  name text not null,
  category text not null default 'primary'
    check (category in ('primary','secondary','associated','systemic')),
  eye text,
  status text not null default 'Active',
  created_at timestamptz not null default now()
);
-- BR-DGN-004 (only one Active primary diagnosis per encounter) is enforced in application code,
-- since a partial unique index needs care with status changes -- keep the check simple in the DB.

create table if not exists prescriptions (
  id uuid primary key default gen_random_uuid(),
  encounter_id uuid not null references encounters(id),
  drug_name text not null,
  dosage text,       -- e.g. '1 drop'
  frequency text,    -- e.g. 'BD'
  duration text,     -- e.g. '1 month'
  eye text,
  status text not null default 'Pending' check (status in ('Pending','Sent','Dispensed')),
  sent_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists investigation_orders (
  id uuid primary key default gen_random_uuid(),
  encounter_id uuid not null references encounters(id),
  name text not null,
  eye text,
  priority text not null default 'Routine' check (priority in ('Routine','Urgent')),
  status text not null default 'Ordered'
    check (status in ('Ordered','In Progress','Completed','Verified')),
  billed boolean not null default false,
  created_at timestamptz not null default now()
);

-- ─────────────────────────────────────────────
-- 8. BILLING
-- ─────────────────────────────────────────────
create table if not exists invoices (
  id uuid primary key default gen_random_uuid(),
  patient_id uuid not null references patients(id),
  visit_id uuid references visits(id),
  status text not null default 'Pending' check (status in ('Pending','Partial','Paid','Cancelled')),
  gross numeric not null default 0,
  gst numeric not null default 0,
  net numeric not null default 0,
  paid numeric not null default 0,
  created_at timestamptz not null default now()
);

create table if not exists invoice_line_items (
  id uuid primary key default gen_random_uuid(),
  invoice_id uuid not null references invoices(id) on delete cascade,
  service_code text,
  service_name text not null,
  dept text,
  qty int not null default 1,
  rate numeric not null,
  gst_pct numeric not null default 0,
  disc numeric not null default 0,
  gross numeric not null,
  gst_amount numeric not null,
  net numeric not null
);

-- ─────────────────────────────────────────────
-- 9. PHARMACY DISPENSING QUEUE
-- ─────────────────────────────────────────────
create table if not exists pharmacy_queue (
  id uuid primary key default gen_random_uuid(),
  patient_id uuid not null references patients(id),
  prescription_id uuid references prescriptions(id),
  status text not null default 'Pending' check (status in ('Pending','Dispensed')),
  dispensed_at timestamptz,
  created_at timestamptz not null default now()
);

-- ─────────────────────────────────────────────
-- 10. CORE MASTER DATA (single source of truth -- M29 equivalent)
-- ─────────────────────────────────────────────
create table if not exists master_services (
  id uuid primary key default gen_random_uuid(),
  code text unique not null,
  name text not null,
  dept text not null,          -- Consultation / Investigation / Pharmacy / Surgery
  rate numeric not null,
  gst_pct numeric not null default 0,
  status text not null default 'Active' check (status in ('Active','Inactive'))
);

create table if not exists master_packages (
  id uuid primary key default gen_random_uuid(),
  code text unique not null,
  name text not null,
  price numeric not null,
  includes text,
  status text not null default 'Active' check (status in ('Active','Inactive'))
);

create table if not exists master_drugs (
  id uuid primary key default gen_random_uuid(),
  code text unique not null,
  brand text,
  generic text not null,
  strength text,
  form text,
  status text not null default 'Active' check (status in ('Active','Inactive'))
);

create table if not exists master_diagnoses (
  id uuid primary key default gen_random_uuid(),
  code text unique not null,
  name text not null,
  category text,
  status text not null default 'Active' check (status in ('Active','Inactive'))
);

create table if not exists master_investigations (
  id uuid primary key default gen_random_uuid(),
  code text unique not null,
  name text not null,
  dept text,
  rate numeric,
  gst_pct numeric default 0,
  status text not null default 'Active' check (status in ('Active','Inactive'))
);

-- ─────────────────────────────────────────────
-- 11. ROW LEVEL SECURITY -- simple version for Phase 1.
-- Any logged-in staff member can read/write for now; we will tighten
-- this to per-role permissions once the core flow is working end to end.
-- ─────────────────────────────────────────────
alter table profiles enable row level security;
alter table patients enable row level security;
alter table appointments enable row level security;
alter table visits enable row level security;
alter table queue_entries enable row level security;
alter table optometry_findings enable row level security;
alter table encounters enable row level security;
alter table diagnoses enable row level security;
alter table prescriptions enable row level security;
alter table investigation_orders enable row level security;
alter table invoices enable row level security;
alter table invoice_line_items enable row level security;
alter table pharmacy_queue enable row level security;
alter table master_services enable row level security;
alter table master_packages enable row level security;
alter table master_drugs enable row level security;
alter table master_diagnoses enable row level security;
alter table master_investigations enable row level security;

do $$
declare
  t text;
begin
  for t in select unnest(array[
    'profiles','patients','appointments','visits','queue_entries',
    'optometry_findings','encounters','diagnoses','prescriptions',
    'investigation_orders','invoices','invoice_line_items','pharmacy_queue',
    'master_services','master_packages','master_drugs','master_diagnoses','master_investigations'
  ])
  loop
    execute format('drop policy if exists "staff_all_access" on %I;', t);
    execute format(
      'create policy "staff_all_access" on %I for all to authenticated using (true) with check (true);', t
    );
  end loop;
end $$;

-- ─────────────────────────────────────────────
-- 12. AUTO-CREATE A PROFILE ROW WHEN A NEW STAFF LOGIN IS CREATED
-- ─────────────────────────────────────────────
create or replace function handle_new_user()
returns trigger as $$
begin
  insert into public.profiles (id, full_name, designation, department)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'full_name', new.email),
    coalesce(new.raw_user_meta_data->>'designation', 'Staff'),
    coalesce(new.raw_user_meta_data->>'department', '')
  );
  return new;
end;
$$ language plpgsql security definer;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure handle_new_user();

-- ============================================================
-- DONE. You should now see 18 new tables under
-- Database -> Tables in the left sidebar.
-- ============================================================

SQLEOF

cat > 'database/migrations/004_queue.sql' << 'SQLEOF'
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

SQLEOF

cat > 'database/migrations/003_checkin.sql' << 'SQLEOF'
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

SQLEOF

cat > 'database/migrations/005_data_integrity.sql' << 'SQLEOF'
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

SQLEOF

cat > 'database/migrations/002_register_patient.sql' << 'SQLEOF'
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

SQLEOF

echo "Database migration history saved."
