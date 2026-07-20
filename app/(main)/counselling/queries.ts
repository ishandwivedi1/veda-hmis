import { createClient } from "@/lib/supabase-server";

// NOTE: adjust this import if your Supabase server helper lives elsewhere --
// this repo doesn't have GitHub access wired up, so this path is an
// assumption based on the standard Next.js + Supabase SSR convention.

export type CounsellingCase = {
  id: string;
  patient_id: string;
  uhid: string;
  patient_name: string;
  age: number | null;
  gender: string | null;
  procedure_name: string;
  eye: string | null;
  priority: string;
  status: string;
  iol_category: string | null;
  decision: string | null;
  decision_reason: string | null;
  biometry_done: boolean;
  fitness_cleared: boolean;
  investigations_complete: boolean;
  package_id: string | null;
  package_name: string | null;
  package_price: number | null;
  surgeon_id: string | null;
  surgeon_name: string | null;
  encounter_id: string | null;
  advance_payment_id: string | null;
};

// Every embedded relation below explicitly selects `id` -- omitting it is
// the recurring Supabase gotcha that silently drops the field and breaks
// downstream RPC/action calls that need it.
const CASE_SELECT = `
  id,
  patient_id,
  encounter_id,
  procedure_name,
  eye,
  priority,
  status,
  iol_category,
  decision,
  decision_reason,
  biometry_done,
  fitness_cleared,
  investigations_complete,
  package_id,
  surgeon_id,
  advance_payment_id,
  patients:patient_id ( id, uhid, first_name, last_name, age, gender ),
  profiles:surgeon_id ( id, full_name ),
  master_packages:package_id ( id, name, price )
`;

function mapCase(c: any): CounsellingCase {
  return {
    id: c.id,
    patient_id: c.patient_id,
    uhid: c.patients?.uhid ?? "--",
    patient_name: c.patients ? `${c.patients.first_name} ${c.patients.last_name}` : "--",
    age: c.patients?.age ?? null,
    gender: c.patients?.gender ?? null,
    procedure_name: c.procedure_name,
    eye: c.eye,
    priority: c.priority,
    status: c.status,
    iol_category: c.iol_category,
    decision: c.decision,
    decision_reason: c.decision_reason,
    biometry_done: c.biometry_done,
    fitness_cleared: c.fitness_cleared,
    investigations_complete: c.investigations_complete,
    package_id: c.package_id,
    package_name: c.master_packages?.name ?? null,
    package_price: c.master_packages?.price ?? null,
    surgeon_id: c.surgeon_id,
    surgeon_name: c.profiles?.full_name ?? null,
    encounter_id: c.encounter_id,
    advance_payment_id: c.advance_payment_id,
  };
}

export async function getCounsellingCases(statusFilter?: string): Promise<CounsellingCase[]> {
  const supabase = await createClient();
  let query = supabase
    .from("surgical_cases")
    .select(CASE_SELECT)
    .order("created_at", { ascending: false });

  if (statusFilter) {
    query = query.eq("status", statusFilter);
  }

  const { data, error } = await query;
  if (error) throw error;
  return (data ?? []).map(mapCase);
}

export async function getCounsellingCase(caseId: string): Promise<CounsellingCase | null> {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from("surgical_cases")
    .select(CASE_SELECT)
    .eq("id", caseId)
    .single();

  if (error) {
    if (error.code === "PGRST116") return null; // no rows
    throw error;
  }
  return mapCase(data);
}

// Readiness (SRI) -- same five checks as the prototype, now driven by real
// columns instead of a hardcoded checklist object.
export function calcReadiness(c: CounsellingCase) {
  const items = [
    { key: "surgeryRec", label: "Surgery Recommended", done: true },
    { key: "biometry", label: "Biometry & IOL Type Advised (M23)", done: c.biometry_done },
    { key: "investigations", label: "Investigations complete", done: c.investigations_complete },
    { key: "fitness", label: "Medical Fitness", done: c.fitness_cleared },
    { key: "advance", label: "Advance Payment", done: !!c.advance_payment_id },
  ];
  const done = items.filter((i) => i.done).length;
  const pct = Math.round((done / items.length) * 100);
  return { items, pct };
}

export type MasterPackage = {
  id: string;
  code: string;
  name: string;
  price: number;
  includes: string | null;
  iol_category: string | null;
  origin: string | null;
};

// Packages matching the advised IOL type, plus non-IOL-specific packages
// (iol_category IS NULL, e.g. Glaucoma surgery). Filtered in JS rather than
// via .or() to avoid PostgREST escaping issues with values like
// "Monofocal Toric" that contain a space.
export async function getPackagesForCase(iolCategory: string | null): Promise<MasterPackage[]> {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from("master_packages")
    .select("id, code, name, price, includes, iol_category, origin")
    .eq("status", "Active");

  if (error) throw error;
  return (data ?? []).filter((p) => !p.iol_category || p.iol_category === iolCategory);
}

export type CounsellingItem = { id: string; topic: string; status: "Pending" | "Done" };

export async function getCounsellingItems(encounterId: string | null): Promise<CounsellingItem[]> {
  if (!encounterId) return [];
  const supabase = await createClient();
  const { data, error } = await supabase
    .from("plan_counselling_items")
    .select("id, topic, status")
    .eq("encounter_id", encounterId)
    .order("created_at", { ascending: true });

  if (error) throw error;
  return data ?? [];
}

export type CaseNote = { id: string; note: string; created_at: string; author_name: string | null };

export async function getCaseNotes(caseId: string): Promise<CaseNote[]> {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from("surgical_case_notes")
    .select("id, note, created_at, profiles:created_by ( id, full_name )")
    .eq("surgical_case_id", caseId)
    .order("created_at", { ascending: false });

  if (error) throw error;
  return (data ?? []).map((n: any) => ({
    id: n.id,
    note: n.note,
    created_at: n.created_at,
    author_name: n.profiles?.full_name ?? null,
  }));
}
