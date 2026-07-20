#!/usr/bin/env bash
# Scaffolds the Counselling (M22) module into a VEDA HMIS Next.js repo.
# Run this from the ROOT of the veda-hmis repo (in Codespaces).
set -euo pipefail

echo "==> Creating Counselling module files..."

mkdir -p "app/(main)/counselling"
mkdir -p "app/(main)/counselling/[caseId]"
mkdir -p "supabase/migrations"

cat > "app/(main)/counselling/queries.ts" << 'VEDA_EOF'
import { createClient } from "@/lib/supabase/server";

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
VEDA_EOF
echo "  wrote app/(main)/counselling/queries.ts"

cat > "app/(main)/counselling/page.tsx" << 'VEDA_EOF'
import Link from "next/link";
import { getCounsellingCases, calcReadiness } from "./queries";
import { StatusFilter } from "./StatusFilter";

// NOTE: surgical_cases.status only allows: 'Pending Workup' | 'Ready for
// Scheduling' | 'Scheduled' | 'Completed' | 'Cancelled' (see migration 026 --
// no new status values were added). "In Counselling" cases are simply
// 'Pending Workup' cases that haven't been marked Ready yet. There is no
// separate "Deferred" status -- a deferred/declined case is a
// 'Pending Workup' case whose `decision` is Declined / Wants Time to Decide
// / etc. Filter on `decision` for that view, not on `status`.

function sriColor(pct: number) {
  return pct >= 80 ? "text-green-700 bg-green-50" : pct >= 50 ? "text-amber-700 bg-amber-50" : "text-red-700 bg-red-50";
}

export default async function CounsellingDashboard({
  searchParams,
}: {
  searchParams: Promise<{ status?: string }>;
}) {
  const { status } = await searchParams;
  const cases = await getCounsellingCases(status || undefined);

  const active = cases.filter((c) => c.status === "Pending Workup").length;
  const ready = cases.filter((c) => c.status === "Ready for Scheduling").length;
  const pending = cases.reduce((sum, c) => sum + (calcReadiness(c).items.filter((i) => !i.done).length), 0);
  const escalations = cases.filter((c) => calcReadiness(c).pct < 50).length;

  return (
    <div className="p-4 space-y-4">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-lg font-bold">Counselling</h1>
          <p className="text-xs text-gray-400">VEDA HMIS / Surgical Pathway / Counselling</p>
        </div>
        <span className="text-xs font-semibold px-2 py-1 rounded-full bg-purple-50 text-purple-700">
          {cases.length} cases
        </span>
      </div>

      <div className="grid grid-cols-4 gap-3">
        <KpiCard label="Active cases" value={active} sub="In counselling" color="border-purple-600" />
        <KpiCard label="Ready to schedule" value={ready} sub="All prereqs met" color="border-green-600" />
        <KpiCard label="Pending items" value={pending} sub="Across all cases" color="border-amber-600" />
        <KpiCard label="Escalations" value={escalations} sub="Need attention" color="border-red-600" />
      </div>

      <div className="grid grid-cols-[2fr_1fr] gap-4">
        <div className="bg-white border rounded-xl p-4">
          <div className="flex items-center justify-between mb-3">
            <h2 className="text-xs font-bold text-gray-800">Counselling cases</h2>
            <StatusFilter current={status} />
          </div>
          <div className="space-y-2">
            {cases.length === 0 && (
              <div className="text-center py-8 text-sm text-gray-400">No cases match this filter.</div>
            )}
            {cases.map((c) => {
              const { pct } = calcReadiness(c);
              return (
                <Link
                  key={c.id}
                  href={`/counselling/${c.id}`}
                  className="flex items-center gap-3 border rounded-lg p-3 hover:border-purple-600 hover:bg-purple-50 transition"
                >
                  <div className="w-9 h-9 rounded-full bg-purple-600 text-white flex items-center justify-center text-sm font-bold shrink-0">
                    {c.patient_name.charAt(0)}
                  </div>
                  <div className="flex-1 min-w-0">
                    <div className="text-sm font-bold flex items-center gap-2">
                      {c.patient_name}
                      <span
                        className={`text-[10px] font-semibold px-2 py-0.5 rounded-full ${
                          c.status === "Ready for Scheduling" ? "bg-green-50 text-green-700" : "bg-amber-50 text-amber-700"
                        }`}
                      >
                        {c.status}
                      </span>
                      {c.iol_category && (
                        <span className="text-[10px] font-semibold px-2 py-0.5 rounded-full bg-purple-50 text-purple-700">
                          {c.iol_category}
                        </span>
                      )}
                    </div>
                    <div className="text-xs text-gray-500 mt-0.5">
                      {c.procedure_name} {c.eye ?? ""} -- {c.surgeon_name ?? "Unassigned"}
                    </div>
                  </div>
                  <div className={`text-xs font-bold px-2 py-1 rounded ${sriColor(pct)}`}>SRI {pct}%</div>
                </Link>
              );
            })}
          </div>
        </div>

        <div className="bg-white border rounded-xl p-4">
          <h2 className="text-xs font-bold text-gray-800 mb-3">Readiness index</h2>
          <div className="space-y-2">
            {cases.map((c) => {
              const { pct, items } = calcReadiness(c);
              const done = items.filter((i) => i.done).length;
              return (
                <div key={c.id} className="flex items-center justify-between text-xs border-b pb-1 last:border-0">
                  <span className="font-semibold">{c.patient_name}</span>
                  <span className="flex items-center gap-2">
                    <span className="text-gray-400">{done}/{items.length}</span>
                    <span className={`font-bold ${sriColor(pct).split(" ")[0]}`}>{pct}%</span>
                  </span>
                </div>
              );
            })}
          </div>
        </div>
      </div>
    </div>
  );
}

