-- Optical Shop billing lives in its own table (optical_sales mirrors
-- invoices: net/paid/status) but was never folded into Total Revenue/
-- Outstanding, even after Payment Mode Summary and Income by Category
-- were extended to include Optical cash movement -- leaving Total
-- Revenue silently hospital-only while everything collected against
-- it (Total Collected) already counted Optical. That's what made
-- "Total Revenue + Advance Collected" fail to reconcile against
-- Total Collected on the Daily Report's Day Totals table.

CREATE OR REPLACE FUNCTION public.close_day(p_date date DEFAULT NULL::date, p_notes text DEFAULT NULL::text)
 RETURNS day_closings
 LANGUAGE plpgsql
AS $function$
declare
  closing day_closings;
  v_revenue numeric;
  v_collected numeric;
  v_outstanding numeric;
  v_invoice_count int;
  v_visit_count int;
  v_date date;
  v_modes_expected int;
  v_modes_reconciled int;
  v_petty_cash numeric;
  v_optical_revenue numeric;
  v_optical_outstanding numeric;
begin
  v_date := coalesce(p_date, ist_date(now()));

  if is_day_closed(v_date) then
    raise exception 'This day has already been closed.';
  end if;

  -- Modes needing reconciliation now include Optical Shop cash
  -- movement (sale_payment/advance), not just hospital payments --
  -- Today's Collection / Reconciliation folded optical in at the app
  -- layer, so this gate must recognise the same modes or a day with
  -- optical-only cash in some mode could be closed without ever
  -- reconciling that mode.
  select count(distinct mode) into v_modes_expected from (
    select pm.mode from payment_modes pm join payments p on p.id = pm.payment_id
    where ist_date(p.collected_at) = v_date
    union
    select opm.mode from optical_payment_modes opm join optical_payments op on op.id = opm.payment_id
    where ist_date(op.collected_at) = v_date and op.payment_type in ('sale_payment', 'advance')
  ) modes_today;

  select count(*) into v_modes_reconciled from day_reconciliation where closing_date = v_date;

  if v_modes_expected > 0 and v_modes_reconciled < v_modes_expected then
    raise exception 'Reconciliation is incomplete for %s -- % of % payment modes reconciled. Complete reconciliation before closing.', v_date, v_modes_reconciled, v_modes_expected;
  end if;

  -- Cancelled invoices carry no real revenue or receivable -- billing's
  -- own active-invoice views already exclude status = 'Cancelled'
  -- everywhere else, so a cancelled invoice with nothing paid must not
  -- inflate Revenue or get counted as Outstanding here either.
  select coalesce(sum(net),0), coalesce(sum(paid),0), coalesce(sum(net - paid),0), count(*)
  into v_revenue, v_collected, v_outstanding, v_invoice_count
  from invoices where ist_date(created_at) = v_date and status <> 'Cancelled';

  select coalesce(sum(net),0), coalesce(sum(net - paid),0)
  into v_optical_revenue, v_optical_outstanding
  from optical_sales where sale_date = v_date and status <> 'Cancelled';

  v_revenue := v_revenue + v_optical_revenue;
  v_outstanding := v_outstanding + v_optical_outstanding;

  select count(*) into v_visit_count from visits where ist_date(created_at) = v_date;

  select coalesce(sum(amount),0) into v_petty_cash from petty_cash_expenses where expense_date = v_date;

  insert into day_closings (closing_date, closed_by, total_revenue, total_collected, total_outstanding, total_invoices, total_visits, notes, total_petty_cash_expenses)
  values (v_date, auth.uid(), v_revenue, v_collected, v_outstanding, v_invoice_count, v_visit_count, p_notes, v_petty_cash)
  returning * into closing;

  return closing;
end;
$function$;
