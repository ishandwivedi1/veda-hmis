#!/bin/bash
set -e

echo "==> Surgical Journey: Recovery & Discharge becomes the real last step (10), deep-linked, new tab, closes on discharge"

if [ ! -d "app/(main)/ot-recovery" ]; then
  echo "ERROR: run this from the root of the veda-hmis repo (app/(main)/ot-recovery not found here)."
  exit 1
fi

cat > /tmp/recovery_discharge_step10.patch << 'PATCH_EOF'
diff --git a/app/(main)/ot-recovery/page.js b/app/(main)/ot-recovery/page.js
index c7a1890..548986c 100644
--- a/app/(main)/ot-recovery/page.js
+++ b/app/(main)/ot-recovery/page.js
@@ -1,6 +1,7 @@
 'use client';
 
-import { useState, useEffect, useCallback } from 'react';
+import { Suspense, useState, useEffect, useCallback } from 'react';
+import { useSearchParams } from 'next/navigation';
 import { getRecoveryCaseList, getRecoveryHistory } from './actions';
 import Workspace from './workspace';
 
@@ -133,9 +134,16 @@ function HistoryTab({ rows, loading, onOpen }) {
   );
 }
 
-export default function RecoveryPage() {
-  const [activeTab, setActiveTab] = useState('dashboard');
-  const [selectedId, setSelectedId] = useState(null);
+// Deep-linkable via ?episodeId=... -- Surgical Journey's Recovery &
+// Discharge step links straight here with the recovery episode's id so
+// it opens that patient's own record instead of dropping onto the
+// Dashboard for a manual pick.
+function RecoveryInner() {
+  const searchParams = useSearchParams();
+  const deepLinkId = searchParams.get('episodeId');
+
+  const [activeTab, setActiveTab] = useState(deepLinkId ? 'workspace' : 'dashboard');
+  const [selectedId, setSelectedId] = useState(deepLinkId || null);
   const [cases, setCases] = useState([]);
   const [history, setHistory] = useState([]);
   const [loadingCases, setLoadingCases] = useState(true);
@@ -179,3 +187,11 @@ export default function RecoveryPage() {
   );
 }
 
+export default function RecoveryPage() {
+  return (
+    <Suspense fallback={<div style={{ textAlign: 'center', marginTop: 60, color: 'var(--g500)' }}>Loading...</div>}>
+      <RecoveryInner />
+    </Suspense>
+  );
+}
+
diff --git a/app/(main)/ot-recovery/workspace.js b/app/(main)/ot-recovery/workspace.js
index 18f2acb..8985caf 100644
--- a/app/(main)/ot-recovery/workspace.js
+++ b/app/(main)/ot-recovery/workspace.js
@@ -148,6 +148,15 @@ export default function Workspace({ episodeId, onBack, onUpdate }) {
     if (!dischargeDate) { setError('Discharge date is required.'); return; }
     const result = await confirmDischarge(episodeId, checklist, dischargeNotes, instructions, dischargeDate, followupPlan);
     if (result.error) { setError(result.error); return; }
+    // Opened as a deep link from Surgical Journey (a real opener window
+    // exists) -- signal completion back and close this tab. Same
+    // close-on-complete pattern as IOL Approval, Medical Fitness,
+    // Patient Check-In, and Intraoperative Management.
+    if (typeof window !== 'undefined' && window.opener) {
+      window.opener.postMessage({ type: 'recovery-updated', episodeId }, window.location.origin);
+      window.close();
+      return;
+    }
     setOk('Patient discharged. Discharge summary is ready to print. Follow-up schedule generated.');
     onUpdate();
     refresh();
diff --git a/app/(main)/surgical-journey/[id]/workspace.js b/app/(main)/surgical-journey/[id]/workspace.js
index 16bf837..777a429 100644
--- a/app/(main)/surgical-journey/[id]/workspace.js
+++ b/app/(main)/surgical-journey/[id]/workspace.js
@@ -178,10 +178,11 @@ export default function Workspace({ caseId }) {
       if (t === 'advance-collected' && e.data.patientId === data?.case?.patients?.id) refresh();
       else if (t === 'checkin-updated' && e.data.otScheduleId === data?.otSchedule?.id) refresh();
       else if (t === 'intraop-updated' && e.data.otScheduleId === data?.otSchedule?.id) refresh();
+      else if (t === 'recovery-updated' && e.data.episodeId === data?.recoveryEpisode?.id) refresh();
     }
     window.addEventListener('message', handleMessage);
     return () => window.removeEventListener('message', handleMessage);
-  }, [data?.case?.patients?.id, data?.otSchedule?.id, refresh]);
+  }, [data?.case?.patients?.id, data?.otSchedule?.id, data?.recoveryEpisode?.id, refresh]);
 
   function flash(fn) {
     return async (...args) => {
@@ -223,7 +224,8 @@ export default function Workspace({ caseId }) {
     fitness: sc.fitness_cleared || sc.fitness_required === false || data.fitnessReferral?.status === 'Cleared',
     payment: netPackageAmount > 0 && advanceBalance >= netPackageAmount - 0.01,
     checkin: !!data.checkinCompletedAt,
-    intraop: !!data.recoveryEpisode?.discharge_date,
+    intraop: data.otSchedule?.status === 'Completed',
+    recovery: !!data.recoveryEpisode?.discharge_date,
   };
   const currentStep = Object.keys(stepDone).find((k) => !stepDone[k]) || null;
 
@@ -310,9 +312,13 @@ export default function Workspace({ caseId }) {
       <PatientCheckinSection otSchedule={data.otSchedule} checkinCompletedAt={data.checkinCompletedAt} paymentDone={stepDone.payment} active={currentStep === 'checkin'} num={8} />
 
       {/* 9. INTRAOPERATIVE MANAGEMENT */}
-      <IntraopManagementSection otSchedule={data.otSchedule} checkinCompletedAt={data.checkinCompletedAt} recoveryEpisode={data.recoveryEpisode} router={router} active={currentStep === 'intraop'} num={9} />
+      <IntraopManagementSection otSchedule={data.otSchedule} checkinCompletedAt={data.checkinCompletedAt} active={currentStep === 'intraop'} num={9} />
 
-      {/* 10. NOTES / FOLLOW-UP */}
+      {/* 10. RECOVERY & DISCHARGE -- separate module: post-op recovery
+          monitoring through to discharge. */}
+      <RecoveryDischargeSection otSchedule={data.otSchedule} recoveryEpisode={data.recoveryEpisode} active={currentStep === 'recovery'} num={10} />
+
+      {/* 11. NOTES / FOLLOW-UP */}
       <NotesSection caseId={sc.id} notes={data.caseNotes} onAction={flash} />
     </div>
   );
@@ -992,15 +998,15 @@ function PatientCheckinSection({ otSchedule, checkinCompletedAt, paymentDone, ac
   );
 }
 
-// ── 8. INTRAOPERATIVE MANAGEMENT (live status, deep-links only -- OT
-// Intraop and Recovery remain their own solid clinical workflows;
-// Recovery/Post-Op are a natural continuation of this same chain, so
-// their status is shown here too rather than yet another section) ──
-function IntraopManagementSection({ otSchedule, checkinCompletedAt, recoveryEpisode, router, active, num }) {
+// ── 8. INTRAOPERATIVE MANAGEMENT (live status, deep-links only) --
+// covers Check-In through the surgery itself. Recovery and discharge
+// are their own dedicated step below (9), not folded in here. ──
+function IntraopManagementSection({ otSchedule, checkinCompletedAt, active, num }) {
   let status = 'Waiting on Patient Check-In';
   let color = 'var(--g400)';
   let action = null;
   const locked = !checkinCompletedAt;
+  const done = otSchedule?.status === 'Completed';
 
   if (otSchedule && checkinCompletedAt) {
     if (otSchedule.status === 'In Progress') {
@@ -1008,18 +1014,8 @@ function IntraopManagementSection({ otSchedule, checkinCompletedAt, recoveryEpis
       color = 'var(--red)';
       action = { label: 'Continue in Intraoperative Management', onClick: () => openTab(`/ot-intraop?otScheduleId=${otSchedule.id}`, `intraop-${otSchedule.id}`) };
     } else if (otSchedule.status === 'Completed') {
-      if (recoveryEpisode && !recoveryEpisode.discharge_date) {
-        status = 'Surgery done -- in Recovery';
-        color = 'var(--teal)';
-        action = { label: 'Open in Recovery', onClick: () => router.push('/ot-recovery') };
-      } else if (recoveryEpisode?.discharge_date) {
-        status = `Discharged -- ${new Date(recoveryEpisode.discharge_date).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short' })}`;
-        color = 'var(--green)';
-        action = { label: 'Open in Post-Op', onClick: () => router.push('/ot-postop') };
-      } else {
-        status = 'Surgery completed';
-        color = 'var(--green)';
-      }
+      status = 'Surgery completed';
+      color = 'var(--green)';
     } else {
       status = 'Checked in -- ready for OT';
       color = 'var(--blue)';
@@ -1028,14 +1024,14 @@ function IntraopManagementSection({ otSchedule, checkinCompletedAt, recoveryEpis
   }
 
   return (
-    <Section num={num} color={color} title="Intraoperative Management" done={!!recoveryEpisode?.discharge_date} defaultOpen={!!checkinCompletedAt} active={active}>
+    <Section num={num} color={color} title="Intraoperative Management" done={done} defaultOpen={!!checkinCompletedAt} active={active}>
       <div style={{ fontSize: 13, fontWeight: 600, marginBottom: 8 }}>{status}</div>
       {locked ? (
         <div style={{ fontSize: 11.5, color: 'var(--g500)' }}><i className="ti ti-lock"></i> Complete Patient Check-In first.</div>
       ) : (
         <>
           <div style={{ fontSize: 11.5, color: 'var(--g500)', marginBottom: 10 }}>
-            The surgery itself and discharge happen in the Intraoperative Management / Recovery modules -- that clinical documentation stays where it is. This just shows where the case currently stands.
+            The surgery itself happens in the Intraoperative Management module -- that clinical documentation stays where it is. This just shows where the case currently stands.
           </div>
           {action && (
             <button className="btn btn-sm btn-primary" onClick={action.onClick}>
@@ -1048,11 +1044,51 @@ function IntraopManagementSection({ otSchedule, checkinCompletedAt, recoveryEpis
   );
 }
 
-// ── 9. NOTES / FOLLOW-UP LOG ──────────────────────────────────────
+// ── 9. RECOVERY & DISCHARGE -- separate module: post-op recovery
+// monitoring through to discharge. Deep-links straight to the
+// patient's recovery episode, opened as a real new tab (window.opener
+// intact) so it can signal back and close itself once discharge is
+// confirmed -- same pattern as IOL Approval, Medical Fitness, Patient
+// Check-In, and Intraoperative Management above. ──
+function RecoveryDischargeSection({ otSchedule, recoveryEpisode, active, num }) {
+  const surgeryDone = otSchedule?.status === 'Completed';
+  const discharged = !!recoveryEpisode?.discharge_date;
+
+  if (!surgeryDone) {
+    return (
+      <Section num={num} color="var(--g400)" title="Recovery &amp; Discharge" done={false} active={active}>
+        <div style={{ fontSize: 12, color: 'var(--g400)' }}><i className="ti ti-lock"></i> Complete Intraoperative Management first.</div>
+      </Section>
+    );
+  }
+
+  const status = discharged
+    ? `Discharged -- ${new Date(recoveryEpisode.discharge_date).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short' })}`
+    : 'In Recovery -- not yet discharged';
+
+  return (
+    <Section num={num} color={discharged ? 'var(--green)' : 'var(--teal)'} title="Recovery &amp; Discharge" done={discharged} defaultOpen={!discharged} active={active}>
+      <div style={{ fontSize: 13, fontWeight: 600, marginBottom: 8 }}>{status}</div>
+      <div style={{ fontSize: 11.5, color: 'var(--g500)', marginBottom: 10 }}>
+        Recovery monitoring, discharge instructions, and the follow-up schedule happen in the Recovery module -- that clinical documentation stays where it is. This just shows where the case currently stands.
+      </div>
+      {recoveryEpisode && (
+        <button
+          className="btn btn-sm btn-primary"
+          onClick={() => openTab(`/ot-recovery?episodeId=${recoveryEpisode.id}`, `recovery-${recoveryEpisode.id}`)}
+        >
+          <i className="ti ti-arrow-right"></i> {discharged ? 'View Recovery Record' : 'Open Recovery & Discharge'}
+        </button>
+      )}
+    </Section>
+  );
+}
+
+// ── 10. NOTES / FOLLOW-UP LOG ──────────────────────────────────────
 function NotesSection({ caseId, notes, onAction }) {
   const [text, setText] = useState('');
   return (
-    <Section num={10} color="var(--g500)" title="Notes &amp; Follow-up Calls" done={false}>
+    <Section num={11} color="var(--g500)" title="Notes &amp; Follow-up Calls" done={false}>
       <div style={{ display: 'flex', gap: 8, marginBottom: 10 }}>
         <input className="fi fi-sm" style={{ flex: 1 }} placeholder="Add a note (e.g. follow-up call outcome)..." value={text} onChange={(e) => setText(e.target.value)} />
         <button
PATCH_EOF

git apply --check /tmp/recovery_discharge_step10.patch
git apply /tmp/recovery_discharge_step10.patch
rm /tmp/recovery_discharge_step10.patch

echo "==> Patch applied cleanly. Running next build to verify..."
npm run build

echo "==> Build succeeded. Changes:"
echo "  - NOTE: this supersedes the earlier Post-Op step-10 idea entirely -- if you ran that script, this patch cleanly reverses it and replaces it with the below (if you did NOT run it, this applies directly, nothing to undo)"
echo "  - Step 9 'Intraoperative Management' now covers Check-In through the surgery itself only"
echo "  - New step 10: 'Recovery & Discharge' -- deep-linked to /ot-recovery?episodeId=..., opens in a real new tab, and closes itself + refreshes Surgical Journey the moment discharge is confirmed"
echo "  - Notes & Follow-up Calls is now step 11"
echo "  - Step-tracking (the 'current step' highlight) now treats surgery completion and discharge as two separate stages instead of one combined 'intraop' stage"
echo ""
echo "==> Committing and pushing..."
git add -A
git commit -m "Surgical Journey: Recovery & Discharge is now the dedicated last step (10), deep-linked new tab that closes on discharge confirmation; Notes & Follow-up Calls renumbered to step 11"
git push origin main

echo "==> Done. Pushed to main -- Vercel will auto-deploy."
