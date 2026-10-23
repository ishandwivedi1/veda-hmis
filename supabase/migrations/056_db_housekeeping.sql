-- 056: database housekeeping from the 23 Oct 2026 speed audit
-- (Supabase performance advisor findings). No data changes, and every rule
-- means exactly what it meant before -- only how efficiently it runs.
-- Safe to run more than once. Apply to production AND training.

-- 1. billing_audit_log: the INSERT check called auth.uid() once PER ROW.
--    Wrapping it in (select ...) evaluates it once per statement. Same rule.
drop policy if exists billing_audit_log_insert on public.billing_audit_log;
create policy billing_audit_log_insert on public.billing_audit_log
  for insert to authenticated
  with check (changed_by = (select auth.uid()));

-- 2. optometry_audit_log: two separate SELECT policies were both evaluated
--    on every read. Merged into one with the identical meaning:
--    Administrators see everything; other staff see doctor-override entries.
drop policy if exists admin_can_select on public.optometry_audit_log;
drop policy if exists staff_can_select_doctor_overrides on public.optometry_audit_log;
drop policy if exists optometry_audit_log_select on public.optometry_audit_log;
create policy optometry_audit_log_select on public.optometry_audit_log
  for select to authenticated
  using (
    message like 'Doctor override%'
    or exists (
      select 1 from public.profiles
      where profiles.id = (select auth.uid())
        and profiles.designation = 'Administrator'
    )
  );

-- 3. Indexes for foreign keys that screens actually search or join on
--    (optical customer/patient lookups, payment <-> credit note / refund /
--    ledger links, the invoice a surgery was billed on, stock location).
--    "created_by / approved_by"-style user columns are deliberately left
--    out: nothing searches on them, and each extra index slows every save.
create index if not exists idx_credit_note_applications_payment_id on public.credit_note_applications (payment_id);
create index if not exists idx_inventory_lots_location_id on public.inventory_lots (location_id);
create index if not exists idx_optical_credit_notes_optical_customer_id on public.optical_credit_notes (optical_customer_id);
create index if not exists idx_optical_credit_notes_patient_id on public.optical_credit_notes (patient_id);
create index if not exists idx_optical_credit_notes_payment_id on public.optical_credit_notes (payment_id);
create index if not exists idx_optical_customer_ledger_payment_id on public.optical_customer_ledger (payment_id);
create index if not exists idx_optical_orders_optical_customer_id on public.optical_orders (optical_customer_id);
create index if not exists idx_optical_orders_patient_id on public.optical_orders (patient_id);
create index if not exists idx_optical_orders_sale_id on public.optical_orders (sale_id);
create index if not exists idx_optical_payment_refunds_optical_customer_id on public.optical_payment_refunds (optical_customer_id);
create index if not exists idx_optical_payment_refunds_patient_id on public.optical_payment_refunds (patient_id);
create index if not exists idx_optical_payment_refunds_refund_payment_id on public.optical_payment_refunds (refund_payment_id);
create index if not exists idx_surgical_case_procedures_billed_invoice_id on public.surgical_case_procedures (billed_invoice_id);
create index if not exists idx_surgical_cases_billed_invoice_id on public.surgical_cases (billed_invoice_id);

-- Not done on purpose: dropping the ~116 indexes the advisor calls "unused".
-- The system is ~3 months old, so many simply haven't been needed YET
-- (month-end reports, audits). Revisit after a full year of usage stats.
