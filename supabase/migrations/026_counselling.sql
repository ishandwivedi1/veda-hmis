-- =====================================================================
-- Migration 026: Counselling (M22)
-- Verify this is actually the next free number in your migrations
-- folder before running -- renumber if not.
--
-- Adds IOL type/origin classification to Master Data so packages can be
-- filtered by the IOL type advised at Biometry (M23), and extends
-- surgical_cases with the fields the Counselling workspace needs
-- (decision, investigations flag, advance payment link, surgeon/priority).
-- Nothing here touches biometry_records, plan_counselling_items or
-- workflow_requests -- those already support this flow as-is.
-- =====================================================================

-- 1. IOL classification on Master Data -----------------------------------
alter table public.master_iol_catalog
  add column if not exists origin text
    check (origin in ('Indian','Imported'));
comment on column public.master_iol_catalog.origin is
  'Indian or Imported make of this specific IOL SKU.';

alter table public.master_packages
  add column if not exists iol_category text
    check (iol_category in ('Monofocal','Monofocal Toric','Multifocal','EDOF')),
  add column if not exists origin text
    check (origin in ('Indian','Imported'));
comment on column public.master_packages.iol_category is
  'Matches biometry_records.final_iol_category. Package is only shown during
   counselling once biometry has advised this IOL type. NULL = not IOL-
   specific (e.g. Glaucoma surgery package), shown regardless of IOL type.';
comment on column public.master_packages.origin is
  'Indian or Imported IOL make -- price tier within an iol_category.
   NULL for non-IOL packages.';

-- 2. Extend surgical_cases for the Counselling workspace ------------------
alter table public.surgical_cases
  add column if not exists visit_id uuid references public.visits(id),
  add column if not exists surgeon_id uuid references public.profiles(id),
  add column if not exists priority text not null default 'Routine'
    check (priority in ('Routine','Urgent','Emergency')),
  add column if not exists iol_category text
    check (iol_category in ('Monofocal','Monofocal Toric','Multifocal','EDOF')),
  add column if not exists decision text
    check (decision in ('Accepted','Wants Time to Decide','Discuss with Family',
                         'Financial Constraint','Declined','Second Opinion','Other')),
  add column if not exists decision_reason text,
  add column if not exists investigations_complete boolean not null default false,
  add column if not exists advance_payment_id uuid references public.payments(id);

comment on column public.surgical_cases.iol_category is
  'Denormalized from biometry_records.final_iol_category once Biometry is
   Approved -- lets the counselling package picker filter Master Data
   packages without joining to biometry_records every time.';
comment on column public.surgical_cases.advance_payment_id is
  'Set once an advance is collected in M11 against the package chosen here.';

-- Backfill visit_id from the linked encounter, where available.
update public.surgical_cases sc
set visit_id = e.visit_id
from public.encounters e
where sc.encounter_id = e.id and sc.visit_id is null;

-- 3. Counselling notes log -------------------------------------------------
create table if not exists public.surgical_case_notes (
  id uuid primary key default gen_random_uuid(),
  surgical_case_id uuid not null references public.surgical_cases(id),
  note text not null,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now()
);

alter table public.surgical_case_notes enable row level security;

create policy "staff_all_access" on public.surgical_case_notes
  for all using (true) with check (true);

-- 4. Helper view -- keeps biometry_records.final_iol_category in sync with
--    surgical_cases.iol_category automatically whenever Biometry is
--    approved, so the app doesn't have to remember to do it in two places.
create or replace function public.sync_surgical_case_iol_category()
returns trigger
language plpgsql
as $$
begin
  if new.status = 'Approved' and new.final_iol_category is not null then
    update public.surgical_cases
    set iol_category = new.final_iol_category,
        biometry_done = true
    where encounter_id = new.encounter_id
      and (iol_category is distinct from new.final_iol_category or biometry_done = false);
  end if;
  return new;
end;
$$;

drop trigger if exists trg_sync_surgical_case_iol_category on public.biometry_records;
create trigger trg_sync_surgical_case_iol_category
  after insert or update on public.biometry_records
  for each row execute function public.sync_surgical_case_iol_category();
