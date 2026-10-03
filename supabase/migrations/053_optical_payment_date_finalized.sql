-- 053: Optical payment date edit -> Daily Report follows it.
--
-- Found 3 Oct 2026 (training): a payment moved from 3 Oct to 2 Oct still
-- counted its bill under 3 Oct in the Daily Report's "Optical Shop Sales"
-- row, because optical_payment_edit recomputed the bill's finalized_at
-- BEFORE it changed the payment's date. Same function, same signature --
-- only the recompute is repeated after the date update. Then a one-time
-- fix for bills whose payment dates were already edited.
-- Run on BOTH databases (training + production).

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

  -- 053: the bill's "fully paid on" date (optical_sales.finalized_at --
  -- what the Daily Report's Optical Shop Sales row is dated by) must
  -- follow the payment's NEW date. The recompute above ran before the
  -- date was changed, so it is run again here.
  if pay.sale_id is not null then
    perform recompute_optical_sale_status(pay.sale_id);
  end if;

  return pay;
end;
$function$;


-- One-time fix: bills whose payment date was edited before this change.
select recompute_optical_sale_status(s.id)
from optical_sales s
where s.status = 'Paid'
  and exists (
    select 1 from optical_payment_edits e join optical_payments p on p.id = e.payment_id
    where p.sale_id = s.id and e.old_date is distinct from e.new_date
  );
