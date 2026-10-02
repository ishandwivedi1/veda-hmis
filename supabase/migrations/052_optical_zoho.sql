-- 052: Optical Shop -- Zoho-style Bills & Payments (same rules as hospital
-- billing, migration 051) + one database call per screen / click.
--
-- Decided (Ishan, 2 Oct 2026):
--  * Two screens: Optical Bills (list + bill pane) and Optical Payments
--    (list + receipt pane), like hospital Billing / Payments.
--  * Same rights as hospital billing: "Edit invoices" edits optical bills,
--    "Edit payments" / "Delete payments" edit / delete optical receipts.
--    Any date; closed cash days stay locked.
--  * Bill: date, items (description, qty, price), discount, notes all
--    editable -- Paid bills too. Total can't go below what's been paid.
--  * Payment (sale payment / advance): amount up or down, date, modes,
--    reference, remarks. Delete keeps a full copy (optical_payment_deletions).
--  * One reason per change (asked in a popup), saved with before/after.
--
-- New functions only; the older optical edit functions
-- (edit_optical_sale_items, edit_optical_payment_clerical,
-- correct_optical_payment_amount) are left as they are, unused by the new
-- screens. Additive columns / table only.

-- ── Additive history columns ──────────────────────────────────────────
-- (old_net/new_net already exist on production; training was missing them)
alter table public.optical_sale_edits    add column if not exists old_net numeric;
alter table public.optical_sale_edits    add column if not exists new_net numeric;
alter table public.optical_sale_edits    add column if not exists old_sale_date date;
alter table public.optical_sale_edits    add column if not exists new_sale_date date;
alter table public.optical_payment_edits add column if not exists old_date date;
alter table public.optical_payment_edits add column if not exists new_date date;

-- ── Deleted receipts (full copy kept) ─────────────────────────────────
create table if not exists public.optical_payment_deletions (
  id uuid primary key default gen_random_uuid(),
  payment_id uuid not null,
  receipt_number text,
  payment_type text,
  amount numeric,
  sale_number text,
  customer_name text,
  snapshot jsonb not null,
  reason text not null,
  deleted_by uuid,
  deleted_at timestamptz not null default now()
);
alter table public.optical_payment_deletions enable row level security;
drop policy if exists staff_all_access on public.optical_payment_deletions;
create policy staff_all_access on public.optical_payment_deletions for all to authenticated using (true) with check (true);

-- ── Helpers ───────────────────────────────────────────────────────────
-- Display name for an optical bill / receipt's customer.
create or replace function public.optical_customer_label(p_patient_id uuid, p_optical_customer_id uuid, p_fallback text)
returns text
language sql
stable
set search_path to 'public'
as $function$
  select coalesce(
    (select trim(regexp_replace(concat_ws(' ', nullif(salutation, ''), first_name, last_name), '\s+', ' ', 'g')) from patients where id = p_patient_id),
    (select name from optical_customers where id = p_optical_customer_id),
    nullif(trim(p_fallback), ''),
    'Walk-in');
$function$;

-- ── 1. Edit a bill ────────────────────────────────────────────────────
-- p_changes: { "date": "YYYY-MM-DD"?, "items": [{description, qty, unit_price}]?,
--              "discount": number?, "notes": text? }  (items = full new list)
create or replace function public.optical_bill_edit(p_sale_id uuid, p_changes jsonb, p_reason text, p_expected_net numeric)
returns optical_sales
language plpgsql
set search_path to 'public'
as $function$
declare
  s optical_sales;
  v_item jsonb;
  v_old_items jsonb;
  v_new_items jsonb;
  v_gross numeric := 0;
  v_discount numeric;
  v_net numeric;
  v_notes text;
  v_date date;
  v_changed boolean := false;