function KpiCard({ label, value, sub, color }: { label: string; value: number; sub: string; color: string }) {
  return (
    <div className={`bg-white border rounded-xl p-3 border-l-4 ${color}`}>
      <div className="text-[11px] text-gray-500 font-medium">{label}</div>
      <div className="text-xl font-bold mt-1">{value}</div>
      <div className="text-[10px] text-gray-400 mt-0.5">{sub}</div>
    </div>
  );
}
VEDA_EOF
echo "  wrote app/(main)/counselling/page.tsx"

cat > "app/(main)/counselling/StatusFilter.tsx" << 'VEDA_EOF'
"use client";

import { useRouter } from "next/navigation";

// Deliberately NOT using the useSearchParams() hook here -- `current` is
// passed down from the server component's already-awaited searchParams
// prop. This sidesteps the Suspense-boundary requirement that
// useSearchParams() would otherwise force in a production build.
export function StatusFilter({ current }: { current?: string }) {
  const router = useRouter();

  return (
    <select
      className="text-xs border rounded px-2 py-1"
      defaultValue={current || ""}
      onChange={(e) => {
        const v = e.target.value;
        router.push(v ? `/counselling?status=${encodeURIComponent(v)}` : "/counselling");
      }}
    >
      <option value="">All</option>
      <option value="Pending Workup">In Counselling</option>
      <option value="Ready for Scheduling">Ready for Scheduling</option>
    </select>
  );
}
VEDA_EOF
echo "  wrote app/(main)/counselling/StatusFilter.tsx"

cat > "app/(main)/counselling/[caseId]/page.tsx" << 'VEDA_EOF'
import { notFound } from "next/navigation";
import {
  getCounsellingCase,
  getPackagesForCase,
  getCounsellingItems,
  getCaseNotes,
  calcReadiness,
} from "../queries";
import {
  selectPackage,
  changePackage,
  setDecision,
  addCaseNote,
  toggleCounsellingItem,
  markInvestigationsComplete,
  markFitnessCleared,
  markReadyForScheduling,
  referBackToDoctor,
} from "./actions";

