// lib/whatsapp.js
// Reusable WhatsApp Cloud API (Meta) integration for VEDA HMIS.
// Requires these env vars (set in Vercel + Codespaces .env.local):
//   WHATSAPP_ACCESS_TOKEN   - permanent system-user token (never commit this)
//   WHATSAPP_PHONE_NUMBER_ID - the numeric phone number ID (e.g. 1125511497312908)
//   WHATSAPP_API_VERSION     - optional, defaults to v21.0

import { createClient } from '@/lib/supabase-server';

const WHATSAPP_API_VERSION = process.env.WHATSAPP_API_VERSION || 'v21.0'; // confirmed working with current token

/**
 * Normalizes an Indian mobile number to WhatsApp's expected format (91XXXXXXXXXX).
 * Mirrors the logic from the previous Deluge implementation.
 */
export function formatIndianMobile(rawNumber) {
  if (!rawNumber) return '';
  let mobile = String(rawNumber).trim();
  mobile = mobile.replace(/\s/g, '');
  mobile = mobile.replace(/-/g, '');
  mobile = mobile.replace(/\+/g, '');

  if (mobile.length === 10) {
    mobile = '91' + mobile;
  }
  return mobile;
}

/**
 * Uploads a file (e.g. an invoice PDF) to Meta's Media API and returns a
 * media id, which can then be referenced in a template's document header.
 * Media ids are valid for ~30 days but should be used immediately after
 * upload since we send right away.
 * @returns {Promise<{ id?: string, error?: string }>}
 */
export async function uploadMediaToWhatsApp(buffer, filename, mimeType = 'application/pdf') {
  const token = process.env.WHATSAPP_ACCESS_TOKEN;
  const phoneNumberId = process.env.WHATSAPP_PHONE_NUMBER_ID;
  if (!token || !phoneNumberId) {
    return { error: 'WhatsApp credentials missing (WHATSAPP_ACCESS_TOKEN / WHATSAPP_PHONE_NUMBER_ID)' };
  }

  try {
    const form = new FormData();
    form.append('messaging_product', 'whatsapp');
    form.append('type', mimeType);
    form.append('file', new Blob([buffer], { type: mimeType }), filename);

    const res = await fetch(`https://graph.facebook.com/${WHATSAPP_API_VERSION}/${phoneNumberId}/media`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}` },
      body: form,
    });
    const data = await res.json();

    if (!res.ok || !data.id) {
      return { error: data?.error?.message || `Media upload failed (status ${res.status})` };
    }
    return { id: data.id };
  } catch (err) {
    return { error: err.message || 'Unknown error uploading media to WhatsApp' };
  }
}

/**
 * Sends a WhatsApp template message via Meta's Cloud API.
 *
 * @param {Object} params
 * @param {string} params.to - Raw mobile number (will be normalized).
 * @param {string} params.templateName - Approved template name (e.g. "registration").
 * @param {string} [params.languageCode] - Defaults to "en_US".
 * @param {Array<{type: string, text: string}>} [params.bodyParams] - Ordered body variables.
 * @param {Object} [params.headerDocument] - Optional { id, filename } for a document-header template.
 * @param {Object} [params.meta] - Optional context for logging: { patientId, visitId, invoiceId, module, triggeredBy }
 * @returns {Promise<{ success: boolean, data?: any, error?: string }>}
 */
export async function sendWhatsAppTemplate({
  to,
  templateName,
  languageCode = 'en_US',
  bodyParams = [],
  headerDocument = null,
  meta = {},
}) {
  const token = process.env.WHATSAPP_ACCESS_TOKEN;
  const phoneNumberId = process.env.WHATSAPP_PHONE_NUMBER_ID;

  if (!token || !phoneNumberId) {
    const error = 'WhatsApp credentials missing (WHATSAPP_ACCESS_TOKEN / WHATSAPP_PHONE_NUMBER_ID)';
    console.error(error);
    return { success: false, error };
  }

  const mobile = formatIndianMobile(to);
  if (!mobile || mobile.length < 12) {
    const error = `Invalid mobile number after formatting: "${mobile}"`;
    await logWhatsAppMessage({ mobile, templateName, meta, success: false, error });
    return { success: false, error };
  }

  const components = [];
  if (headerDocument) {
    components.push({
      type: 'header',
      parameters: [
        {
          type: 'document',
          document: { id: headerDocument.id, filename: headerDocument.filename || 'document.pdf' },
        },
      ],
    });
  }
  if (bodyParams.length) {
    components.push({ type: 'body', parameters: bodyParams });
  }

  const payload = {
    messaging_product: 'whatsapp',
    to: mobile,
    type: 'template',
    template: {
      name: templateName,
      language: { code: languageCode },
      components,
    },
  };

  try {
    const res = await fetch(
      `https://graph.facebook.com/${WHATSAPP_API_VERSION}/${phoneNumberId}/messages`,
      {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${token}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify(payload),
      }
    );

    const data = await res.json();

    if (!res.ok) {
      const error = data?.error?.message || `WhatsApp API error (status ${res.status})`;
      await logWhatsAppMessage({ mobile, templateName, meta, success: false, error, response: data });
      return { success: false, error, data };
    }

    const logResult = await logWhatsAppMessage({ mobile, templateName, meta, success: true, response: data });
    return { success: true, data, logError: logResult.error || null };
  } catch (err) {
    const error = err.message || 'Unknown error sending WhatsApp message';
    const logResult = await logWhatsAppMessage({ mobile, templateName, meta, success: false, error });
    return { success: false, error, logError: logResult.error || null };
  }
}