begin
  if p_reason is null or trim(p_reason) = '' then
    raise exception 'A reason is required to edit a bill.';
  end if;

  select * into s from optical_sales where id = p_sale_id for update;
  if s is null then raise exception 'Bill not found.'; end if;
  if s.status = 'Cancelled' then raise exception 'This bill is cancelled and cannot be edited.'; end if;

  perform assert_billing_edit_allowed('invoice.edit', s.sale_date);

  if p_expected_net is not null and round(s.net, 2) <> round(p_expected_net, 2) then
    raise exception 'This bill was changed by someone else since you opened it (total is now Rs.%). Close and reopen it, then try again.', s.net;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('description', description, 'qty', qty, 'unit_price', unit_price) order by created_at, id), '[]'::jsonb)
    into v_old_items from optical_sale_items where sale_id = p_sale_id;

  -- items
  if p_changes ? 'items' then
    v_new_items := '[]'::jsonb;
    if jsonb_array_length(coalesce(p_changes->'items', '[]'::jsonb)) = 0 then
      raise exception 'A bill must keep at least one item. To cancel the whole bill, use Cancel instead.';
    end if;
    for v_item in select * from jsonb_array_elements(p_changes->'items') loop
      if coalesce(trim(v_item->>'description'), '') = '' then raise exception 'Every item needs a description.'; end if;
      if coalesce((v_item->>'qty')::integer, 0) < 1 then raise exception '"%": quantity must be at least 1.', v_item->>'description'; end if;
      if coalesce((v_item->>'unit_price')::numeric, -1) < 0 then raise exception '"%": enter a valid price.', v_item->>'description'; end if;
      v_gross := v_gross + (v_item->>'qty')::integer * (v_item->>'unit_price')::numeric;
      v_new_items := v_new_items || jsonb_build_object('description', trim(v_item->>'description'), 'qty', (v_item->>'qty')::integer, 'unit_price', (v_item->>'unit_price')::numeric);
    end loop;
  else
    v_new_items := v_old_items;
    v_gross := s.gross;
  end if;

  v_discount := coalesce((p_changes->>'discount')::numeric, s.discount, 0);
  if v_discount < 0 then raise exception 'Discount cannot be negative.'; end if;
  if v_discount > v_gross then raise exception 'Discount (Rs.%) cannot be more than the items total (Rs.%).', v_discount, v_gross; end if;
  v_net := v_gross - v_discount;
  v_notes := case when p_changes ? 'notes' then nullif(trim(p_changes->>'notes'), '') else s.notes end;

  -- date
  v_date := coalesce(nullif(p_changes->>'date', '')::date, s.sale_date);
  if v_date <> s.sale_date then
    if v_date > ist_date(now()) then raise exception 'A bill cannot be dated in the future.'; end if;
    if is_day_closed(v_date) then
      raise exception '% (new date) is closed. An Administrator must reopen it in Cash Management first.', to_char(v_date, 'DD Mon YYYY');
    end if;
  end if;

  -- Zoho rule: the total can't go below what's already been paid.
  if round(v_net, 2) < round(s.paid, 2) then
    raise exception 'The new total (Rs.%) is less than the Rs.% already paid on this bill. Adjust or remove the payment first, then edit the bill.',
      round(v_net, 2), round(s.paid, 2);
  end if;

  v_changed := v_new_items <> v_old_items or round(v_discount, 2) <> round(s.discount, 2)
               or coalesce(v_notes, '') <> coalesce(s.notes, '') or v_date <> s.sale_date;
  if not v_changed then raise exception 'Nothing was changed on this bill.'; end if;

  insert into optical_sale_edits (sale_id, old_items, new_items, old_discount, new_discount, old_notes, new_notes, old_net, new_net,
                                  old_sale_date, new_sale_date, reason, edited_by)
  values (p_sale_id, v_old_items, v_new_items, s.discount, v_discount, s.notes, v_notes, s.net, v_net,
          s.sale_date, v_date, trim(p_reason), auth.uid());

  if p_changes ? 'items' then
    delete from optical_sale_items where sale_id = p_sale_id;
    -- created_at steps by a microsecond per row so the bill keeps the order entered
    insert into optical_sale_items (sale_id, description, qty, unit_price, amount, created_at)
    select p_sale_id, x.value->>'description', (x.value->>'qty')::integer, (x.value->>'unit_price')::numeric,
           (x.value->>'qty')::integer * (x.value->>'unit_price')::numeric,
           clock_timestamp() + (x.ord * interval '1 microsecond')
    from jsonb_array_elements(v_new_items) with ordinality as x(value, ord);
  end if;

  update optical_sales set gross = v_gross, discount = v_discount, net = v_net, notes = v_notes, sale_date = v_date
   where id = p_sale_id;
  return recompute_optical_sale_status(p_sale_id);
