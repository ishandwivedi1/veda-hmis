-- 051: Zoho-style editing for invoices and payments.
--
-- Decided (Ishan, 2 Oct 2026):
--  * Anyone with the edit right ("Edit invoices" / "Edit payments") can edit
--    a transaction of ANY date -- the extra "earlier days" rights and the
--    Administrator-only invoice-date change are gone. Closed cash days stay
--    locked (an Administrator reopens the day in Cash Management first).
--  * Invoice: every field editable -- date, item description, price (rate),
--    quantity, discount, add / remove items. No separate discount reason;
--    the one edit reason (asked in a popup) is recorded with the change.
--  * Paid invoices (Zoho rule): an edit cannot bring the total below what
--    has already been paid -- adjust or remove the payment first. (Before,
--    the excess was moved to patient credit automatically.)
--  * Payments: unchanged rules (every field editable; applied amount can't
--    exceed the payment), now any date too.
--  * Every edit still writes billing_audit_log with full before/after.
--
-- Same function signatures as before (no new overloads).

-- 1. Edit rights: edit right + day not closed. No "today only" rule.
create or replace function public.assert_billing_edit_allowed(p_action text, p_txn_date date)
returns void
language plpgsql
stable
as $function$
declare
  v_labels constant jsonb := jsonb_build_object(
    'invoice.edit', 'edit invoices', 'invoice.void', 'void invoices',
    'payment.edit', 'edit payments', 'payment.delete', 'delete payments');
begin
  if p_action not in ('invoice.edit', 'invoice.void', 'payment.edit', 'payment.delete') then
    raise exception 'Unknown billing action: %', p_action;
  end if;
  if is_day_closed(p_txn_date) then
    raise exception '% is closed for financial reconciliation. An Administrator must reopen it in Cash Management first.',
      to_char(p_txn_date, 'DD Mon YYYY');
  end if;
  if not has_billing_permission(p_action) then
    raise exception 'You do not have permission to %. Ask an Administrator.', v_labels->>p_action;
  end if;
end;
$function$;

