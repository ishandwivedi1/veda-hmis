-- RLS hardening -- Phase 1
--
-- Every table in this database currently has a single policy:
-- `USING (true) WITH CHECK (true)` for role `authenticated`. That
-- means every server-side permission check in the app (Administrator
-- gates, day-open guards, etc.) is a convenience, not a real
-- boundary -- anyone with a valid login can bypass all of them by
-- calling the Supabase client directly from the browser console.
--
-- This migration closes the two gaps that matter most and are safe
-- to fix without risking real functionality:
--   1. profiles: currently any logged-in user can grant themselves
--      Administrator by updating their own row. Fixed with a trigger
--      that blocks changing designation/status unless the acting
--      user is already an Administrator (or the change comes from
--      the service-role admin client, used by createUser()).
--   2. Financial/audit tables that no part of the app ever deletes
--      from (invoices, payments, day closings, the append-only
--      journey/audit logs) currently allow DELETE anyway, purely
--      because the blanket policy covers every operation. Removing
--      just the DELETE capability from these doesn't change any
--      existing behavior -- nothing in the codebase issues a delete
--      against them -- it only removes a capability nothing uses.
--
-- Deliberately NOT changed in this pass: SELECT/INSERT/UPDATE access
-- across clinical and operational tables. A full per-designation
-- redesign (e.g. only Doctor can write clinical_examinations, only
-- Front Office can write invoices) would be far more valuable but is
-- also much higher-risk to get right without a way to click through
-- every role's workflow end-to-end first -- that's a deliberate,
-- separately-tested Phase 2, not something to rush alongside
-- everything else in this session.

-- ── 1. profiles: block self-escalation ──
CREATE OR REPLACE FUNCTION "public"."prevent_profile_role_escalation"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
begin
  -- The admin client (service_role) is what createUser() uses to set
  -- up a brand new profile's designation -- always allowed.
  if auth.role() = 'service_role' then
    return new;
  end if;

  if (new.designation is distinct from old.designation) or (new.status is distinct from old.status) then
    if not exists (select 1 from profiles where id = auth.uid() and designation = 'Administrator') then
      raise exception 'Only an Administrator can change designation or status.';
    end if;
  end if;

  return new;
end;
$$;

DROP TRIGGER IF EXISTS "trg_prevent_profile_role_escalation" ON "public"."profiles";
CREATE TRIGGER "trg_prevent_profile_role_escalation"
  BEFORE UPDATE ON "public"."profiles"
  FOR EACH ROW EXECUTE FUNCTION "public"."prevent_profile_role_escalation"();

DROP POLICY IF EXISTS "staff_all_access" ON "public"."profiles";

-- Reading the staff list (names, designations, online status) is
-- needed broadly -- queue displays, approver dropdowns, "who's
-- online", print templates showing a doctor's name, etc.
CREATE POLICY "profiles_select_all" ON "public"."profiles"
  FOR SELECT TO "authenticated" USING (true);

-- A person can update their own row (heartbeat, self-service fields)
-- -- but the trigger above still blocks them from touching their own
-- designation/status even here. An Administrator can update anyone's
-- row, since updateUserProfile()/toggleUserStatus() run through the
-- regular (RLS-bound) client, not the admin client.
CREATE POLICY "profiles_update_self_or_admin" ON "public"."profiles"
  FOR UPDATE TO "authenticated"
  USING (id = auth.uid() OR EXISTS (SELECT 1 FROM profiles p WHERE p.id = auth.uid() AND p.designation = 'Administrator'))
  WITH CHECK (id = auth.uid() OR EXISTS (SELECT 1 FROM profiles p WHERE p.id = auth.uid() AND p.designation = 'Administrator'));

-- Direct inserts from a non-admin session were never a real path
-- (createUser always goes through the admin client, which bypasses
-- RLS) -- this is pure defense-in-depth against someone trying it
-- manually.
CREATE POLICY "profiles_insert_admin_only" ON "public"."profiles"
  FOR INSERT TO "authenticated"
  WITH CHECK (EXISTS (SELECT 1 FROM profiles p WHERE p.id = auth.uid() AND p.designation = 'Administrator'));

-- No DELETE policy at all -- nothing in the app deletes a profile
-- (deactivation uses status = 'Inactive' instead), so this is simply
-- removing a capability nothing uses.


-- ── 2. Financial and audit tables: remove unused DELETE capability ──
-- Each of these keeps its exact current SELECT/INSERT/UPDATE access
-- (still USING (true) WITH CHECK (true) for authenticated) -- only
-- DELETE is dropped, and only for tables where no app code issues one.
DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'invoices', 'invoice_line_items', 'payments', 'payment_modes',
    'day_closings', 'day_reconciliation',
    'visit_journey_events', 'master_data_audit_log'
  ]
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS "staff_all_access" ON "public".%I', t);
    EXECUTE format('CREATE POLICY "select_all" ON "public".%I FOR SELECT TO "authenticated" USING (true)', t);
    EXECUTE format('CREATE POLICY "insert_all" ON "public".%I FOR INSERT TO "authenticated" WITH CHECK (true)', t);
    EXECUTE format('CREATE POLICY "update_all" ON "public".%I FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true)', t);
    -- No DELETE policy created -- deliberately omitted.
  END LOOP;
END $$;
