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