end;
$function$;

-- ── 2. Edit a payment (sale payment or advance) ───────────────────────
create or replace function public.optical_payment_edit(p_payment_id uuid, p_amount numeric, p_date date, p_modes jsonb,
                                                       p_reference text, p_remarks text, p_reason text, p_expected_amount numeric)
returns optical_payments
language plpgsql
set search_path to 'public'
as $function$
declare
  pay optical_payments;
  s optical_sales;
  v_old_date date;
  v_new_date date;
  v_mode jsonb;
  v_sum numeric := 0;
  v_old_modes jsonb;
  v_old_credit numeric;
  v_new_credit numeric;
  v_old_alloc numeric := 0;
  v_new_alloc numeric := 0;
  v_room numeric;
  v_ledger_id uuid;
begin
  if p_reason is null or trim(p_reason) = '' then raise exception 'A reason is required to edit a payment.'; end if;

  select * into pay from optical_payments where id = p_payment_id for update;
  if pay is null then raise exception 'Payment not found.'; end if;
  if pay.payment_type = 'advance_adjustment' then
    raise exception 'This is advance credit applied to a bill, not money received. To undo it, use Delete (the credit goes back to the customer).';
  end if;
  if pay.payment_type not in ('sale_payment', 'advance') then
    raise exception 'Credit notes and refunds cannot be edited here.';
  end if;

  v_old_date := ist_date(pay.collected_at);
  v_new_date := coalesce(p_date, v_old_date);
  perform assert_billing_edit_allowed('payment.edit', v_old_date);
  if v_new_date <> v_old_date then
    if v_new_date > ist_date(now()) then raise exception 'A payment cannot be dated in the future.'; end if;
    perform assert_billing_edit_allowed('payment.edit', v_new_date);
  end if;

  if p_expected_amount is not null and round(pay.total_amount, 2) <> round(p_expected_amount, 2) then
    raise exception 'This payment was changed by someone else since you opened it (amount is now Rs.%). Close and reopen it, then try again.', pay.total_amount;
  end if;
  if exists (select 1 from optical_payment_refunds where payment_id = p_payment_id and cancelled_at is null) then
    raise exception 'This payment has a refund recorded against it. Cancel that refund first (Refund screen), then edit the payment.';
  end if;

  if p_amount is null or p_amount <= 0 then raise exception 'Amount must be greater than zero. To remove the payment, use Delete.'; end if;
  if p_modes is null or jsonb_array_length(p_modes) = 0 then raise exception 'Enter at least one payment mode.'; end if;
  for v_mode in select * from jsonb_array_elements(p_modes) loop
    if coalesce((v_mode->>'amount')::numeric, 0) <= 0 or coalesce(trim(v_mode->>'mode'), '') = '' then
      raise exception 'Every payment mode needs a name and an amount above zero.';
    end if;
    v_sum := v_sum + (v_mode->>'amount')::numeric;
  end loop;
  if round(v_sum, 2) <> round(p_amount, 2) then
    raise exception 'Payment modes (Rs.%) must add up to the amount (Rs.%).', v_sum, p_amount;
  end if;

  -- credit this payment created (advance, or overpayment of a bill)
  v_old_credit := coalesce((select sum(amount) from optical_customer_ledger where payment_id = p_payment_id and entry_type = 'Advance Collected'), 0);

  if pay.payment_type = 'sale_payment' and pay.sale_id is not null then
    select * into s from optical_sales where id = pay.sale_id for update;
    v_old_alloc := pay.total_amount - v_old_credit;
    v_room := s.net - (s.paid - v_old_alloc);
    v_new_alloc := least(p_amount, greatest(v_room, 0));
    v_new_credit := p_amount - v_new_alloc;
  else
    v_new_credit := p_amount;
  end if;

  if v_new_credit < v_old_credit
     and round(get_optical_advance_balance(pay.patient_id, pay.optical_customer_id) - (v_old_credit - v_new_credit), 2) < 0 then
    raise exception 'This change takes back Rs.% of the customer''s advance credit, but only Rs.% is still unused (the rest was already applied to bills). Remove those applications first.',
      v_old_credit - v_new_credit, get_optical_advance_balance(pay.patient_id, pay.optical_customer_id);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('mode', mode, 'amount', amount)), '[]'::jsonb) into v_old_modes
    from optical_payment_modes where payment_id = p_payment_id;

  insert into optical_payment_edits (payment_id, old_reference, new_reference, old_remarks, new_remarks, old_modes, new_modes,
                                     old_amount, new_amount, old_date, new_date, reason, edited_by)
  values (p_payment_id, pay.reference, nullif(trim(coalesce(p_reference, '')), ''), pay.remarks, nullif(trim(coalesce(p_remarks, '')), ''),
          v_old_modes, p_modes,
          case when round(pay.total_amount, 2) <> round(p_amount, 2) then pay.total_amount end,
          case when round(pay.total_amount, 2) <> round(p_amount, 2) then p_amount end,
          v_old_date, v_new_date, trim(p_reason), auth.uid());

  delete from optical_payment_modes where payment_id = p_payment_id;
  for v_mode in select * from jsonb_array_elements(p_modes) loop
    insert into optical_payment_modes (payment_id, mode, amount) values (p_payment_id, trim(v_mode->>'mode'), (v_mode->>'amount')::numeric);
  end loop;

  -- bill side
  if pay.payment_type = 'sale_payment' and pay.sale_id is not null then
    update optical_sales set paid = paid - v_old_alloc + v_new_alloc where id = pay.sale_id;
    perform recompute_optical_sale_status(pay.sale_id);
  end if;

  -- credit side (one 'Advance Collected' row per payment)
  if round(v_new_credit, 2) <> round(v_old_credit, 2) then
    select id into v_ledger_id from optical_customer_ledger
     where payment_id = p_payment_id and entry_type = 'Advance Collected' order by recorded_at limit 1;
    delete from optical_customer_ledger where payment_id = p_payment_id and entry_type = 'Advance Collected'
       and id is distinct from v_ledger_id;
    if v_new_credit <= 0 then
      delete from optical_customer_ledger where id = v_ledger_id;
    elsif v_ledger_id is not null then
      update optical_customer_ledger set amount = v_new_credit where id = v_ledger_id;
    else
      insert into optical_customer_ledger (patient_id, optical_customer_id, payment_id, entry_type, amount, remarks, recorded_by)
      values (pay.patient_id, pay.optical_customer_id, p_payment_id, 'Advance Collected', v_new_credit,
              'Overpayment from Receipt ' || coalesce(pay.receipt_number, '-'), auth.uid());
    end if;
  end if;

  update optical_payments
     set total_amount = p_amount,
         collected_at = ((v_new_date + (pay.collected_at at time zone 'Asia/Kolkata')::time) at time zone 'Asia/Kolkata'),
         reference = nullif(trim(coalesce(p_reference, '')), ''),
         remarks = nullif(trim(coalesce(p_remarks, '')), '')
   where id = p_payment_id
  returning * into pay;

  return pay;
