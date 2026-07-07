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

