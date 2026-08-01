// lib/pdf-generator.js
// Renders VEDA HMIS's existing Handlebars invoice HTML (renderInvoiceHtml)
// into an actual PDF file, using a serverless-compatible headless Chromium.
// This is the same visual output as the browser print/PDF, just generated
// server-side so it can be attached to a WhatsApp message.
//
// Requires (add to package.json): puppeteer-core, @sparticuz/chromium

import { renderInvoiceHtml } from '@/app/print-templates/actions';

/**
 * Generates a PDF buffer for the given invoice.
 * @param {string} invoiceId
 * @param {boolean} includeBreakup
 * @returns {Promise<{ buffer?: Buffer, error?: string }>}
 */
export async function generateInvoicePdfBuffer(invoiceId, includeBreakup = false) {
  const result = await renderInvoiceHtml(invoiceId, includeBreakup);
  if (result.error) return { error: result.error };

  let browser;
  try {
    // Dynamic imports -- these packages are heavy and only needed here.
    const chromium = (await import('@sparticuz/chromium')).default;
    const puppeteer = await import('puppeteer-core');

    browser = await puppeteer.launch({
      args: chromium.args,
      defaultViewport: chromium.defaultViewport,
      executablePath: await chromium.executablePath(),
      headless: chromium.headless,
    });

    const page = await browser.newPage();
    await page.setContent(result.html, { waitUntil: 'networkidle0' });

    const pdfUint8 = await page.pdf({
      format: 'A4',
      printBackground: true,
      margin: { top: '10mm', bottom: '10mm', left: '10mm', right: '10mm' },
    });

    return { buffer: Buffer.from(pdfUint8) };
  } catch (err) {
    return { error: `PDF generation failed: ${err.message}` };
  } finally {
    if (browser) await browser.close();
  }
}
