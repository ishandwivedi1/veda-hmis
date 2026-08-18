#!/bin/bash
set -e

echo "==> Fix: cases wrongly dropping off Active list on surgery completion; add History tab; remove Notes step"

if [ ! -d "app/(main)/surgical-journey" ]; then
  echo "ERROR: run this from the root of the veda-hmis repo (app/(main)/surgical-journey not found here)."
  exit 1
fi

cat > /tmp/journey_active_history_notes.patch << 'PATCH_EOF'
diff --git a/app/(main)/surgical-journey/[id]/workspace.js b/app/(main)/surgical-journey/[id]/workspace.js
index 777a429..7aac160 100644
--- a/app/(main)/surgical-journey/[id]/workspace.js
+++ b/app/(main)/surgical-journey/[id]/workspace.js
@@ -12,7 +12,7 @@ import {
 import { getSurgeries } from '@/app/(main)/master-data/actions';
 import {
   selectPackage, changePackage, updatePackageDiscount, getPackagesForCase,
-  setDecision, markReadyForScheduling, bookOTSlot, getSurgeons, addCaseNote,
+  setDecision, markReadyForScheduling, bookOTSlot, getSurgeons,
 } from '@/app/(main)/counselling/actions';
 import { rescheduleOTSlot } from '@/app/(main)/ot-schedule/actions';
 import { openPopup, openTab } from '@/lib/popup';
@@ -317,9 +317,6 @@ export default function Workspace({ caseId }) {
       {/* 10. RECOVERY & DISCHARGE -- separate module: post-op recovery
           monitoring through to discharge. */}
       <RecoveryDischargeSection otSchedule={data.otSchedule} recoveryEpisode={data.recoveryEpisode} active={currentStep === 'recovery'} num={10} />
-
-      {/* 11. NOTES / FOLLOW-UP */}
-      <NotesSection caseId={sc.id} notes={data.caseNotes} onAction={flash} />
     </div>
   );
 }
@@ -1083,27 +1080,3 @@ function RecoveryDischargeSection({ otSchedule, recoveryEpisode, active, num })
     </Section>
   );
 }