/**
 * Convenience wrapper for the "appointment" template (used for visit
 * registration confirmation): Patient Name + Visit Number + Visit Date.
 * patientDbId is the patient's UUID, used only for the audit log FK.
 */
export async function sendVisitConfirmationWhatsApp({ name, visitNumber, visitDate, mobile, patientDbId, visitDbId, meta = {} }) {
  return sendWhatsAppTemplate({
    to: mobile,
    templateName: 'appointment',
    bodyParams: [
      { type: 'text', text: name || '' },
      { type: 'text', text: visitNumber || '' },
      { type: 'text', text: visitDate || '' },
    ],
    meta: { ...meta, patientId: patientDbId || null, visitId: visitDbId || null },
  });
}

/**
 * Formats a timestamp for display in WhatsApp messages, in IST --
 * matches the project-wide Asia/Kolkata convention.
 */
export function formatVisitDateIST(isoTimestamp) {
  if (!isoTimestamp) return '';
  return new Intl.DateTimeFormat('en-IN', {
    timeZone: 'Asia/Kolkata',
    day: '2-digit',
    month: 'short',
    year: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  }).format(new Date(isoTimestamp));
}

/**
 * Convenience wrapper for the "registration" template (Patient Name + Patient ID).
 * patientUhid is the human-readable ID shown in the message (e.g. "VEH-00011").
 * patientDbId is the patient's actual UUID row id, used only for the audit log FK.
 */
export async function sendRegistrationWhatsApp({ name, patientUhid, patientDbId, mobile, meta = {} }) {
  return sendWhatsAppTemplate({
    to: mobile,
    templateName: 'registration',
    bodyParams: [
      { type: 'text', text: name || '' },
      { type: 'text', text: patientUhid || '' },
    ],
    meta: { ...meta, patientId: patientDbId || null },
  });
}

/**
 * Formats a number as Indian Rupees, matching the display convention
 * used elsewhere (Rs.X.XX), but with comma grouping for the WhatsApp copy.
 */
