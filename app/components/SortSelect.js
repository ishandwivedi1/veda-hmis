'use client';

import { useRouter, usePathname, useSearchParams } from 'next/navigation';

export default function SortSelect({ options, paramName = 'sort', defaultValue }) {
  const router = useRouter();
  const pathname = usePathname();
  const searchParams = useSearchParams();
  const current = searchParams.get(paramName) || defaultValue || options[0]?.value;

  function handleChange(e) {
    const params = new URLSearchParams(searchParams.toString());
    params.set(paramName, e.target.value);
    router.push(`${pathname}?${params.toString()}`);
  }

  return (
    <select className="fi" style={{ width: 'auto' }} value={current} onChange={handleChange}>
      {options.map((o) => (
        <option key={o.value} value={o.value}>Sort: {o.label}</option>
      ))}
    </select>
  );
}
