-- ============================================================================
-- 037 — Edit Invoice (Zoho-style billing edits, Phase 2)
--
-- PURELY ADDITIVE: three new functions. No existing function, table, policy
-- or row is altered by this migration. Uses CREATE (not CREATE OR REPLACE)
-- so it fails loudly instead of creating a second overload.
--
--   invoice_line_lock_reason(line)  why a line can't be edited (NULL = editable)
--   invoice_edit_snapshot(invoice)  totals + lines as jsonb, for before/after history
--   edit_invoice(...)               the one entry point for editing an issued invoice
--
-- Rules agreed with Ishan (27 Sep 2026):
--   * gate: assert_billing_edit_allowed('invoice.edit', <invoice date>) —
--     permission, today-only unless 'invoice.edit_past', closed day = locked
--   * a reason is always required; full before/after kept in billing_audit_log
--   * Pharmacy lines (stock was deducted) and surgery-package lines (linked to
--     the surgical case) cannot be changed or removed here
--   * new items come only from master_services (no drugs, no packages)
--   * the rate always comes from the catalog; staff change qty / discount
--   * if the new total is less than what was already paid, the excess is
--     un-applied from the most recent payment(s) and kept as patient credit
--     (patient_ledger 'Advance Collected'); no cash moves, so cash reports
--     (which read payments) are unaffected
--
-- Apply to BOTH Supabase projects (production + training).
-- ============================================================================

create function public.invoice_line_lock_reason(p_line invoice_line_items)
returns text
language sql stable
as $$
  select case
    when p_line.dept = 'Pharmacy'
      then 'Pharmacy items change stock and cannot be edited here.'
    when p_line.service_code is not null
     and exists (select 1 from master_packages mp where mp.code = p_line.service_code)
      then 'Surgery package items are linked to the surgical case and cannot be edited here.'
    else null
  end;
$$;

create function public.invoice_edit_snapshot(p_invoice_id uuid)
returns jsonb
language sql stable
as $$
  select jsonb_build_object(
    'invoice_number', i.invoice_number,
    'status', i.status,
    'gross', i.gross, 'gst', i.gst, 'net', i.net, 'paid', i.paid,
    'lines', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', l.id, 'service_code', l.service_code, 'service_name', l.service_name,
               'dept', l.dept, 'qty', l.qty, 'rate', l.rate, 'disc', l.disc,
               'gst_amount', l.gst_amount, 'net', l.net) order by l.service_name, l.id)
      from invoice_line_items l where l.invoice_id = i.id), '[]'::jsonb)
  )
  from invoices i where i.id = p_invoice_id;
$$;

-- p_changes:
-- {
--   "update": [ {"id": uuid, "qty": int, "disc_type": "none|pct|fixed", "disc_value": num, "disc_reason": text} ],
--   "remove": [ uuid, ... ],
--   "add":    [ {"service_code": text, "qty": int, "disc_type": ..., "disc_value": ..., "disc_reason": ...} ]
-- }
-- p_expected_net: the net total the user saw when they opened the editor;
-- if the invoice changed since, the edit is refused ("refresh and try again").
create function public.edit_invoice(p_invoice_id uuid, p_changes jsonb, p_reason text, p_expected_net numeric)
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
    delete from invoice_line_items where id = v_line.id;
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
      continue;  -- nothing actually changed on this line
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

  -- 3. Additions (catalog services only; never drugs or packages) -------------
  for v_item in select * from jsonb_array_elements(coalesce(p_changes->'add', '[]'::jsonb)) loop
    if not exists (select 1 from master_services
                    where code = v_item->>'service_code' and status = 'Active' and dept <> 'Pharmacy') then
      raise exception 'Only active hospital services can be added when editing. Medicines and surgery packages are billed from Pharmacy / Surgical Journey.';
    end if;
    if coalesce(v_item->>'disc_type', 'none') <> 'none' and coalesce(trim(v_item->>'disc_reason'), '') <> '' then
      v_disc_reasons := v_disc_reasons || jsonb_build_object('service', v_item->>'service_code', 'reason', trim(v_item->>'disc_reason'));
    end if;
    -- existing, proven function: validates the discount reason, prices from
    -- the catalog and recomputes invoice totals
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
      -- paid is net of refunds, so allocations always cover it; defensive only
      raise exception 'Could not move the overpaid amount to patient credit (Rs.% left). Nothing was saved.', v_excess;
    end if;
    inv := sync_invoice_paid(p_invoice_id);
  end if;

  -- 6. Permanent history -----------------------------------------------------
  v_after := invoice_edit_snapshot(p_invoice_id)
             || jsonb_build_object('credited_to_patient', v_credited,
                                   'credit_moves', v_credit_moves,
                                   'discount_reasons', v_disc_reasons);
  insert into billing_audit_log (entity_type, entity_id, entity_ref, action, reason, before_data, after_data, changed_by)
  values ('invoice', p_invoice_id, inv.invoice_number, 'invoice_edited', trim(p_reason), v_before, v_after, auth.uid());

  return inv;
end;
$$;
