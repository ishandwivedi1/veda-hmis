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
