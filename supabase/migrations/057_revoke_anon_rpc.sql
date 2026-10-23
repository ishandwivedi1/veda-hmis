-- 057: security -- logged-out visitors can no longer call privileged
-- database functions (found 23 Oct 2026 by the Supabase security advisor).
--
-- These SECURITY DEFINER functions bypass row-level security, and by
-- default anyone holding the site's public (anon) key -- visible in any
-- browser -- could call them without logging in:
--   * book_ot_slot        -- no login/permission check inside (!)
--   * reschedule_ot_slot  -- no permission check inside (!)
--   * get_doctor_override_assessment_ids, has_billing_permission,
--     set_billing_permission, correct_closed_day_payment_modes -- these
--     already refuse or reveal nothing to a logged-out caller; tightened
--     here too as defence in depth.
-- The app only ever calls them with a logged-in session, so staff see no
-- difference. Trigger functions (handle_new_user,
-- prevent_profile_role_escalation) cannot be called directly and are left
-- alone. Safe to run more than once. Apply to production AND training.

revoke execute on function public.book_ot_slot(uuid, date, uuid, uuid, text) from public, anon;
grant execute on function public.book_ot_slot(uuid, date, uuid, uuid, text) to authenticated;

revoke execute on function public.reschedule_ot_slot(uuid, date, uuid, text) from public, anon;
grant execute on function public.reschedule_ot_slot(uuid, date, uuid, text) to authenticated;

revoke execute on function public.get_doctor_override_assessment_ids(uuid[]) from public, anon;
grant execute on function public.get_doctor_override_assessment_ids(uuid[]) to authenticated;

revoke execute on function public.has_billing_permission(text) from public, anon;
grant execute on function public.has_billing_permission(text) to authenticated;

revoke execute on function public.set_billing_permission(text, text, boolean) from public, anon;
grant execute on function public.set_billing_permission(text, text, boolean) to authenticated;

revoke execute on function public.correct_closed_day_payment_modes(uuid, jsonb, text, text, text, numeric) from public, anon;
grant execute on function public.correct_closed_day_payment_modes(uuid, jsonb, text, text, text, numeric) to authenticated;
