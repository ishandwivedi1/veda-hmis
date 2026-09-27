-- ============================================================================
-- 039 — Edit / delete payments (Zoho-style billing edits, Phase 3)
--
-- Rule verified on all 698 production payments (27 Sep 2026):
--   for invoice payments and advances,
--   amount received = amount applied to invoices + credit it left behind
--   (patient_ledger rows carrying this payment_id).
-- Everything here keeps that rule true, and billing_reconciliation() now
-- checks it.
--
-- Changes (both projects):
--   * patient_ledger entry types WIDENED (superset; every existing row still
--     valid): + 'Correction: Credit Added', 'Correction: Credit Removed'
--   * payment_edit_snapshot()  NEW
--   * edit_payment()           NEW  amount, date, modes, reference, remarks,
--                                   which invoices it pays; rest -> credit
--   * delete_payment()         NEW  invoice payment / advance: removed;
--                                   credit application: un-applied
--   * billing_reconciliation() REPLACED IN PLACE (same signature) with one
--                                   extra check: payment_applied_plus_credit
--
-- Guards: permission + closed day on the payment's date (and the new date),
-- today-only unless payment.edit_past, reason required, stale-screen check,
-- payments with an active refund are blocked, credit already spent elsewhere
-- cannot be taken back, invoices can never be over-paid.
-- Old ledger entries are never rewritten; corrections are new lines.
-- ============================================================================

-- 1. Ledger entry types (widen) ----------------------------------------------
alter table public.patient_ledger drop constraint patient_ledger_entry_type_check;
alter table public.patient_ledger add constraint patient_ledger_entry_type_check
  check (entry_type = any (array[
    'Advance Collected', 'Advance Adjusted', 'Advance Refunded', 'Credit Note Issued',
    'Correction: Credit Added', 'Correction: Credit Removed']));

-- 2. Snapshot ----------------------------------------------------------------
create function public.payment_edit_snapshot(p_payment_id uuid)
returns jsonb
language sql stable
as $$
  select jsonb_build_object(
    'receipt_number', p.receipt_number,
    'payment_type', p.payment_type,
    'advance_type', p.advance_type,
    'patient_id', p.patient_id,
    'total_amount', p.total_amount,
    'collected_at', p.collected_at,
    'date', ist_date(p.collected_at),
    'reference', p.reference,
    'remarks', p.remarks,
    'modes', coalesce((select jsonb_agg(jsonb_build_object('mode', m.mode, 'amount', m.amount) order by m.mode)
                         from payment_modes m where m.payment_id = p.id), '[]'::jsonb),
    'allocations', coalesce((select jsonb_agg(jsonb_build_object('invoice_id', a.invoice_id, 'invoice_number', i.invoice_number, 'amount', a.amount) order by i.invoice_number)
                               from payment_allocations a join invoices i on i.id = a.invoice_id where a.payment_id = p.id), '[]'::jsonb),
    'credit', coalesce((select sum(l.amount) from patient_ledger l
                         where l.payment_id = p.id
                           and l.entry_type in ('Advance Collected', 'Correction: Credit Added', 'Correction: Credit Removed')), 0)
  )
  from payments p where p.id = p_payment_id;
$$;

-- 3. Edit ---------------------------------------------------------------------
-- p_allocations: [ {"invoice_id": uuid, "amount": num}, ... ]  (ignored for advances)
create function public.edit_payment(
  p_payment_id uuid, p_amount numeric, p_date date, p_modes jsonb,
  p_reference text, p_remarks text, p_allocations jsonb, p_reason text, p_expected_amount numeric)
returns payments
language plpgsql
as $$
declare
  pay payments;
  v_before jsonb;
  v_after jsonb;
  v_old_date date;
  v_new_date date;
  v_mode jsonb;
  v_modes_sum numeric := 0;
  v_alloc jsonb;
  v_alloc_total numeric := 0;
  v_inv invoices;
  v_other numeric;
  v_old_credit numeric;
  v_new_credit numeric;
  v_delta numeric;
  v_ids uuid[];
  v_id uuid;
  v_old_modes jsonb;