const DECISIONS = [
  "Accepted",
  "Wants Time to Decide",
  "Discuss with Family",
  "Financial Constraint",
  "Declined",
  "Second Opinion",
  "Other",
];

export default async function CounsellingWorkspace({
  params,
}: {
  params: Promise<{ caseId: string }>;
}) {
  const { caseId } = await params;
  const c = await getCounsellingCase(caseId);
  if (!c) notFound();

  const { items, pct } = calcReadiness(c);
  const stage2Unlocked = !!c.package_id && c.decision === "Accepted";
  const packages = c.biometry_done ? await getPackagesForCase(c.iol_category) : [];
  const eduItems = await getCounsellingItems(c.encounter_id);
  const notes = await getCaseNotes(c.id);

  return (
    <div className="p-4 space-y-3 max-w-5xl">
      {/* Header */}
      <div className="rounded-xl p-4 text-white flex items-center gap-3" style={{ background: "linear-gradient(135deg,#4c1d95,#7c3aed)" }}>
        <div className="w-11 h-11 rounded-full bg-white/20 border-2 border-white/30 flex items-center justify-center text-lg font-bold">
          {c.patient_name.charAt(0)}
        </div>
        <div className="flex-1">
          <div className="text-base font-bold">{c.patient_name} -- {c.age ?? "--"}{c.gender ?? ""}</div>
          <div className="text-xs opacity-80">{c.uhid}</div>
          <div className="text-xs opacity-80 mt-0.5">{c.procedure_name} -- {c.eye ?? "--"} -- {c.priority}</div>
        </div>
        <div className="text-right">
          <div className="text-[10px] opacity-70">IOL Type Advised</div>
          <div className="text-sm font-bold">{c.iol_category ?? "Pending biometry"}</div>
          <div className="text-[10px] opacity-70 mt-1.5">Status</div>
          <div className="text-sm font-bold">{c.status}</div>
        </div>
      </div>

      {/* Package selection -- gated on biometry */}
      <div className="bg-white border-2 border-purple-600 rounded-xl p-4">
        <div className="flex items-center justify-between mb-2">
          <h2 className="text-xs font-bold flex items-center gap-1.5">Package Selection</h2>
          <span className={`text-[10px] font-semibold px-2 py-0.5 rounded-full ${c.biometry_done ? "bg-purple-50 text-purple-700" : "bg-gray-100 text-gray-500"}`}>
            {c.biometry_done ? "Step 2 -- Counselling decision" : "Locked -- awaiting Biometry (M23)"}
          </span>
        </div>

        {!c.biometry_done && (
          <div className="text-center py-6 text-gray-400 text-xs bg-gray-50 rounded-lg">
            Complete Biometry & IOL type advice (M23) before presenting packages.
          </div>
        )}

        {c.biometry_done && !c.package_id && (
          <div className="space-y-2">
            <div className="text-[11px] text-gray-500">
              Showing packages for IOL type: <strong>{c.iol_category}</strong> (from Master Data)
            </div>
            {packages.length === 0 && (
              <div className="text-center py-4 text-xs text-gray-400">
                No packages found for IOL type "{c.iol_category}" in Master Data.
              </div>
            )}
            {packages.map((p) => (
              <form action={async () => { "use server"; await selectPackage(c.id, p.id); }} key={p.id}>
                <button className="w-full text-left border rounded-lg p-3 hover:border-purple-600 hover:bg-purple-50 transition">
                  <div className="flex justify-between items-center">
                    <div className="font-bold text-xs flex items-center gap-2">
                      {p.name}
                      {p.origin && (
                        <span className={`text-[10px] px-1.5 py-0.5 rounded-full ${p.origin === "Imported" ? "bg-blue-50 text-blue-700" : "bg-green-50 text-green-700"}`}>
                          {p.origin}
                        </span>
                      )}
                    </div>
                    <div className="font-bold text-green-700 text-sm">Rs.{p.price.toLocaleString("en-IN")}</div>
                  </div>
                  {p.includes && <div className="text-[11px] text-gray-500 mt-1">{p.includes}</div>}
                </button>
              </form>
            ))}
          </div>
        )}

        {c.package_id && (
          <div className="bg-green-50 border border-green-300 rounded-lg p-3">
            <div className="flex justify-between items-center">
              <div>
                <div className="font-bold text-sm">{c.package_name}</div>
              </div>
              <div className="font-bold text-green-700 text-sm">Rs.{(c.package_price ?? 0).toLocaleString("en-IN")}</div>
            </div>
            <form action={async () => { "use server"; await changePackage(c.id); }}>
              <button className="text-xs mt-2 border rounded px-2 py-1 hover:bg-white">Change package</button>
            </form>
          </div>
        )}
      </div>

      <div className="grid grid-cols-2 gap-4">
        <div className="space-y-3">
          {/* Checklist */}
          <div className="bg-white border rounded-xl p-4">
            <div className="flex justify-between items-center mb-2">
              <h2 className="text-xs font-bold">Surgical Readiness Checklist</h2>
              <span className="text-[10px] font-bold bg-purple-50 text-purple-700 px-2 py-0.5 rounded-full">{pct}%</span>
            </div>
            <div className="space-y-1.5">
              {items.map((item) => {
                const locked = (item.key === "investigations" || item.key === "fitness") && !stage2Unlocked;
                return (
                  <div
                    key={item.key}
                    className={`flex items-center gap-2 px-3 py-2 rounded-lg text-xs border ${
                      item.done ? "bg-green-50 border-green-200" : locked ? "bg-gray-50 border-gray-200 opacity-60" : "bg-amber-50 border-amber-200"
                    }`}
                  >
                    <span className={`w-5 h-5 rounded-full flex items-center justify-center text-white text-[10px] ${item.done ? "bg-green-600" : "bg-amber-500"}`}>
                      {item.done ? "✓" : "…"}
                    </span>
                    <span className="flex-1 font-semibold">{item.label}</span>
                    {item.key === "investigations" && !item.done && !locked && (
                      <form action={async () => { "use server"; await markInvestigationsComplete(c.id); }}>
                        <button className="text-[10px] border rounded px-2 py-0.5 bg-white">Mark done</button>
                      </form>
                    )}
                    {item.key === "fitness" && !item.done && !locked && (
                      <form action={async () => { "use server"; await markFitnessCleared(c.id); }}>
                        <button className="text-[10px] border rounded px-2 py-0.5 bg-white">Mark done</button>
                      </form>
                    )}
                    {locked && <span className="text-[10px] text-gray-400">Locked</span>}
                  </div>
                );
              })}
            </div>
          </div>

          {/* Decision */}
          <div className="bg-white border rounded-xl p-4">
            <h2 className="text-xs font-bold mb-2">Patient decision</h2>
            <div className="flex flex-wrap gap-1.5">
              {DECISIONS.map((d) => (
                <form key={d} action={async () => { "use server"; await setDecision(c.id, d, null); }}>
                  <button
                    className={`text-xs font-semibold px-3 py-1 rounded-full border ${
                      c.decision === d
                        ? d === "Accepted"
                          ? "bg-green-600 text-white border-green-600"
                          : d === "Declined"
                          ? "bg-red-600 text-white border-red-600"
                          : "bg-purple-600 text-white border-purple-600"
                        : "bg-white text-gray-600 border-gray-200 hover:border-purple-600 hover:text-purple-600"
                    }`}
                  >
                    {d}
                  </button>
                </form>
              ))}
            </div>
          </div>
        </div>

        <div className="space-y-3">
          {/* Patient education */}
          <div className="bg-white border rounded-xl p-4">
            <h2 className="text-xs font-bold mb-2">Patient education</h2>
            <div className="space-y-1.5">
              {eduItems.length === 0 && <div className="text-xs text-gray-400">No education topics logged from the doctor's plan.</div>}
              {eduItems.map((item) => (
                <form key={item.id} action={async () => { "use server"; await toggleCounsellingItem(item.id, item.status !== "Done"); }}>
                  <button className="w-full flex items-center gap-2 text-xs px-2 py-1.5 rounded hover:bg-gray-50 text-left">
                    <span className={`w-4 h-4 rounded border flex items-center justify-center text-[10px] ${item.status === "Done" ? "bg-teal-600 border-teal-600 text-white" : "border-gray-300"}`}>
                      {item.status === "Done" ? "✓" : ""}
                    </span>
                    <span className="flex-1">{item.topic}</span>
                  </button>
                </form>
              ))}
            </div>
          </div>

          {/* Notes */}
          <div className="bg-white border rounded-xl p-4">
            <h2 className="text-xs font-bold mb-2">Counselling notes</h2>
            <form
              action={async (formData: FormData) => {
                "use server";
                await addCaseNote(c.id, String(formData.get("note") || ""));
              }}
            >
              <textarea name="note" rows={3} className="w-full text-xs border rounded p-2" placeholder="e.g. Patient wants surgery after 1 week..." />
              <button className="text-xs mt-1.5 border rounded px-2 py-1 bg-gray-900 text-white">Save note</button>
            </form>
            <div className="mt-2 space-y-1.5">
              {notes.map((n) => (
                <div key={n.id} className="text-[11px] bg-gray-50 rounded px-2 py-1.5">
                  <span className="text-gray-400">{new Date(n.created_at).toLocaleString("en-IN")} -- {n.author_name ?? "Staff"}: </span>
                  {n.note}
                </div>
              ))}
            </div>
          </div>
        </div>
      </div>

      {/* Actions */}
      <div className="bg-gray-900 rounded-xl p-3 flex items-center gap-2 flex-wrap">
        <form action={async () => { "use server"; await referBackToDoctor(c.id); }}>
          <button className="text-xs px-3 py-1.5 rounded bg-amber-500/20 text-amber-300 border border-amber-500/30">Refer back to doctor</button>
        </form>
        <form action={async () => { "use server"; await markReadyForScheduling(c.id); }}>
          <button className="text-xs font-bold px-3 py-1.5 rounded bg-green-500/20 text-green-300 border border-green-500/40">
            Ready for Scheduling (VAL-SCC-002)
          </button>
        </form>
      </div>
    </div>
  );
}
VEDA_EOF
echo "  wrote app/(main)/counselling/[caseId]/page.tsx"

cat > "app/(main)/counselling/[caseId]/actions.ts" << 'VEDA_EOF'
"use server";

import { createClient } from "@/lib/supabase/server";
import { revalidatePath } from "next/cache";

const DECISIONS = [
  "Accepted",
  "Wants Time to Decide",
  "Discuss with Family",
  "Financial Constraint",
  "Declined",
  "Second Opinion",
  "Other",
] as const;

async function requireCase(caseId: string) {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from("surgical_cases")
    .select("id, biometry_done, package_id, decision, investigations_complete, fitness_cleared")
    .eq("id", caseId)
    .single();
  if (error || !data) throw new Error("Case not found");
  return data;
}

export async function selectPackage(caseId: string, packageId: string) {
  const supabase = await createClient();
  const c = await requireCase(caseId);
  if (!c.biometry_done) {
    throw new Error("BR-SCC-002: Biometry & IOL type advice must be complete before selecting a package.");
  }

  const { error } = await supabase
    .from("surgical_cases")
    .update({ package_id: packageId })
    .eq("id", caseId);
  if (error) throw error;

  revalidatePath(`/counselling/${caseId}`);
  revalidatePath("/counselling");
}

export async function changePackage(caseId: string) {
  const supabase = await createClient();
  const { error } = await supabase
    .from("surgical_cases")
    .update({ package_id: null })
    .eq("id", caseId);
  if (error) throw error;

  revalidatePath(`/counselling/${caseId}`);
  revalidatePath("/counselling");
}

export async function setDecision(caseId: string, decision: string, reason: string | null) {
  if (!DECISIONS.includes(decision as (typeof DECISIONS)[number])) {
    throw new Error("Invalid decision value.");
  }
  const supabase = await createClient();
  const { error } = await supabase
    .from("surgical_cases")
    .update({ decision, decision_reason: reason || null })
    .eq("id", caseId);
  if (error) throw error;

  revalidatePath(`/counselling/${caseId}`);
  revalidatePath("/counselling");
}

export async function addCaseNote(caseId: string, note: string) {
  if (!note.trim()) return;
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const { error } = await supabase.from("surgical_case_notes").insert({
    surgical_case_id: caseId,
    note: note.trim(),
    created_by: user?.id ?? null,
  });
  if (error) throw error;

  revalidatePath(`/counselling/${caseId}`);
}

export async function toggleCounsellingItem(itemId: string, done: boolean) {
  const supabase = await createClient();
  const { error } = await supabase
    .from("plan_counselling_items")
    .update({ status: done ? "Done" : "Pending" })
    .eq("id", itemId);
  if (error) throw error;
}

export async function markInvestigationsComplete(caseId: string) {
  const c = await requireCase(caseId);
  if (!(c.package_id && c.decision === "Accepted")) {
    throw new Error("BR-SCC-004: Package must be confirmed and decision Accepted first.");
  }
  const supabase = await createClient();
  const { error } = await supabase
    .from("surgical_cases")
    .update({ investigations_complete: true })
    .eq("id", caseId);
  if (error) throw error;

  revalidatePath(`/counselling/${caseId}`);
}

export async function markFitnessCleared(caseId: string) {
  const c = await requireCase(caseId);
  if (!(c.package_id && c.decision === "Accepted")) {
    throw new Error("BR-SCC-004: Package must be confirmed and decision Accepted first.");
  }
  const supabase = await createClient();
  const { error } = await supabase
    .from("surgical_cases")
    .update({ fitness_cleared: true })
    .eq("id", caseId);
  if (error) throw error;

  revalidatePath(`/counselling/${caseId}`);
}

export async function markReadyForScheduling(caseId: string) {
  const supabase = await createClient();
  const c = await requireCase(caseId);

  if (!c.package_id) {
    throw new Error("VAL-SCC-002: Select a package before scheduling.");
  }
  if (c.decision !== "Accepted") {
    throw new Error("VAL-SCC-002: Patient decision must be Accepted before scheduling.");
  }
  if (!c.biometry_done || !c.investigations_complete || !c.fitness_cleared) {
    throw new Error("VAL-SCC-002: Incomplete prerequisites -- Biometry, Investigations & Medical Fitness must all be done.");
  }

  const { error } = await supabase
    .from("surgical_cases")
    .update({ status: "Ready for Scheduling" })
    .eq("id", caseId);
  if (error) throw error;

  revalidatePath(`/counselling/${caseId}`);
  revalidatePath("/counselling");
}

export async function referBackToDoctor(caseId: string) {
  const supabase = await createClient();
  const { error } = await supabase
    .from("surgical_cases")
    .update({ status: "Pending Workup" })
    .eq("id", caseId);
  if (error) throw error;

  revalidatePath(`/counselling/${caseId}`);
  revalidatePath("/counselling");
}
VEDA_EOF
echo "  wrote app/(main)/counselling/[caseId]/actions.ts"

cat > "supabase/migrations/026_counselling.sql" << 'VEDA_EOF'
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
VEDA_EOF
echo "  wrote supabase/migrations/026_counselling.sql"

echo ""
echo "==> Done. Next steps:"
echo "  1. Check the createClient() import path in queries.ts and actions.ts"
echo "     matches your actual @/lib/supabase/server helper."
echo "  2. Run supabase/migrations/026_counselling.sql in the Supabase SQL Editor"
echo "     (check 026 is really the next free migration number first)."
echo "  3. npm run build"
echo "  4. git add -A && git commit -m \"Add Counselling (M22) module\" && git push"
