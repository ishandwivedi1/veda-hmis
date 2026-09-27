-- ============================================================================
-- 041 — Fixes from the Mr. Claude walkthrough on Training (27 Sep 2026)
--
-- 1. release_credit_application() NEW (internal only; no one can call it
--    directly). Shrinks a credit application and gives the credit back; if
--    nothing is left, removes it (-> Deleted receipts), keeping its ledger
--    lines. Used by:
-- 2. void_invoice()  -- before: left an empty Rs.3,800 "Adjustment" row (step 17)
-- 3. edit_invoice()  -- same flaw in its excess-to-credit step
--    Both also: no amber "no surgical case found" when a package never had a
--    case (step 15); only flag when several cases could match.
-- 4. change_invoice_date(): a visit's invoice cannot be dated before the
--    visit (step 11).
-- 5. billing_reconciliation(): new check, credit application = amount applied.
-- 6. Tidy the one empty credit application on Training (production has none).
--
-- Replaced functions keep their exact signatures; SECURITY DEFINER and
-- search_path are restated (CREATE OR REPLACE would otherwise drop them).
-- Apply to BOTH projects.
-- ============================================================================

create function public.release_credit_application(p_adj_id uuid, p_invoice_id uuid, p_amount numeric, p_note text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  adj payments;
  v_alloc payment_allocations;
  v_before jsonb;
  v_n integer;
begin
  select * into adj from payments where id = p_adj_id for update;
  if adj is null or adj.payment_type <> 'advance_adjustment' then
    raise exception 'Not a credit application. Nothing was changed.';
  end if;
  select * into v_alloc from payment_allocations where payment_id = p_adj_id and invoice_id = p_invoice_id for update;
  if v_alloc is null or p_amount is null or p_amount <= 0 or round(p_amount, 2) > round(v_alloc.amount, 2) then
    raise exception 'Credit application amount mismatch. Nothing was changed.';
  end if;

  v_before := payment_edit_snapshot(p_adj_id);

  -- the credit goes back to the patient
  insert into patient_ledger (patient_id, payment_id, entry_type, amount, remarks, recorded_by)
  values (adj.patient_id, p_adj_id, 'Correction: Credit Added', p_amount, p_note, auth.uid());

  if round(p_amount, 2) = round(v_alloc.amount, 2) then
    delete from payment_allocations where id = v_alloc.id;
  else
    update payment_allocations set amount = amount - p_amount where id = v_alloc.id;
  end if;

  update payments set total_amount = total_amount - p_amount where id = p_adj_id returning * into adj;

  -- nothing left of it: remove it (its ledger lines are kept and now net to zero)
  if round(adj.total_amount, 2) <= 0 then
    update patient_ledger
       set payment_id = null, remarks = coalesce(remarks, '') || ' [credit application removed]'
     where payment_id = p_adj_id;
    delete from payments where id = p_adj_id;
    get diagnostics v_n = row_count;
    if v_n <> 1 then
      raise exception 'Could not remove the credit application. Nothing was changed.';
    end if;
    insert into billing_audit_log (entity_type, entity_id, entity_ref, action, reason, before_data, after_data, changed_by)
    values ('payment', p_adj_id, 'Credit application', 'credit_application_removed', p_note, v_before,
            jsonb_build_object('released_from_invoice', (select invoice_number from invoices where id = p_invoice_id)), auth.uid());
  end if;
end;
$$;

create or replace function public.void_invoice(p_invoice_id uuid, p_reason text, p_expected_net numeric)
returns invoices
language plpgsql
security definer
set search_path = public
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
    if v_alloc.payment_type = 'advance_adjustment' then
      -- credit application: give the credit back and remove the application
      -- cleanly (041; before, an empty application row was left behind)
      perform release_credit_application(v_alloc.payment_id, p_invoice_id, v_alloc.amount,
        'Credit returned: ' || coalesce(inv.invoice_number, 'invoice') || ' voided: ' || trim(p_reason));
    else
      delete from payment_allocations where id = v_alloc.id;
      get diagnostics v_n = row_count;
      if v_n <> 1 then raise exception 'Could not remove a payment from this invoice. Nothing was changed.'; end if;

      insert into patient_ledger (patient_id, payment_id, entry_type, amount, remarks, recorded_by)
      values (v_alloc.patient_id, v_alloc.payment_id, 'Advance Collected', v_alloc.amount,
              'Payment ' || coalesce(v_alloc.receipt_number, '-') || ' kept as credit: ' || coalesce(inv.invoice_number, 'invoice') || ' voided',
              auth.uid());
    end if;
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
      elsif v_n2 > 1 then
        -- several billed cases for this package: don't guess, flag it
        v_side := v_side || jsonb_build_object('effect', 'surgical_case_ambiguous', 'service', v_pkg.name, 'count', v_n2);
      end if;
      -- no billed case at all (billed straight from New Invoice): nothing to do
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

create or replace function public.edit_invoice(p_invoice_id uuid, p_changes jsonb, p_reason text, p_expected_net numeric)
returns invoices
language plpgsql
security definer
set search_path = public
as $$
declare
  inv invoices;
  v_before jsonb;
  v_after jsonb;
  v_item jsonb;
  v_line invoice_line_items;
  v_lock text;
  v_qty integer;
  v_disc_type text;
  v_disc_value numeric;
  v_gross numeric;
  v_disc numeric;
  v_gst numeric;
  v_changed integer := 0;
  v_excess numeric;
  v_take numeric;
  v_credited numeric := 0;
  v_alloc record;
  v_credit_moves jsonb := '[]'::jsonb;
  v_disc_reasons jsonb := '[]'::jsonb;
  v_side_effects jsonb := '[]'::jsonb;
  v_pkg_id uuid;
  v_n integer;
  v_n2 integer;
  v_case_id uuid;
begin
  if p_reason is null or trim(p_reason) = '' then
    raise exception 'A reason is required to edit an invoice.';
  end if;

  select * into inv from invoices where id = p_invoice_id for update;
  if inv is null then
    raise exception 'Invoice not found.';
  end if;
  if inv.status in ('Cancelled', 'Void') then
    raise exception 'This invoice is % and cannot be edited.', lower(inv.status);
  end if;

  perform assert_billing_edit_allowed('invoice.edit', ist_date(inv.created_at));

  if p_expected_net is not null and round(inv.net, 2) <> round(p_expected_net, 2) then
    raise exception 'This invoice was changed by someone else since you opened it (total is now Rs.%). Close and reopen it, then try again.', inv.net;
  end if;

  v_before := invoice_edit_snapshot(p_invoice_id);

  -- 1. Removals ---------------------------------------------------------------
  for v_item in select * from jsonb_array_elements(coalesce(p_changes->'remove', '[]'::jsonb)) loop
    select * into v_line from invoice_line_items where id = (v_item #>> '{}')::uuid and invoice_id = p_invoice_id;
    if v_line is null then
      raise exception 'An item being removed is no longer on this invoice. Close and reopen it, then try again.';
    end if;
    v_lock := invoice_line_lock_reason(v_line);
    if v_lock is not null then
      raise exception '"%": %', v_line.service_name, v_lock;
    end if;

    -- medicine: release the prescription(s) back to Pharmacy as Pending
    update prescriptions
       set billing_status = 'Pending', invoice_id = null, invoice_line_item_id = null,
           billing_note = 'Removed from ' || coalesce(inv.invoice_number, 'invoice') || ' by invoice edit: ' || trim(p_reason),
           billing_updated_by = auth.uid(), billing_updated_at = now()
     where invoice_line_item_id = v_line.id;
    get diagnostics v_n = row_count;
    if v_n > 0 then
      v_side_effects := v_side_effects || jsonb_build_object('effect', 'prescription_back_to_pending', 'service', v_line.service_name, 'count', v_n);
    end if;

    delete from invoice_line_items where id = v_line.id;

    -- surgery package: mark the case as not billed again, unless the invoice
    -- still carries another line for the same package
    select id into v_pkg_id from master_packages where code = v_line.service_code;
    if v_pkg_id is not null
       and not exists (select 1 from invoice_line_items where invoice_id = p_invoice_id and service_code = v_line.service_code) then
      update surgical_cases set package_billed = false, billed_invoice_id = null
       where billed_invoice_id = p_invoice_id and package_id = v_pkg_id;
      get diagnostics v_n = row_count;
      update surgical_case_procedures set package_billed = false, billed_invoice_id = null
       where billed_invoice_id = p_invoice_id and package_id = v_pkg_id;
      get diagnostics v_n2 = row_count;
      v_n := v_n + v_n2;
      if v_n = 0 then
        -- older bills never recorded the invoice on the case: only act when
        -- exactly one billed case for this patient + package is unlinked
        select count(*), (array_agg(id))[1] into v_n2, v_case_id from surgical_cases
         where patient_id = inv.patient_id and package_id = v_pkg_id and package_billed and billed_invoice_id is null;
        if v_n2 = 1 then
          update surgical_cases set package_billed = false where id = v_case_id;
          v_n := 1;
        elsif v_n2 > 1 then
          -- several billed cases for this package: don't guess, flag it
          v_side_effects := v_side_effects || jsonb_build_object('effect', 'surgical_case_ambiguous', 'service', v_line.service_name, 'count', v_n2);
        end if;
        -- no billed case at all (billed straight from New Invoice): nothing to do
      end if;
      if v_n > 0 then
        v_side_effects := v_side_effects || jsonb_build_object('effect', 'surgical_case_unbilled', 'service', v_line.service_name, 'count', v_n);
      end if;
    end if;

    v_changed := v_changed + 1;
  end loop;

  -- 2. Quantity / discount changes -------------------------------------------
  for v_item in select * from jsonb_array_elements(coalesce(p_changes->'update', '[]'::jsonb)) loop
    select * into v_line from invoice_line_items where id = (v_item->>'id')::uuid and invoice_id = p_invoice_id;
    if v_line is null then
      raise exception 'An item being changed is no longer on this invoice. Close and reopen it, then try again.';
    end if;

    v_qty := coalesce((v_item->>'qty')::integer, v_line.qty);
    v_disc_type := coalesce(v_item->>'disc_type', 'fixed');
    v_disc_value := coalesce((v_item->>'disc_value')::numeric, 0);
    if v_qty < 1 then
      raise exception '"%": quantity must be at least 1. To take the item off, remove it instead.', v_line.service_name;
    end if;
    if v_disc_type not in ('none', 'pct', 'fixed') or v_disc_value < 0 then
      raise exception '"%": invalid discount.', v_line.service_name;
    end if;

    v_gross := v_line.rate * v_qty;
    v_disc := case v_disc_type
                when 'pct'   then round(v_gross * least(v_disc_value, 100) / 100, 2)
                when 'fixed' then least(v_disc_value, v_gross)
                else 0 end;

    if v_qty = v_line.qty and round(v_disc, 2) = round(v_line.disc, 2) then
      continue;
    end if;

    v_lock := invoice_line_lock_reason(v_line);
    if v_lock is not null then
      raise exception '"%": %', v_line.service_name, v_lock;
    end if;
    if v_disc > v_line.disc and coalesce(trim(v_item->>'disc_reason'), '') = '' then
      raise exception '"%": a discount reason is required whenever a discount is given or increased.', v_line.service_name;
    end if;
    if coalesce(trim(v_item->>'disc_reason'), '') <> '' then
      v_disc_reasons := v_disc_reasons || jsonb_build_object('service', v_line.service_name, 'reason', trim(v_item->>'disc_reason'));
    end if;

    v_gst := round((v_gross - v_disc) * v_line.gst_pct / 100, 2);
    update invoice_line_items
       set qty = v_qty, gross = v_gross, disc = v_disc, gst_amount = v_gst, net = v_gross - v_disc + v_gst
     where id = v_line.id;
    v_changed := v_changed + 1;
  end loop;

  -- 3. Additions: any catalog item (service, medicine, package) ---------------
  --    add_invoice_line_item() is the existing, proven path: it validates the
  --    code, prices from the catalog, requires a discount reason, marks a
  --    locked package as billed, and recomputes totals.
  for v_item in select * from jsonb_array_elements(coalesce(p_changes->'add', '[]'::jsonb)) loop
    if coalesce(v_item->>'disc_type', 'none') <> 'none' and coalesce(trim(v_item->>'disc_reason'), '') <> '' then
      v_disc_reasons := v_disc_reasons || jsonb_build_object('service', v_item->>'service_code', 'reason', trim(v_item->>'disc_reason'));
    end if;
    perform add_invoice_line_item(
      p_invoice_id,
      v_item->>'service_code',
      greatest(coalesce((v_item->>'qty')::integer, 1), 1),
      coalesce(v_item->>'disc_type', 'none'),
      coalesce((v_item->>'disc_value')::numeric, 0),
      nullif(trim(coalesce(v_item->>'disc_reason', '')), ''));
    v_changed := v_changed + 1;
  end loop;

  if v_changed = 0 then
    raise exception 'Nothing was changed on this invoice.';
  end if;
  if not exists (select 1 from invoice_line_items where invoice_id = p_invoice_id) then
    raise exception 'An invoice must keep at least one item. To cancel the whole bill, use Cancel/Void instead.';
  end if;

  -- 4. Recalculate from payments (never by hand) ------------------------------
  inv := sync_invoice_paid(p_invoice_id);

  -- 5. Paid more than the new total -> excess becomes patient credit ----------
  v_excess := round(inv.paid - inv.net, 2);
  if v_excess > 0 then
    -- moving excess off payments that were partly refunded against this
    -- invoice could leave a payment below what was refunded from it
    if exists (select 1 from payment_refunds where invoice_id = p_invoice_id and cancelled_at is null) then
      raise exception 'This edit leaves Rs.% overpaid, but the invoice has a refund recorded against it. Cancel the refund first, then edit.', v_excess;
    end if;
    if is_day_closed(ist_date(now())) then
      raise exception 'This edit leaves Rs.% overpaid, which must be moved to patient credit today, but today is already closed. An Administrator must reopen today first.', v_excess;
    end if;
    for v_alloc in
      select pa.id, pa.amount, pa.payment_id, p.receipt_number, p.payment_type
        from payment_allocations pa join payments p on p.id = pa.payment_id
       where pa.invoice_id = p_invoice_id and pa.amount > 0
       order by p.collected_at desc, pa.id desc
    loop
      exit when v_excess <= 0;
      v_take := least(v_alloc.amount, v_excess);
      if v_alloc.payment_type = 'advance_adjustment' then
        -- credit application: shrink it (or remove it) and give the credit back (041)
        perform release_credit_application(v_alloc.payment_id, p_invoice_id, v_take,
          'Excess from edit of ' || coalesce(inv.invoice_number, 'invoice') || ' returned to credit');
      else
        if v_take = v_alloc.amount then
          delete from payment_allocations where id = v_alloc.id;
        else
          update payment_allocations set amount = amount - v_take where id = v_alloc.id;
        end if;
        insert into patient_ledger (patient_id, payment_id, entry_type, amount, remarks, recorded_by)
        values (inv.patient_id, v_alloc.payment_id, 'Advance Collected', v_take,
                'Excess from edit of ' || coalesce(inv.invoice_number, 'invoice') || ' (receipt ' || coalesce(v_alloc.receipt_number, '-') || ') kept as patient credit',
                auth.uid());
      end if;
      v_credit_moves := v_credit_moves || jsonb_build_object('receipt', coalesce(v_alloc.receipt_number, 'Credit application'), 'amount', v_take);
      v_credited := v_credited + v_take;
      v_excess := v_excess - v_take;
    end loop;
    if v_excess > 0 then
      raise exception 'Could not move the overpaid amount to patient credit (Rs.% left). Nothing was saved.', v_excess;
    end if;
    inv := sync_invoice_paid(p_invoice_id);
  end if;

  -- 6. Permanent history -----------------------------------------------------
  v_after := invoice_edit_snapshot(p_invoice_id)
             || jsonb_build_object('credited_to_patient', v_credited,
                                   'credit_moves', v_credit_moves,
                                   'discount_reasons', v_disc_reasons,
                                   'side_effects', v_side_effects);
  insert into billing_audit_log (entity_type, entity_id, entity_ref, action, reason, before_data, after_data, changed_by)
  values ('invoice', p_invoice_id, inv.invoice_number, 'invoice_edited', trim(p_reason), v_before, v_after, auth.uid());

  return inv;
end;
$$;

create or replace function public.change_invoice_date(p_invoice_id uuid, p_new_date date, p_reason text)
returns invoices
language plpgsql
security definer
set search_path = public
as $$
declare
  inv invoices;
  v_old_date date;
  v_visit_date date;
  v_visit_no text;
begin
  if not exists (select 1 from profiles where id = auth.uid() and designation = 'Administrator') then
    raise exception 'Only an Administrator can change an invoice date.';
  end if;
  if p_reason is null or trim(p_reason) = '' then
    raise exception 'A reason is required to change an invoice date.';
  end if;
  if p_new_date is null then
    raise exception 'Choose the new date.';
  end if;

  select * into inv from invoices where id = p_invoice_id for update;
  if inv is null then raise exception 'Invoice not found.'; end if;
  if inv.status in ('Cancelled', 'Void') then
    raise exception 'This invoice is % and cannot be changed.', lower(inv.status);
  end if;

  v_old_date := ist_date(inv.created_at);
  if p_new_date = v_old_date then
    raise exception 'The invoice is already dated %.', to_char(p_new_date, 'DD Mon YYYY');
  end if;
  if p_new_date > ist_date(now()) then
    raise exception 'An invoice cannot be dated in the future.';
  end if;
  -- a bill cannot be dated before the visit it belongs to (041)
  if inv.visit_id is not null then
    select ist_date(created_at), visit_number into v_visit_date, v_visit_no from visits where id = inv.visit_id;
    if v_visit_date is not null and p_new_date < v_visit_date then
      raise exception 'This invoice belongs to visit % dated %. It cannot be dated before the visit.',
        coalesce(v_visit_no, '-'), to_char(v_visit_date, 'DD Mon YYYY');
    end if;
  end if;
  if is_day_closed(v_old_date) then
    raise exception '% (current invoice date) is closed. Reopen it in Cash Management first.', to_char(v_old_date, 'DD Mon YYYY');
  end if;
  if is_day_closed(p_new_date) then
    raise exception '% (new date) is closed. Reopen it in Cash Management first.', to_char(p_new_date, 'DD Mon YYYY');
  end if;

  -- keep the original time of day, move the calendar date (IST)
  update invoices
     set created_at = ((p_new_date + (inv.created_at at time zone 'Asia/Kolkata')::time) at time zone 'Asia/Kolkata')
   where id = p_invoice_id
  returning * into inv;

  insert into billing_audit_log (entity_type, entity_id, entity_ref, action, reason, before_data, after_data, changed_by)
  values ('invoice', p_invoice_id, inv.invoice_number, 'invoice_date_changed', trim(p_reason),
          jsonb_build_object('date', v_old_date), jsonb_build_object('date', p_new_date), auth.uid());

  return inv;
end;
$$;

create or replace function public.billing_reconciliation()
returns table (check_name text, reference text, expected numeric, actual numeric)
language sql stable
as $$
  with alloc as (select invoice_id, sum(amount) s from payment_allocations group by 1),
       refs  as (select invoice_id, sum(amount) s from payment_refunds where cancelled_at is null group by 1),
       lines as (select invoice_id, sum(net) s from invoice_line_items group by 1),
       palloc as (select payment_id, sum(amount) s from payment_allocations group by 1),
       pcred as (select payment_id, sum(amount) s from patient_ledger
                  where entry_type in ('Advance Collected', 'Correction: Credit Added', 'Correction: Credit Removed')
                    and payment_id is not null group by 1)
  select 'invoice_total_vs_lines', i.invoice_number, round(coalesce(l.s, 0), 2), round(i.net, 2)
    from invoices i left join lines l on l.invoice_id = i.id
   where round(i.net, 2) <> round(coalesce(l.s, 0), 2)
  union all
  select 'invoice_paid_vs_payments', i.invoice_number, round(coalesce(a.s, 0) - coalesce(r.s, 0), 2), round(i.paid, 2)
    from invoices i left join alloc a on a.invoice_id = i.id left join refs r on r.invoice_id = i.id
   where round(i.paid, 2) <> round(coalesce(a.s, 0) - coalesce(r.s, 0), 2)
  union all
  select 'invoice_status', i.invoice_number || ' (' || i.status || ')', null, null
    from invoices i
   where i.status not in ('Cancelled', 'Void')
     and exists (select 1 from invoice_line_items li where li.invoice_id = i.id)
     and i.status <> case when i.net <= 0 then 'Paid' when i.paid <= 0 then 'Pending'
                          when i.paid >= i.net then 'Paid' else 'Partial' end
  union all
  select 'payment_modes_vs_total', p.receipt_number, round(p.total_amount, 2),
         round(coalesce((select sum(amount) from payment_modes m where m.payment_id = p.id), 0), 2)
    from payments p
   where p.payment_type not in ('credit_note', 'advance_adjustment')
     and round(p.total_amount, 2) <> round(coalesce((select sum(amount) from payment_modes m where m.payment_id = p.id), 0), 2)
  union all
  select 'payment_applied_plus_credit', p.receipt_number, round(p.total_amount, 2),
         round(coalesce(pa.s, 0) + coalesce(pc.s, 0), 2)
    from payments p left join palloc pa on pa.payment_id = p.id left join pcred pc on pc.payment_id = p.id
   where p.payment_type in ('invoice_payment', 'advance')
     and round(p.total_amount, 2) <> round(coalesce(pa.s, 0) + coalesce(pc.s, 0), 2)
  union all
  select 'credit_application_vs_applied', coalesce(p.receipt_number, p.id::text), round(p.total_amount, 2), round(coalesce(pa.s, 0), 2)
    from payments p left join palloc pa on pa.payment_id = p.id
   where p.payment_type = 'advance_adjustment'
     and round(p.total_amount, 2) <> round(coalesce(pa.s, 0), 2)
  union all
  select 'negative_patient_credit', l.patient_id::text, 0, round(sum(l.amount), 2)
    from patient_ledger l group by l.patient_id having sum(l.amount) < 0;
$$;

-- 6. Tidy: credit applications left empty by the earlier void (Training has
-- one, production none). Same outcome as "Remove credit application".
do $$
declare
  r record;
begin
  for r in
    select p.id from payments p
     where p.payment_type = 'advance_adjustment'
       and not exists (select 1 from payment_allocations a where a.payment_id = p.id)
       and coalesce((select sum(amount) from patient_ledger l where l.payment_id = p.id), 0) = 0
  loop
    insert into billing_audit_log (entity_type, entity_id, entity_ref, action, reason, before_data, after_data, changed_by)
    values ('payment', r.id, 'Credit application', 'credit_application_removed',
            'Tidy-up: left empty by an invoice void before fix 041', payment_edit_snapshot(r.id),
            jsonb_build_object('tidy', true), null);
    update patient_ledger set payment_id = null, remarks = coalesce(remarks, '') || ' [credit application removed]'
     where payment_id = r.id;
    delete from payments where id = r.id;
  end loop;
end $$;

revoke execute on function public.release_credit_application(uuid, uuid, numeric, text) from public, anon, authenticated;
revoke execute on function public.void_invoice(uuid, text, numeric) from public, anon;
grant  execute on function public.void_invoice(uuid, text, numeric) to authenticated;
revoke execute on function public.edit_invoice(uuid, jsonb, text, numeric) from public, anon;
grant  execute on function public.edit_invoice(uuid, jsonb, text, numeric) to authenticated;
revoke execute on function public.change_invoice_date(uuid, date, text) from public, anon;
grant  execute on function public.change_invoice_date(uuid, date, text) to authenticated;