begin
  if p_reason is null or trim(p_reason) = '' then
    raise exception 'A reason is required to edit a payment.';
  end if;

  select * into pay from payments where id = p_payment_id for update;
  if pay is null then raise exception 'Payment not found.'; end if;
  if pay.payment_type = 'advance_adjustment' then
    raise exception 'This is an application of existing credit, not money received. To undo it, use Remove; to apply credit differently, use Apply Advance.';
  end if;
  if pay.payment_type not in ('invoice_payment', 'advance') then
    raise exception 'Credit notes and refunds cannot be edited here. Cancel them from their own screen instead.';
  end if;

  v_old_date := ist_date(pay.collected_at);
  v_new_date := coalesce(p_date, v_old_date);
  perform assert_billing_edit_allowed('payment.edit', v_old_date);
  if v_new_date <> v_old_date then
    if v_new_date > ist_date(now()) then
      raise exception 'A payment cannot be dated in the future.';
    end if;
    perform assert_billing_edit_allowed('payment.edit', v_new_date);
  end if;

  if p_expected_amount is not null and round(pay.total_amount, 2) <> round(p_expected_amount, 2) then
    raise exception 'This payment was changed by someone else since you opened it (amount is now Rs.%). Close and reopen it, then try again.', pay.total_amount;
  end if;

  if exists (select 1 from payment_refunds where payment_id = p_payment_id and cancelled_at is null) then
    raise exception 'This payment has a refund recorded against it. Cancel that refund first (Payments > Refund), then edit the payment.';
  end if;

  if p_amount is null or p_amount <= 0 then
    raise exception 'Amount must be greater than zero. To remove the payment entirely, use Delete.';
  end if;

  -- modes must add up to the amount
  if p_modes is null or jsonb_array_length(p_modes) = 0 then
    raise exception 'Enter at least one payment mode.';
  end if;
  for v_mode in select * from jsonb_array_elements(p_modes) loop
    if coalesce((v_mode->>'amount')::numeric, 0) <= 0 or coalesce(trim(v_mode->>'mode'), '') = '' then
      raise exception 'Every payment mode needs a name and an amount above zero.';
    end if;
    v_modes_sum := v_modes_sum + (v_mode->>'amount')::numeric;
  end loop;
  if round(v_modes_sum, 2) <> round(p_amount, 2) then
    raise exception 'Payment modes (Rs.%) must add up to the amount (Rs.%).', v_modes_sum, p_amount;
  end if;

  v_before := payment_edit_snapshot(p_payment_id);

  -- invoices affected = old ones + new ones
  select coalesce(array_agg(invoice_id), '{}') into v_ids from payment_allocations where payment_id = p_payment_id;

  if pay.payment_type = 'advance' then
    if p_allocations is not null and jsonb_array_length(p_allocations) > 0 then
      raise exception 'An advance stays as patient credit. Use Apply Advance to put it against a bill.';
    end if;
    if jsonb_array_length(v_before->'allocations') > 0 then
      raise exception 'This advance has invoice applications recorded on it directly; it cannot be edited here. Contact support.';
    end if;
  else
    -- validate new applications
    for v_alloc in select * from jsonb_array_elements(coalesce(p_allocations, '[]'::jsonb)) loop
      if coalesce((v_alloc->>'amount')::numeric, 0) < 0 then
        raise exception 'Applied amounts cannot be negative.';
      end if;
      continue when coalesce((v_alloc->>'amount')::numeric, 0) = 0;
      select * into v_inv from invoices where id = (v_alloc->>'invoice_id')::uuid for update;
      if v_inv is null then raise exception 'An invoice in this payment no longer exists. Close and reopen, then try again.'; end if;
      if v_inv.patient_id <> pay.patient_id then raise exception 'A payment can only be applied to the same patient''s invoices.'; end if;
      if v_inv.status in ('Cancelled', 'Void') then
        raise exception '% is % and cannot receive payments.', v_inv.invoice_number, lower(v_inv.status);
      end if;
      if not ((v_alloc->>'invoice_id')::uuid = any (v_ids)) then
        v_ids := v_ids || (v_alloc->>'invoice_id')::uuid;
      end if;
      -- what everyone else has paid on this invoice (net of their refunds)
      select coalesce((select sum(amount) from payment_allocations where invoice_id = v_inv.id and payment_id <> p_payment_id), 0)
           - coalesce((select sum(amount) from payment_refunds where invoice_id = v_inv.id and cancelled_at is null), 0)
        into v_other;
      if round((v_alloc->>'amount')::numeric, 2) > round(v_inv.net - v_other, 2) then
        raise exception '% only has Rs.% left to pay; Rs.% was applied.', v_inv.invoice_number, round(v_inv.net - v_other, 2), (v_alloc->>'amount')::numeric;
      end if;
      v_alloc_total := v_alloc_total + (v_alloc->>'amount')::numeric;
    end loop;
    if (select count(distinct x->>'invoice_id') from jsonb_array_elements(coalesce(p_allocations, '[]'::jsonb)) x)
       <> jsonb_array_length(coalesce(p_allocations, '[]'::jsonb)) then
      raise exception 'The same invoice is listed twice.';
    end if;
    if round(v_alloc_total, 2) > round(p_amount, 2) then
      raise exception 'Rs.% is applied to invoices but the payment is only Rs.%.', v_alloc_total, p_amount;
    end if;
  end if;

  -- credit left behind by this payment
  v_old_credit := coalesce((v_before->>'credit')::numeric, 0);
  v_new_credit := p_amount - v_alloc_total;
  v_delta := round(v_new_credit - v_old_credit, 2);
  if v_delta < 0 and round(get_advance_balance(pay.patient_id) + v_delta, 2) < 0 then
    raise exception 'This change takes back Rs.% of patient credit, but only Rs.% is still unused (the rest was already applied to other bills). Remove those credit applications first.',
      -v_delta, get_advance_balance(pay.patient_id);
  end if;

  -- apply ------------------------------------------------------------------
  select coalesce(jsonb_agg(jsonb_build_object('mode', mode, 'amount', amount)), '[]'::jsonb) into v_old_modes
    from payment_modes where payment_id = p_payment_id;
  delete from payment_modes where payment_id = p_payment_id;
  for v_mode in select * from jsonb_array_elements(p_modes) loop
    insert into payment_modes (payment_id, mode, amount) values (p_payment_id, trim(v_mode->>'mode'), (v_mode->>'amount')::numeric);
  end loop;

  delete from payment_allocations where payment_id = p_payment_id;
  if pay.payment_type = 'invoice_payment' then
    for v_alloc in select * from jsonb_array_elements(coalesce(p_allocations, '[]'::jsonb)) loop
      continue when coalesce((v_alloc->>'amount')::numeric, 0) = 0;
      insert into payment_allocations (payment_id, invoice_id, amount)
      values (p_payment_id, (v_alloc->>'invoice_id')::uuid, (v_alloc->>'amount')::numeric);
    end loop;
  end if;

  if v_delta <> 0 then
    insert into patient_ledger (patient_id, payment_id, entry_type, amount, remarks, recorded_by)
    values (pay.patient_id, p_payment_id,
            case when v_delta > 0 then 'Correction: Credit Added' else 'Correction: Credit Removed' end,
            v_delta,
            'Receipt ' || coalesce(pay.receipt_number, '-') || ' edited: ' || trim(p_reason),
            auth.uid());
  end if;

  update payments
     set total_amount = p_amount,
         collected_at = ((v_new_date + (pay.collected_at at time zone 'Asia/Kolkata')::time) at time zone 'Asia/Kolkata'),
         reference = nullif(trim(coalesce(p_reference, '')), ''),
         remarks = nullif(trim(coalesce(p_remarks, '')), '')
   where id = p_payment_id
  returning * into pay;

  foreach v_id in array v_ids loop
    v_inv := sync_invoice_paid(v_id);
    if round(v_inv.paid, 2) > round(v_inv.net, 2) then
      raise exception '% would be over-paid. Nothing was saved.', v_inv.invoice_number;
    end if;
  end loop;

  -- keep the older per-payment edit log in step (Receipt Register used it)
  insert into payment_edits (payment_id, old_reference, new_reference, old_remarks, new_remarks, old_modes, new_modes, old_amount, new_amount, reason, edited_by)
  values (p_payment_id, v_before->>'reference', pay.reference, v_before->>'remarks', pay.remarks,
          v_old_modes, p_modes,
          case when round((v_before->>'total_amount')::numeric, 2) <> round(p_amount, 2) then (v_before->>'total_amount')::numeric end,
          case when round((v_before->>'total_amount')::numeric, 2) <> round(p_amount, 2) then p_amount end,
          trim(p_reason), auth.uid());

  v_after := payment_edit_snapshot(p_payment_id) || jsonb_build_object('credit_change', v_delta);
  insert into billing_audit_log (entity_type, entity_id, entity_ref, action, reason, before_data, after_data, changed_by)
  values ('payment', p_payment_id, pay.receipt_number, 'payment_edited', trim(p_reason), v_before, v_after, auth.uid());

  return pay;