end;
$function$;

-- ── 3. Delete a payment (copy kept in optical_payment_deletions) ──────
create or replace function public.optical_payment_delete(p_payment_id uuid, p_reason text, p_expected_amount numeric)
returns jsonb
language plpgsql
set search_path to 'public'
as $function$
declare
  pay optical_payments;
  v_credit numeric;
  v_alloc numeric;
  v_snapshot jsonb;
  v_sale_number text;
begin
  if p_reason is null or trim(p_reason) = '' then raise exception 'A reason is required to delete a payment.'; end if;

  select * into pay from optical_payments where id = p_payment_id for update;
  if pay is null then raise exception 'Payment not found.'; end if;
  if pay.payment_type not in ('sale_payment', 'advance', 'advance_adjustment') then
    raise exception 'Credit notes and refunds cannot be deleted here.';
  end if;

  perform assert_billing_edit_allowed('payment.delete', ist_date(pay.collected_at));

  if p_expected_amount is not null and round(pay.total_amount, 2) <> round(p_expected_amount, 2) then
    raise exception 'This payment was changed by someone else since you opened it. Close and reopen it, then try again.';
  end if;
  if exists (select 1 from optical_payment_refunds where payment_id = p_payment_id or refund_payment_id = p_payment_id) then
    raise exception 'This payment has refund history and cannot be deleted. Use Edit, or cancel the refund on the Refund screen.';
  end if;

  v_credit := coalesce((select sum(amount) from optical_customer_ledger where payment_id = p_payment_id and entry_type = 'Advance Collected'), 0);
  if v_credit > 0 and round(get_optical_advance_balance(pay.patient_id, pay.optical_customer_id) - v_credit, 2) < 0 then
    raise exception 'Rs.% of advance credit from this receipt was already applied to bills (only Rs.% unused). Remove those applications first.',
      v_credit, get_optical_advance_balance(pay.patient_id, pay.optical_customer_id);
  end if;

  select sale_number into v_sale_number from optical_sales where id = pay.sale_id;
  v_snapshot := jsonb_build_object(
    'payment', to_jsonb(pay),
    'modes', coalesce((select jsonb_agg(to_jsonb(m)) from optical_payment_modes m where m.payment_id = p_payment_id), '[]'::jsonb),
    'ledger', coalesce((select jsonb_agg(to_jsonb(l)) from optical_customer_ledger l where l.payment_id = p_payment_id), '[]'::jsonb),
    'edits', coalesce((select jsonb_agg(to_jsonb(e)) from optical_payment_edits e where e.payment_id = p_payment_id), '[]'::jsonb),
    'sale_number', v_sale_number);

  -- bill side
  if pay.sale_id is not null then
    v_alloc := case pay.payment_type
                 when 'sale_payment' then pay.total_amount - v_credit
                 when 'advance_adjustment' then pay.total_amount
                 else 0 end;
    if v_alloc <> 0 then
      update optical_sales set paid = paid - v_alloc where id = pay.sale_id;
      perform recompute_optical_sale_status(pay.sale_id);
    end if;
  end if;

  -- credit side: the receipt's own ledger rows go (an applied-advance row
  -- going away puts that credit back with the customer)
  delete from optical_customer_ledger where payment_id = p_payment_id;
  delete from optical_payment_edits where payment_id = p_payment_id;
  delete from optical_payments where id = p_payment_id;  -- modes cascade

  insert into optical_payment_deletions (payment_id, receipt_number, payment_type, amount, sale_number, customer_name, snapshot, reason, deleted_by)
  values (p_payment_id, pay.receipt_number, pay.payment_type, pay.total_amount, v_sale_number,
          optical_customer_label(pay.patient_id, pay.optical_customer_id, null), v_snapshot, trim(p_reason), auth.uid());

  return jsonb_build_object('deleted', true, 'receipt_number', pay.receipt_number, 'sale_id', pay.sale_id);