-- 2. Edit an invoice. p_changes:
--   { "date": "YYYY-MM-DD" (optional),
--     "remove": [line_id, ...],
--     "update": [{ "id", "service_name"?, "rate"?, "qty"?, "disc_type"?, "disc_value"? }],
--     "add":    [{ "service_code", "service_name"?, "rate"?, "qty"?, "disc_type"?, "disc_value"? }] }
create or replace function public.edit_invoice(p_invoice_id uuid, p_changes jsonb, p_reason text, p_expected_net numeric)
returns invoices
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  inv invoices;
  v_before jsonb;
  v_after jsonb;
  v_item jsonb;
  v_line invoice_line_items;
  v_lock text;
  v_name text;
  v_rate numeric;
  v_qty integer;
  v_disc_type text;
  v_disc_value numeric;
  v_gross numeric;
  v_disc numeric;
  v_gst numeric;
  v_changed integer := 0;
  v_side_effects jsonb := '[]'::jsonb;
  v_pkg_id uuid;
  v_n integer;
  v_n2 integer;
  v_case_id uuid;
  v_old_date date;
  v_new_date date;
  v_visit_date date;
  v_visit_no text;
  v_existing uuid[];
  v_new_line uuid;
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

  v_old_date := ist_date(inv.created_at);
  perform assert_billing_edit_allowed('invoice.edit', v_old_date);

  if p_expected_net is not null and round(inv.net, 2) <> round(p_expected_net, 2) then
    raise exception 'This invoice was changed by someone else since you opened it (total is now Rs.%). Close and reopen it, then try again.', inv.net;
  end if;

  v_before := invoice_edit_snapshot(p_invoice_id) || jsonb_build_object('date', v_old_date);

  -- Date
  v_new_date := nullif(p_changes->>'date', '')::date;
  if v_new_date is not null and v_new_date <> v_old_date then
    if v_new_date > ist_date(now()) then
      raise exception 'An invoice cannot be dated in the future.';
    end if;
    if inv.visit_id is not null then
      select ist_date(created_at), visit_number into v_visit_date, v_visit_no from visits where id = inv.visit_id;
      if v_visit_date is not null and v_new_date < v_visit_date then
        raise exception 'This invoice belongs to visit % dated %. It cannot be dated before the visit.',
          coalesce(v_visit_no, '-'), to_char(v_visit_date, 'DD Mon YYYY');
      end if;
    end if;
    if is_day_closed(v_new_date) then
      raise exception '% (new date) is closed. An Administrator must reopen it in Cash Management first.', to_char(v_new_date, 'DD Mon YYYY');
    end if;
    update invoices
       set created_at = ((v_new_date + (inv.created_at at time zone 'Asia/Kolkata')::time) at time zone 'Asia/Kolkata')
     where id = p_invoice_id;
    v_changed := v_changed + 1;
  end if;

  -- Remove items
  for v_item in select * from jsonb_array_elements(coalesce(p_changes->'remove', '[]'::jsonb)) loop
    select * into v_line from invoice_line_items where id = (v_item #>> '{}')::uuid and invoice_id = p_invoice_id;
    if v_line is null then
      raise exception 'An item being removed is no longer on this invoice. Close and reopen it, then try again.';
    end if;
    v_lock := invoice_line_lock_reason(v_line);
    if v_lock is not null then
      raise exception '"%": %', v_line.service_name, v_lock;
    end if;

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
        select count(*), (array_agg(id))[1] into v_n2, v_case_id from surgical_cases
         where patient_id = inv.patient_id and package_id = v_pkg_id and package_billed and billed_invoice_id is null;
        if v_n2 = 1 then
          update surgical_cases set package_billed = false where id = v_case_id;
          v_n := 1;
        elsif v_n2 > 1 then
          v_side_effects := v_side_effects || jsonb_build_object('effect', 'surgical_case_ambiguous', 'service', v_line.service_name, 'count', v_n2);
        end if;
      end if;
      if v_n > 0 then
        v_side_effects := v_side_effects || jsonb_build_object('effect', 'surgical_case_unbilled', 'service', v_line.service_name, 'count', v_n);
      end if;
    end if;

    v_changed := v_changed + 1;
  end loop;

  -- Change items: description, price, quantity, discount
  for v_item in select * from jsonb_array_elements(coalesce(p_changes->'update', '[]'::jsonb)) loop
    select * into v_line from invoice_line_items where id = (v_item->>'id')::uuid and invoice_id = p_invoice_id;
    if v_line is null then
      raise exception 'An item being changed is no longer on this invoice. Close and reopen it, then try again.';
    end if;

    v_name := coalesce(nullif(trim(v_item->>'service_name'), ''), v_line.service_name);
    v_rate := coalesce((v_item->>'rate')::numeric, v_line.rate);
    v_qty := coalesce((v_item->>'qty')::integer, v_line.qty);
    v_disc_type := coalesce(v_item->>'disc_type', 'fixed');
    v_disc_value := coalesce((v_item->>'disc_value')::numeric, v_line.disc);
    if v_rate < 0 then
      raise exception '"%": price cannot be negative.', v_name;
    end if;
    if v_qty < 1 then
      raise exception '"%": quantity must be at least 1. To take the item off, remove it instead.', v_name;
    end if;
    if v_disc_type not in ('none', 'pct', 'fixed') or v_disc_value < 0 then
      raise exception '"%": invalid discount.', v_name;
    end if;

    v_gross := v_rate * v_qty;
    v_disc := case v_disc_type
                when 'pct'   then round(v_gross * least(v_disc_value, 100) / 100, 2)
                when 'fixed' then least(v_disc_value, v_gross)
                else 0 end;

    if v_name = v_line.service_name and round(v_rate, 2) = round(v_line.rate, 2)
       and v_qty = v_line.qty and round(v_disc, 2) = round(v_line.disc, 2) then
      continue;
    end if;

    -- a medicine whose stock was deducted: quantity stays (return it in Inventory first)
    if v_qty <> v_line.qty then
      v_lock := invoice_line_lock_reason(v_line);
      if v_lock is not null then
        raise exception '"%": %', v_line.service_name, v_lock;
      end if;
    end if;

    v_gst := round((v_gross - v_disc) * v_line.gst_pct / 100, 2);
    update invoice_line_items
       set service_name = v_name, rate = v_rate, qty = v_qty,
           gross = v_gross, disc = v_disc, gst_amount = v_gst, net = v_gross - v_disc + v_gst
     where id = v_line.id;
    v_changed := v_changed + 1;
  end loop;

  -- Add items (from the catalogue; price / description can be changed)
  for v_item in select * from jsonb_array_elements(coalesce(p_changes->'add', '[]'::jsonb)) loop
    select coalesce(array_agg(id), '{}') into v_existing from invoice_line_items where invoice_id = p_invoice_id;
    perform add_invoice_line_item(
      p_invoice_id,
      v_item->>'service_code',
      greatest(coalesce((v_item->>'qty')::integer, 1), 1),
      coalesce(v_item->>'disc_type', 'none'),
      coalesce((v_item->>'disc_value')::numeric, 0),
      trim(p_reason));  -- the edit reason covers any discount
    if nullif(trim(v_item->>'service_name'), '') is not null or v_item ? 'rate' then
      select * into v_line from invoice_line_items
       where invoice_id = p_invoice_id and not (id = any (v_existing)) limit 1;
      if v_line.id is not null then
        v_name := coalesce(nullif(trim(v_item->>'service_name'), ''), v_line.service_name);
        v_rate := coalesce((v_item->>'rate')::numeric, v_line.rate);
        if v_rate < 0 then
          raise exception '"%": price cannot be negative.', v_name;
        end if;
        v_gross := v_rate * v_line.qty;
        v_disc := case coalesce(v_item->>'disc_type', 'none')
                    when 'pct'   then round(v_gross * least(coalesce((v_item->>'disc_value')::numeric, 0), 100) / 100, 2)
                    when 'fixed' then least(coalesce((v_item->>'disc_value')::numeric, 0), v_gross)
                    else 0 end;
        v_gst := round((v_gross - v_disc) * v_line.gst_pct / 100, 2);
        update invoice_line_items
           set service_name = v_name, rate = v_rate, gross = v_gross, disc = v_disc, gst_amount = v_gst, net = v_gross - v_disc + v_gst
         where id = v_line.id;
      end if;
    end if;
    v_changed := v_changed + 1;
  end loop;

  if v_changed = 0 then
    raise exception 'Nothing was changed on this invoice.';
  end if;
  if not exists (select 1 from invoice_line_items where invoice_id = p_invoice_id) then
    raise exception 'An invoice must keep at least one item. To cancel the whole bill, use Cancel/Void instead.';
  end if;

  inv := sync_invoice_paid(p_invoice_id);

  -- Zoho rule: the total can't go below what's already been paid.
  if round(inv.paid, 2) > round(inv.net, 2) then
    raise exception 'The new total (Rs.%) is less than the Rs.% already paid on this invoice. Adjust or remove the payment first, then edit the invoice.',
      round(inv.net, 2), round(inv.paid, 2);
  end if;

  v_after := invoice_edit_snapshot(p_invoice_id)
             || jsonb_build_object('date', ist_date(inv.created_at), 'side_effects', v_side_effects);
  insert into billing_audit_log (entity_type, entity_id, entity_ref, action, reason, before_data, after_data, changed_by)
  values ('invoice', p_invoice_id, inv.invoice_number, 'invoice_edited', trim(p_reason), v_before, v_after, auth.uid());

  return inv;
end;
$function$;

-- 3. Everything the invoice Edit screen needs in ONE call (was 4 steps in a
--    row): invoice + lines, which lines are locked / what removing them
--    does, whether the user may edit / void, visit date (earliest allowed
--    invoice date). Read-only.
create or replace function public.ui_invoice_edit_context(p_invoice_id uuid)
returns jsonb
language sql
stable
set search_path to 'public'
as $function$
  with inv as (select * from invoices where id = p_invoice_id),
  d as (select ist_date(inv.created_at) as inv_date, ist_date(now()) as today from inv),
  ln as (select l.* from invoice_line_items l where l.invoice_id = p_invoice_id)
  select case when not exists (select 1 from inv) then null else jsonb_build_object(
    'invoice', (select jsonb_build_object('id', i.id, 'status', i.status, 'net', i.net, 'paid', i.paid, 'created_at', i.created_at,
                                          'invoice_number', i.invoice_number, 'patient_id', i.patient_id) from inv i),
    'lines', coalesce((select jsonb_agg(to_jsonb(l) order by l.id) from ln l), '[]'::jsonb),
    'lockReasons', coalesce((select jsonb_object_agg(l.id::text, 'Stock was deducted -- quantity can''t change and it can''t be removed until it''s returned in Inventory')
                             from ln l where invoice_line_lock_reason(l) is not null), '{}'::jsonb),
    'removeHints', coalesce((select jsonb_object_agg(l.id::text, case
                               when exists (select 1 from prescriptions rx where rx.invoice_line_item_id = l.id) then 'Prescription goes back to Pending in Pharmacy'
                               else 'Surgical case will show as not billed' end)
                             from ln l
                             where invoice_line_lock_reason(l) is null
                               and (exists (select 1 from prescriptions rx where rx.invoice_line_item_id = l.id)
                                    or exists (select 1 from master_packages mp where mp.code = l.service_code))), '{}'::jsonb),
    'invoiceDate', (select inv_date from d),
    'today', (select today from d),
    'dayClosed', (select is_day_closed(inv_date) from d),
    'canEditRight', has_billing_permission('invoice.edit'),
    'canVoidRight', has_billing_permission('invoice.void'),
    'appliedTotal', coalesce((select sum(amount) from payment_allocations where invoice_id = p_invoice_id), 0),
    'hasAllocations', exists (select 1 from payment_allocations where invoice_id = p_invoice_id),
    'hasRefund', exists (select 1 from payment_refunds where invoice_id = p_invoice_id and cancelled_at is null),
    'hasCreditNote', exists (select 1 from credit_notes where invoice_id = p_invoice_id),
    'visitDate', (select ist_date(v.created_at) from inv i join visits v on v.id = i.visit_id),
    'visitNumber', (select v.visit_number from inv i join visits v on v.id = i.visit_id),
    'isAdmin', coalesce((select designation = 'Administrator' from profiles where id = auth.uid()), false)
  ) end;
$function$;
