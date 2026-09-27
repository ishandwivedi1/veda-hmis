-- ============================================================================
-- 040c — Retire the old, unguarded billing-change paths (27 Sep 2026)
--
-- No screen uses these any more (verified: no references in app/ or lib/):
--   cancel_invoice            -> replaced by void_invoice (permission-gated)
--   remove_invoice_line_item  -> replaced by edit_invoice (and it silently
--                                skipped deletes for staff anyway, see 038b)
--   edit_payment_clerical     -> replaced by edit_payment
--   correct_payment_amount    -> replaced by edit_payment (it rewrote old
--                                credit entries; the new path never does)
--
-- They had no Billing Permissions check, so any signed-in user could still
-- call them directly. EXECUTE is revoked for signed-in and anonymous users;
-- functions are NOT dropped (restore with a single GRANT if ever needed).
-- ============================================================================

revoke execute on function public.cancel_invoice(uuid, text) from public, anon, authenticated;
revoke execute on function public.remove_invoice_line_item(uuid, text) from public, anon, authenticated;
revoke execute on function public.edit_payment_clerical(uuid, jsonb, text, text, text, integer) from public, anon, authenticated;
revoke execute on function public.correct_payment_amount(uuid, numeric, text) from public, anon, authenticated;
