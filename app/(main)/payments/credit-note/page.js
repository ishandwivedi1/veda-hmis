import { redirect } from 'next/navigation';

// Credit notes are their own Zoho-style module now (/credit-notes, 2 Oct
// 2026). Old links (e.g. ?patientId=&invoiceId=) open the new form.
export default async function Page({ searchParams }) {
  const params = (await searchParams) || {};
  const qs = new URLSearchParams();
  ['patientId', 'invoiceId'].forEach((k) => { if (params[k]) qs.set(k, String(params[k])); });
  redirect(qs.toString() ? `/credit-notes/new?${qs}` : '/credit-notes');
}
