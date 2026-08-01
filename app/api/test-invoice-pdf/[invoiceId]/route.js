// Standalone diagnostic route -- NOT part of the final feature.
// Visit /api/test-invoice-pdf/<invoiceId> in the browser to confirm
// Puppeteer + @sparticuz/chromium actually work on Vercel's serverless
// environment before wiring the full WhatsApp bill-send flow on top of it.
// Safe to delete once confirmed working.

import { generateInvoicePdfBuffer } from '@/lib/pdf-generator';

export const runtime = 'nodejs';
export const maxDuration = 60;

export async function GET(request, { params }) {
  const { invoiceId } = await params;

  const result = await generateInvoicePdfBuffer(invoiceId);
  if (result.error) {
    return new Response(JSON.stringify({ error: result.error }), {
      status: 500,
      headers: { 'Content-Type': 'application/json' },
    });
  }

  return new Response(result.buffer, {
    status: 200,
    headers: {
      'Content-Type': 'application/pdf',
      'Content-Disposition': 'inline; filename="test-invoice.pdf"',
    },
  });
}
