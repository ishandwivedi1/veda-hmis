import { redirect } from 'next/navigation';

// Merged into the single Payments screen at /payments (2 Oct 2026).
export default async function Page({ searchParams }) {
  const params = await searchParams;
  redirect(params?.paymentId ? `/payments?paymentId=${encodeURIComponent(params.paymentId)}` : '/payments');
}
