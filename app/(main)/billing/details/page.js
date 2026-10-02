import { redirect } from 'next/navigation';

// Merged into the single Invoices screen at /billing (2 Oct 2026).
// Keeps ?invoiceId=, ?visitId= and ?q= so links from other screens still
// open the right invoice(s).
export default async function Page({ searchParams }) {
  const params = (await searchParams) || {};
  const qs = new URLSearchParams();
  ['invoiceId', 'visitId', 'q'].forEach((k) => { if (params[k]) qs.set(k, String(params[k])); });
  const s = qs.toString();
  redirect(s ? `/billing?${s}` : '/billing');
}