-
-// ── 10. NOTES / FOLLOW-UP LOG ──────────────────────────────────────
-function NotesSection({ caseId, notes, onAction }) {
-  const [text, setText] = useState('');
-  return (
-    <Section num={11} color="var(--g500)" title="Notes &amp; Follow-up Calls" done={false}>
-      <div style={{ display: 'flex', gap: 8, marginBottom: 10 }}>
-        <input className="fi fi-sm" style={{ flex: 1 }} placeholder="Add a note (e.g. follow-up call outcome)..." value={text} onChange={(e) => setText(e.target.value)} />
-        <button
-          className="btn btn-sm"
-          onClick={async () => { if (!text.trim()) return; await onAction(addCaseNote)(caseId, text); setText(''); }}
-        >
-          Add
-        </button>
-      </div>
-      {notes.map((n) => (
-        <div key={n.id} style={{ fontSize: 11.5, color: 'var(--g600)', padding: '6px 0', borderBottom: '1px solid var(--g100)' }}>
-          <span style={{ color: 'var(--g400)' }}>{new Date(n.created_at).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })} -- {n.profiles?.full_name || 'Staff'}:</span> {n.note}
-        </div>
-      ))}
-      {notes.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No notes yet.</div>}
-    </Section>
-  );
-}
diff --git a/app/(main)/surgical-journey/actions.js b/app/(main)/surgical-journey/actions.js
index 1dea26d..78ca6bb 100644
--- a/app/(main)/surgical-journey/actions.js
+++ b/app/(main)/surgical-journey/actions.js
@@ -180,18 +180,69 @@ export async function setTreatmentInstructions(caseId, instructions) {
 
 // ── DASHBOARD ────────────────────────────────────────────────────────
 
+// A "Completed" surgical_cases.status only means the surgery itself is
+// done (set the moment Intraoperative Management's Surgery Complete is
+// submitted) -- the patient isn't actually through the journey until
+// Recovery confirms discharge. This resolves, for a batch of case ids
+// already known to be status='Completed', which of them also have a
+// discharge_date recorded -- those are the only ones that should
+// actually drop out of the Active list.
+async function getDischargedCaseIds(supabase, completedCaseIds) {
+  if (completedCaseIds.length === 0) return new Set();
+  const { data: schedules } = await supabase
+    .from('ot_schedule')
+    .select('id, surgical_case_id')
+    .in('surgical_case_id', completedCaseIds);
+  const scheduleIds = (schedules || []).map((s) => s.id);
+  if (scheduleIds.length === 0) return new Set();
+  const scheduleToCase = Object.fromEntries((schedules || []).map((s) => [s.id, s.surgical_case_id]));
+  const { data: episodes } = await supabase
+    .from('recovery_episodes')
+    .select('ot_schedule_id, discharge_date')
+    .in('ot_schedule_id', scheduleIds)
+    .not('discharge_date', 'is', null);
+  return new Set((episodes || []).map((e) => scheduleToCase[e.ot_schedule_id]).filter(Boolean));
+}
+
 // Every open surgical case (any staff member -- a small setup doesn't
-// have per-doctor case ownership walls). "Open" = not yet Completed or
-// Cancelled.
+// have per-doctor case ownership walls). "Open" = not Cancelled, and
+// not a Completed case that's also been discharged (see
+// getDischargedCaseIds above) -- a case whose surgery finished but
+// whose patient hasn't been discharged yet still belongs here.
 export async function getMyActiveSurgicalCases() {
   const supabase = await createClient();
   const { data, error } = await supabase
     .from('surgical_cases')
     .select('*, patients:patient_id(first_name, last_name, uhid, mobile), master_packages:package_id(name, price)')
-    .not('status', 'in', '("Completed","Cancelled")')
+    .neq('status', 'Cancelled')
     .order('created_at', { ascending: false });
   if (error) return [];
-  return data || [];
+  const cases = data || [];
+
+  const completedIds = cases.filter((c) => c.status === 'Completed').map((c) => c.id);
+  const dischargedIds = await getDischargedCaseIds(supabase, completedIds);
+
+  return cases.filter((c) => !(c.status === 'Completed' && dischargedIds.has(c.id)));
+}
+
+// Cancelled cases, plus Completed cases that have actually been
+// discharged -- the counterpart to getMyActiveSurgicalCases above, for
+// the History tab so a case doesn't just vanish once it drops off
+// Active.
+export async function getCompletedSurgicalCases() {
+  const supabase = await createClient();
+  const { data, error } = await supabase
+    .from('surgical_cases')
+    .select('*, patients:patient_id(first_name, last_name, uhid, mobile), master_packages:package_id(name, price)')
+    .order('created_at', { ascending: false })
+    .limit(300);
+  if (error) return [];
+  const cases = data || [];
+
+  const completedIds = cases.filter((c) => c.status === 'Completed').map((c) => c.id);
+  const dischargedIds = await getDischargedCaseIds(supabase, completedIds);
+
+  return cases.filter((c) => c.status === 'Cancelled' || (c.status === 'Completed' && dischargedIds.has(c.id)));
 }
 
 // Patients whose decision is "Wants Time to Decide" and haven't
@@ -296,12 +347,6 @@ export async function getSurgicalCaseDetail(caseId) {
     .limit(1)
     .maybeSingle();
 
-  const { data: caseNotes } = await supabase
-    .from('surgical_case_notes')
-    .select('*, profiles:created_by(full_name)')
-    .eq('surgical_case_id', caseId)
-    .order('created_at', { ascending: false });
-
   // The surgeon's final IOL choice -- separate module/step from both
   // Biometry (raw device recommendations) and this page's own package
   // selection (billing category only).
@@ -328,7 +373,6 @@ export async function getSurgicalCaseDetail(caseId) {
     otSchedule: otSchedule || null,
     checkinCompletedAt,
     recoveryEpisode,
-    caseNotes: caseNotes || [],
     advanceBalance: Number(advanceBalance) || 0,
   };
 }
diff --git a/app/(main)/surgical-journey/page.js b/app/(main)/surgical-journey/page.js
index 5c5acd9..eec3c5d 100644
--- a/app/(main)/surgical-journey/page.js
+++ b/app/(main)/surgical-journey/page.js
@@ -2,7 +2,7 @@
 
 import { useState, useEffect, useCallback } from 'react';
 import { useRouter } from 'next/navigation';
-import { getMyActiveSurgicalCases, getAwaitingReturnCases, recordManualReminder } from './actions';
+import { getMyActiveSurgicalCases, getAwaitingReturnCases, getCompletedSurgicalCases, recordManualReminder } from './actions';
 
 const STAGE_LABEL = {
   'Pending Workup': 'Working Up',
@@ -15,6 +15,18 @@ const STAGE_BADGE = {
   Scheduled: 'b-green',
 };
 
+function TabButton({ active, onClick, icon, label }) {
+  return (
+    <button
+      type="button"
+      onClick={onClick}
+      style={{ flex: 1, padding: '8px 10px', borderRadius: 6, fontSize: 12, fontWeight: 600, border: 'none', background: active ? '#fff' : 'transparent', color: active ? 'var(--indigo)' : 'var(--g500)', cursor: 'pointer', boxShadow: active ? '0 1px 4px rgba(0,0,0,.08)' : 'none' }}
+    >
+      <i className={`ti ${icon}`}></i> {label}
+    </button>
+  );
+}
+
 function daysAgo(dateStr) {
   const diff = Date.now() - new Date(dateStr).getTime();
   const days = Math.floor(diff / (1000 * 60 * 60 * 24));
@@ -58,10 +70,56 @@ function ReminderModal({ caseRow, onClose, onDone }) {
   );
 }
 
+function HistoryTab({ rows, loading, onOpen }) {
+  const [search, setSearch] = useState('');
+  const filtered = search.trim()
+    ? rows.filter((c) => {
+        const q = search.trim().toLowerCase();
+        return `${c.patients?.first_name} ${c.patients?.last_name}`.toLowerCase().includes(q) || (c.patients?.uhid || '').toLowerCase().includes(q);
+      })
+    : rows;
+
+  return (
+    <div className="card">
+      <div className="card-head" style={{ marginBottom: 10, flexWrap: 'wrap', gap: 8 }}>
+        <div className="card-title"><i className="ti ti-circle-check" style={{ color: 'var(--green)' }}></i> Completed / Cancelled Cases <span className="badge b-gray" style={{ marginLeft: 8 }}>{rows.length}</span></div>
+        <input className="fi fi-sm" placeholder="Search patient / UHID" value={search} onChange={(e) => setSearch(e.target.value)} style={{ width: 180 }} />
+      </div>
+      <div style={{ fontSize: 11.5, color: 'var(--g500)', marginBottom: 10 }}>
+        Cases that have finished the journey (discharged) or been cancelled -- Active Cases only shows cases still in progress, including surgeries done but not yet discharged.
+      </div>
+
+      {loading && <div style={{ fontSize: 12, color: 'var(--g400)', padding: 20, textAlign: 'center' }}>Loading...</div>}
+
+      {!loading && filtered.map((c) => (
+        <div key={c.id} onClick={() => onOpen(c.id)} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 0', borderBottom: '1px solid var(--g100)', cursor: 'pointer' }}>
+          <div style={{ width: 34, height: 34, borderRadius: '50%', background: c.status === 'Cancelled' ? 'var(--g400)' : 'var(--green)', color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 14, fontWeight: 700, flexShrink: 0 }}>
+            {c.patients?.first_name?.charAt(0)}
+          </div>
+          <div style={{ flex: 1 }}>
+            <span style={{ fontWeight: 700, fontSize: 13 }}>{c.patients?.first_name} {c.patients?.last_name}</span>
+            <span className={`badge ${c.status === 'Cancelled' ? 'b-gray' : 'b-green'}`} style={{ marginLeft: 8, fontSize: 10 }}>{c.status}</span>
+            <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 1 }}>
+              {c.surgery_code ? `${c.surgery_code} -- ` : ''}{c.patients?.uhid} -- {c.procedure_name} -- {c.eye}{c.master_packages ? ` -- ${c.master_packages.name}` : ''}
+            </div>
+          </div>
+          <i className="ti ti-chevron-right" style={{ color: 'var(--g400)' }}></i>
+        </div>
+      ))}
+      {!loading && filtered.length === 0 && (
+        <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>No completed or cancelled cases yet.</div>
+      )}
+    </div>
+  );
+}
+
 export default function SurgicalJourneyPage() {
+  const [activeTab, setActiveTab] = useState('active');
   const [cases, setCases] = useState([]);
   const [awaiting, setAwaiting] = useState([]);
+  const [history, setHistory] = useState([]);
   const [loading, setLoading] = useState(true);
+  const [loadingHistory, setLoadingHistory] = useState(true);
   const [reminderFor, setReminderFor] = useState(null);
   const router = useRouter();
 
@@ -70,8 +128,12 @@ export default function SurgicalJourneyPage() {
     setAwaiting(await getAwaitingReturnCases());
     setLoading(false);
   }, []);
