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
 * Sends a WhatsApp template message via Meta's Cloud API.
 *
 * @param {Object} params
 * @param {string} params.to - Raw mobile number (will be normalized).
 * @param {string} params.templateName - Approved template name (e.g. "registration").
 * @param {string} [params.languageCode] - Defaults to "en_US".
 * @param {Array<{type: string, text: string}>} [params.bodyParams] - Ordered body variables.
 * @param {Object} [params.meta] - Optional context for logging: { patientId, visitId, module, triggeredBy }
 * @returns {Promise<{ success: boolean, data?: any, error?: string }>}
 */
export async function sendWhatsAppTemplate({
  to,
  templateName,
  languageCode = 'en_US',
  bodyParams = [],
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

  const payload = {
    messaging_product: 'whatsapp',
    to: mobile,
    type: 'template',
    template: {
      name: templateName,
      language: { code: languageCode },
      components: bodyParams.length
        ? [
            {
              type: 'body',
              parameters: bodyParams,
            },
          ]
        : [],
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
      module: meta.module || null,
      triggered_by: meta.triggeredBy || null,
      sent_at: new Date().toISOString(),
    });
  } catch (logErr) {
    console.error('Failed to write whatsapp_logs row:', logErr.message);
  }
}
