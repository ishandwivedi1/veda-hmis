-- 045: Zoho-style credit notes.
--
-- A credit note is now a document of its own: number, date, line items,
-- an approver, and a credit BALANCE that is applied to any of the
-- patient's unpaid invoices (now or later). Status: Open -> Closed when
-- fully applied; Void if cancelled before any use.
--
-- Additive only:
--   * credit_notes: new columns status / void info (existing rows kept);
--   * new tables credit_note_items, credit_note_applications;
--   * new functions cn_create, cn_apply, cn_void.
-- create_credit_note() (old screen) is left in place, unchanged.
--
-- Money effect is unchanged in kind: applying a credit note adds a
-- payments row (payment_type 'credit_note', no payment modes -> no cash),
-- an allocation to the invoice, and raises invoices.paid -- exactly what
-- the old flow did, so the daily cash report treats it the same way.
-- Each application's reference is <CN number>-<n> (receipt numbers are
-- unique).

alter table public.credit_notes add column if not exists status text not null default 'Open';
alter table public.credit_notes add column if not exists voided_at timestamptz;
alter table public.credit_notes add column if not exists voided_by uuid references public.profiles(id);
alter table public.credit_notes add column if not exists void_reason text;
alter table public.credit_notes add constraint credit_notes_status_check check (status in ('Open', 'Closed', 'Void'));

create table if not exists public.credit_note_items (
  id uuid primary key default gen_random_uuid(),
  credit_note_id uuid not null references public.credit_notes(id),
  invoice_line_item_id uuid,
  description text not null,
  dept text,
  qty numeric not null default 1 check (qty > 0),
  rate numeric not null check (rate >= 0),
  amount numeric not null check (amount >= 0),
  sort_order integer not null default 0
);
create index if not exists idx_credit_note_items_cn on public.credit_note_items (credit_note_id);

create table if not exists public.credit_note_applications (
  id uuid primary key default gen_random_uuid(),
  credit_note_id uuid not null references public.credit_notes(id),
  invoice_id uuid not null references public.invoices(id),
  payment_id uuid references public.payments(id),
  amount numeric not null check (amount > 0),
  applied_at timestamptz not null default now(),
  applied_by uuid references public.profiles(id)
);
create index if not exists idx_cn_applications_cn on public.credit_note_applications (credit_note_id);
create index if not exists idx_cn_applications_invoice on public.credit_note_applications (invoice_id);

alter table public.credit_note_items enable row level security;
alter table public.credit_note_applications enable row level security;
create policy staff_all_access on public.credit_note_items for all to authenticated using (true) with check (true);
create policy staff_all_access on public.credit_note_applications for all to authenticated using (true) with check (true);

-- Carry the existing credit notes over: each was applied in full to its own
-- invoice at creation, so it becomes a Closed note with one line and one
-- application (its existing payments row).
insert into public.credit_note_items (credit_note_id, description, qty, rate, amount)
select cn.id, coalesce(nullif(trim(cn.reason), ''), 'Credit'), 1, cn.amount, cn.amount
from public.credit_notes cn
where not exists (select 1 from public.credit_note_items i where i.credit_note_id = cn.id);

insert into public.credit_note_applications (credit_note_id, invoice_id, payment_id, amount, applied_at, applied_by)
select cn.id, a.invoice_id, cn.payment_id, a.amount, cn.created_at, cn.created_by
from public.credit_notes cn
join public.payment_allocations a on a.payment_id = cn.payment_id
where not exists (select 1 from public.credit_note_applications x where x.credit_note_id = cn.id);

update public.credit_notes cn
   set status = 'Closed'
 where status = 'Open'
   and cn.amount <= coalesce((select sum(x.amount) from public.credit_note_applications x where x.credit_note_id = cn.id), 0);

-- Old "store credit" notes (issued against an already-paid invoice) put
-- their value into the patient's advance credit (patient_ledger 'Credit
-- Note Issued'). That credit already shows as advance, so these notes are
-- Closed here -- leaving them Open would count the same money twice.
update public.credit_notes cn
   set status = 'Closed',
       remarks = trim(coalesce(cn.remarks, '') || ' [value held as patient advance credit]')
 where status = 'Open'
   and exists (select 1 from public.patient_ledger l where l.payment_id = cn.payment_id and l.entry_type = 'Credit Note Issued');