+  const refreshHistory = useCallback(async () => {
+    setHistory(await getCompletedSurgicalCases());
+    setLoadingHistory(false);
+  }, []);
 
-  useEffect(() => { refresh(); }, [refresh]);
+  useEffect(() => { refresh(); refreshHistory(); }, [refresh, refreshHistory]);
 
   const proceeding = cases.filter((c) => c.decision !== 'Wants Time to Decide' && c.decision !== 'Declined');
 
@@ -84,64 +146,77 @@ export default function SurgicalJourneyPage() {
         </div>
       </div>
 
-      {awaiting.length > 0 && (
-        <div className="card" style={{ marginBottom: 16, borderColor: 'var(--amber)' }}>
-          <div className="card-title" style={{ marginBottom: 4 }}>
-            <i className="ti ti-clock-pause" style={{ color: 'var(--amber)' }}></i> Awaiting Return
-            <span className="badge b-amber" style={{ marginLeft: 8 }}>{awaiting.length}</span>
-          </div>
-          <div style={{ fontSize: 11.5, color: 'var(--g500)', marginBottom: 10 }}>
-            Advised surgery, said they'd come back another day. Worth a call if it's been a while.
-          </div>
-          {awaiting.map((c) => (
-            <div key={c.id} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 0', borderBottom: '1px solid var(--g100)' }}>
-              <div style={{ width: 34, height: 34, borderRadius: '50%', background: 'var(--amber)', color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 14, fontWeight: 700, flexShrink: 0 }}>
-                {c.patients?.first_name?.charAt(0)}
+      <div style={{ display: 'flex', gap: 4, marginBottom: 16, background: 'var(--g100)', borderRadius: 8, padding: 4, maxWidth: 400 }}>
+        <TabButton active={activeTab === 'active'} onClick={() => setActiveTab('active')} icon="ti-list-numbers" label="Active Cases" />
+        <TabButton active={activeTab === 'history'} onClick={() => setActiveTab('history')} icon="ti-history" label="Completed / History" />
+      </div>
+
+      {activeTab === 'active' && (
+        <>
+          {awaiting.length > 0 && (
+            <div className="card" style={{ marginBottom: 16, borderColor: 'var(--amber)' }}>
+              <div className="card-title" style={{ marginBottom: 4 }}>
+                <i className="ti ti-clock-pause" style={{ color: 'var(--amber)' }}></i> Awaiting Return
+                <span className="badge b-amber" style={{ marginLeft: 8 }}>{awaiting.length}</span>
               </div>
-              <div style={{ flex: 1, cursor: 'pointer' }} onClick={() => router.push(`/surgical-journey/${c.id}`)}>
-                <span style={{ fontWeight: 700, fontSize: 13 }}>{c.patients?.first_name} {c.patients?.last_name}</span>
-                <span className="badge b-gray" style={{ marginLeft: 8, fontSize: 10 }}>Advised {daysAgo(c.created_at)}</span>
-                {c.reminder_count > 0 && <span className="badge b-blue" style={{ marginLeft: 6, fontSize: 10 }}>{c.reminder_count} call{c.reminder_count > 1 ? 's' : ''} logged</span>}
-                <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 1 }}>
-                  {c.surgery_code ? `${c.surgery_code} -- ` : ''}{c.patients?.uhid} -- {c.procedure_name} -- {c.eye} -- {c.patients?.mobile}
-                </div>
+              <div style={{ fontSize: 11.5, color: 'var(--g500)', marginBottom: 10 }}>
+                Advised surgery, said they'd come back another day. Worth a call if it's been a while.
               </div>
-              <button className="btn btn-sm" onClick={() => setReminderFor(c)}>
-                <i className="ti ti-phone-call"></i> Log Call
-              </button>
-              <button className="btn btn-sm btn-primary" onClick={() => router.push(`/surgical-journey/${c.id}`)}>
-                Open
-              </button>
+              {awaiting.map((c) => (
+                <div key={c.id} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 0', borderBottom: '1px solid var(--g100)' }}>
+                  <div style={{ width: 34, height: 34, borderRadius: '50%', background: 'var(--amber)', color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 14, fontWeight: 700, flexShrink: 0 }}>
+                    {c.patients?.first_name?.charAt(0)}
+                  </div>
+                  <div style={{ flex: 1, cursor: 'pointer' }} onClick={() => router.push(`/surgical-journey/${c.id}`)}>
+                    <span style={{ fontWeight: 700, fontSize: 13 }}>{c.patients?.first_name} {c.patients?.last_name}</span>
+                    <span className="badge b-gray" style={{ marginLeft: 8, fontSize: 10 }}>Advised {daysAgo(c.created_at)}</span>
+                    {c.reminder_count > 0 && <span className="badge b-blue" style={{ marginLeft: 6, fontSize: 10 }}>{c.reminder_count} call{c.reminder_count > 1 ? 's' : ''} logged</span>}
+                    <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 1 }}>
+                      {c.surgery_code ? `${c.surgery_code} -- ` : ''}{c.patients?.uhid} -- {c.procedure_name} -- {c.eye} -- {c.patients?.mobile}
+                    </div>
+                  </div>
+                  <button className="btn btn-sm" onClick={() => setReminderFor(c)}>
+                    <i className="ti ti-phone-call"></i> Log Call
+                  </button>
+                  <button className="btn btn-sm btn-primary" onClick={() => router.push(`/surgical-journey/${c.id}`)}>
+                    Open
+                  </button>
+                </div>
+              ))}
             </div>
-          ))}
-        </div>
-      )}
+          )}
 