end;
$function$;

-- ── 4. One-call reads ─────────────────────────────────────────────────
-- Bills screen: list (+ when p_full: summary, day bar, bookings awaiting delivery).
create or replace function public.ui_optical_bills(p_query text default null, p_status text default null,
                                                   p_from date default null, p_to date default null, p_full boolean default true)
returns jsonb
language sql
stable
set search_path to 'public'
as $function$
  with t as (select ist_date(now()) as today),
  q as (select nullif(trim(coalesce(p_query, '')), '') as term),
  bills as (
    select s.*, optical_customer_label(s.patient_id, s.optical_customer_id, s.customer_name) as customer,
           coalesce((select mobile from patients where id = s.patient_id), (select mobile from optical_customers where id = s.optical_customer_id), s.customer_mobile) as mobile,
           (select uhid from patients where id = s.patient_id) as uhid
    from optical_sales s
  ),
  filtered as (
    select b.* from bills b, q
    where (p_status is null or p_status = '' or b.status = p_status)
      and (p_from is null or b.sale_date >= p_from)
      and (p_to is null or b.sale_date <= p_to)
      and (q.term is null or b.sale_number ilike '%' || q.term || '%' or b.customer ilike '%' || q.term || '%'
           or coalesce(b.mobile, '') ilike '%' || q.term || '%' or coalesce(b.uhid, '') ilike '%' || q.term || '%')
    order by b.sale_date desc, b.created_at desc
    limit case when (select term from q) is null and coalesce(p_status, '') = '' and p_from is null and p_to is null then 100 else 500 end
  )
  select jsonb_build_object(
    'bills', coalesce((select jsonb_agg(jsonb_build_object(
        'id', f.id, 'sale_number', f.sale_number, 'sale_date', f.sale_date, 'status', f.status,
        'net', f.net, 'paid', f.paid, 'due', case when f.status = 'Cancelled' then 0 else greatest(f.net - f.paid, 0) end,
        'customer', f.customer, 'mobile', f.mobile, 'uhid', f.uhid) order by f.sale_date desc, f.created_at desc) from filtered f), '[]'::jsonb)
  ) || case when not p_full then '{}'::jsonb else jsonb_build_object(
    'day', ui_day_status(),
    'summary', jsonb_build_object(
      'todayBilled', coalesce((select sum(net) from optical_sales, t where sale_date = t.today and status <> 'Cancelled'), 0),
      'todayCount', (select count(*) from optical_sales, t where sale_date = t.today and status <> 'Cancelled'),
      'monthBilled', coalesce((select sum(net) from optical_sales, t where sale_date >= date_trunc('month', t.today)::date and sale_date <= t.today and status <> 'Cancelled'), 0),
      'outstanding', coalesce((select sum(net - paid) from optical_sales where status in ('Pending', 'Partial')), 0),
      'outstandingCount', (select count(*) from optical_sales where status in ('Pending', 'Partial')),
      'advanceHeld', coalesce((select sum(amount) from optical_customer_ledger), 0)),
    'bookings', coalesce((select jsonb_agg(jsonb_build_object(
        'id', o.id, 'order_number', o.order_number, 'net', o.net, 'created_at', o.created_at,
        'customer', optical_customer_label(o.patient_id, o.optical_customer_id, o.customer_name),
        'advanceOnFile', greatest(get_optical_advance_balance(o.patient_id, o.optical_customer_id), 0)) order by o.created_at)
      from optical_orders o where o.status = 'Pending'), '[]'::jsonb)
  ) end;