export function formatINR(amount) {
  const n = Number(amount) || 0;
  return `Rs. ${n.toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}

/**
 * Plain comma-grouped number, no currency prefix -- for templates that
 * already have the ₹ symbol baked into the static template text.
 */
export function formatAmountPlain(amount) {
  const n = Number(amount) || 0;
  return n.toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

/** Date-only (no time) IST formatter, for receipt-style messages. */
export function formatDateOnlyIST(isoTimestamp) {
  if (!isoTimestamp) return '';
  return new Intl.DateTimeFormat('en-IN', {
    timeZone: 'Asia/Kolkata',
    day: '2-digit',
    month: 'short',
    year: 'numeric',
  }).format(new Date(isoTimestamp));
}

/**
 * Convenience wrapper for the "payment" template (advance payment
 * confirmation): Name + Amount + Receipt No + Date.
 */
export async function sendAdvancePaymentWhatsApp({ name, amount, receiptNumber, date, mobile, patientDbId, meta = {} }) {
  return sendWhatsAppTemplate({
    to: mobile,
    templateName: 'payment',
    bodyParams: [
      { type: 'text', text: name || '' },
      { type: 'text', text: formatAmountPlain(amount) },
      { type: 'text', text: receiptNumber || '' },
      { type: 'text', text: date || '' },
    ],
    meta: { ...meta, patientId: patientDbId || null },
  });
}

/**
 * Sends the "bill_template_with_pdf" template: uploads an already-generated
 * invoice PDF to WhatsApp as media, then sends the template with the PDF
 * attached as a document header and Name/Bill No/Amount as body variables.
 * @param {Object} params
 * @param {Buffer} params.pdfBuffer - Already-generated invoice PDF.
 * @param {string} params.filename - e.g. "Invoice-INV26-000123.pdf"
 */
export async function sendInvoiceBillWhatsApp({ name, invoiceNumber, amount, mobile, pdfBuffer, filename, patientDbId, invoiceDbId, meta = {} }) {
  const upload = await uploadMediaToWhatsApp(pdfBuffer, filename, 'application/pdf');
  if (upload.error) {
    // Log the failure even though no message was attempted, so it shows
    // up in the audit trail exactly like any other failed send.
    await logWhatsAppMessage({
      mobile: formatIndianMobile(mobile),
      templateName: 'bill_template_with_pdf',
      meta: { ...meta, patientId: patientDbId || null, invoiceId: invoiceDbId || null },
      success: false,
      error: `Media upload failed: ${upload.error}`,
    });
    return { success: false, error: `Media upload failed: ${upload.error}` };
  }

  return sendWhatsAppTemplate({
    to: mobile,
    templateName: 'bill_template_with_pdf',
    bodyParams: [
      { type: 'text', text: name || '' },
      { type: 'text', text: invoiceNumber || '' },
      { type: 'text', text: formatINR(amount) },
    ],
    headerDocument: { id: upload.id, filename },
    meta: { ...meta, patientId: patientDbId || null, invoiceId: invoiceDbId || null },
  });
}

/**
 * Writes an audit row to whatsapp_logs. Never throws — logging failures
 * should not break the calling flow (e.g. registration) — but the error
 * is returned to the caller so it can be surfaced for diagnosis instead
 * of vanishing into server-side console logs.
 */
async function logWhatsAppMessage({ mobile, templateName, meta = {}, success, error = null, response = null }) {
  try {
    const supabase = await createClient();
    const { error: insertError } = await supabase.from('whatsapp_logs').insert({
      mobile_number: mobile,
      template_name: templateName,
      success,
      error_message: error,
      response_payload: response,
      patient_id: meta.patientId || null,
      visit_id: meta.visitId || null,
      invoice_id: meta.invoiceId || null,
      module: meta.module || null,
      triggered_by: meta.triggeredBy || null,
      sent_at: new Date().toISOString(),
    });
    return { error: insertError ? insertError.message : null };
  } catch (logErr) {
    console.error('Failed to write whatsapp_logs row:', logErr.message);
    return { error: logErr.message };
  }
}
