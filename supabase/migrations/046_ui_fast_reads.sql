-- 046: One-round-trip reads for the Billing / Payments screens.
--
-- Each screen action used to chain several requests (browser -> server ->
-- database, one after another). These read-only functions return
-- everything a click needs in ONE database call; auth.uid() is read inside
-- Postgres, so no separate login lookups either. SECURITY INVOKER (RLS
-- applies exactly as before). Nothing here writes.

-- Day status for the "day not opened" bar: open? + suggested opening cash.
create or replace function public.ui_day_status()
returns jsonb
language sql
stable
set search_path to 'public'
as $function$
  select jsonb_build_object(
    'open', exists (select 1 from day_openings where opening_date = ist_date(now())),
    'suggested', (
      select jsonb_build_object('date', counter_date, 'amount', closing_cash)
      from cash_counter
      where closing_cash is not null and counter_date < ist_date(now())
      order by counter_date desc limit 1
    )
  );
$function$;

-- Everything the payment detail pane (and its Edit panel) needs.
create or replace function public.ui_payment_detail(p_payment_id uuid)
returns jsonb
language sql
stable
set search_path to 'public'
as $function$
  with p as (select * from payments where id = p_payment_id),
       me as (select designation from profiles where id = auth.uid()),
       d as (select ist_date(p.collected_at) as pay_date from p)
  select case when not exists (select 1 from p) then null else jsonb_build_object(
    'payment', (
      select to_jsonb(p) || jsonb_build_object(
        'patients', (select jsonb_build_object('id', pt.id, 'first_name', pt.first_name, 'salutation', pt.salutation, 'last_name', pt.last_name, 'uhid', pt.uhid, 'mobile', pt.mobile) from patients pt where pt.id = p.patient_id),
        'payment_modes', coalesce((select jsonb_agg(jsonb_build_object('mode', m.mode, 'amount', m.amount)) from payment_modes m where m.payment_id = p.id), '[]'::jsonb),
        'payment_allocations', coalesce((select jsonb_agg(jsonb_build_object('invoice_id', a.invoice_id, 'amount', a.amount, 'invoices', jsonb_build_object('invoice_number', i.invoice_number)))
                                          from payment_allocations a join invoices i on i.id = a.invoice_id where a.payment_id = p.id), '[]'::jsonb)
      ) from p),
    'paymentDate', (select pay_date from d),
    'today', ist_date(now()),
    'dayClosed', (select is_day_closed(pay_date) from d),
    'hasRefund', exists (select 1 from payment_refunds r where r.payment_id = p_payment_id and r.cancelled_at is null),
    'isAdmin', coalesce((select designation = 'Administrator' from me), false),
    'perms', jsonb_build_object(
      'payment.edit', has_billing_permission('payment.edit'),
      'payment.edit_past', has_billing_permission('payment.edit_past'),
      'payment.delete', has_billing_permission('payment.delete')),
    'patientCredit', (select get_advance_balance(p.patient_id) from p),
    'paymentCredit', coalesce((select sum(l.amount) from patient_ledger l where l.payment_id = p_payment_id
                                and l.entry_type in ('Advance Collected', 'Correction: Credit Added', 'Correction: Credit Removed')), 0),
    'cashHandedOver', (select c.amount_handed_over from cash_counter c, d where c.counter_date = d.pay_date),
    'collectedBy', (select pr.full_name from profiles pr, p where pr.id = p.collected_by),
    'audit', coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'at', b.changed_at, 'by', coalesce(pr.full_name, 'Unknown'), 'action', b.action,
                                       'reason', b.reason, 'before', b.before_data, 'after', b.after_data) order by b.changed_at desc)
                       from billing_audit_log b left join profiles pr on pr.id = b.changed_by
                       where b.entity_type = 'payment' and b.entity_id = p_payment_id), '[]'::jsonb),
    'edits', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'at', e.edited_at, 'by', coalesce(pr.full_name, 'Unknown'), 'reason', e.reason,
                                       'old_amount', e.old_amount, 'new_amount', e.new_amount, 'old_modes', e.old_modes, 'new_modes', e.new_modes) order by e.edited_at desc)
                       from payment_edits e left join profiles pr on pr.id = e.edited_by
                       where e.payment_id = p_payment_id), '[]'::jsonb)
  ) end;
$function$;

-- Everything the invoice detail pane needs, incl. the patient's credits.
create or replace function public.ui_invoice_panel(p_invoice_id uuid)
returns jsonb
language sql
stable
set search_path to 'public'
as $function$
  with inv as (select * from invoices where id = p_invoice_id)
  select case when not exists (select 1 from inv) then null else jsonb_build_object(
    'invoice', (select to_jsonb(inv) || jsonb_build_object(
        'patients', (select jsonb_build_object('id', pt.id, 'first_name', pt.first_name, 'salutation', pt.salutation, 'last_name', pt.last_name, 'uhid', pt.uhid, 'mobile', pt.mobile) from patients pt where pt.id = inv.patient_id),
        'visits', (select jsonb_build_object('id', v.id, 'visit_number', v.visit_number, 'visit_type', v.visit_type, 'created_at', v.created_at) from visits v where v.id = inv.visit_id)
      ) from inv),
    'lineItems', coalesce((select jsonb_agg(to_jsonb(li) order by li.id) from invoice_line_items li where li.invoice_id = p_invoice_id), '[]'::jsonb),
    'payments', coalesce((select jsonb_agg(jsonb_build_object(
          'id', pay.id, 'receipt_number', pay.receipt_number, 'collected_at', pay.collected_at, 'payment_type', pay.payment_type,
          'applied', a.amount,
          'modes', (select string_agg(distinct m.mode, ' + ') from payment_modes m where m.payment_id = pay.id)
        ) order by pay.collected_at)
        from payment_allocations a join payments pay on pay.id = a.payment_id where a.invoice_id = p_invoice_id), '[]'::jsonb),
    'refunds', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'amount', r.amount, 'refunded_at', r.refunded_at, 'refund_mode', r.refund_mode) order by r.refunded_at)
        from payment_refunds r where r.invoice_id = p_invoice_id and r.cancelled_at is null), '[]'::jsonb),
    'surgeonName', (select pr.full_name from profiles pr, inv where pr.id = inv.manual_surgeon_id),
    'advanceBalance', (select get_advance_balance(inv.patient_id) from inv),
    'openCreditNotes', coalesce((select jsonb_agg(x order by x->>'created_at') from (
        select jsonb_build_object('id', c.id, 'credit_note_number', c.credit_note_number, 'created_at', c.created_at, 'amount', c.amount,
               'balance', round(c.amount - coalesce((select sum(ap.amount) from credit_note_applications ap where ap.credit_note_id = c.id), 0), 2)) as x
        from credit_notes c, inv where c.patient_id = inv.patient_id and c.status = 'Open'
      ) s where (x->>'balance')::numeric > 0), '[]'::jsonb)
  ) end;
$function$;

grant execute on function public.ui_day_status() to authenticated;
grant execute on function public.ui_payment_detail(uuid) to authenticated;
grant execute on function public.ui_invoice_panel(uuid) to authenticated;
