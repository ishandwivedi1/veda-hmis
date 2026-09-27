-- ============================================================================
-- 040 — Void invoice (Zoho-style billing edits, Phase 4)
--
-- Voids an invoice even after it has been paid. Reuses the existing
-- 'Cancelled' status (99 places in screens/reports already exclude it), so
-- no report needs to learn a new status.
--
--   * gate: unpaid invoice dated today -> 'invoice.edit' (front desk can
--     still cancel a wrong bill, as before); paid or past-day -> 'invoice.void'.
--     Closed day locked. Reason required. Stale-screen check.
--   * blocked if the invoice has an active refund or a credit note
--     (those already settled money against it; cancel them first)
--   * every payment application is removed:
--       money received  -> patient credit ('Advance Collected' tagged with
--                          the payment, so received = applied + credit holds)
--       credit applied  -> credit returned ('Correction: Credit Added')
--   * everything linked goes back to Pending: prescriptions, investigation
--     orders, OPD procedures, biometry; surgery-package cases un-billed
--   * invoice kept: status 'Cancelled', paid 0, reason; lines kept for
--     history; full before/after in billing_audit_log (+ legacy
--     invoice_modifications row so older screens show it)
--   * runs with owner rights (see 038b); anon EXECUTE revoked
-- New function only. Apply to BOTH projects.
-- ============================================================================

create function public.void_invoice(p_invoice_id uuid, p_reason text, p_expected_net numeric)
returns invoices
language plpgsql
as $$
declare
  inv invoices;
  v_before jsonb;
  v_has_alloc boolean;
  v_alloc record;
  v_credited numeric := 0;
  v_moves jsonb := '[]'::jsonb;
  v_side jsonb := '[]'::jsonb;
  v_n integer;
  v_n2 integer;
  v_pkg record;
  v_case_id uuid;
