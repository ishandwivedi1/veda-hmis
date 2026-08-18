#!/bin/bash
set -e

echo "==> Wiring IOL Approval: new-tab deep link, auto-close on completion, locked Edit view"

if [ ! -d "app/(main)/iol-approval" ]; then
  echo "ERROR: run this from the root of the veda-hmis repo (app/(main)/iol-approval not found here)."
  exit 1
fi

cat > /tmp/iol_approval_deeplink_lockmode.patch << 'PATCH_EOF'
diff --git a/app/(main)/iol-approval/page.js b/app/(main)/iol-approval/page.js
index 0c0a85b..7dc2e3f 100644
--- a/app/(main)/iol-approval/page.js
+++ b/app/(main)/iol-approval/page.js
@@ -1,6 +1,7 @@
 'use client';
 
-import { useState, useEffect, useCallback } from 'react';
+import { Suspense, useState, useEffect, useCallback } from 'react';
+import { useSearchParams } from 'next/navigation';
 import { getPendingIolApprovals, getApprovedToday, getIolApprovalHistory, getIolApprovalDetail, approveIol } from './actions';
 import { getActiveIolCatalog } from '@/app/(main)/master-data/actions';
 
@@ -142,7 +143,7 @@ function HistoryTab({ onOpen }) {
 // convention as Patient Check-In / Intraoperative Management (gradient
 // banner with all patient/case info up top, big-visibility summary
 // cards below), instead of the small popup this used to be. ──
-function WorkspaceView({ caseId, onBack, onDone }) {
+function WorkspaceView({ caseId, onBack, onDone, initialLocked }) {
   const [detail, setDetail] = useState(null);
   const [loadError, setLoadError] = useState('');
   const [catalog, setCatalog] = useState([]);
@@ -152,6 +153,7 @@ function WorkspaceView({ caseId, onBack, onDone }) {
   const [error, setError] = useState('');
   const [ok, setOk] = useState('');
   const [saving, setSaving] = useState(false);
+  const [locked, setLocked] = useState(!!initialLocked);
 
   const refresh = useCallback(async () => {
     const result = await getIolApprovalDetail(caseId);
@@ -178,6 +180,7 @@ function WorkspaceView({ caseId, onBack, onDone }) {
   const sc = detail.case;
   const patient = sc.patients;
   const approved = detail.approval?.status === 'Approved';
+  const isLocked = locked && approved;
   const eyeKey = sc.eye === 'OD' ? 're_power' : sc.eye === 'OS' ? 'le_power' : null;
 
   function pickRecommendation(rec) {
@@ -204,6 +207,16 @@ function WorkspaceView({ caseId, onBack, onDone }) {
     setSaving(false);
     if (result.error) { setError(result.error); return; }
     setOk('Saved.');
+    // Opened as a deep link from Surgical Journey (a real opener window
+    // exists) -- signal the approval back and close this tab so the
+    // person lands right back on Surgical Journey instead of having to
+    // switch tabs and manually refresh. Opened normally from the
+    // sidebar (no opener), just refresh in place as before.
+    if (typeof window !== 'undefined' && window.opener) {
+      window.opener.postMessage({ type: 'iol-approved', caseId }, window.location.origin);
+      window.close();
+      return;
+    }
     refresh();
     onDone();
   }
@@ -255,8 +268,32 @@ function WorkspaceView({ caseId, onBack, onDone }) {
       {error && <div className="msg-err" style={{ marginBottom: 12 }}>{error}</div>}
       {ok && <div className="msg-ok" style={{ marginBottom: 12 }}>{ok}</div>}
 
+      {isLocked && (
+        <div className="msg-info" style={{ background: 'var(--g100)', color: 'var(--g600)', padding: '9px 13px', borderRadius: 8, fontSize: 12.5, marginBottom: 12, display: 'flex', alignItems: 'center', gap: 8 }}>
+          <i className="ti ti-lock"></i>
+          <span style={{ flex: 1 }}>This approval is finalized and locked for viewing.</span>
+          <button className="btn btn-sm" onClick={() => setLocked(false)}>
+            <i className="ti ti-lock-open"></i> Unlock to Edit
+          </button>
+        </div>
+      )}
+
       <div className="card">
-        {!detail.biometry ? (
+        {isLocked ? (
+          <div style={{ fontSize: 12.5 }}>
+            <div style={{ fontWeight: 600, fontSize: 12, marginBottom: 10 }}>Approved IOL</div>
+            <table style={{ width: '100%', fontSize: 12.5 }}>
+              <tbody>
+                <tr><td style={{ color: 'var(--g500)', padding: '4px 0', width: 140 }}>Brand / Model</td><td style={{ padding: '4px 0' }}><strong>{detail.approval.master_iol_catalog?.brand} {detail.approval.master_iol_catalog?.model}</strong></td></tr>
+                <tr><td style={{ color: 'var(--g500)', padding: '4px 0' }}>Category</td><td style={{ padding: '4px 0' }}>{detail.approval.master_iol_catalog?.category || '--'}</td></tr>
+                <tr><td style={{ color: 'var(--g500)', padding: '4px 0' }}>Power</td><td style={{ padding: '4px 0' }}><strong>{detail.approval.power} D</strong></td></tr>
+                <tr><td style={{ color: 'var(--g500)', padding: '4px 0' }}>Eye</td><td style={{ padding: '4px 0' }}>{EYE_LABEL[sc.eye] || sc.eye}</td></tr>
+                {detail.approval.notes && <tr><td style={{ color: 'var(--g500)', padding: '4px 0', verticalAlign: 'top' }}>Notes</td><td style={{ padding: '4px 0' }}>{detail.approval.notes}</td></tr>}
+                <tr><td style={{ color: 'var(--g500)', padding: '4px 0' }}>Approved On</td><td style={{ padding: '4px 0' }}>{detail.approval.approved_at ? new Date(detail.approval.approved_at).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' }) : '--'}</td></tr>
+              </tbody>
+            </table>
+          </div>
+        ) : !detail.biometry ? (
           <div style={{ textAlign: 'center', padding: 20, color: 'var(--red)' }}>No measured biometry on file for this patient.</div>
         ) : (
           <>
@@ -312,9 +349,19 @@ function WorkspaceView({ caseId, onBack, onDone }) {
   );
 }
 
-export default function IolApprovalPage() {
-  const [activeTab, setActiveTab] = useState('dashboard');
-  const [selectedCaseId, setSelectedCaseId] = useState(null);
+// Deep-linkable via ?caseId=...&mode=view -- Surgical Journey's IOL
+// Approval step links straight here with the case's id so it opens
+// that patient's own record instead of dropping onto the Dashboard for
+// a manual pick. mode=view additionally opens an already-approved
+// record locked/read-only (the "Edit" entry point from Surgical
+// Journey), matching the same treatment as Biometry.
+function IolApprovalInner() {
+  const searchParams = useSearchParams();
+  const deepLinkCaseId = searchParams.get('caseId');
+  const lockMode = searchParams.get('mode') === 'view';
+
+  const [activeTab, setActiveTab] = useState(deepLinkCaseId ? 'workspace' : 'dashboard');
+  const [selectedCaseId, setSelectedCaseId] = useState(deepLinkCaseId || null);
   const [pending, setPending] = useState([]);
   const [approvedToday, setApprovedToday] = useState([]);
   const [loading, setLoading] = useState(true);
@@ -361,10 +408,18 @@ export default function IolApprovalPage() {
 
       {activeTab === 'dashboard' && <DashboardTab pending={pending} approvedToday={approvedToday} loading={loading} onOpen={openCase} />}
       {activeTab === 'history' && <HistoryTab onOpen={openCase} />}
-      {activeTab === 'workspace' && selectedCaseId && <WorkspaceView caseId={selectedCaseId} onBack={handleBack} onDone={refresh} />}
+      {activeTab === 'workspace' && selectedCaseId && <WorkspaceView caseId={selectedCaseId} onBack={handleBack} onDone={refresh} initialLocked={lockMode} />}
       {activeTab === 'workspace' && !selectedCaseId && (
         <div className="card" style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>Select a case from the Dashboard or History.</div>
       )}
     </div>
   );
 }
+
+export default function IolApprovalPage() {
+  return (
+    <Suspense fallback={<div style={{ textAlign: 'center', marginTop: 60, color: 'var(--g500)' }}>Loading...</div>}>
+      <IolApprovalInner />
+    </Suspense>
+  );
+}
diff --git a/app/(main)/surgical-journey/[id]/workspace.js b/app/(main)/surgical-journey/[id]/workspace.js
index 4428a53..0d148f9 100644
--- a/app/(main)/surgical-journey/[id]/workspace.js
+++ b/app/(main)/surgical-journey/[id]/workspace.js
@@ -235,7 +235,7 @@ export default function Workspace({ caseId }) {
 
       {/* 4. IOL APPROVAL -- separate module: surgeon's final brand/power
           sign-off, based on Biometry's device recommendations. */}
-      <IolApprovalSection sc={sc} iolApproval={data.iolApproval} active={currentStep === 'iolApproval'} />
+      <IolApprovalSection sc={sc} iolApproval={data.iolApproval} active={currentStep === 'iolApproval'} refresh={refresh} />
 
       {/* 5. IOL PROCUREMENT + DATE + BOOK */}
       <IolAndBookingSection sc={sc} otSchedule={data.otSchedule} iolApproval={data.iolApproval} onAction={flash} active={currentStep === 'iol'} num={5} />
@@ -344,9 +344,24 @@ function FitnessSection({ sc, fitnessReferral, onAction, active, num }) {
 
 // ── IOL APPROVAL -- separate module, deep-link only (same treatment as
 // Medical Fitness and Day of Surgery). The surgeon's actual approve
-// action happens in /iol-approval, not embedded here. ──
-function IolApprovalSection({ sc, iolApproval, active }) {
+// action happens in /iol-approval, not embedded here. Opens as a real
+// new tab (not a popup window) so the person can use the full
+// Workspace comfortably; the tab signals back via postMessage and
+// closes itself once the approval is saved, returning focus straight
+// to Surgical Journey with the step refreshed. ──
+function IolApprovalSection({ sc, iolApproval, active, refresh }) {
   const approved = iolApproval?.status === 'Approved';
+
+  useEffect(() => {
+    function handleMessage(e) {
+      if (e.origin !== window.location.origin) return;
+      if (e.data?.type !== 'iol-approved' || e.data.caseId !== sc.id) return;
+      refresh();
+    }
+    window.addEventListener('message', handleMessage);
+    return () => window.removeEventListener('message', handleMessage);
+  }, [sc.id, refresh]);
+
   if (sc.decision !== 'Accepted') {
     return (
       <Section num={5} color="var(--indigo)" title="IOL Approval" done={false} active={active}>
@@ -358,9 +373,16 @@ function IolApprovalSection({ sc, iolApproval, active }) {
     <Section num={5} color="var(--indigo)" title="IOL Approval" done={approved} active={active}>
       {approved ? (
         <div style={{ fontSize: 12.5 }}>
-          <span className="badge b-green" style={{ marginBottom: 6 }}><i className="ti ti-check"></i> Approved</span>
-          <div style={{ marginTop: 6 }}>
-            {iolApproval.master_iol_catalog?.brand} {iolApproval.master_iol_catalog?.model} -- {iolApproval.power}D ({iolApproval.eye})
+          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 10, flexWrap: 'wrap' }}>
+            <div>
+              <span className="badge b-green" style={{ marginBottom: 6 }}><i className="ti ti-check"></i> Approved</span>
+              <div style={{ marginTop: 6 }}>
+                {iolApproval.master_iol_catalog?.brand} {iolApproval.master_iol_catalog?.model} -- {iolApproval.power}D ({iolApproval.eye})
+              </div>
+            </div>
+            <a href={`/iol-approval?caseId=${sc.id}&mode=view`} target="_blank" className="btn btn-sm" style={{ textDecoration: 'none' }}>
+              <i className="ti ti-pencil"></i> Edit
+            </a>
           </div>
         </div>
       ) : (
@@ -368,7 +390,7 @@ function IolApprovalSection({ sc, iolApproval, active }) {
           <div style={{ fontSize: 11.5, color: 'var(--g500)', marginBottom: 8 }}>
             The surgeon needs to review Biometry's device recommendations and confirm the specific brand/power for this case.
           </div>
-          <a href="/iol-approval" className="btn btn-sm btn-primary" style={{ textDecoration: 'none' }}>
+          <a href={`/iol-approval?caseId=${sc.id}`} target="_blank" className="btn btn-sm btn-primary" style={{ textDecoration: 'none' }}>
             <i className="ti ti-lens"></i> Open IOL Approval
           </a>
         </div>
PATCH_EOF

git apply --check /tmp/iol_approval_deeplink_lockmode.patch
git apply /tmp/iol_approval_deeplink_lockmode.patch
rm /tmp/iol_approval_deeplink_lockmode.patch

echo "==> Patch applied cleanly. Running next build to verify..."
npm run build

echo "==> Build succeeded. Changes:"
echo "  - Surgical Journey > IOL Approval step: 'Open IOL Approval' now opens in a real new tab, deep-linked straight to that patient's case (no more landing on the general Dashboard to pick manually)"
echo "  - On successful Approve/Update in that tab, it signals back via postMessage and closes itself -- you land right back on Surgical Journey, which auto-refreshes the step to show Approved"
echo "  - Once approved, Surgical Journey shows an 'Edit' button -- opens in a new tab, deep-linked to the same case, in LOCKED read-only view (brand/model/power/notes/approved-on summary) with an 'Unlock to Edit' button before any field becomes editable"
echo "  - This mirrors the same close-on-complete pattern already used for OT slot picking, and the same locked/unlock pattern already used in Biometry"
echo ""
echo "==> Committing and pushing..."
git add -A
git commit -m "Surgical Journey: IOL Approval opens in new tab (deep-linked), auto-closes and refreshes parent on completion; approved cases get a locked Edit view"
git push origin main

echo "==> Done. Pushed to main -- Vercel will auto-deploy."
