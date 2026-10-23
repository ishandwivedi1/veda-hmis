-- 055: keep growing lists fast (23 Oct 2026).
--
-- 1. ui_optometry_history_page -- Optometry > Assessment History.
--    ui_optometry_history (048) returns EVERY assessment ever recorded
--    (~900 on 23 Oct 2026, +~340/month; ~0.5 s of database time and
--    growing linearly). This returns one page instead: newest first,
--    p_limit rows (default 50), older pages via p_before (the created_at of
--    the last row already shown), and p_search matched on the SERVER across
--    all records (patient name, UHID or visit number) -- so nothing becomes
--    unreachable. Same row shape as ui_optometry_history.
--
-- 2. ui_optical_advance_balances -- Optical dashboard.
--    The dashboard downloaded every optical_customer_ledger row ever written
--    just to add them up. This returns one row per customer identity with
--    its summed balance (zero balances left out). Same columns the screen
--    already reads (patient_id, optical_customer_id, amount), so the shop
--    total and each booking's advance-on-file come out identical.
--
-- Purely additive: two new read-only functions; nothing existing changes.
-- The app falls back to the old behaviour until this is applied.
-- Apply to production AND training.

create or replace function public.ui_optometry_history_page(
  p_status text default null,
  p_search text default null,
  p_limit integer default 50,
  p_before timestamptz default null
) returns jsonb
language sql
stable
security invoker
set search_path = public
as $$
  with term as (
    select nullif(btrim(coalesce(p_search, '')), '') as t
  ), page as (
    select a.*
    from optometry_assessments a
    left join visits v on v.id = a.visit_id
    left join patients pt on pt.id = v.patient_id
    cross join term
    where (p_status is null or a.status = p_status)
      and (p_before is null or a.created_at < p_before)
      and (term.t is null
           or pt.uhid ilike '%' || term.t || '%'
           or pt.first_name ilike '%' || term.t || '%'
           or pt.last_name ilike '%' || term.t || '%'
           or (coalesce(pt.first_name, '') || ' ' || coalesce(pt.last_name, '')) ilike '%' || term.t || '%'
           or v.visit_number ilike '%' || term.t || '%')
    order by a.created_at desc
    limit least(greatest(coalesce(p_limit, 50), 1), 200)
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', a.id, 'visit_id', a.visit_id, 'status', a.status,
      'created_at', a.created_at, 'updated_at', a.updated_at, 'completed_at', a.completed_at,
      're_dist_unaided', a.re_dist_unaided, 'le_dist_unaided', a.le_dist_unaided,
      'visits', case when v.id is null then null else jsonb_build_object('visit_number', v.visit_number,
                  'patients', case when pt.id is null then null else jsonb_build_object(
                    'first_name', pt.first_name, 'salutation', pt.salutation, 'last_name', pt.last_name, 'uhid', pt.uhid) end) end,
      'recorded_by_profile', case when rp.id is null then null else jsonb_build_object('full_name', rp.full_name) end,
      'completed_by_profile', case when cp.id is null then null else jsonb_build_object('full_name', cp.full_name) end,
      'iopRe', (select r.value from optometry_iop_readings r where r.assessment_id = a.id and r.eye = 'RE' order by r.recorded_at desc limit 1),
      'iopLe', (select r.value from optometry_iop_readings r where r.assessment_id = a.id and r.eye = 'LE' order by r.recorded_at desc limit 1),
      'hasDoctorCorrection', exists (select 1 from optometry_audit_log l where l.assessment_id = a.id and l.message like 'Doctor override%'),
      'queueEntryId', (select qe.id from queue_entries qe where qe.visit_id = a.visit_id and qe.department = 'Optometry' order by qe.issued_at desc limit 1)
    ) order by a.created_at desc), '[]'::jsonb)
  from page a
  left join visits v on v.id = a.visit_id
  left join patients pt on pt.id = v.patient_id
  left join profiles rp on rp.id = a.recorded_by
  left join profiles cp on cp.id = a.completed_by;
$$;

create index if not exists idx_optometry_assessments_created_at on public.optometry_assessments (created_at desc);

create or replace function public.ui_optical_advance_balances()
returns table (patient_id uuid, optical_customer_id uuid, amount numeric)
language sql
stable
security invoker
set search_path = public
as $$
  select l.patient_id, l.optical_customer_id, sum(l.amount)::numeric as amount
  from optical_customer_ledger l
  group by l.patient_id, l.optical_customer_id
  having sum(l.amount) <> 0;
$$;

grant execute on function public.ui_optometry_history_page(text, text, integer, timestamptz) to authenticated;
grant execute on function public.ui_optical_advance_balances() to authenticated;
