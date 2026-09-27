-- ============================================================================
-- 036 — Billing edit foundation (Zoho-style invoice & payment editing, Phase 1)
--
-- PURELY ADDITIVE. Creates new objects only; does not alter or replace any
-- existing table, function, trigger or policy, and does not touch any data.
-- Uses CREATE (not CREATE OR REPLACE) so it fails loudly if any name already
-- exists, instead of silently creating a second overload.
--
--   1. billing_permissions       per-designation rights (Administrator always allowed)
--   2. billing_audit_log         append-only history; UPDATE/DELETE blocked by trigger
--   3. has_billing_permission()  / assert_billing_edit_allowed()  — the gate every
--                                 later edit/void/delete function calls first
--   4. set_billing_permission()  Administrator-only toggle, audited
--   5. sync_invoice_paid()       paid = payments applied − active refunds (recalculated,
--                                 never incremented by hand)
--   6. billing_reconciliation()  lists any invoice/payment/credit inconsistency
--
-- Apply to BOTH Supabase projects (production + training).
-- ============================================================================

-- 1. Permissions ------------------------------------------------------------
create table public.billing_permissions (
  designation text not null,
  permission  text not null check (permission in (
    'invoice.edit',       -- edit an invoice dated today
    'invoice.edit_past',  -- edit an invoice from an earlier (not closed) day
    'invoice.void',
    'payment.edit',       -- edit a payment dated today
    'payment.edit_past',  -- edit a payment from an earlier (not closed) day
    'payment.delete'
  )),
  allowed     boolean not null default false,
  updated_by  uuid default auth.uid(),
  updated_at  timestamptz not null default now(),
  primary key (designation, permission)
);

alter table public.billing_permissions enable row level security;
-- Everyone signed in may read (the UI needs it to show/hide buttons).
-- No write policies: writes go only through set_billing_permission().
create policy billing_permissions_select on public.billing_permissions
  for select to authenticated using (true);

-- Defaults agreed with Ishan (27 Sep 2026): Front Executive may edit today's
-- invoices and payments; cannot touch past days, void or delete.
-- Administrator is always allowed in code, so needs no rows.
insert into public.billing_permissions (designation, permission, allowed, updated_by) values
  ('Front Executive', 'invoice.edit',      true,  null),
  ('Front Executive', 'invoice.edit_past', false, null),
  ('Front Executive', 'invoice.void',      false, null),
  ('Front Executive', 'payment.edit',      true,  null),
  ('Front Executive', 'payment.edit_past', false, null),
  ('Front Executive', 'payment.delete',    false, null);

-- 2. Append-only audit log ---------------------------------------------------
create table public.billing_audit_log (
  id          uuid primary key default gen_random_uuid(),
  entity_type text not null check (entity_type in ('invoice', 'payment', 'permission')),
  entity_id   uuid,
  entity_ref  text,          -- invoice / receipt number, or 'Designation:permission'
  action      text not null,
  reason      text,
  before_data jsonb,
  after_data  jsonb,
  changed_by  uuid default auth.uid(),
  changed_at  timestamptz not null default now()
);
create index billing_audit_log_entity_idx on public.billing_audit_log (entity_type, entity_id, changed_at desc);
create index billing_audit_log_changed_at_idx on public.billing_audit_log (changed_at desc);

alter table public.billing_audit_log enable row level security;
create policy billing_audit_log_select on public.billing_audit_log
  for select to authenticated using (true);
create policy billing_audit_log_insert on public.billing_audit_log
  for insert to authenticated with check (changed_by = auth.uid());
-- Deliberately no UPDATE / DELETE policies.

-- Belt and braces: even the service role cannot rewrite or erase history.
create function public.billing_audit_log_block_changes()
returns trigger language plpgsql as $$
begin
  raise exception 'The billing audit log is permanent: entries cannot be changed or deleted.';
end;
$$;
create trigger billing_audit_log_no_update_delete
  before update or delete on public.billing_audit_log
  for each row execute function public.billing_audit_log_block_changes();

-- 3. Permission checks -------------------------------------------------------
create function public.has_billing_permission(p_permission text)
returns boolean
language sql stable security definer set search_path = public
as $$
  select case
    when exists (select 1 from profiles where id = auth.uid() and designation = 'Administrator') then true
    else coalesce((
      select bp.allowed
      from billing_permissions bp
      join profiles p on p.designation = bp.designation
      where p.id = auth.uid() and bp.permission = p_permission
    ), false)
  end;
$$;

