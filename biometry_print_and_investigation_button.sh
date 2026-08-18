#!/bin/bash
set -e

echo "==> Making Biometry button prominent in Investigation queue, and restoring the Print Biometry Report button"

if [ ! -d "app/(main)/biometry" ]; then
  echo "ERROR: run this from the root of the veda-hmis repo (app/(main)/biometry not found here)."
  exit 1
fi

cat > /tmp/biometry_print_and_investigation_button.patch << 'PATCH_EOF'
diff --git a/app/(main)/biometry/[id]/workspace.js b/app/(main)/biometry/[id]/workspace.js
index d42bf88..dd0e7d0 100644
--- a/app/(main)/biometry/[id]/workspace.js
+++ b/app/(main)/biometry/[id]/workspace.js
@@ -6,6 +6,7 @@ import {
   getBiometryDetail, saveBiometryDraft, markBiometryMeasured,
 } from '../actions';
 import AttachmentUploader from '@/app/components/AttachmentUploader';
+import { openPrintPopup } from '@/lib/printPopup';
 
 const MEAS_FIELDS = [
   { key: 'axl', label: 'Axial Length', unit: 'mm' },
@@ -230,9 +231,14 @@ export default function BiometryWorkspace({ recordId }) {
 
       {isMeasured && (
         <div className="card" style={{ background: 'var(--green-lt)', borderColor: '#86efac' }}>
-          <div style={{ fontSize: 13, color: 'var(--green)', display: 'flex', alignItems: 'center', gap: 8 }}>
-            <i className="ti ti-circle-check" style={{ fontSize: 18 }}></i>
-            Measured{record.verified_at ? ` on ${new Date(record.verified_at).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })}` : ''}. Ready for Surgeon IOL Approval when a surgical case needs it.
+          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 12 }}>
+            <div style={{ fontSize: 13, color: 'var(--green)', display: 'flex', alignItems: 'center', gap: 8 }}>
+              <i className="ti ti-circle-check" style={{ fontSize: 18 }}></i>
+              Measured{record.verified_at ? ` on ${new Date(record.verified_at).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })}` : ''}. Ready for Surgeon IOL Approval when a surgical case needs it.
+            </div>
+            <button type="button" className="btn btn-sm" style={{ background: 'var(--green)', color: '#fff', border: 'none', flexShrink: 0 }} onClick={() => openPrintPopup(`/biometry-print/${recordId}`)}>
+              <i className="ti ti-printer"></i> Print Biometry Report
+            </button>
           </div>
         </div>
       )}
diff --git a/app/(main)/investigation/page.js b/app/(main)/investigation/page.js
index ce18e09..40f6e94 100644
--- a/app/(main)/investigation/page.js
+++ b/app/(main)/investigation/page.js
@@ -108,9 +108,19 @@ export default function InvestigationPage() {
                 <td><span className="badge b-amber">{r.status}</span></td>
                 <td><span className={`badge ${r.payment?.badge || 'b-gray'}`}>{r.payment?.label || 'Unbilled'}</span></td>
                 <td>
-                  <button className="btn" style={{ padding: '3px 8px', fontSize: 11 }} onClick={() => router.push(investigationHref(r))} title={isBiometryName(r.name) ? 'Open Biometry' : 'View'}>
-                    <i className={`ti ${isBiometryName(r.name) ? 'ti-ruler-measure' : 'ti-eye'}`}></i>
-                  </button>
+                  {isBiometryName(r.name) ? (
+                    <button
+                      className="btn btn-sm btn-primary"
+                      style={{ padding: '6px 14px', fontSize: 12, fontWeight: 700 }}
+                      onClick={() => router.push(investigationHref(r))}
+                    >
+                      <i className="ti ti-ruler-measure"></i> Measure
+                    </button>
+                  ) : (
+                    <button className="btn" style={{ padding: '3px 8px', fontSize: 11 }} onClick={() => router.push(investigationHref(r))} title="View">
+                      <i className="ti ti-eye"></i>
+                    </button>
+                  )}
                 </td>
               </tr>
             ))}
PATCH_EOF

git apply --check /tmp/biometry_print_and_investigation_button.patch
git apply /tmp/biometry_print_and_investigation_button.patch
rm /tmp/biometry_print_and_investigation_button.patch

echo "==> Patch applied cleanly. Running next build to verify..."
npm run build

echo "==> Build succeeded. Changes:"
echo "  - Investigation queue > Today's Pending: Biometry row now shows a prominent labeled 'Measure' button (btn-primary) instead of a tiny icon-only button"
echo "  - Biometry workspace: restored the 'Print Biometry Report' button (was present in the old tabs-based UI, missing from the current single-page workspace) -- shows once a record is Measured"
echo ""
echo "==> Committing and pushing..."
git add -A
git commit -m "Investigation: prominent Measure button for Biometry rows; Biometry: restore Print Biometry Report button"
git push origin main

echo "==> Done. Pushed to main -- Vercel will auto-deploy."
