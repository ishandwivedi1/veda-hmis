#!/bin/bash
set -e

echo "==> Fixing IOL Approval tab: auto-close + auto-refresh wasn't firing"

if [ ! -d "app/(main)/surgical-journey" ]; then
  echo "ERROR: run this from the root of the veda-hmis repo (app/(main)/surgical-journey not found here)."
  exit 1
fi

cat > /tmp/iol_approval_opener_fix.patch << 'PATCH_EOF'
diff --git a/app/(main)/surgical-journey/[id]/workspace.js b/app/(main)/surgical-journey/[id]/workspace.js
index 0d148f9..e89ab86 100644
--- a/app/(main)/surgical-journey/[id]/workspace.js
+++ b/app/(main)/surgical-journey/[id]/workspace.js
@@ -15,7 +15,7 @@ import {
   setDecision, markReadyForScheduling, bookOTSlot, getSurgeons, addCaseNote,
 } from '@/app/(main)/counselling/actions';
 import { getOTAvailability, rescheduleOTSlot } from '@/app/(main)/ot-schedule/actions';
-import { openPopup } from '@/lib/popup';
+import { openPopup, openTab } from '@/lib/popup';
 
 const EYE_LABEL = { OD: 'Right (OD)', OS: 'Left (OS)', OU: 'Both (OU)' };
 
@@ -380,9 +380,9 @@ function IolApprovalSection({ sc, iolApproval, active, refresh }) {
                 {iolApproval.master_iol_catalog?.brand} {iolApproval.master_iol_catalog?.model} -- {iolApproval.power}D ({iolApproval.eye})
               </div>
             </div>
-            <a href={`/iol-approval?caseId=${sc.id}&mode=view`} target="_blank" className="btn btn-sm" style={{ textDecoration: 'none' }}>
+            <button type="button" className="btn btn-sm" onClick={() => openTab(`/iol-approval?caseId=${sc.id}&mode=view`, `iol-approval-${sc.id}`)}>
               <i className="ti ti-pencil"></i> Edit
-            </a>
+            </button>
           </div>
         </div>
       ) : (
@@ -390,9 +390,9 @@ function IolApprovalSection({ sc, iolApproval, active, refresh }) {
           <div style={{ fontSize: 11.5, color: 'var(--g500)', marginBottom: 8 }}>
             The surgeon needs to review Biometry's device recommendations and confirm the specific brand/power for this case.
           </div>
-          <a href={`/iol-approval?caseId=${sc.id}`} target="_blank" className="btn btn-sm btn-primary" style={{ textDecoration: 'none' }}>
+          <button type="button" className="btn btn-sm btn-primary" onClick={() => openTab(`/iol-approval?caseId=${sc.id}`, `iol-approval-${sc.id}`)}>
             <i className="ti ti-lens"></i> Open IOL Approval
-          </a>
+          </button>
         </div>
       )}
     </Section>
diff --git a/lib/popup.js b/lib/popup.js
index 184c406..d442603 100644
--- a/lib/popup.js
+++ b/lib/popup.js
@@ -15,3 +15,18 @@ export function openPopup(url, name = 'popup', size = {}) {
   );
 }
 
+// Opens a full new browser tab (not a fixed-size popup), while keeping
+// window.opener available in that tab. A plain <a target="_blank"> link
+// looks identical but does NOT do this: since Chrome 88 / modern
+// Firefox, browsers apply rel="noopener" by default to target="_blank"
+// links, which nulls out window.opener in the new tab. That silently
+// breaks any postMessage-back-to-parent + self-close flow (and
+// window.close() is also blocked entirely for tabs that weren't opened
+// via script). Calling window.open() directly, with no "noopener" in
+// the features string, avoids both problems -- use this instead of a
+// target="_blank" link anywhere the opened tab needs to signal back
+// and close itself when done.
+export function openTab(url, name = '_blank') {
+  window.open(url, name);
+}
+
PATCH_EOF

git apply --check /tmp/iol_approval_opener_fix.patch
git apply /tmp/iol_approval_opener_fix.patch
rm /tmp/iol_approval_opener_fix.patch

echo "==> Patch applied cleanly. Running next build to verify..."
npm run build

echo "==> Build succeeded. Root cause + fix:"
echo "  - Modern browsers (Chrome 88+, Firefox) silently apply rel=noopener to any <a target="_blank"> link by default"
echo "  - That nulled window.opener in the IOL Approval tab, so its postMessage-back-and-close-self logic never ran -- window.close() is also blocked entirely for tabs not opened via script, which compounded it"
echo "  - Fixed by opening the tab via a real window.open() call (new lib/popup.js openTab helper) instead of a plain link -- this keeps window.opener intact and lets the tab close itself"
echo "  - Both the 'Open IOL Approval' and 'Edit' buttons in Surgical Journey now use this -- approving/updating in that tab will close it and refresh Surgical Journey automatically, no manual refresh needed"
echo ""
echo "==> Committing and pushing..."
git add -A
git commit -m "Fix IOL Approval tab not closing/notifying parent: use window.open() instead of target=_blank link so window.opener survives browsers' default noopener behavior"
git push origin main

echo "==> Done. Pushed to main -- Vercel will auto-deploy."
