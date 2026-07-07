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

