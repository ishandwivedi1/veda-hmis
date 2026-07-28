#!/bin/bash
set -e
echo "Applying: make consent forms optional (not required for OT check-in)"

cat > "app/(main)/ot-intraop/constants.js" << 'PYEOF_CONSENT'
export const CONSENT_FORM_TYPES = [
  { key: 'surgical', label: 'Surgical Consent Form', required: false },
  { key: 'iol', label: 'IOL Consent Form', required: false },
  { key: 'anaesthesia', label: 'Anaesthesia Consent Form', required: false },
  { key: 'highrisk', label: 'High-Risk / Complication Acknowledgement', required: false },
  { key: 'photo', label: 'Photography & Teaching Consent', required: false },
];

export const CHECKIN_ITEMS = [
  'Patient identity confirmed', 'Planned procedure confirmed', 'Eye (OD/OS) confirmed',
  'Surgeon confirmed', 'Allergy reviewed', 'Consent availability verified',
  'Approved IOL Plan reviewed', 'OT Case verified',
];

PYEOF_CONSENT

echo "File written. Run: npm run build"
