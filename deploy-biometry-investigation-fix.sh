#!/bin/bash
set -e

echo "== Veda HMIS: Biometry routing + external investigation print fix =="

# Run this from the root of your veda-hmis repo (Codespaces terminal)

git add -A
git commit -m "Fix Biometry routing across Investigations/doctor modules; simplify external investigation referral print"
git push origin main

echo "== Done. Vercel will redeploy production and training automatically. =="
