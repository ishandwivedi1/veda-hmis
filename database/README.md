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