-- ─────────────────────────────────────────────────────────────────────
-- cn_apply: put (part of) a credit note's balance against an invoice.
-- ─────────────────────────────────────────────────────────────────────
create or replace function public.cn_apply(p_credit_note_id uuid, p_invoice_id uuid, p_amount numeric)
returns credit_notes
language plpgsql
set search_path to 'public'
as $function$
declare
  cn credit_notes;
  inv invoices;
  v_applied numeric;
  v_balance numeric;
  v_outstanding numeric;
  v_n int;
  new_payment payments;
begin
  if is_day_closed(ist_date(now())) then
    raise exception 'Today has been closed for financial reconciliation. An administrator must reopen it before credit can be applied.';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'Amount to apply must be greater than zero.';
  end if;

  select * into cn from credit_notes where id = p_credit_note_id for update;
  if cn is null then raise exception 'Credit note not found.'; end if;
  if cn.status <> 'Open' then
    raise exception 'Credit note % is % and has no credit left to apply.', cn.credit_note_number, lower(cn.status);
  end if;

  select coalesce(sum(amount), 0), count(*) into v_applied, v_n from credit_note_applications where credit_note_id = cn.id;
  v_balance := round(cn.amount - v_applied, 2);
  if round(p_amount, 2) > v_balance then
    raise exception 'Only Rs.% is left on credit note %.', v_balance, cn.credit_note_number;
  end if;

  select * into inv from invoices where id = p_invoice_id for update;
  if inv is null then raise exception 'Invoice not found.'; end if;
  if inv.patient_id <> cn.patient_id then raise exception 'A credit note can only be applied to the same patient''s invoices.'; end if;
  if inv.status in ('Cancelled', 'Void') then raise exception '% is void.', inv.invoice_number; end if;
  v_outstanding := round(inv.net - inv.paid, 2);
  if round(p_amount, 2) > v_outstanding then
    raise exception '% only has Rs.% left to pay.', inv.invoice_number, v_outstanding;
  end if;

  insert into payments (receipt_number, patient_id, total_amount, remarks, collected_by, payment_type)
  values (cn.credit_note_number || '-' || (v_n + 1), cn.patient_id, p_amount,
          'Credit note ' || cn.credit_note_number || ' applied to ' || coalesce(inv.invoice_number, 'invoice'),
          auth.uid(), 'credit_note')
  returning * into new_payment;

  insert into payment_allocations (payment_id, invoice_id, amount) values (new_payment.id, inv.id, p_amount);
  insert into credit_note_applications (credit_note_id, invoice_id, payment_id, amount, applied_by)
  values (cn.id, inv.id, new_payment.id, p_amount, auth.uid());

  update invoices set paid = paid + p_amount where id = inv.id;
  perform recompute_invoice_totals(inv.id);

  if round(v_balance - p_amount, 2) <= 0 then
    update credit_notes set status = 'Closed' where id = cn.id;
  end if;

  insert into billing_audit_log (entity_type, entity_id, entity_ref, action, reason, before_data, after_data, changed_by)
  values ('invoice', inv.id, inv.invoice_number, 'credit_note_applied', 'Credit note ' || cn.credit_note_number,
          jsonb_build_object('paid', inv.paid), jsonb_build_object('credit_note', cn.credit_note_number, 'amount', p_amount), auth.uid());

  select * into cn from credit_notes where id = p_credit_note_id;
  return cn;
end;
$function$;

-- ─────────────────────────────────────────────────────────────────────
-- cn_create: issue a credit note (items), optionally applying part of it
-- to the referenced invoice straight away.
-- ─────────────────────────────────────────────────────────────────────
create or replace function public.cn_create(
  p_patient_id uuid,
  p_invoice_id uuid,
  p_items jsonb,
  p_reason text,
  p_approved_by uuid,
  p_remarks text,
  p_apply_amount numeric
)
returns credit_notes
language plpgsql
set search_path to 'public'
as $function$
declare
  cn credit_notes;
  inv invoices;
  v_item jsonb;
  v_total numeric := 0;
  v_qty numeric;
  v_rate numeric;
  v_other numeric;
  v_i int := 0;
