-- ============================================================================
-- 038b — Fix: invoice edits must run with owner rights (found 27 Sep 2026)
--
-- invoice_line_items (and payments) have no DELETE row-security policy, so
-- when edit_invoice() ran with the signed-in staff member's rights, removing
-- an item was silently skipped (0 rows) while the edit was still logged.
-- Found before any real use (no invoice edits existed in production or
-- training).
--
-- Fix: run the gated edit functions as their owner (SECURITY DEFINER) with a
-- fixed search_path. Every check inside them still uses the signed-in user
-- (auth.uid() comes from the request's JWT): permission, closed day, reason.
-- Staff still cannot delete rows directly; only through these functions.
-- Settings-only change (ALTER FUNCTION): bodies untouched, no new versions.
-- Anonymous callers lose EXECUTE.
-- ============================================================================

alter function public.edit_invoice(uuid, jsonb, text, numeric) security definer;
alter function public.edit_invoice(uuid, jsonb, text, numeric) set search_path = public;
alter function public.change_invoice_date(uuid, date, text) security definer;
alter function public.change_invoice_date(uuid, date, text) set search_path = public;

revoke execute on function public.edit_invoice(uuid, jsonb, text, numeric) from public, anon;
grant  execute on function public.edit_invoice(uuid, jsonb, text, numeric) to authenticated;
revoke execute on function public.change_invoice_date(uuid, date, text) from public, anon;
grant  execute on function public.change_invoice_date(uuid, date, text) to authenticated;