-      <div className="card">
-        <div className="card-title" style={{ marginBottom: 10 }}>
-          <i className="ti ti-list-numbers" style={{ color: 'var(--indigo)' }}></i> Active Cases
-          <span className="badge b-gray" style={{ marginLeft: 8 }}>{proceeding.length}</span>
-        </div>
-        {loading && <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>Loading...</div>}
-        {!loading && proceeding.map((c) => (
-          <div key={c.id} onClick={() => router.push(`/surgical-journey/${c.id}`)} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 0', borderBottom: '1px solid var(--g100)', cursor: 'pointer' }}>
-            <div style={{ width: 34, height: 34, borderRadius: '50%', background: 'var(--indigo)', color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 14, fontWeight: 700, flexShrink: 0 }}>
-              {c.patients?.first_name?.charAt(0)}
+          <div className="card">
+            <div className="card-title" style={{ marginBottom: 10 }}>
+              <i className="ti ti-list-numbers" style={{ color: 'var(--indigo)' }}></i> Active Cases
+              <span className="badge b-gray" style={{ marginLeft: 8 }}>{proceeding.length}</span>
             </div>
-            <div style={{ flex: 1 }}>
-              <span style={{ fontWeight: 700, fontSize: 13 }}>{c.patients?.first_name} {c.patients?.last_name}</span>
-              <span className={`badge ${STAGE_BADGE[c.status] || 'b-gray'}`} style={{ marginLeft: 8, fontSize: 10 }}>{STAGE_LABEL[c.status] || c.status}</span>
-              <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 1 }}>
-                {c.surgery_code ? `${c.surgery_code} -- ` : ''}{c.patients?.uhid} -- {c.procedure_name} -- {c.eye}{c.master_packages ? ` -- ${c.master_packages.name}` : ''}
+            {loading && <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>Loading...</div>}
+            {!loading && proceeding.map((c) => (
+              <div key={c.id} onClick={() => router.push(`/surgical-journey/${c.id}`)} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 0', borderBottom: '1px solid var(--g100)', cursor: 'pointer' }}>
+                <div style={{ width: 34, height: 34, borderRadius: '50%', background: 'var(--indigo)', color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 14, fontWeight: 700, flexShrink: 0 }}>
+                  {c.patients?.first_name?.charAt(0)}
+                </div>
+                <div style={{ flex: 1 }}>
+                  <span style={{ fontWeight: 700, fontSize: 13 }}>{c.patients?.first_name} {c.patients?.last_name}</span>
+                  <span className={`badge ${STAGE_BADGE[c.status] || 'b-gray'}`} style={{ marginLeft: 8, fontSize: 10 }}>{STAGE_LABEL[c.status] || c.status}</span>
+                  <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 1 }}>
+                    {c.surgery_code ? `${c.surgery_code} -- ` : ''}{c.patients?.uhid} -- {c.procedure_name} -- {c.eye}{c.master_packages ? ` -- ${c.master_packages.name}` : ''}
+                  </div>
+                </div>
+                <i className="ti ti-chevron-right" style={{ color: 'var(--g400)' }}></i>
               </div>
-            </div>
-            <i className="ti ti-chevron-right" style={{ color: 'var(--g400)' }}></i>
+            ))}
+            {!loading && proceeding.length === 0 && (
+              <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>No active surgical cases right now.</div>
+            )}
           </div>
