#!/usr/bin/env bash
# Surgery codes now use one common prefix (SUR) across ALL categories --
# SUR01, SUR02... regardless of Cataract/Glaucoma/Retina -- instead of a
# different prefix per category (CAT/GLA/RET). Every other Clinical
# Masters table's category-linked scheme is unchanged.
set -euo pipefail

mkdir -p "app/(main)/master-data"
echo "==> Applying fix to actions.js (surgery code generation)..."

python3 << 'PYEOF'
import re

path = "app/(main)/master-data/actions.js"
with open(path) as f:
    content = f.read()

old = "const code = await generateCategoryCode(supabase, 'master_surgeries', category);"
new = "const code = await generateCategoryCode(supabase, 'master_surgeries', 'SUR');"

if old in content:
    content = content.replace(old, new, 1)
    with open(path, "w") as f:
        f.write(content)
    print("  Fixed: master_surgeries now uses a fixed 'SUR' prefix instead of category.")
elif "generateCategoryCode(supabase, 'master_surgeries', 'SUR')" in content:
    print("  Already applied -- no change needed.")
else:
    print("  WARNING: expected line not found in actions.js -- check manually.")
    print("  Looking for:", old)
PYEOF

echo ""
echo "==> Done. Next steps:"
echo "  1. npm run build"
echo "  2. git add -A && git commit -m \"Surgery codes: one common SUR prefix, not per-category\" && git push"