begin
  if p_patient_id is null then raise exception 'Choose a patient.'; end if;
  -- credit_notes.invoice_id is NOT NULL: every credit note references the
  -- bill it corrects (its credit can still be applied to any of the
  -- patient's unpaid invoices).
  if p_invoice_id is null then raise exception 'Choose the invoice this credit note is for.'; end if;
  if p_reason is null or trim(p_reason) = '' then raise exception 'A reason is required for a credit note.'; end if;
  if p_approved_by is null then raise exception 'An approver is required for a credit note.'; end if;
  if p_items is null or jsonb_array_length(p_items) = 0 then raise exception 'Add at least one item.'; end if;

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_qty := coalesce((v_item->>'qty')::numeric, 0);
    v_rate := coalesce((v_item->>'rate')::numeric, -1);
    if coalesce(trim(v_item->>'description'), '') = '' then raise exception 'Every item needs a description.'; end if;
    if v_qty <= 0 then raise exception 'Quantity must be more than zero.'; end if;
    if v_rate < 0 then raise exception 'Rate cannot be negative.'; end if;
    v_total := v_total + round(v_qty * v_rate, 2);
  end loop;
  if v_total <= 0 then raise exception 'Credit note total must be more than zero.'; end if;

  if p_invoice_id is not null then
    select * into inv from invoices where id = p_invoice_id;
    if inv is null then raise exception 'Invoice not found.'; end if;
    if inv.patient_id <> p_patient_id then raise exception 'That invoice belongs to a different patient.'; end if;
    if inv.status in ('Cancelled', 'Void') then raise exception '% is void.', inv.invoice_number; end if;
    select coalesce(sum(amount), 0) into v_other from credit_notes where invoice_id = p_invoice_id and status <> 'Void';
    if round(v_other + v_total, 2) > round(inv.net, 2) then
      raise exception 'Credit notes against % would total Rs.% -- more than its billed amount (Rs.%).', inv.invoice_number, v_other + v_total, inv.net;
    end if;
  end if;

  insert into credit_notes (credit_note_number, patient_id, invoice_id, amount, reason, approved_by, remarks, created_by, status)
  values (next_credit_note_number(), p_patient_id, p_invoice_id, v_total, trim(p_reason), p_approved_by, nullif(trim(coalesce(p_remarks, '')), ''), auth.uid(), 'Open')
  returning * into cn;

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_i := v_i + 1;
    insert into credit_note_items (credit_note_id, invoice_line_item_id, description, dept, qty, rate, amount, sort_order)
    values (cn.id, nullif(v_item->>'invoice_line_item_id', '')::uuid, trim(v_item->>'description'), nullif(v_item->>'dept', ''),
            (v_item->>'qty')::numeric, (v_item->>'rate')::numeric, round((v_item->>'qty')::numeric * (v_item->>'rate')::numeric, 2), v_i);
  end loop;

  if coalesce(p_apply_amount, 0) > 0 then
    if p_invoice_id is null then raise exception 'Pick an invoice to apply the credit to.'; end if;
    cn := cn_apply(cn.id, p_invoice_id, p_apply_amount);
  end if;

  return cn;
end;
$function$;

-- ─────────────────────────────────────────────────────────────────────
-- cn_void: cancel a credit note that has not been applied anywhere.
-- ─────────────────────────────────────────────────────────────────────
create or replace function public.cn_void(p_credit_note_id uuid, p_reason text)
returns credit_notes
language plpgsql
set search_path to 'public'
as $function$
declare
  cn credit_notes;
begin
  if p_reason is null or trim(p_reason) = '' then raise exception 'A reason is required to void a credit note.'; end if;
  if not has_billing_permission('invoice.void') then
    raise exception 'You do not have permission to void credit notes. Ask an Administrator.';
  end if;
  select * into cn from credit_notes where id = p_credit_note_id for update;
  if cn is null then raise exception 'Credit note not found.'; end if;
  if cn.status = 'Void' then raise exception 'Already void.'; end if;
  if exists (select 1 from credit_note_applications where credit_note_id = cn.id) then
    raise exception 'Credit note % has already been applied to an invoice and cannot be voided.', cn.credit_note_number;
  end if;
  update credit_notes set status = 'Void', voided_at = now(), voided_by = auth.uid(), void_reason = trim(p_reason)
   where id = cn.id returning * into cn;
  return cn;
end;
$function$;

grant execute on function public.cn_apply(uuid, uuid, numeric) to authenticated;
grant execute on function public.cn_create(uuid, uuid, jsonb, text, uuid, text, numeric) to authenticated;
grant execute on function public.cn_void(uuid, text) to authenticated;