-- Raises a clear, staff-readable error if the current user may not perform
-- p_action on a transaction dated p_txn_date. p_action is one of
-- 'invoice.edit', 'invoice.void', 'payment.edit', 'payment.delete'.
create function public.assert_billing_edit_allowed(p_action text, p_txn_date date)
returns void
language plpgsql stable
as $$
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

  if p_action in ('invoice.edit', 'payment.edit')
     and p_txn_date < ist_date(now())
     and not has_billing_permission(p_action || '_past') then
    raise exception 'You can only % dated today. This one is from %. Ask an Administrator.',
      v_labels->>p_action, to_char(p_txn_date, 'DD Mon YYYY');
  end if;
end;
$$;

-- 4. Administrator toggle ----------------------------------------------------
create function public.set_billing_permission(p_designation text, p_permission text, p_allowed boolean)
returns billing_permissions
language plpgsql security definer set search_path = public
as $$
declare
  v_old boolean;
  v_row billing_permissions;
begin
  if not exists (select 1 from profiles where id = auth.uid() and designation = 'Administrator') then
    raise exception 'Only an Administrator can change billing permissions.';
  end if;
  if p_designation is null or trim(p_designation) = '' or p_designation = 'Administrator' then
    raise exception 'Administrators always have every billing permission; choose another designation.';
  end if;

  select allowed into v_old from billing_permissions
   where designation = p_designation and permission = p_permission;

  insert into billing_permissions (designation, permission, allowed, updated_by, updated_at)
  values (p_designation, p_permission, p_allowed, auth.uid(), now())
  on conflict (designation, permission)
  do update set allowed = excluded.allowed, updated_by = excluded.updated_by, updated_at = excluded.updated_at
  returning * into v_row;

  if v_old is distinct from p_allowed then
    insert into billing_audit_log (entity_type, entity_ref, action, before_data, after_data, changed_by)
    values ('permission', p_designation || ':' || p_permission,
            case when p_allowed then 'permission_granted' else 'permission_revoked' end,
            jsonb_build_object('allowed', coalesce(v_old, false)),
            jsonb_build_object('allowed', p_allowed),
            auth.uid());
  end if;

  return v_row;
end;
$$;

-- 5. Recalculation engine ----------------------------------------------------
-- The one rule, verified against all 687 production invoices on 27 Sep 2026:
--   paid = sum(payment_allocations) − sum(non-cancelled payment_refunds)
-- Cancelled / Void invoices are returned untouched (recompute_invoice_totals
-- would otherwise overwrite their status).
create function public.sync_invoice_paid(p_invoice_id uuid)
returns invoices
language plpgsql
as $$
declare
  inv invoices;
  v_paid numeric;
begin
  select * into inv from invoices where id = p_invoice_id for update;
  if inv is null then
    raise exception 'Invoice not found';
  end if;
  if inv.status in ('Cancelled', 'Void') then
    return inv;
  end if;

  select coalesce((select sum(amount) from payment_allocations where invoice_id = p_invoice_id), 0)
       - coalesce((select sum(amount) from payment_refunds where invoice_id = p_invoice_id and cancelled_at is null), 0)
    into v_paid;

  update invoices set paid = v_paid where id = p_invoice_id;

  -- recompute_invoice_totals() marks an invoice with net <= 0 as 'Paid'. An
  -- invoice with no items yet is still being built and must stay as it is.
  if not exists (select 1 from invoice_line_items where invoice_id = p_invoice_id) then
    select * into inv from invoices where id = p_invoice_id;
    return inv;
  end if;

  return recompute_invoice_totals(p_invoice_id);
end;
$$;

-- 6. Reconciliation ----------------------------------------------------------
-- Returns one row per problem; an empty result means everything is consistent.
create function public.billing_reconciliation()
returns table (check_name text, reference text, expected numeric, actual numeric)
language sql stable
as $$
  with alloc as (select invoice_id, sum(amount) s from payment_allocations group by 1),
       refs  as (select invoice_id, sum(amount) s from payment_refunds where cancelled_at is null group by 1),
       lines as (select invoice_id, sum(net) s from invoice_line_items group by 1)
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
     -- an invoice with no items yet is still being built and is legitimately 'Pending'
     and exists (select 1 from invoice_line_items li where li.invoice_id = i.id)
     and i.status <> case when i.net <= 0 then 'Paid' when i.paid <= 0 then 'Pending'
                          when i.paid >= i.net then 'Paid' else 'Partial' end
  union all
  -- credit notes and advance adjustments legitimately carry no payment modes
  select 'payment_modes_vs_total', p.receipt_number, round(p.total_amount, 2),
         round(coalesce((select sum(amount) from payment_modes m where m.payment_id = p.id), 0), 2)
    from payments p
   where p.payment_type not in ('credit_note', 'advance_adjustment')
     and round(p.total_amount, 2) <> round(coalesce((select sum(amount) from payment_modes m where m.payment_id = p.id), 0), 2)
  union all
  select 'negative_patient_credit', l.patient_id::text, 0, round(sum(l.amount), 2)
    from patient_ledger l group by l.patient_id having sum(l.amount) < 0;
$$;