$function$;

-- Bill pane: everything for one bill.
create or replace function public.ui_optical_bill_panel(p_sale_id uuid)
returns jsonb
language sql
stable
set search_path to 'public'
as $function$
  with s as (select * from optical_sales where id = p_sale_id)
  select case when not exists (select 1 from s) then null else jsonb_build_object(
    'sale', (select to_jsonb(s) || jsonb_build_object(
               'customer', optical_customer_label(s.patient_id, s.optical_customer_id, s.customer_name),
               'mobile', coalesce((select mobile from patients where id = s.patient_id), (select mobile from optical_customers where id = s.optical_customer_id), s.customer_mobile),
               'uhid', (select uhid from patients where id = s.patient_id),
               'due', case when s.status = 'Cancelled' then 0 else greatest(s.net - s.paid, 0) end) from s),
    'items', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'description', i.description, 'qty', i.qty, 'unit_price', i.unit_price, 'amount', i.amount)
                                         order by i.created_at, i.id) from optical_sale_items i where i.sale_id = p_sale_id), '[]'::jsonb),
    'payments', coalesce((select jsonb_agg(jsonb_build_object(
                   'id', p.id, 'receipt_number', p.receipt_number, 'payment_type', p.payment_type, 'amount', p.total_amount,
                   'collected_at', p.collected_at,
                   'modes', (select string_agg(m.mode || ' ' || m.amount, ', ') from optical_payment_modes m where m.payment_id = p.id),
                   'refundCancelled', exists (select 1 from optical_payment_refunds r where r.refund_payment_id = p.id and r.cancelled_at is not null))
                 order by p.collected_at) from optical_payments p where p.sale_id = p_sale_id), '[]'::jsonb),
    'history', coalesce((select jsonb_agg(jsonb_build_object(
                   'id', e.id, 'at', e.edited_at, 'by', coalesce(pr.full_name, 'Unknown'), 'reason', e.reason,
                   'old_items', e.old_items, 'new_items', e.new_items, 'old_discount', e.old_discount, 'new_discount', e.new_discount,
                   'old_net', e.old_net, 'new_net', e.new_net, 'old_notes', e.old_notes, 'new_notes', e.new_notes,
                   'old_date', e.old_sale_date, 'new_date', e.new_sale_date) order by e.edited_at desc)
                 from optical_sale_edits e left join profiles pr on pr.id = e.edited_by where e.sale_id = p_sale_id), '[]'::jsonb),
    'advanceBalance', (select greatest(get_optical_advance_balance(s.patient_id, s.optical_customer_id), 0) from s),
    'today', ist_date(now()),
    'dayClosed', (select is_day_closed(s.sale_date) from s),
    'todayClosed', is_day_closed(ist_date(now())),
    'canEdit', has_billing_permission('invoice.edit'),
    'isAdmin', coalesce((select designation = 'Administrator' from profiles where id = auth.uid()), false)
  ) end;