-        ))}
-        {!loading && proceeding.length === 0 && (
-          <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>No active surgical cases right now.</div>
-        )}
-      </div>
+        </>
+      )}
+
+      {activeTab === 'history' && (
+        <HistoryTab rows={history} loading={loadingHistory} onOpen={(id) => router.push(`/surgical-journey/${id}`)} />
+      )}
 
       {reminderFor && (
         <ReminderModal
PATCH_EOF

git apply --check /tmp/journey_active_history_notes.patch
git apply /tmp/journey_active_history_notes.patch
rm /tmp/journey_active_history_notes.patch

echo "==> Patch applied cleanly. Running next build to verify..."
npm run build

echo "==> Build succeeded. Root cause + fixes:"
echo "  - ROOT CAUSE: the Active Cases query excluded ANY case with status='Completed' -- but that status flips the moment surgery itself finishes (Intraoperative Management), not on discharge. That is why Utkarsh Prakash disappeared from Surgical Journey with discharge still pending."
echo "  - FIX: Active Cases now only excludes a Completed case once it has actually been discharged (checked via its OT schedule -> recovery episode). A completed-surgery-but-not-discharged case now correctly stays in Active."
echo "  - NEW: Surgical Journey now has two tabs -- 'Active Cases' (unchanged list, plus the fix above) and 'Completed / History' -- showing cases that are Cancelled, or Completed AND discharged. Searchable by patient/UHID."
echo "  - REMOVED: step 11 'Notes & Follow-up Calls' section is gone from the case detail page entirely (per request)."
echo ""
echo "==> Committing and pushing..."
git add -A
git commit -m "Surgical Journey: fix cases dropping off Active list on surgery completion instead of discharge; add Completed/History tab; remove Notes & Follow-up Calls step"
git push origin main

echo "==> Done. Pushed to main -- Vercel will auto-deploy."
