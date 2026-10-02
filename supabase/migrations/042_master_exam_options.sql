-- 042: Examination options become a Clinical Master.
--
-- The pill/dropdown options in the doctor's Examination tab (External,
-- Anterior Segment, Posterior Segment, Gonioscopy) used to be hard-coded
-- in app/consultation/[id]/examination-tab.js. They now live here so staff
-- can add, rename, reorder, deactivate or delete them from Clinical Masters.
--
-- Additive only: a new table, nothing existing is altered. Saved
-- examinations store the chosen text itself, so changing options here
-- never rewrites past patient records.
--
-- sort_order matters: the FIRST active option of a structure is what
-- "All Normal" fills in (e.g. Conjunctiva -> Normal, Cornea -> Clear).

create table if not exists public.master_exam_options (
  id uuid primary key default gen_random_uuid(),
  region text not null check (region in ('external', 'anterior', 'posterior', 'gonioscopy')),
  structure text not null,
  name text not null,
  sort_order integer not null default 0,
  status text not null default 'Active' check (status in ('Active', 'Inactive')),
  code text not null,
  created_at timestamptz not null default now(),
  unique (region, structure, name),
  unique (code)
);

create index if not exists idx_master_exam_options_lookup
  on public.master_exam_options (region, structure, status, sort_order);

alter table public.master_exam_options enable row level security;

create policy staff_all_access on public.master_exam_options
  for all to authenticated using (true) with check (true);

-- Seed with the exact lists in use today (2 Oct 2026), in their current order.
insert into public.master_exam_options (region, structure, name, sort_order, code)
select v.region, v.structure, v.name, v.ord, 'EXO' || lpad(row_number() over (order by v.region_ord, v.struct_ord, v.ord)::text, 3, '0')
from (
  select r.region, r.region_ord, s.structure, s.struct_ord, o.name, o.ord
  from (values
    ('external', 1), ('anterior', 2), ('posterior', 3), ('gonioscopy', 4)
  ) as r(region, region_ord)
  join (values
    ('external', 'Lids', 1, array['Normal','Blepharitis','Ptosis','Entropion','Ectropion','Chalazion','Stye']),
    ('external', 'Adnexa', 2, array['Normal','Swelling','Mass']),
    ('external', 'Lacrimal', 3, array['Patent','Watering','Blocked','Dacryocystitis']),
    ('external', 'Motility', 4, array['Full','Restriction','Squint','Nystagmus']),
    ('anterior', 'Conjunctiva', 1, array['Normal','Congested','Subconjunctival haemorrhage']),
    ('anterior', 'Cornea', 2, array['Clear','Scar','Ulcer','Edema','Pterygium','Guttae','DMF','KP''s']),
    ('anterior', 'Anterior Chamber', 3, array['Deep & Quiet','Shallow','Cells+','Hypopyon','Hyphema']),
    ('anterior', 'Iris', 4, array['Normal Pattern','Rubeosis','Heterochromia','Synechiae']),
    ('anterior', 'Pupil', 5, array['Round & Reactive','RAPD','Irregular','Fixed & Dilated']),
    ('anterior', 'Lens', 6, array['Clear','NS1','NS2','NS3','NS4','PSC','Cortical','Mature','Hypermature','IMSC','PCIOL','Aphakia']),
    ('posterior', 'Vitreous', 1, array['Clear','Haze','Haemorrhage','PVD']),
    ('posterior', 'Disc', 2, array['Healthy','Pale','Cupped','Swollen','Tilted','PPA+']),
    ('posterior', 'CDR', 3, array['0.1','0.2','0.3','0.4','0.5','0.6','0.65','0.7','0.75','0.8','0.85','0.9','0.95','GOA']),
    ('posterior', 'Macula', 4, array['Normal','ARMD','CSME','CME','SRF','Macular Hole','Epiretinal Membrane','Scar','FR Dull','Drusens Present','Dot-blot hemorrhages','CWS','Tessalated Fundus']),
    ('posterior', 'Vessels', 5, array['Normal','Arteriovenous nipping','Disc collaterals','Arteriolar Attenuation']),
    ('posterior', 'Peripheral Retina', 6, array['Attached','Lattice','Tear','Detachment','Laser Marks']),
    ('gonioscopy', 'Angle Configuration', 1, array['Open Angle','Open Angle till CBB','Open Angle till SS','Open Angle till PTM','Occludable','Closed Angle','Synechiae','Iris Process']),
    ('gonioscopy', 'PTM Pigmentation', 2, array['+1','+2','+3']),
    ('gonioscopy', 'Iris Configuration', 3, array['Concave','Convex','Regular'])
  ) as s(region, structure, struct_ord, opts) on s.region = r.region
  cross join lateral unnest(s.opts) with ordinality as o(name, ord)
) v
on conflict (region, structure, name) do nothing;
