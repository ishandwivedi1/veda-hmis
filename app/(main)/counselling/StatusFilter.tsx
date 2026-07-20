"use client";

import { useRouter } from "next/navigation";

// Deliberately NOT using the useSearchParams() hook here -- `current` is
// passed down from the server component's already-awaited searchParams
// prop. This sidesteps the Suspense-boundary requirement that
// useSearchParams() would otherwise force in a production build.
export function StatusFilter({ current }: { current?: string }) {
  const router = useRouter();

  return (
    <select
      className="text-xs border rounded px-2 py-1"
      defaultValue={current || ""}
      onChange={(e) => {
        const v = e.target.value;
        router.push(v ? `/counselling?status=${encodeURIComponent(v)}` : "/counselling");
      }}
    >
      <option value="">All</option>
      <option value="Pending Workup">In Counselling</option>
      <option value="Ready for Scheduling">Ready for Scheduling</option>
    </select>
  );
}
