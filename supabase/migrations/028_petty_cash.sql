-- Petty Cash Expenses
-- Tracks the hospital's own day-to-day cash outgoings (stationery,
-- transport, refreshments, minor repairs, etc.) so Close Day
-- reconciliation for the Cash mode ties out against what actually
-- left the drawer, not just what came in.

-- ── Expense Categories (Financial Masters) ──
CREATE TABLE IF NOT EXISTS "public"."master_expense_categories" (
    "id" uuid DEFAULT gen_random_uuid() NOT NULL,
    "code" text NOT NULL,
    "name" text NOT NULL,
    "status" text NOT NULL DEFAULT 'Active'
);

ALTER TABLE "public"."master_expense_categories" OWNER TO "postgres";

ALTER TABLE ONLY "public"."master_expense_categories"
    ADD CONSTRAINT "master_expense_categories_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."master_expense_categories"
    ADD CONSTRAINT "master_expense_categories_code_key" UNIQUE ("code");

ALTER TABLE "public"."master_expense_categories"
    ADD CONSTRAINT "master_expense_categories_status_check" CHECK (("status" = ANY (ARRAY['Active'::text, 'Inactive'::text])));

ALTER TABLE "public"."master_expense_categories" ENABLE ROW LEVEL SECURITY;
CREATE POLICY "staff_all_access" ON "public"."master_expense_categories" TO "authenticated" USING (true) WITH CHECK (true);

GRANT ALL ON TABLE "public"."master_expense_categories" TO "anon";
GRANT ALL ON TABLE "public"."master_expense_categories" TO "authenticated";
GRANT ALL ON TABLE "public"."master_expense_categories" TO "service_role";

INSERT INTO "public"."master_expense_categories" (code, name) VALUES
  ('STA01', 'Stationery'),
  ('TRA01', 'Transport'),
  ('REF01', 'Refreshments'),
  ('REP01', 'Repairs & Maintenance'),
  ('MIS01', 'Miscellaneous')
ON CONFLICT (code) DO NOTHING;


-- ── Petty Cash Expenses ──
-- Entered by any staff on a day that is currently open (same
-- requireDayOpen() guard used by payment collection/refund). No
-- approval step by design -- kept lightweight, matching the low-stakes
-- nature of day-to-day petty spend.
CREATE TABLE IF NOT EXISTS "public"."petty_cash_expenses" (
    "id" uuid DEFAULT gen_random_uuid() NOT NULL,
    "expense_date" date NOT NULL,
    "category_id" uuid NOT NULL,
    "amount" numeric NOT NULL,
    "paid_to" text,
    "note" text,
    "entered_by" uuid,
    "created_at" timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT "petty_cash_expenses_amount_check" CHECK (("amount" > 0))
);

ALTER TABLE "public"."petty_cash_expenses" OWNER TO "postgres";

ALTER TABLE ONLY "public"."petty_cash_expenses"
    ADD CONSTRAINT "petty_cash_expenses_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."petty_cash_expenses"
    ADD CONSTRAINT "petty_cash_expenses_category_id_fkey" FOREIGN KEY ("category_id") REFERENCES "public"."master_expense_categories"("id");

ALTER TABLE ONLY "public"."petty_cash_expenses"
    ADD CONSTRAINT "petty_cash_expenses_entered_by_fkey" FOREIGN KEY ("entered_by") REFERENCES "public"."profiles"("id");

CREATE INDEX "idx_petty_cash_expenses_date" ON "public"."petty_cash_expenses" USING "btree" ("expense_date");

ALTER TABLE "public"."petty_cash_expenses" ENABLE ROW LEVEL SECURITY;
CREATE POLICY "staff_all_access" ON "public"."petty_cash_expenses" TO "authenticated" USING (true) WITH CHECK (true);

GRANT ALL ON TABLE "public"."petty_cash_expenses" TO "anon";
GRANT ALL ON TABLE "public"."petty_cash_expenses" TO "authenticated";
GRANT ALL ON TABLE "public"."petty_cash_expenses" TO "service_role";


-- ── Fold into Close Day ──
-- Stores the day's total petty cash spend alongside the other
-- Close Day totals, so Daily Report/History show it without a
-- separate join every time.
ALTER TABLE "public"."day_closings" ADD COLUMN IF NOT EXISTS "total_petty_cash_expenses" numeric DEFAULT 0 NOT NULL;

CREATE OR REPLACE FUNCTION "public"."close_day"("p_date" "date" DEFAULT NULL::"date", "p_notes" "text" DEFAULT NULL::"text") RETURNS "public"."day_closings"
    LANGUAGE "plpgsql"
    AS $$
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
begin
  v_date := coalesce(p_date, ist_date(now()));

  if is_day_closed(v_date) then
    raise exception 'This day has already been closed.';
  end if;

  select count(distinct pm.mode) into v_modes_expected
  from payment_modes pm join payments p on p.id = pm.payment_id
  where ist_date(p.collected_at) = v_date;

  select count(*) into v_modes_reconciled from day_reconciliation where closing_date = v_date;

  if v_modes_expected > 0 and v_modes_reconciled < v_modes_expected then
    raise exception 'Reconciliation is incomplete for %s -- % of % payment modes reconciled. Complete reconciliation before closing.', v_date, v_modes_reconciled, v_modes_expected;
  end if;

  select coalesce(sum(net),0), coalesce(sum(paid),0), coalesce(sum(net - paid),0), count(*)
  into v_revenue, v_collected, v_outstanding, v_invoice_count
  from invoices where ist_date(created_at) = v_date;

  select count(*) into v_visit_count from visits where ist_date(created_at) = v_date;

  select coalesce(sum(amount),0) into v_petty_cash from petty_cash_expenses where expense_date = v_date;

  insert into day_closings (closing_date, closed_by, total_revenue, total_collected, total_outstanding, total_invoices, total_visits, notes, total_petty_cash_expenses)
  values (v_date, auth.uid(), v_revenue, v_collected, v_outstanding, v_invoice_count, v_visit_count, p_notes, v_petty_cash)
  returning * into closing;

  return closing;
end;
$$;

