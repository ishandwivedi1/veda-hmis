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