begin
  if p_reason is null or trim(p_reason) = '' then
    raise exception 'A reason is required to cancel / void an invoice.';
  end if;

  select * into inv from invoices where id = p_invoice_id for update;
  if inv is null then raise exception 'Invoice not found.'; end if;
  if inv.status in ('Cancelled', 'Void') then
    raise exception 'This invoice is already cancelled.';
  end if;

  select exists (select 1 from payment_allocations where invoice_id = p_invoice_id) into v_has_alloc;

  if v_has_alloc or ist_date(inv.created_at) < ist_date(now()) then
    perform assert_billing_edit_allowed('invoice.void', ist_date(inv.created_at));
  else
    perform assert_billing_edit_allowed('invoice.edit', ist_date(inv.created_at));
  end if;

  if p_expected_net is not null and round(inv.net, 2) <> round(p_expected_net, 2) then
    raise exception 'This invoice was changed by someone else since you opened it (total is now Rs.%). Close and reopen it, then try again.', inv.net;
  end if;
  if exists (select 1 from payment_refunds where invoice_id = p_invoice_id and cancelled_at is null) then
    raise exception 'This invoice has a refund recorded against it. Cancel the refund first (Payments > Refund), then void the invoice.';
  end if;
  if exists (select 1 from credit_notes where invoice_id = p_invoice_id) then
    raise exception 'This invoice has a credit note against it, so it cannot be voided. Contact an Administrator.';
  end if;
  if v_has_alloc and is_day_closed(ist_date(now())) then
    raise exception 'Payments on this invoice must be moved to patient credit today, but today is already closed. An Administrator must reopen today first.';
  end if;

  v_before := invoice_edit_snapshot(p_invoice_id) || jsonb_build_object(
    'allocations', coalesce((select jsonb_agg(jsonb_build_object('receipt', p.receipt_number, 'payment_type', p.payment_type, 'amount', a.amount))
                               from payment_allocations a join payments p on p.id = a.payment_id where a.invoice_id = p_invoice_id), '[]'::jsonb));

  -- 1. payments on it -> patient credit --------------------------------------
  for v_alloc in
    select a.id, a.amount, a.payment_id, p.payment_type, p.receipt_number, p.patient_id
      from payment_allocations a join payments p on p.id = a.payment_id
     where a.invoice_id = p_invoice_id
  loop
    if v_alloc.payment_type not in ('invoice_payment', 'advance', 'advance_adjustment') then
      raise exception 'This invoice has a % applied to it and cannot be voided here. Contact an Administrator.', v_alloc.payment_type;
    end if;
    delete from payment_allocations where id = v_alloc.id;
    get diagnostics v_n = row_count;
    if v_n <> 1 then raise exception 'Could not remove a payment from this invoice. Nothing was changed.'; end if;

    insert into patient_ledger (patient_id, payment_id, entry_type, amount, remarks, recorded_by)
    values (v_alloc.patient_id, v_alloc.payment_id,
            case when v_alloc.payment_type = 'advance_adjustment' then 'Correction: Credit Added' else 'Advance Collected' end,
            v_alloc.amount,
            case when v_alloc.payment_type = 'advance_adjustment'
                 then 'Credit returned: ' || coalesce(inv.invoice_number, 'invoice') || ' voided'
                 else 'Payment ' || coalesce(v_alloc.receipt_number, '-') || ' kept as credit: ' || coalesce(inv.invoice_number, 'invoice') || ' voided' end,
            auth.uid());
    v_moves := v_moves || jsonb_build_object('receipt', coalesce(v_alloc.receipt_number, 'Credit application'), 'amount', v_alloc.amount);
    v_credited := v_credited + v_alloc.amount;
  end loop;

  -- 2. linked records back to Pending ----------------------------------------
  update prescriptions
     set billing_status = 'Pending', invoice_id = null, invoice_line_item_id = null,
         billing_note = 'Released: ' || coalesce(inv.invoice_number, 'invoice') || ' voided: ' || trim(p_reason),
         billing_updated_by = auth.uid(), billing_updated_at = now()
   where invoice_id = p_invoice_id
      or invoice_line_item_id in (select id from invoice_line_items where invoice_id = p_invoice_id);
  get diagnostics v_n = row_count;
  if v_n > 0 then v_side := v_side || jsonb_build_object('effect', 'prescriptions_back_to_pending', 'count', v_n); end if;

  update investigation_orders
     set billing_status = 'Pending', billed = false, invoice_id = null,
         billing_note = 'Released: ' || coalesce(inv.invoice_number, 'invoice') || ' voided',
         billing_updated_by = auth.uid(), billing_updated_at = now()
   where invoice_id = p_invoice_id;
  get diagnostics v_n = row_count;
  if v_n > 0 then v_side := v_side || jsonb_build_object('effect', 'investigations_back_to_pending', 'count', v_n); end if;

  update plan_procedures
     set billing_status = 'Pending', billed = false, invoice_id = null,
         billing_updated_by = auth.uid(), billing_updated_at = now()
   where invoice_id = p_invoice_id;
  get diagnostics v_n = row_count;
  if v_n > 0 then v_side := v_side || jsonb_build_object('effect', 'procedures_back_to_pending', 'count', v_n); end if;

  update biometry_records
     set billing_status = 'Pending', invoice_id = null,
         billing_note = 'Released: ' || coalesce(inv.invoice_number, 'invoice') || ' voided',
         billing_updated_by = auth.uid(), billing_updated_at = now()
   where invoice_id = p_invoice_id;
  get diagnostics v_n = row_count;
  if v_n > 0 then v_side := v_side || jsonb_build_object('effect', 'biometry_back_to_pending', 'count', v_n); end if;

  -- surgery packages: linked cases first, then (older bills) exactly one
  -- unlinked billed case per package for this patient
  update surgical_cases set package_billed = false, billed_invoice_id = null where billed_invoice_id = p_invoice_id;
  get diagnostics v_n = row_count;
  update surgical_case_procedures set package_billed = false, billed_invoice_id = null where billed_invoice_id = p_invoice_id;
  get diagnostics v_n2 = row_count;
  if v_n + v_n2 = 0 then
    for v_pkg in
      select distinct mp.id, mp.name from invoice_line_items l join master_packages mp on mp.code = l.service_code
       where l.invoice_id = p_invoice_id
    loop
      select count(*), (array_agg(id))[1] into v_n2, v_case_id from surgical_cases
       where patient_id = inv.patient_id and package_id = v_pkg.id and package_billed and billed_invoice_id is null;
      if v_n2 = 1 then
        update surgical_cases set package_billed = false where id = v_case_id;
        v_n := v_n + 1;
      else
        v_side := v_side || jsonb_build_object('effect', 'surgical_case_not_found', 'service', v_pkg.name, 'count', 0);
      end if;
    end loop;
  else
    v_n := v_n + v_n2;
  end if;
  if v_n > 0 then v_side := v_side || jsonb_build_object('effect', 'surgical_case_unbilled', 'count', v_n); end if;

  -- 3. the invoice itself ------------------------------------------------------
  update invoices
     set status = 'Cancelled', paid = 0,
         cancelled_at = now(), cancelled_by = auth.uid(), cancellation_reason = trim(p_reason)
   where id = p_invoice_id
  returning * into inv;

  insert into invoice_modifications (invoice_id, modified_by, action, reason, details)
  values (p_invoice_id, auth.uid(), 'cancelled', trim(p_reason),
          case when v_credited > 0 then 'Voided; Rs.' || v_credited || ' moved to patient credit' else 'Cancelled' end);

  insert into billing_audit_log (entity_type, entity_id, entity_ref, action, reason, before_data, after_data, changed_by)
  values ('invoice', p_invoice_id, inv.invoice_number, 'invoice_voided', trim(p_reason), v_before,
          jsonb_build_object('status', 'Cancelled', 'credited_to_patient', v_credited, 'credit_moves', v_moves, 'side_effects', v_side),
          auth.uid());

  return inv;
end;
$$;

alter function public.void_invoice(uuid, text, numeric) security definer;
alter function public.void_invoice(uuid, text, numeric) set search_path = public;
revoke execute on function public.void_invoice(uuid, text, numeric) from public, anon;
grant  execute on function public.void_invoice(uuid, text, numeric) to authenticated;
