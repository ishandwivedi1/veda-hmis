#!/usr/bin/env bash
# Removes the 'Send for Biometry' button from Doctor's Diagnosis & Plan
# (Consultation). The doctor now only marks for surgery -- sending the
# patient for Biometry is being moved to the Counselling module instead
# (that part comes in a follow-up script). This one only touches
# consultation-form.js: removes the button, the handleSendOut('biometry')
# branch, and the now-unused import. Run from the ROOT of the veda-hmis
# repo (in Codespaces).
set -euo pipefail

echo "==> Removing Send for Biometry from Doctor Diagnosis & Plan..."
python3 << 'PYFIX'
import json

fixes = json.loads("[[\"app/(main)/consultation/[id]/consultation-form.js\", \"  sendForDilationFromConsultation,\\n  sendForInvestigationFromConsultation,\\n  sendForBiometryFromConsultation,\\n  completeWorkflowRequest,\", \"  sendForDilationFromConsultation,\\n  sendForInvestigationFromConsultation,\\n  completeWorkflowRequest,\"], [\"app/(main)/consultation/[id]/consultation-form.js\", \"      // Biometry stays in Financial Masters for billing purposes only --\\n      // excluded here since clinical biometry has its own dedicated\\n      // workflow (Send for Biometry button), not a generic investigation.\\n      setInvestigationOptions(sv.filter((s) => s.status === 'Active' && s.dept === 'Investigation' && s.name.toLowerCase() !== 'biometry'));\", \"      // Biometry stays in Financial Masters for billing purposes only --\\n      // excluded here since clinical biometry has its own dedicated\\n      // workflow, now triggered from Counselling (M22) rather than here.\\n      setInvestigationOptions(sv.filter((s) => s.status === 'Active' && s.dept === 'Investigation' && s.name.toLowerCase() !== 'biometry'));\"], [\"app/(main)/consultation/[id]/consultation-form.js\", \"    const result = kind === 'dilate'\\n      ? await sendForDilationFromConsultation(queueEntryId, data.encounter.id)\\n      : kind === 'biometry'\\n      ? await sendForBiometryFromConsultation(queueEntryId, data.encounter.id)\\n      : await sendForInvestigationFromConsultation(queueEntryId, data.encounter.id);\", \"    const result = kind === 'dilate'\\n      ? await sendForDilationFromConsultation(queueEntryId, data.encounter.id)\\n      : await sendForInvestigationFromConsultation(queueEntryId, data.encounter.id);\"], [\"app/(main)/consultation/[id]/consultation-form.js\", \"            <button className=\\\"btn\\\" onClick={() => handleSendOut('investigate')} disabled={loading}>\\n              Send for Investigation\\n            </button>\\n            <button className=\\\"btn\\\" onClick={() => handleSendOut('biometry')} disabled={loading}>\\n              Send for Biometry\\n            </button>\\n            <a href={`/visit-summary-print/${data.encounter.id}`} target=\\\"_blank\\\" rel=\\\"noopener noreferrer\\\" className=\\\"btn\\\" style={{ marginLeft: 'auto' }}>\", \"            <button className=\\\"btn\\\" onClick={() => handleSendOut('investigate')} disabled={loading}>\\n              Send for Investigation\\n            </button>\\n            <a href={`/visit-summary-print/${data.encounter.id}`} target=\\\"_blank\\\" rel=\\\"noopener noreferrer\\\" className=\\\"btn\\\" style={{ marginLeft: 'auto' }}>\"]]")

for path, old, new in fixes:
    with open(path, 'r') as f:
        content = f.read()
    count = content.count(old)
    if count != 1:
        print(f'  WARNING: expected exactly 1 match in {path}, found {count} -- skipped, check manually')
        print(f'    looking for: {old[:80]!r}...')
        continue
    content = content.replace(old, new, 1)
    with open(path, 'w') as f:
        f.write(content)
    print(f'  applied 1 edit to {path}')
PYFIX

echo "==> Verifying no stale references remain..."
REMAINING=$(grep -n "sendForBiometryFromConsultation\|handleSendOut(\x27biometry\x27)" "app/(main)/consultation/[id]/consultation-form.js" || true)
if [ -n "$REMAINING" ]; then
  echo "WARNING: found remaining references:"
  echo "$REMAINING"
else
  echo "  clean -- no stale references found."
fi

echo ""
echo "==> Done. Note: sendForBiometryFromConsultation() itself is UNTOUCHED"
echo "    in app/(main)/consultation/actions.js -- only the button that called"
echo "    it from this page is gone. Next steps:"
echo "  1. npm run build"
echo "  2. git add -A && git commit -m \"Remove Send for Biometry from Doctor Diagnosis & Plan\" && git push"