end;
$$;

-- 4. Delete / un-apply --------------------------------------------------------
create function public.delete_payment(p_payment_id uuid, p_reason text, p_expected_amount numeric)
returns jsonb
language plpgsql
as $$
declare
  pay payments;
  v_before jsonb;
  v_ids uuid[];
  v_id uuid;
  v_credit numeric;
  v_side jsonb := '[]'::jsonb;
  v_n integer;
  l record;
begin
  if p_reason is null or trim(p_reason) = '' then
    raise exception 'A reason is required to delete a payment.';
  end if;

  select * into pay from payments where id = p_payment_id for update;
  if pay is null then raise exception 'Payment not found.'; end if;
  if pay.payment_type not in ('invoice_payment', 'advance', 'advance_adjustment') then
    raise exception 'Credit notes and refunds cannot be deleted here. Cancel them from their own screen instead.';
  end if;

  perform assert_billing_edit_allowed('payment.delete', ist_date(pay.collected_at));

  if p_expected_amount is not null and round(pay.total_amount, 2) <> round(p_expected_amount, 2) then
    raise exception 'This payment was changed by someone else since you opened it. Close and reopen it, then try again.';
  end if;
  if exists (select 1 from payment_refunds where payment_id = p_payment_id and cancelled_at is null) then
    raise exception 'This payment has a refund recorded against it. Cancel that refund first (Payments > Refund).';
  end if;

  v_before := payment_edit_snapshot(p_payment_id);
  select coalesce(array_agg(invoice_id), '{}') into v_ids from payment_allocations where payment_id = p_payment_id;

  -- credit this payment created must still be unused
  v_credit := coalesce((v_before->>'credit')::numeric, 0);
  if v_credit > 0 and round(get_advance_balance(pay.patient_id) - v_credit, 2) < 0 then
    raise exception 'Rs.% of credit from this payment was already applied to other bills (only Rs.% unused). Remove those credit applications first.',
      v_credit, get_advance_balance(pay.patient_id);
  end if;

  -- ledger: keep every old line, detach it from the receipt being deleted,
  -- and add one reversing correction line per entry
  for l in select * from patient_ledger where payment_id = p_payment_id loop
    update patient_ledger set payment_id = null,
           remarks = coalesce(remarks, '') || ' [receipt ' || coalesce(pay.receipt_number, 'credit application') || ' deleted]'
     where id = l.id;
    insert into patient_ledger (patient_id, payment_id, entry_type, amount, remarks, recorded_by)
    values (l.patient_id, null,
            case when -l.amount > 0 then 'Correction: Credit Added' else 'Correction: Credit Removed' end,
            -l.amount,
            case when pay.payment_type = 'advance_adjustment'
                 then 'Credit application removed (' || coalesce((select string_agg(x->>'invoice_number', ', ') from jsonb_array_elements(v_before->'allocations') x), '-') || '): ' || trim(p_reason)
                 else 'Receipt ' || coalesce(pay.receipt_number, '-') || ' deleted: ' || trim(p_reason) end,
            auth.uid());
  end loop;

  update surgical_cases set advance_payment_id = null where advance_payment_id = p_payment_id;
  get diagnostics v_n = row_count;
  if v_n > 0 then
    v_side := v_side || jsonb_build_object('effect', 'surgical_case_advance_unlinked', 'count', v_n);
  end if;

  -- modes, applications and the older edit log cascade with the payment;
  -- the full record is kept in v_before below
  v_before := v_before || jsonb_build_object(
    'older_edits', coalesce((select jsonb_agg(to_jsonb(e) - 'payment_id') from payment_edits e where e.payment_id = p_payment_id), '[]'::jsonb));
  delete from payments where id = p_payment_id;
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    raise exception 'The payment could not be deleted. Nothing was changed.';
  end if;

  foreach v_id in array v_ids loop
    perform sync_invoice_paid(v_id);
  end loop;

  insert into billing_audit_log (entity_type, entity_id, entity_ref, action, reason, before_data, after_data, changed_by)
  values ('payment', p_payment_id, coalesce(pay.receipt_number, 'Credit application'),
          case when pay.payment_type = 'advance_adjustment' then 'credit_application_removed' else 'payment_deleted' end,
          trim(p_reason), v_before, jsonb_build_object('side_effects', v_side), auth.uid());

  return jsonb_build_object('deleted', true, 'receipt_number', pay.receipt_number, 'invoices', to_jsonb(v_ids));
end;
$$;

-- 5. Reconciliation: add the payment rule (same signature, replaced in place) --
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
  select 'negative_patient_credit', l.patient_id::text, 0, round(sum(l.amount), 2)
    from patient_ledger l group by l.patient_id having sum(l.amount) < 0;
$$;

-- 6. Run as owner (see 038b): payments have no DELETE row-security policy by
-- design; deletes happen only through these gated functions. All checks
-- inside still use the signed-in user.
alter function public.edit_payment(uuid, numeric, date, jsonb, text, text, jsonb, text, numeric) security definer;
alter function public.edit_payment(uuid, numeric, date, jsonb, text, text, jsonb, text, numeric) set search_path = public;
alter function public.delete_payment(uuid, text, numeric) security definer;
alter function public.delete_payment(uuid, text, numeric) set search_path = public;
revoke execute on function public.edit_payment(uuid, numeric, date, jsonb, text, text, jsonb, text, numeric) from public, anon;
grant  execute on function public.edit_payment(uuid, numeric, date, jsonb, text, text, jsonb, text, numeric) to authenticated;
revoke execute on function public.delete_payment(uuid, text, numeric) from public, anon;
grant  execute on function public.delete_payment(uuid, text, numeric) to authenticated;
