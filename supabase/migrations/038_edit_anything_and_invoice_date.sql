-- ============================================================================
-- 038 — Edit anything on an invoice + Administrator invoice-date change
--
-- Decision by Ishan (27 Sep 2026): the old "original items are locked" rules
-- go. Anything can be added or removed through the new, permission-gated,
-- fully-audited edit.
--
-- Changes (both projects):
--   * invoice_line_lock_reason()  REPLACED IN PLACE (identical signature,
--       verified single version). Now only locks a pharmacy line whose
--       prescription(s) actually had stock deducted (none in production
--       today; stock tracking has not been used yet).
--   * edit_invoice()  REPLACED IN PLACE (identical signature, verified single
--       version). Differences from 037:
--       - add: any catalog item (services, medicines, packages) exactly as
--         the old Invoice Modification tab allowed, via add_invoice_line_item()
--       - removing a medicine line releases its prescription(s):
--         billing_status -> 'Pending', invoice links cleared, note added.
--         (Needed anyway: prescriptions.invoice_line_item_id has a foreign key,
--         so the line could not otherwise be deleted.)
--       - removing a surgery-package line marks the surgical case (and case
--         procedures) as not billed again, if no other line on the invoice
--         still carries that package
--       - side effects recorded in the audit entry
--   * change_invoice_date()  NEW. Administrator only; both days must be open;
--       not in the future; reason required; audited.
-- ============================================================================

create or replace function public.invoice_line_lock_reason(p_line invoice_line_items)
returns text
language sql stable
as $$
  select case
    when p_line.dept = 'Pharmacy'
     and exists (select 1 from prescriptions rx
                   join inventory_movements m on m.reference_id = rx.id
                  where rx.invoice_line_item_id = p_line.id)
      then 'Stock was deducted for this medicine. Return it in Inventory first.'
    else null
  end;
$$;

create or replace function public.edit_invoice(p_invoice_id uuid, p_changes jsonb, p_reason text, p_expected_net numeric)
returns invoices
language plpgsql
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
        select count(*), (array_agg(id))[1] into v_n, v_case_id from surgical_cases
         where patient_id = inv.patient_id and package_id = v_pkg_id and package_billed and billed_invoice_id is null;
        if v_n = 1 then
          update surgical_cases set package_billed = false where id = v_case_id;
        else
          v_n := 0;
        end if;
      end if;
      v_side_effects := v_side_effects || jsonb_build_object(
        'effect', case when v_n > 0 then 'surgical_case_unbilled' else 'surgical_case_not_found' end,
        'service', v_line.service_name, 'count', v_n);
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
    if is_day_closed(ist_date(now())) then
      raise exception 'This edit leaves Rs.% overpaid, which must be moved to patient credit today, but today is already closed. An Administrator must reopen today first.', v_excess;
    end if;
    for v_alloc in
      select pa.id, pa.amount, pa.payment_id, p.receipt_number
        from payment_allocations pa join payments p on p.id = pa.payment_id
       where pa.invoice_id = p_invoice_id and pa.amount > 0
       order by p.collected_at desc, pa.id desc
    loop
      exit when v_excess <= 0;
      v_take := least(v_alloc.amount, v_excess);
      if v_take = v_alloc.amount then
        delete from payment_allocations where id = v_alloc.id;
      else
        update payment_allocations set amount = amount - v_take where id = v_alloc.id;
      end if;
      insert into patient_ledger (patient_id, payment_id, entry_type, amount, remarks, recorded_by)
      values (inv.patient_id, v_alloc.payment_id, 'Advance Collected', v_take,
              'Excess from edit of ' || coalesce(inv.invoice_number, 'invoice') || ' (receipt ' || coalesce(v_alloc.receipt_number, '-') || ') kept as patient credit',
              auth.uid());
      v_credit_moves := v_credit_moves || jsonb_build_object('receipt', v_alloc.receipt_number, 'amount', v_take);
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

create function public.change_invoice_date(p_invoice_id uuid, p_new_date date, p_reason text)
returns invoices
language plpgsql
as $$
declare
  inv invoices;
  v_old_date date;
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
