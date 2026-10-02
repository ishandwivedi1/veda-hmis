-- 043: Separate Without Dilatation lists for Posterior Segment Disc/CDR.
-- Data only (applied to production + training, 2 Oct 2026). The Examination
-- tab reads structure "<Struct> (Without Dilatation)" during the Without
-- Dilatation pass; With Dilatation keeps the plain "Disc"/"CDR" lists.
with src as (
  select structure || ' (Without Dilatation)' as structure, name, sort_order,
         row_number() over (order by case structure when 'Disc' then 1 else 2 end, sort_order) as rn
  from public.master_exam_options where region='posterior' and structure in ('Disc','CDR') and status='Active'
), base as (
  select coalesce(max(substring(code from 4)::int),0) as mx from public.master_exam_options where code ~ '^EXO[0-9]+$'
)
insert into public.master_exam_options (region, structure, name, sort_order, code)
select 'posterior', s.structure, s.name, s.sort_order, 'EXO' || lpad((b.mx + s.rn)::text, 3, '0') from src s, base b
on conflict (region, structure, name) do nothing;

-- Doctor asked for PPA+ under Without Dilatation only.
update public.master_exam_options set status='Inactive'
where region='posterior' and structure='Disc' and name='PPA+';
