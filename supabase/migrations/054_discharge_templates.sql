-- 054: Discharge Instruction Templates -- editable in Clinical Masters.
--
-- Why (Ishan, 23 Oct 2026): the "Standard cataract template" and
-- "Glaucoma surgery template" quick-picks above Discharge Instructions in
-- Recovery & Discharge were hard-coded in ot-recovery/workspace.js, so
-- nobody could change their wording. They now live in this master table
-- and are managed from Clinical Masters > Discharge Templates.
--
--  * master_discharge_templates: label (button text) + body (text filled
--    into Discharge Instructions), ordered by sort_order, Active/Inactive.
--    Seeded with the two templates that were hard-coded, word for word.
--  * discharge_template_save: every Clinical Masters click (add, edit,
--    activate/deactivate, move up/down, delete) in ONE database call --
--    the change, its master_data_audit_log entry, and the refreshed list
--    come back together, so the screen never needs a second request.
--
-- The Recovery workspace reads Active templates inside its existing
-- detail load (getRecoveryEpisodeDetail) -- no extra request there either.
--
-- Purely additive: new table, new function. Apply to production AND training.

create table if not exists public.master_discharge_templates (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  label text not null,
  body text not null,
  sort_order integer not null default 0,
  status text not null default 'Active',
  created_at timestamptz not null default now()
);

alter table public.master_discharge_templates enable row level security;

drop policy if exists staff_all_access on public.master_discharge_templates;
create policy staff_all_access on public.master_discharge_templates
  for all to authenticated using (true) with check (true);

insert into public.master_discharge_templates (code, label, body, sort_order)
values
  ('DT01', 'Standard cataract template',
   E'Eye drops as prescribed -- Moxifloxacin QID x1wk, Prednisolone QID tapering over 4wks.\nUse eye shield while sleeping for 1 week.\nAvoid bending, lifting heavy objects, and swimming for 2 weeks.\nWarning signs: sudden pain, redness, decreased vision -- contact immediately.\nFollow-up: Day 1, Week 1, Month 1, Final refraction at 4-6 weeks.',
   1),
  ('DT02', 'Glaucoma surgery template',
   E'Eye drops as prescribed. Avoid rubbing operated eye.\nAvoid straining, heavy lifting for 4 weeks.\nWarning signs: severe pain, sudden vision loss, excessive redness -- contact immediately.\nFollow-up as scheduled by surgeon.',
   2)
on conflict (code) do nothing;

-- p_action: 'add' | 'edit' | 'toggle' | 'up' | 'down' | 'delete'
-- Returns {"rows": [...all templates in display order...]} or {"error": "..."}.
create or replace function public.discharge_template_save(
  p_action text,
  p_id uuid default null,
  p_label text default null,
  p_body text default null
) returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_label text := nullif(btrim(regexp_replace(coalesce(p_label, ''), '\s+', ' ', 'g')), '');
  v_body  text := nullif(btrim(coalesce(p_body, '')), '');
  v_row   public.master_discharge_templates;
  v_other public.master_discharge_templates;
  v_code  text;
  v_audit_action text;
  v_detail text;
begin
  if p_action = 'add' then
    if v_label is null then return jsonb_build_object('error', 'Button label is required.'); end if;
    if v_body is null then return jsonb_build_object('error', 'Template text is required.'); end if;
    select 'DT' || lpad((coalesce(max(substring(code from '^DT(\d+)$')::int), 0) + 1)::text, 2, '0')
      into v_code from public.master_discharge_templates;
    insert into public.master_discharge_templates (code, label, body, sort_order)
    values (v_code, v_label, v_body, (select coalesce(max(sort_order), 0) + 1 from public.master_discharge_templates))
    returning * into v_row;
    v_audit_action := 'Create'; v_detail := v_label || ' created';

  else
    select * into v_row from public.master_discharge_templates where id = p_id;
    if not found then return jsonb_build_object('error', 'Template not found -- it may have been deleted. Refresh the page.'); end if;

    if p_action = 'edit' then
      if v_label is null then return jsonb_build_object('error', 'Button label is required.'); end if;
      if v_body is null then return jsonb_build_object('error', 'Template text is required.'); end if;
      update public.master_discharge_templates set label = v_label, body = v_body where id = p_id;
      v_audit_action := 'Edit'; v_detail := v_row.label || ' updated';

    elsif p_action = 'toggle' then
      update public.master_discharge_templates
        set status = case when status = 'Active' then 'Inactive' else 'Active' end
        where id = p_id returning * into v_row;
      v_audit_action := case when v_row.status = 'Active' then 'Reactivate' else 'Deactivate' end;
      v_detail := 'Status changed to ' || v_row.status;

    elsif p_action in ('up', 'down') then
      if p_action = 'up' then
        select * into v_other from public.master_discharge_templates
          where (sort_order, code) < (v_row.sort_order, v_row.code) order by sort_order desc, code desc limit 1;
      else
        select * into v_other from public.master_discharge_templates
          where (sort_order, code) > (v_row.sort_order, v_row.code) order by sort_order, code limit 1;
      end if;
      if v_other.id is null then return jsonb_build_object('rows', public.discharge_template_rows()); end if;
      -- swap positions (de-duplicate equal sort_orders while at it)
      update public.master_discharge_templates set sort_order =
        case when id = v_row.id then v_other.sort_order else v_row.sort_order end
        where id in (v_row.id, v_other.id);
      if v_row.sort_order = v_other.sort_order then
        update public.master_discharge_templates set sort_order = sort_order + (case when p_action = 'up' then 1 else -1 end)
          where id = v_other.id;
      end if;
      v_audit_action := 'Edit'; v_detail := v_row.label || ' moved ' || p_action;

    elsif p_action = 'delete' then
      delete from public.master_discharge_templates where id = p_id;
      v_audit_action := 'Delete'; v_detail := 'Record deleted';

    else
      return jsonb_build_object('error', 'Unknown action.');
    end if;
  end if;

  insert into public.master_data_audit_log (master_table, record_code, action, detail, changed_by)
  values ('master_discharge_templates', v_row.code, v_audit_action, v_detail, auth.uid());

  return jsonb_build_object('rows', public.discharge_template_rows());
end;
$$;

-- Helper used by the function above (defined after it is fine in plpgsql,
-- but create it first when running statements one by one).
create or replace function public.discharge_template_rows() returns jsonb
language sql stable security invoker set search_path = public as $$
  select coalesce(jsonb_agg(to_jsonb(t) order by t.sort_order, t.code), '[]'::jsonb)
  from public.master_discharge_templates t;
$$;

grant execute on function public.discharge_template_save(text, uuid, text, text) to authenticated;
grant execute on function public.discharge_template_rows() to authenticated;
