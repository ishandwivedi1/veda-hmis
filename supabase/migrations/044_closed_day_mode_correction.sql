-- 044: Correct a payment's MODE on a closed day without reopening it.
--
-- Why: the commonest correction is "this was UPI, not Cash". Until now that
-- needed Reopen Day -> edit -> redo reconciliation -> close again, and on
-- 2 Oct 2026 that left the reconciliation's counted (Actual) figures stale.
--
-- What it does (Administrator only, closed days only):
--   * re-splits the payment's modes -- the TOTAL must stay the same
--     (amount/date/invoice changes still need the day reopened);
--   * moves the same amounts between that day's reconciliation rows, on
--     BOTH Expected and Actual, so each mode's variance is unchanged and
--     the day's totals stay identical;
--   * never touches Cash Counter (cash handed over) -- the screen warns
--     when Cash is involved;
--   * mode rows are replaced by the existing edit_payment_clerical();
--   * logs payment_edits + billing_audit_log ('payment_modes_corrected_closed_day').
--
-- Additive: new function only. edit_payment / delete_payment /
-- assert_billing_edit_allowed are unchanged.

create or replace function public.correct_closed_day_payment_modes(
  p_payment_id uuid,
  p_modes jsonb,
  p_reference text,
  p_remarks text,
  p_reason text,
  p_expected_amount numeric
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  pay payments;
  v_date date;
  v_before jsonb;
  v_after jsonb;
  v_mode jsonb;
  v_sum numeric := 0;
  v_old_modes jsonb;
  v_deltas jsonb := '{}'::jsonb;
  r record;
  v_updated int;
  v_clean jsonb;
begin
  if p_reason is null or trim(p_reason) = '' then
    raise exception 'A reason is required.';
  end if;
  if not exists (select 1 from profiles where id = auth.uid() and designation = 'Administrator') then
    raise exception 'Only an Administrator can correct a payment on a closed day.';
  end if;

  select * into pay from payments where id = p_payment_id for update;
  if pay is null then raise exception 'Payment not found.'; end if;
  if pay.payment_type not in ('invoice_payment', 'advance') then
    raise exception 'Only payments and advances can be corrected here.';
  end if;

  v_date := ist_date(pay.collected_at);
  if not is_day_closed(v_date) then
    raise exception '% is not closed -- use the normal Edit instead.', to_char(v_date, 'DD Mon YYYY');
  end if;

  if p_expected_amount is not null and round(pay.total_amount, 2) <> round(p_expected_amount, 2) then
    raise exception 'This payment was changed by someone else since you opened it. Close and reopen it, then try again.';
  end if;
  if exists (select 1 from payment_refunds where payment_id = p_payment_id and cancelled_at is null) then
    raise exception 'This payment has a refund recorded against it. Cancel that refund first.';
  end if;

  if p_modes is null or jsonb_array_length(p_modes) = 0 then
    raise exception 'Enter at least one payment mode.';
  end if;
  for v_mode in select * from jsonb_array_elements(p_modes) loop
    if coalesce((v_mode->>'amount')::numeric, 0) <= 0 or coalesce(trim(v_mode->>'mode'), '') = '' then
      raise exception 'Every payment mode needs a name and an amount above zero.';
    end if;
    v_sum := v_sum + (v_mode->>'amount')::numeric;
  end loop;
  if round(v_sum, 2) <> round(pay.total_amount, 2) then
    raise exception 'On a closed day only the split between modes can change. Modes must add up to Rs.% (they add up to Rs.%). To change the amount, reopen the day.', pay.total_amount, v_sum;
  end if;

  v_before := payment_edit_snapshot(p_payment_id);
  select coalesce(jsonb_agg(jsonb_build_object('mode', mode, 'amount', amount)), '[]'::jsonb) into v_old_modes
    from payment_modes where payment_id = p_payment_id;

  -- Per-mode change = new - old.
  for r in
    select mode, round(sum(amt), 2) as delta from (
      select trim(x->>'mode') as mode, (x->>'amount')::numeric as amt from jsonb_array_elements(p_modes) x
      union all
      select mode, -amount from payment_modes where payment_id = p_payment_id
    ) d group by mode having round(sum(amt), 2) <> 0
  loop
    v_deltas := v_deltas || jsonb_build_object(r.mode, r.delta);
    update day_reconciliation
       set expected = expected + r.delta,
           actual = actual + r.delta,
           variance = (actual + r.delta) - (expected + r.delta)
     where closing_date = v_date and mode = r.mode;
    get diagnostics v_updated = row_count;
    if v_updated = 0 then
      insert into day_reconciliation (closing_date, mode, expected, actual, variance, reason, saved_by)
      values (v_date, r.mode, r.delta, r.delta, 0,
              'Added by closed-day mode correction of ' || coalesce(pay.receipt_number, '-'), auth.uid());
    end if;
  end loop;

  if v_deltas = '{}'::jsonb and coalesce(p_reference, '') = coalesce(pay.reference, '') and coalesce(p_remarks, '') = coalesce(pay.remarks, '') then
    raise exception 'Nothing was changed.';
  end if;

  -- Replace the mode rows via the existing edit_payment_clerical (keeps
  -- the total fixed, locks the row, writes payment_edits).
  select coalesce(jsonb_agg(jsonb_build_object('mode', trim(x->>'mode'), 'amount', (x->>'amount')::numeric)), '[]'::jsonb)
    into v_clean from jsonb_array_elements(p_modes) x;
  perform edit_payment_clerical(
    p_payment_id, v_clean,
    nullif(trim(coalesce(p_reference, '')), ''),
    nullif(trim(coalesce(p_remarks, '')), ''),
    trim(p_reason) || ' [closed day ' || to_char(v_date, 'DD Mon YYYY') || ']',
    null);
  select * into pay from payments where id = p_payment_id;

  v_after := payment_edit_snapshot(p_payment_id) || jsonb_build_object('closed_day', v_date, 'reconciliation_moved', v_deltas);
  insert into billing_audit_log (entity_type, entity_id, entity_ref, action, reason, before_data, after_data, changed_by)
  values ('payment', p_payment_id, pay.receipt_number, 'payment_modes_corrected_closed_day', trim(p_reason), v_before, v_after, auth.uid());

  return jsonb_build_object('receipt_number', pay.receipt_number, 'date', v_date, 'moved', v_deltas,
                            'cash_change', coalesce((v_deltas->>'Cash')::numeric, 0));
end;
$function$;

grant execute on function public.correct_closed_day_payment_modes(uuid, jsonb, text, text, text, numeric) to authenticated;