$function$;

-- Payments screen: list (+ when p_full: today's summary + day bar).
create or replace function public.ui_optical_payments(p_query text default null, p_type text default null,
                                                      p_from date default null, p_to date default null, p_full boolean default true)
returns jsonb
language sql
stable
set search_path to 'public'
as $function$
  with t as (select ist_date(now()) as today),
  q as (select nullif(trim(coalesce(p_query, '')), '') as term),
  pays as (
    select p.*, s.sale_number,
           optical_customer_label(p.patient_id, p.optical_customer_id, s.customer_name) as customer,
           (select string_agg(m.mode || ' ' || m.amount, ', ') from optical_payment_modes m where m.payment_id = p.id) as modes,
           exists (select 1 from optical_payment_refunds r where r.refund_payment_id = p.id and r.cancelled_at is not null) as refund_cancelled
    from optical_payments p left join optical_sales s on s.id = p.sale_id
  ),
  filtered as (
    select x.* from pays x, q
    where (p_type is null or p_type = '' or x.payment_type = p_type)
      and (p_from is null or ist_date(x.collected_at) >= p_from)
      and (p_to is null or ist_date(x.collected_at) <= p_to)
      and (q.term is null or coalesce(x.receipt_number, '') ilike '%' || q.term || '%' or coalesce(x.sale_number, '') ilike '%' || q.term || '%'
           or x.customer ilike '%' || q.term || '%' or coalesce(x.reference, '') ilike '%' || q.term || '%')
    order by x.collected_at desc
    limit case when (select term from q) is null and coalesce(p_type, '') = '' and p_from is null and p_to is null then 100 else 500 end
  ),
  today_pays as (
    select p.payment_type, p.total_amount, p.id from optical_payments p, t
    where ist_date(p.collected_at) = t.today and p.payment_type in ('sale_payment', 'advance', 'refund')
      and not exists (select 1 from optical_payment_refunds r where r.refund_payment_id = p.id and r.cancelled_at is not null)
  )
  select jsonb_build_object(
    'payments', coalesce((select jsonb_agg(jsonb_build_object(
        'id', f.id, 'receipt_number', f.receipt_number, 'payment_type', f.payment_type, 'amount', f.total_amount,
        'collected_at', f.collected_at, 'sale_id', f.sale_id, 'sale_number', f.sale_number, 'customer', f.customer,
        'modes', f.modes, 'reference', f.reference, 'refundCancelled', f.refund_cancelled) order by f.collected_at desc) from filtered f), '[]'::jsonb)
  ) || case when not p_full then '{}'::jsonb else jsonb_build_object(
    'day', ui_day_status(),
    'summary', jsonb_build_object(
      'todayCollected', coalesce((select sum(case when payment_type = 'refund' then -total_amount else total_amount end) from today_pays), 0),
      'todayCount', (select count(*) from today_pays where payment_type <> 'refund'),
      'byMode', coalesce((select jsonb_object_agg(mode, amt) from (
          select m.mode, sum(case when tp.payment_type = 'refund' then -m.amount else m.amount end) amt
          from today_pays tp join optical_payment_modes m on m.payment_id = tp.id group by m.mode
          having sum(case when tp.payment_type = 'refund' then -m.amount else m.amount end) <> 0) z), '{}'::jsonb))
  ) end;
$function$;

-- Receipt pane: everything for one receipt.
create or replace function public.ui_optical_payment_detail(p_payment_id uuid)
returns jsonb
language sql
stable
set search_path to 'public'
as $function$
  with p as (select * from optical_payments where id = p_payment_id),
       s as (select os.* from optical_sales os, p where os.id = p.sale_id)
  select case when not exists (select 1 from p) then null else jsonb_build_object(
    'payment', (select to_jsonb(p) || jsonb_build_object(
        'modes', coalesce((select jsonb_agg(jsonb_build_object('mode', m.mode, 'amount', m.amount)) from optical_payment_modes m where m.payment_id = p.id), '[]'::jsonb),
        'customer', optical_customer_label(p.patient_id, p.optical_customer_id, (select customer_name from s)),
        'collectedBy', (select full_name from profiles where id = p.collected_by)) from p),
    'sale', (select jsonb_build_object('id', s.id, 'sale_number', s.sale_number, 'net', s.net, 'paid', s.paid, 'status', s.status) from s),
    'credit', coalesce((select sum(amount) from optical_customer_ledger l, p where l.payment_id = p.id and l.entry_type = 'Advance Collected'), 0),
    'advanceBalance', (select greatest(get_optical_advance_balance(p.patient_id, p.optical_customer_id), 0) from p),
    'refunds', coalesce((select jsonb_agg(jsonb_build_object('refund_number', r.refund_number, 'amount', r.amount, 'refunded_at', r.refunded_at,
                                                            'cancelled_at', r.cancelled_at, 'reason', r.reason) order by r.refunded_at)
                         from optical_payment_refunds r where r.payment_id = p_payment_id), '[]'::jsonb),
    'hasRefundHistory', exists (select 1 from optical_payment_refunds r where r.payment_id = p_payment_id or r.refund_payment_id = p_payment_id),
    'hasActiveRefund', exists (select 1 from optical_payment_refunds r where r.payment_id = p_payment_id and r.cancelled_at is null),
    'history', coalesce((select jsonb_agg(jsonb_build_object(
                   'id', e.id, 'at', e.edited_at, 'by', coalesce(pr.full_name, 'Unknown'), 'reason', e.reason,
                   'old_amount', e.old_amount, 'new_amount', e.new_amount, 'old_modes', e.old_modes, 'new_modes', e.new_modes,
                   'old_reference', e.old_reference, 'new_reference', e.new_reference, 'old_date', e.old_date, 'new_date', e.new_date)
                   order by e.edited_at desc)
                 from optical_payment_edits e left join profiles pr on pr.id = e.edited_by where e.payment_id = p_payment_id), '[]'::jsonb),
    'paymentDate', (select ist_date(collected_at) from p),
    'today', ist_date(now()),
    'dayClosed', (select is_day_closed(ist_date(collected_at)) from p),
    'canEdit', has_billing_permission('payment.edit'),
    'canDelete', has_billing_permission('payment.delete')
  ) end;
$function$;

-- Deleted receipts list.
create or replace function public.ui_optical_deleted_payments()
returns jsonb
language sql
stable
set search_path to 'public'
as $function$
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', d.id, 'receipt_number', d.receipt_number, 'payment_type', d.payment_type, 'amount', d.amount,
      'sale_number', d.sale_number, 'customer', d.customer_name, 'reason', d.reason,
      'deleted_at', d.deleted_at, 'by', coalesce(pr.full_name, 'Unknown'),
      'collected_at', d.snapshot->'payment'->>'collected_at') order by d.deleted_at desc), '[]'::jsonb)
  from (select * from optical_payment_deletions order by deleted_at desc limit 200) d
  left join profiles pr on pr.id = d.deleted_by;
$function$;
