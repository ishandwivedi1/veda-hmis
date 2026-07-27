#!/bin/bash
set -e

echo "== Print Templates v2: Hospital Settings form + OPD/Surgery Bill =="
echo "   1. New Hospital Settings panel -- real labeled fields (name,"
echo "      address, phone, terms) plus logo upload with preview, instead"
echo "      of hunting through HTML. Applies to every template at once."
echo "   2. Two invoice templates now: OPD Bill (as before) and Surgery"
echo "      Bill (SURGERY BILL title, Package field, Discharge Date field)."
echo "      Picked automatically based on whether the invoice contains a"
echo "      surgical package line item."

echo "-- Installing handlebars (template engine) --"
npm install handlebars --no-audit --no-fund

echo "-- Writing app/print-templates/actions.js --"
mkdir -p "$(dirname "app/print-templates/actions.js")"
cat > "app/print-templates/actions.js" << 'JSEOF_31957219'
'use server';

import { createClient } from '@/lib/supabase-server';
import Handlebars from 'handlebars';

// ── Editable print templates ──────────────────────────────────────────
// Each template's HTML lives here as a code-level DEFAULT (versioned,
// reviewable) which the database can override once someone edits and
// saves it from the Print Templates admin page. getPrintTemplate()
// always returns *something renderable* -- the DB row if one exists,
// otherwise this default -- so there's never a missing-template state.
//
// Hospital-wide info (name, address, logo, etc) is deliberately NOT
// hardcoded into these templates -- it lives in hospital_settings and
// gets merged into the render context, edited once as a proper form
// rather than hunted down inside every template's HTML.
//
// Templates use Handlebars {field} tokens ({{field}} for the one
// HTML field, the logo). All formatting (currency, dates) happens in
// the *data-building* functions below, so editors only ever see plain
// tokens, never format-string logic.

const DEFAULT_TEMPLATES = {
  invoice_opd: "<div style=\"max-width: 800px; margin: 0 auto; padding: 24px; font-family: Arial, Helvetica, sans-serif; color: #1a1a1a; font-size: 13px;\">\n\n  <!-- HEADER -->\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 6px;\">\n    <tr>\n      <td style=\"width: 70px; vertical-align: top;\">\n        {{{logo_html}}}\n      </td>\n      <td style=\"vertical-align: top;\">\n        <div style=\"font-size: 26px; font-weight: 800; letter-spacing: .3px; text-decoration: underline;\">{{hospital_name}}</div>\n        <div style=\"font-size: 12px; font-weight: 700; margin-top: 2px;\">{{hospital_unit_line}}</div>\n        <div style=\"font-size: 11px; font-weight: 700;\">REGN NO : {{hospital_regn_no}}</div>\n      </td>\n      <td style=\"text-align: right; vertical-align: top; font-size: 11px; line-height: 1.5;\">\n        {{hospital_address_line1}}<br/>\n        {{hospital_address_line2}}<br/>\n        {{hospital_city_state_pin}}<br/>\n        <br/>\n        Tel: {{hospital_phone}}<br/>\n        <strong>{{hospital_email}}</strong>\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; font-size: 16px; font-weight: 700; border-top: 1.5px solid #333; border-bottom: 1.5px solid #333; padding: 8px 0; margin: 10px 0 16px;\">\n    OPD BILL/INVOICE\n  </div>\n\n  <!-- PATIENT / BILL INFO -->\n  <table style=\"width: 100%; border: 1.5px solid #333; border-collapse: collapse; margin-bottom: 18px;\">\n    <tr>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9; border-right: 1px solid #999;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 130px; color: #444;\">PATIENT ID</td><td>: <strong>{{patient_id}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">PATIENT NAME</td><td>: <strong>{{patient_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">MOBILE NUMBER</td><td>: <strong>{{patient_mobile}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">AGE/GENDER</td><td>: <strong>{{patient_age}} / {{patient_gender}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">PROCEDURE</td><td>: <strong>{{procedure}}</strong></td></tr>\n        </table>\n      </td>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 140px; color: #444;\">BILL NO</td><td>: <strong>{{bill_no}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">BILL DATE</td><td>: <strong>{{bill_date}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">VISIT DATE</td><td>: <strong>{{visit_date}}</strong></td></tr>\n          <tr><td colspan=\"2\">&nbsp;</td></tr>\n          <tr><td style=\"color: #444;\">DOCTOR NAME</td><td>: <strong>{{doctor_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">DOCTOR REGN NO</td><td>: <strong>{{doctor_regn_no}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">HOSPITAL REGN NO</td><td>: <strong>{{hospital_regn_no}}</strong></td></tr>\n        </table>\n      </td>\n    </tr>\n  </table>\n\n  <!-- ITEMS -->\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 4px; font-size: 12px;\">\n    <thead>\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: center; width: 50px;\">S.NO</th>\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: left;\">Billing_Item</th>\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: center; width: 70px;\">QTY</th>\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: right; width: 110px;\">RATE</th>\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: right; width: 120px;\">AMOUNT</th>\n      </tr>\n    </thead>\n    <tbody>\n      {{#each items}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: center;\">{{sno}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px;\">{{name}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: center;\">{{qty}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: right;\">{{rate}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: right;\">{{amount}}</td>\n      </tr>\n      {{/each}}\n    </tbody>\n  </table>\n\n  <!-- TOTALS -->\n  <table style=\"width: 260px; margin: 14px 0 0 auto; border-collapse: collapse; font-size: 12px;\">\n    <tr>\n      <td style=\"border: 1px solid #999; background: #e9edf2; padding: 6px 10px; font-weight: 700;\">GROSS AMOUNT</td>\n      <td style=\"border: 1px solid #999; padding: 6px 10px; text-align: right;\">{{gross_amount}}</td>\n    </tr>\n    <tr>\n      <td style=\"border: 1px solid #999; background: #e9edf2; padding: 6px 10px; font-weight: 700;\">DISCOUNT</td>\n      <td style=\"border: 1px solid #999; padding: 6px 10px; text-align: right;\">{{discount}}</td>\n    </tr>\n    <tr>\n      <td style=\"border: 1px solid #999; background: #e9edf2; padding: 6px 10px; font-weight: 700;\">NET AMOUNT PAYABLE</td>\n      <td style=\"border: 1px solid #999; padding: 6px 10px; text-align: right; font-weight: 700;\">{{net_amount}}</td>\n    </tr>\n  </table>\n\n  <!-- SIGNATURE + PAYMENT DETAILS -->\n  <table style=\"width: 100%; margin-top: 50px; border-collapse: collapse;\">\n    <tr>\n      <td style=\"width: 45%; vertical-align: bottom; font-size: 12px;\">\n        <div>AUTHORISED SIGNATURE</div>\n        <div>FOR {{hospital_name}}</div>\n      </td>\n      <td style=\"width: 55%; vertical-align: top;\">\n        <div style=\"font-size: 12px; margin-bottom: 6px;\">Payment Details</div>\n        <table style=\"width: 100%; border-collapse: collapse; font-size: 11.5px;\">\n          <tr style=\"background: #e9edf2;\">\n            <th style=\"border: 1px solid #999; padding: 6px;\">Payment Date</th>\n            <th style=\"border: 1px solid #999; padding: 6px;\">Ref Number</th>\n            <th style=\"border: 1px solid #999; padding: 6px;\">Payment</th>\n          </tr>\n          {{#each payments}}\n          <tr>\n            <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{date}}</td>\n            <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{ref_number}}</td>\n            <td style=\"border: 1px solid #999; padding: 6px; text-align: right;\">{{amount}}</td>\n          </tr>\n          {{/each}}\n          <tr>\n            <td colspan=\"2\" style=\"border: 1px solid #999; padding: 6px; background: #e9edf2; font-weight: 700;\">Payments Received</td>\n            <td style=\"border: 1px solid #999; padding: 6px; text-align: right; font-weight: 700;\">{{total_paid}}</td>\n          </tr>\n        </table>\n      </td>\n    </tr>\n  </table>\n\n  <!-- TERMS -->\n  <div style=\"margin-top: 30px; font-size: 11.5px;\">\n    <div style=\"font-weight: 700; margin-bottom: 4px;\">Terms &amp; Conditions</div>\n    <div>{{terms_text}}</div>\n    <div style=\"margin-top: 4px;\">For any Queries please contact us at {{hospital_phone}} or Email us at {{hospital_email}}</div>\n  </div>\n\n</div>\n",
  invoice_surgery: "<div style=\"max-width: 800px; margin: 0 auto; padding: 24px; font-family: Arial, Helvetica, sans-serif; color: #1a1a1a; font-size: 13px;\">\n\n  <!-- HEADER -->\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 6px;\">\n    <tr>\n      <td style=\"width: 70px; vertical-align: top;\">\n        {{{logo_html}}}\n      </td>\n      <td style=\"vertical-align: top;\">\n        <div style=\"font-size: 26px; font-weight: 800; letter-spacing: .3px; text-decoration: underline;\">{{hospital_name}}</div>\n        <div style=\"font-size: 12px; font-weight: 700; margin-top: 2px;\">{{hospital_unit_line}}</div>\n        <div style=\"font-size: 11px; font-weight: 700;\">REGN NO : {{hospital_regn_no}}</div>\n      </td>\n      <td style=\"text-align: right; vertical-align: top; font-size: 11px; line-height: 1.5;\">\n        {{hospital_address_line1}}<br/>\n        {{hospital_address_line2}}<br/>\n        {{hospital_city_state_pin}}<br/>\n        <br/>\n        Tel: {{hospital_phone}}<br/>\n        <strong>{{hospital_email}}</strong>\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; font-size: 16px; font-weight: 700; border-top: 1.5px solid #333; border-bottom: 1.5px solid #333; padding: 8px 0; margin: 10px 0 16px;\">\n    SURGERY BILL\n  </div>\n\n  <!-- PATIENT / BILL INFO -->\n  <table style=\"width: 100%; border: 1.5px solid #333; border-collapse: collapse; margin-bottom: 18px;\">\n    <tr>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9; border-right: 1px solid #999;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 130px; color: #444;\">PATIENT ID</td><td>: <strong>{{patient_id}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">PATIENT NAME</td><td>: <strong>{{patient_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">MOBILE NUMBER</td><td>: <strong>{{patient_mobile}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">AGE/GENDER</td><td>: <strong>{{patient_age}} / {{patient_gender}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">PROCEDURE</td><td>: <strong>{{procedure}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">PACKAGE</td><td>: <strong>{{package_name}}</strong></td></tr>\n        </table>\n      </td>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 140px; color: #444;\">BILL NO</td><td>: <strong>{{bill_no}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">BILL DATE</td><td>: <strong>{{bill_date}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">VISIT DATE</td><td>: <strong>{{visit_date}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">DISCHARGE DATE</td><td>: <strong>{{discharge_date}}</strong></td></tr>\n          <tr><td colspan=\"2\">&nbsp;</td></tr>\n          <tr><td style=\"color: #444;\">DOCTOR NAME</td><td>: <strong>{{doctor_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">DOCTOR REGN NO</td><td>: <strong>{{doctor_regn_no}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">HOSPITAL REGN NO</td><td>: <strong>{{hospital_regn_no}}</strong></td></tr>\n        </table>\n      </td>\n    </tr>\n  </table>\n\n  <!-- ITEMS -->\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 4px; font-size: 12px;\">\n    <thead>\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: center; width: 50px;\">S.NO</th>\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: left;\">Billing_Item</th>\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: center; width: 70px;\">QTY</th>\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: right; width: 110px;\">RATE</th>\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: right; width: 120px;\">AMOUNT</th>\n      </tr>\n    </thead>\n    <tbody>\n      {{#each items}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: center;\">{{sno}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px;\">{{name}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: center;\">{{qty}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: right;\">{{rate}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: right;\">{{amount}}</td>\n      </tr>\n      {{/each}}\n    </tbody>\n  </table>\n\n  <!-- TOTALS -->\n  <table style=\"width: 260px; margin: 14px 0 0 auto; border-collapse: collapse; font-size: 12px;\">\n    <tr>\n      <td style=\"border: 1px solid #999; background: #e9edf2; padding: 6px 10px; font-weight: 700;\">GROSS AMOUNT</td>\n      <td style=\"border: 1px solid #999; padding: 6px 10px; text-align: right;\">{{gross_amount}}</td>\n    </tr>\n    <tr>\n      <td style=\"border: 1px solid #999; background: #e9edf2; padding: 6px 10px; font-weight: 700;\">DISCOUNT</td>\n      <td style=\"border: 1px solid #999; padding: 6px 10px; text-align: right;\">{{discount}}</td>\n    </tr>\n    <tr>\n      <td style=\"border: 1px solid #999; background: #e9edf2; padding: 6px 10px; font-weight: 700;\">NET AMOUNT PAYABLE</td>\n      <td style=\"border: 1px solid #999; padding: 6px 10px; text-align: right; font-weight: 700;\">{{net_amount}}</td>\n    </tr>\n  </table>\n\n  <!-- SIGNATURE + PAYMENT DETAILS -->\n  <table style=\"width: 100%; margin-top: 50px; border-collapse: collapse;\">\n    <tr>\n      <td style=\"width: 45%; vertical-align: bottom; font-size: 12px;\">\n        <div>AUTHORISED SIGNATURE</div>\n        <div>FOR {{hospital_name}}</div>\n      </td>\n      <td style=\"width: 55%; vertical-align: top;\">\n        <div style=\"font-size: 12px; margin-bottom: 6px;\">Payment Details</div>\n        <table style=\"width: 100%; border-collapse: collapse; font-size: 11.5px;\">\n          <tr style=\"background: #e9edf2;\">\n            <th style=\"border: 1px solid #999; padding: 6px;\">Payment Date</th>\n            <th style=\"border: 1px solid #999; padding: 6px;\">Ref Number</th>\n            <th style=\"border: 1px solid #999; padding: 6px;\">Payment</th>\n          </tr>\n          {{#each payments}}\n          <tr>\n            <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{date}}</td>\n            <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{ref_number}}</td>\n            <td style=\"border: 1px solid #999; padding: 6px; text-align: right;\">{{amount}}</td>\n          </tr>\n          {{/each}}\n          <tr>\n            <td colspan=\"2\" style=\"border: 1px solid #999; padding: 6px; background: #e9edf2; font-weight: 700;\">Payments Received</td>\n            <td style=\"border: 1px solid #999; padding: 6px; text-align: right; font-weight: 700;\">{{total_paid}}</td>\n          </tr>\n        </table>\n      </td>\n    </tr>\n  </table>\n\n  <!-- TERMS -->\n  <div style=\"margin-top: 30px; font-size: 11.5px;\">\n    <div style=\"font-weight: 700; margin-bottom: 4px;\">Terms &amp; Conditions</div>\n    <div>{{terms_text}}</div>\n    <div style=\"margin-top: 4px;\">For any Queries please contact us at {{hospital_phone}} or Email us at {{hospital_email}}</div>\n  </div>\n\n</div>\n",
};

const PRINT_TEMPLATE_CATALOG = [
  { key: 'invoice_opd', name: 'OPD Bill / Invoice', description: 'Printed for OPD invoices (Billing module -> Print).' },
  { key: 'invoice_surgery', name: 'Surgery Bill / Invoice', description: 'Printed for invoices containing a surgical package.' },
  { key: 'receipt', name: 'Payment Receipt', description: 'Coming soon.', comingSoon: true },
  { key: 'investigation_report', name: 'Investigation Report', description: 'Coming soon.', comingSoon: true },
  { key: 'opd_summary', name: 'OPD Patient Summary', description: 'Coming soon.', comingSoon: true },
  { key: 'consent_form', name: 'Consent Form', description: 'Coming soon.', comingSoon: true },
  { key: 'discharge_summary', name: 'Discharge Summary', description: 'Coming soon.', comingSoon: true },
];

// ── Hospital Settings -- the "actual fields to edit" form (name,
//    address, logo, etc), shared across every template. Singleton row
//    (id is always `true`). ──
export async function getHospitalSettings() {
  const supabase = await createClient();
  const { data } = await supabase.from('hospital_settings').select('*').eq('id', true).maybeSingle();
  return data || {};
}

export async function saveHospitalSettings(fields) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('hospital_settings').update({
    ...fields, updated_at: new Date().toISOString(), updated_by: userData?.user?.id || null,
  }).eq('id', true);
  if (error) return { error: error.message };
  return { success: true };
}

function logoHtml(settings) {
  if (settings?.logo_data_url) {
    return `<img src="${settings.logo_data_url}" style="width: 56px; height: 56px; object-fit: contain;" />`;
  }
  // Fallback mark if no logo has been uploaded yet.
  return `<svg width="56" height="56" viewBox="0 0 100 100" xmlns="http://www.w3.org/2000/svg">
    <path d="M10 50 Q50 15 90 50 Q50 85 10 50 Z" fill="none" stroke="#1e4e8c" stroke-width="6"/>
    <circle cx="50" cy="50" r="16" fill="#1e4e8c"/>
    <path d="M8 52 Q3 60 12 66 Q10 56 8 52 Z" fill="#a6791f"/>
  </svg>`;
}

export async function listPrintTemplates() {
  const supabase = await createClient();
  const { data } = await supabase.from('print_templates').select('template_key, updated_at, updated_by, profiles(full_name)');
  const byKey = {};
  (data || []).forEach((r) => { byKey[r.template_key] = r; });
  return PRINT_TEMPLATE_CATALOG.map((t) => ({
    ...t,
    customized: !!byKey[t.key],
    updatedAt: byKey[t.key]?.updated_at || null,
    updatedBy: byKey[t.key]?.profiles?.full_name || null,
  }));
}

export async function getPrintTemplate(key) {
  const supabase = await createClient();
  const { data } = await supabase.from('print_templates').select('html, updated_at').eq('template_key', key).maybeSingle();
  const catalog = PRINT_TEMPLATE_CATALOG.find((t) => t.key === key);
  return {
    key,
    name: catalog?.name || key,
    html: data?.html || DEFAULT_TEMPLATES[key] || '<div>No template found.</div>',
    isCustomized: !!data,
    updatedAt: data?.updated_at || null,
  };
}

export async function savePrintTemplate(key, html) {
  const supabase = await createClient();
  const catalog = PRINT_TEMPLATE_CATALOG.find((t) => t.key === key);
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('print_templates').upsert({
    template_key: key, name: catalog?.name || key, html,
    updated_at: new Date().toISOString(), updated_by: userData?.user?.id || null,
  }, { onConflict: 'template_key' });
  if (error) return { error: error.message };
  return { success: true };
}

export async function resetPrintTemplate(key) {
  const supabase = await createClient();
  const { error } = await supabase.from('print_templates').delete().eq('template_key', key);
  if (error) return { error: error.message };
  return { success: true };
}

// ── Preview arbitrary (possibly unsaved) template HTML against sample
//    data -- lets the editor see changes before committing them. ──
export async function previewTemplateHtml(key, html) {
  try {
    const compiled = Handlebars.compile(html);
    return { html: compiled(await getSampleData(key)) };
  } catch (e) {
    return { error: `Template error: ${e.message}` };
  }
}

// ── Sample data for the admin preview pane -- deliberately fake/generic
//    so editors can see the layout without needing a real invoice. ──
export async function getSampleData(key) {
  const settings = await getHospitalSettings();
  if (key === 'invoice_opd') return buildInvoiceContext(settings, SAMPLE_OPD_RAW);
  if (key === 'invoice_surgery') return buildInvoiceContext(settings, SAMPLE_SURGERY_RAW);
  return {};
}

const SAMPLE_OPD_RAW = {
  patient: { patient_code: 'VEH-P-00031', first_name: 'Dharam', last_name: '', mobile: '+919758041970', age: 39, gender: 'Male' },
  invoice: { invoice_number: 'VEH-BILL-0143', created_at: '2026-06-04T00:00:00Z', gross: 300, gst: 0, net: 300, paid: 300, purpose: 'OPD Services' },
  visit: { created_at: '2026-06-01T00:00:00Z' },
  doctor: { full_name: 'Dr. Nisha Bachkheti', registration_no: 'UKMC-3436' },
  lineItems: [{ service_name: 'OPD Consultation', qty: 1, rate: 300, disc: 0, net: 300, dept: 'Consultation' }],
  payments: [{ created_at: '2026-06-03T00:00:00Z', receipt_number: 'VEH/RECEIPT/-0054', amount: 300 }],
  packageName: null, dischargeDate: null,
};

const SAMPLE_SURGERY_RAW = {
  ...SAMPLE_OPD_RAW,
  invoice: { invoice_number: 'VEH-BILL-0200', created_at: '2026-06-10T00:00:00Z', gross: 35000, gst: 0, net: 35000, paid: 35000, purpose: 'Surgery Package' },
  lineItems: [{ service_name: 'Cataract Surgery Package', qty: 1, rate: 35000, disc: 0, net: 35000, dept: 'Surgery' }],
  payments: [{ created_at: '2026-06-10T00:00:00Z', receipt_number: 'VEH/RECEIPT/-0091', amount: 35000 }],
  packageName: 'Cataract Surgery -- Standard IOL Package', dischargeDate: '2026-06-11T00:00:00Z',
};

// ── Renders the actual invoice HTML for a given invoiceId. Picks the
//    OPD or Surgery variant based on whether any line item was billed
//    under the Surgery department (package billing tags its line item
//    dept: 'Surgery' -- see billing/new/new-invoice-tab.js). ──
export async function renderInvoiceHtml(invoiceId) {
  const supabase = await createClient();

  const { data: invoice, error } = await supabase
    .from('invoices')
    .select('*, patients(uhid, first_name, last_name, mobile, age, gender), visits(id, created_at, doctor_id, profiles:doctor_id(full_name, registration_no))')
    .eq('id', invoiceId)
    .single();
  if (error || !invoice) return { error: 'Invoice not found.' };

  const { data: lineItems } = await supabase.from('invoice_line_items').select('*').eq('invoice_id', invoiceId).order('id');
  const { data: allocations } = await supabase
    .from('payment_allocations')
    .select('amount, payments(receipt_number, collected_at)')
    .eq('invoice_id', invoiceId);
  const payments = (allocations || []).map((a) => ({
    amount: a.amount, receipt_number: a.payments?.receipt_number, created_at: a.payments?.collected_at,
  }));

  const isSurgery = (lineItems || []).some((li) => li.dept === 'Surgery');

  let packageName = null;
  let dischargeDate = null;
  if (isSurgery && invoice.visit_id) {
    const { data: surgicalCase } = await supabase
      .from('surgical_cases')
      .select('id, procedure_name, master_packages:package_id(name)')
      .eq('visit_id', invoice.visit_id)
      .neq('status', 'Cancelled')
      .maybeSingle();
    packageName = surgicalCase?.master_packages?.name || null;
    if (surgicalCase) {
      const { data: episode } = await supabase
        .from('recovery_episodes')
        .select('discharge_date')
        .eq('surgical_case_id', surgicalCase.id)
        .maybeSingle();
      dischargeDate = episode?.discharge_date || null;
    }
  }

  const settings = await getHospitalSettings();
  const context = buildInvoiceContext(settings, {
    patient: {
      patient_code: invoice.patients?.uhid, first_name: invoice.patients?.first_name, last_name: invoice.patients?.last_name,
      mobile: invoice.patients?.mobile, age: invoice.patients?.age, gender: invoice.patients?.gender,
    },
    invoice,
    visit: invoice.visits,
    doctor: invoice.visits?.profiles,
    lineItems: lineItems || [],
    payments,
    packageName,
    dischargeDate,
  });

  const templateKey = isSurgery ? 'invoice_surgery' : 'invoice_opd';
  const template = await getPrintTemplate(templateKey);
  const compiled = Handlebars.compile(template.html);
  return { html: compiled(context) };
}

function inr(n) {
  return `Rs. ${Number(n || 0).toFixed(2)}`;
}
function fmtDate(d) {
  if (!d) return '--';
  return new Date(d).toLocaleDateString('en-IN', { day: '2-digit', month: 'short', year: 'numeric' });
}

function buildInvoiceContext(settings, { patient, invoice, visit, doctor, lineItems, payments, packageName, dischargeDate }) {
  const totalPaid = (payments || []).reduce((s, p) => s + Number(p.amount || 0), 0);
  const totalDisc = (lineItems || []).reduce((s, li) => s + Number(li.disc || 0), 0);
  return {
    hospital_name: settings.name || 'VEDA EYE HOSPITAL',
    hospital_unit_line: settings.unit_line || '',
    hospital_regn_no: settings.regn_no || '',
    hospital_address_line1: settings.address_line1 || '',
    hospital_address_line2: settings.address_line2 || '',
    hospital_city_state_pin: settings.city_state_pin || '',
    hospital_phone: settings.phone || '',
    hospital_email: settings.email || '',
    terms_text: settings.terms_text || '',
    logo_html: logoHtml(settings),

    patient_id: patient.patient_code || '--',
    patient_name: `${patient.first_name || ''} ${patient.last_name || ''}`.trim(),
    patient_mobile: patient.mobile || '--',
    patient_age: patient.age ?? '--',
    patient_gender: patient.gender || '--',
    procedure: invoice.purpose || 'OPD Services',
    package_name: packageName || '--',
    discharge_date: fmtDate(dischargeDate),

    bill_no: invoice.invoice_number,
    bill_date: fmtDate(invoice.created_at),
    visit_date: fmtDate(visit?.created_at),
    doctor_name: doctor?.full_name || '--',
    doctor_regn_no: doctor?.registration_no || '--',

    items: (lineItems || []).map((li, idx) => ({
      sno: idx + 1, name: li.service_name, qty: li.qty, rate: inr(li.rate), amount: inr(li.net),
    })),
    gross_amount: inr(invoice.gross),
    discount: inr(totalDisc),
    net_amount: inr(invoice.net),

    payments: (payments || []).map((p) => ({
      date: fmtDate(p.created_at), ref_number: p.receipt_number || '--', amount: inr(p.amount),
    })),
    total_paid: inr(totalPaid),
  };
}
JSEOF_31957219

echo "-- Writing app/invoice-print/[invoiceId]/page.js --"
mkdir -p "$(dirname "app/invoice-print/[invoiceId]/page.js")"
cat > "app/invoice-print/[invoiceId]/page.js" << 'JSEOF_12384722'
import { renderInvoiceHtml } from '@/app/print-templates/actions';
import PrintButton from './print-button';

export default async function InvoicePrintPage({ params }) {
  const { invoiceId } = await params;
  const result = await renderInvoiceHtml(invoiceId);

  if (result.error) {
    return <div style={{ padding: 40, textAlign: 'center', color: '#b3261e' }}>{result.error}</div>;
  }

  return (
    <div>
      <div className="no-print" style={{ textAlign: 'right', padding: '16px 24px 0' }}>
        <PrintButton />
      </div>
      {/* eslint-disable-next-line react/no-danger -- renderInvoiceHtml
          compiles this from the editable print_templates table via
          Handlebars, which HTML-escapes every {{token}} by default; the
          template's own static markup is authored by staff through the
          admin editor, not user input. */}
      <div dangerouslySetInnerHTML={{ __html: result.html }} />
    </div>
  );
}
JSEOF_12384722

echo "-- Writing app/(main)/print-templates/page.js --"
mkdir -p "$(dirname "app/(main)/print-templates/page.js")"
cat > "app/(main)/print-templates/page.js" << 'JSEOF_2193892'
'use client';

import { useState, useEffect, useCallback, useRef } from 'react';
import {
  listPrintTemplates, getPrintTemplate, savePrintTemplate, resetPrintTemplate, previewTemplateHtml,
  getHospitalSettings, saveHospitalSettings,
} from '@/app/print-templates/actions';

const PLACEHOLDER_REFERENCE = {
  invoice_opd: [
    'hospital_name', 'hospital_unit_line', 'hospital_regn_no', 'hospital_address_line1', 'hospital_address_line2',
    'hospital_city_state_pin', 'hospital_phone', 'hospital_email', 'terms_text', '{{{logo_html}}}',
    'patient_id', 'patient_name', 'patient_mobile', 'patient_age', 'patient_gender', 'procedure',
    'bill_no', 'bill_date', 'visit_date', 'doctor_name', 'doctor_regn_no',
    'items (loop: sno, name, qty, rate, amount)', 'gross_amount', 'discount', 'net_amount',
    'payments (loop: date, ref_number, amount)', 'total_paid',
  ],
};
PLACEHOLDER_REFERENCE.invoice_surgery = [...PLACEHOLDER_REFERENCE.invoice_opd, 'package_name', 'discharge_date'];

const SETTINGS_FIELDS = [
  { key: 'name', label: 'Hospital Name' },
  { key: 'unit_line', label: 'Unit Line (e.g. "A Unit of...")' },
  { key: 'regn_no', label: 'Hospital Registration No' },
  { key: 'address_line1', label: 'Address Line 1' },
  { key: 'address_line2', label: 'Address Line 2' },
  { key: 'city_state_pin', label: 'City, State - PIN' },
  { key: 'phone', label: 'Phone Number(s)' },
  { key: 'email', label: 'Email' },
  { key: 'terms_text', label: 'Terms & Conditions text' },
];

function HospitalSettingsPanel() {
  const [settings, setSettings] = useState(null);
  const [saving, setSaving] = useState(false);
  const [saveMsg, setSaveMsg] = useState('');
  const fileInputRef = useRef(null);

  const load = useCallback(async () => { setSettings(await getHospitalSettings()); }, []);
  useEffect(() => { load(); }, [load]);

  function update(key, value) {
    setSettings((prev) => ({ ...prev, [key]: value }));
    setSaveMsg('');
  }

  function handleLogoFile(e) {
    const file = e.target.files?.[0];
    if (!file) return;
    if (file.size > 1024 * 1024) { setSaveMsg('Logo image should be under 1MB.'); return; }
    const reader = new FileReader();
    reader.onload = () => update('logo_data_url', reader.result);
    reader.readAsDataURL(file);
  }

  async function handleSave() {
    setSaving(true);
    const result = await saveHospitalSettings(settings);
    setSaving(false);
    setSaveMsg(result.error || 'Saved -- applies to every template automatically.');
  }

  if (!settings) return <div style={{ fontSize: 12, color: 'var(--g400)' }}>Loading...</div>;

  return (
    <div className="card" style={{ marginBottom: 16 }}>
      <div className="card-head" style={{ marginBottom: 10 }}>
        <div className="card-title"><i className="ti ti-building-hospital" style={{ color: 'var(--blue)' }}></i> Hospital Settings</div>
        <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
          {saveMsg && <span style={{ fontSize: 11.5, color: saveMsg.includes('under') ? 'var(--red)' : 'var(--green)' }}>{saveMsg}</span>}
          <button className="btn btn-primary btn-sm" onClick={handleSave} disabled={saving}>{saving ? 'Saving...' : 'Save'}</button>
        </div>
      </div>
      <div style={{ fontSize: 11.5, color: 'var(--g500)', marginBottom: 14 }}>
        This information -- including the logo -- appears on every print template automatically. Edit it once here rather than in each template.
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: '120px 1fr', gap: 14, alignItems: 'center', marginBottom: 16 }}>
        <div>
          <div style={{
            width: 100, height: 100, border: '1.5px dashed var(--g300)', borderRadius: 10,
            display: 'flex', alignItems: 'center', justifyContent: 'center', overflow: 'hidden', background: '#fff',
          }}>
            {settings.logo_data_url
              ? <img src={settings.logo_data_url} alt="Logo" style={{ maxWidth: '100%', maxHeight: '100%', objectFit: 'contain' }} />
              : <i className="ti ti-photo" style={{ fontSize: 28, color: 'var(--g300)' }}></i>}
          </div>
        </div>
        <div>
          <label className="flbl">Hospital Logo</label>
          <input ref={fileInputRef} type="file" accept="image/png,image/jpeg,image/svg+xml" onChange={handleLogoFile} className="fi fi-sm" />
          <div style={{ fontSize: 10.5, color: 'var(--g400)', marginTop: 4 }}>PNG, JPG, or SVG -- under 1MB. Falls back to a default mark if none is uploaded.</div>
          {settings.logo_data_url && (
            <button className="btn" style={{ padding: '2px 8px', fontSize: 11, marginTop: 6 }} onClick={() => update('logo_data_url', null)}>Remove logo</button>
          )}
        </div>
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
        {SETTINGS_FIELDS.map((f) => (
          <div key={f.key} style={f.key === 'terms_text' ? { gridColumn: 'span 2' } : undefined}>
            <label className="flbl">{f.label}</label>
            <input className="fi fi-sm" value={settings[f.key] || ''} onChange={(e) => update(f.key, e.target.value)} />
          </div>
        ))}
      </div>
    </div>
  );
}

export default function PrintTemplatesPage() {
  const [templates, setTemplates] = useState([]);
  const [loading, setLoading] = useState(true);
  const [activeKey, setActiveKey] = useState(null);
  const [html, setHtml] = useState('');
  const [previewHtml, setPreviewHtml] = useState('');
  const [previewError, setPreviewError] = useState('');
  const [saving, setSaving] = useState(false);
  const [saveMsg, setSaveMsg] = useState('');
  const debounceRef = useRef(null);

  const refresh = useCallback(async () => {
    setTemplates(await listPrintTemplates());
    setLoading(false);
  }, []);

  useEffect(() => { refresh(); }, [refresh]);

  async function openTemplate(key) {
    setActiveKey(key);
    setSaveMsg('');
    const t = await getPrintTemplate(key);
    setHtml(t.html);
  }

  // Debounced live preview -- re-renders against sample data ~500ms
  // after typing stops, rather than on every keystroke.
  useEffect(() => {
    if (!activeKey) return;
    if (debounceRef.current) clearTimeout(debounceRef.current);
    debounceRef.current = setTimeout(async () => {
      const result = await previewTemplateHtml(activeKey, html);
      if (result.error) { setPreviewError(result.error); return; }
      setPreviewError('');
      setPreviewHtml(result.html);
    }, 500);
    return () => clearTimeout(debounceRef.current);
  }, [html, activeKey]);

  async function handleSave() {
    setSaving(true);
    setSaveMsg('');
    const result = await savePrintTemplate(activeKey, html);
    setSaving(false);
    if (result.error) { setPreviewError(result.error); return; }
    setSaveMsg('Saved.');
    refresh();
  }

  async function handleReset() {
    if (!window.confirm('Reset this template to the built-in default? Any customizations will be lost.')) return;
    setSaving(true);
    await resetPrintTemplate(activeKey);
    setSaving(false);
    const t = await getPrintTemplate(activeKey);
    setHtml(t.html);
    setSaveMsg('Reset to default.');
    refresh();
  }

  if (loading) return <div style={{ padding: 20, color: 'var(--g400)', fontSize: 13 }}>Loading...</div>;

  const activeMeta = templates.find((t) => t.key === activeKey);

  return (
    <div>
      <div style={{ marginBottom: 16 }}>
        <div style={{ fontSize: 18, fontWeight: 700 }}><i className="ti ti-file-invoice" style={{ color: 'var(--blue)' }}></i> Print Templates</div>
        <div style={{ fontSize: 12.5, color: 'var(--g500)' }}>
          Bills, receipts, reports, forms, and summaries printed across the app -- each one is an editable HTML template, not fixed layout.
        </div>
      </div>

      <HospitalSettingsPanel />

      <div style={{ display: 'grid', gridTemplateColumns: '260px 1fr', gap: 20, alignItems: 'start' }}>
        <div className="card">
          <div className="card-title" style={{ marginBottom: 10 }}>Templates</div>
          {templates.map((t) => (
            <button
              key={t.key}
              onClick={() => !t.comingSoon && openTemplate(t.key)}
              disabled={t.comingSoon}
              className="btn"
              style={{
                width: '100%', textAlign: 'left', marginBottom: 6, display: 'block',
                background: activeKey === t.key ? 'var(--blue-lt)' : t.comingSoon ? 'var(--g50)' : '',
                borderColor: activeKey === t.key ? 'var(--blue)' : '',
                cursor: t.comingSoon ? 'not-allowed' : 'pointer', opacity: t.comingSoon ? .6 : 1,
              }}
            >
              <div style={{ fontWeight: 600, fontSize: 12.5 }}>{t.name}</div>
              <div style={{ fontSize: 10.5, color: 'var(--g500)' }}>
                {t.comingSoon ? 'Coming soon' : t.customized ? `Customized -- ${t.updatedBy || 'someone'}` : 'Using default'}
              </div>
            </button>
          ))}
        </div>

        {!activeKey && (
          <div className="card" style={{ textAlign: 'center', color: 'var(--g400)', padding: 40 }}>
            Select a template on the left to edit its layout.
          </div>
        )}

        {activeKey && (
          <div>
            <div className="card" style={{ marginBottom: 16 }}>
              <div className="card-head" style={{ marginBottom: 10, flexWrap: 'wrap', gap: 8 }}>
                <div className="card-title">{activeMeta?.name}</div>
                <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
                  {saveMsg && <span style={{ fontSize: 11.5, color: 'var(--green)' }}>{saveMsg}</span>}
                  {activeMeta?.customized && (
                    <button className="btn btn-sm" onClick={handleReset} disabled={saving}>Reset to Default</button>
                  )}
                  <button className="btn btn-primary btn-sm" onClick={handleSave} disabled={saving}>
                    {saving ? 'Saving...' : 'Save'}
                  </button>
                </div>
              </div>

              <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 8 }}>
                Hospital name, address, and logo come from Hospital Settings above automatically. Edit the layout below for anything specific to this document -- {'{{tokens}}'} get replaced with real data when printed. Preview updates automatically as you type.
              </div>

              <details style={{ marginBottom: 10 }}>
                <summary style={{ fontSize: 11.5, color: 'var(--blue)', cursor: 'pointer' }}>Available placeholders</summary>
                <div style={{ fontSize: 11, color: 'var(--g600)', marginTop: 6, lineHeight: 1.8 }}>
                  {(PLACEHOLDER_REFERENCE[activeKey] || []).map((p) => (
                    <code key={p} style={{ background: 'var(--g100)', padding: '2px 6px', borderRadius: 4, marginRight: 6, display: 'inline-block', marginBottom: 4 }}>
                      {p.startsWith('{{') ? p : `{{${p}}}`}
                    </code>
                  ))}
                </div>
              </details>

              <textarea
                className="fi"
                value={html}
                onChange={(e) => setHtml(e.target.value)}
                spellCheck={false}
                style={{ width: '100%', height: 400, fontFamily: 'monospace', fontSize: 12, lineHeight: 1.5, resize: 'vertical' }}
              />
            </div>

            <div className="card">
              <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-eye" style={{ color: 'var(--teal)' }}></i> Preview (sample data)</div>
              {previewError && <div className="msg-err">{previewError}</div>}
              {!previewError && (
                <div style={{ border: '1px solid var(--g200)', borderRadius: 8, overflow: 'hidden' }}>
                  <iframe title="Template preview" srcDoc={previewHtml} style={{ width: '100%', height: 700, border: 'none' }} />
                </div>
              )}
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
JSEOF_2193892

echo "-- Writing app/components/AppShell.js --"
mkdir -p "$(dirname "app/components/AppShell.js")"
cat > "app/components/AppShell.js" << 'JSEOF_99686504'
'use client';

import { usePathname, useRouter } from 'next/navigation';
import Link from 'next/link';
import { useEffect, useState } from 'react';
import { createClient } from '@/lib/supabase-browser';

const NAV_ITEMS = [
  { href: '/dashboard', label: 'Dashboard', icon: 'ti-layout-dashboard', section: 'Overview' },
  { href: '/reports', label: 'Reports', icon: 'ti-chart-bar', section: 'Overview' },
  { href: '/front-office-dashboard', label: 'Front Office Dashboard', icon: 'ti-user-check', section: 'Overview' },
  { href: '/patients', label: 'Patients', icon: 'ti-users', section: 'Front Office' },
  { href: '/appointments', label: 'Appointments', icon: 'ti-calendar-event', section: 'Front Office' },
  { href: '/visits', label: 'Visits', icon: 'ti-door-enter', section: 'Front Office' },
  { href: '/billing', label: 'Billing', icon: 'ti-receipt', section: 'Finance' },
  { href: '/payments', label: 'Payments', icon: 'ti-cash', section: 'Finance' },
  { href: '/cash-management', label: 'Cash Management', icon: 'ti-cash-register', section: 'Finance' },
  { href: '/payments/reports', label: 'Reports', icon: 'ti-report-money', section: 'Finance' },
  { href: '/payments/ledger', label: 'Ledger View', icon: 'ti-book', section: 'Patient Ledger' },
  { href: '/payments/credit-note', label: 'Credit Note', icon: 'ti-file-minus', section: 'Patient Ledger' },
  { href: '/payments/refund', label: 'Refund', icon: 'ti-rotate-clockwise', section: 'Patient Ledger' },
  { href: '/queue', label: 'Queue Management', icon: 'ti-list-numbers', section: 'Clinical' },
  { href: '/investigation', label: 'Investigation', icon: 'ti-flask', section: 'Clinical' },
  { href: '/pharmacy', label: 'Pharmacy', icon: 'ti-pill', section: 'Clinical' },
  { href: '/doctor-dashboard', label: 'Doctor Dashboard', icon: 'ti-stethoscope', section: 'Ophthalmologist' },
  { href: '/medical-fitness', label: 'Medical Fitness', icon: 'ti-heart-rate-monitor', section: 'Ophthalmologist' },
  { href: '/patient-timeline', label: 'Patient Timeline', icon: 'ti-timeline', section: 'Ophthalmologist' },
  { href: '/workflow-monitor', label: 'Workflow Monitor', icon: 'ti-activity', section: 'Ophthalmologist' },
  { href: '/optometry-dashboard', label: 'Optometry Queue', icon: 'ti-eye-check', section: 'Optometrist' },
  { href: '/optometry-history', label: 'Optometry History', icon: 'ti-history', section: 'Optometrist' },
  { href: '/optometry-reports', label: 'Optometry Reports', icon: 'ti-chart-bar', section: 'Optometrist' },
  { href: '/counselling', label: 'Counselling', icon: 'ti-scalpel', section: 'Surgical' },
  { href: '/biometry', label: 'Biometry', icon: 'ti-ruler-measure', section: 'Surgical' },
  { href: '/ot-intraop', label: 'Operation Theatre', icon: 'ti-building-hospital', section: 'Surgical' },
  { href: '/ot-recovery', label: 'Recovery', icon: 'ti-bed', section: 'Surgical' },
  { href: '/ot-postop', label: 'Post Op', icon: 'ti-calendar-plus', section: 'Surgical' },
  { href: '/master-data/clinical', label: 'Clinical Masters', icon: 'ti-stethoscope', section: 'Administration' },
  { href: '/master-data/financial', label: 'Financial Masters', icon: 'ti-currency-rupee', section: 'Administration' },
  { href: '/print-templates', label: 'Print Templates', icon: 'ti-file-invoice', section: 'Administration' },
  { href: '/users', label: 'User Management', icon: 'ti-users-group', section: 'Administration' },
];

const PAGE_TITLES = [
  { match: /^\/dashboard/, title: 'Dashboard' },
  { match: /^\/reports/, title: 'Reports' },
  { match: /^\/front-office-dashboard/, title: 'Front Office Dashboard' },
  { match: /^\/patients\/new/, title: 'Register New Patient' },
  { match: /^\/patients/, title: 'Patients' },
  { match: /^\/appointments\/new/, title: 'Book Appointment' },
  { match: /^\/appointments/, title: 'Appointments' },
  { match: /^\/visits\/new/, title: 'Create Walk-in Visit' },
  { match: /^\/visits/, title: 'Visits' },
  { match: /^\/queue/, title: 'Queue Management' },
  { match: /^\/doctor-dashboard/, title: 'Doctor Dashboard' },
  { match: /^\/medical-fitness/, title: 'Medical Fitness' },
  { match: /^\/patient-timeline/, title: 'Patient Timeline' },
  { match: /^\/workflow-monitor/, title: 'Workflow Monitor' },
  { match: /^\/optometry-dashboard/, title: 'Optometry Queue' },
  { match: /^\/optometry-history/, title: 'Optometry History' },
  { match: /^\/optometry-reports/, title: 'Optometry Reports' },
  { match: /^\/optometry/, title: 'Optometry Assessment' },
  { match: /^\/consultation/, title: 'Doctor Consultation' },
  { match: /^\/investigation/, title: 'Investigation' },
  { match: /^\/billing/, title: 'Billing' },
  { match: /^\/payments/, title: 'Payments' },
  { match: /^\/cash-management/, title: 'Cash Management' },
  { match: /^\/pharmacy/, title: 'Pharmacy' },
  { match: /^\/counselling/, title: 'Counselling' },
  { match: /^\/biometry/, title: 'Biometry & IOL Planning' },
  { match: /^\/ot-intraop/, title: 'Operation Theatre' },
  { match: /^\/ot-recovery/, title: 'Recovery' },
  { match: /^\/ot-postop/, title: 'Post Op' },
  { match: /^\/master-data\/clinical/, title: 'Clinical Masters' },
  { match: /^\/master-data\/financial/, title: 'Financial Masters' },
  { match: /^\/print-templates/, title: 'Print Templates' },
  { match: /^\/master-data/, title: 'Master Data' },
  { match: /^\/users/, title: 'User Management' },
];

export default function AppShell({ children }) {
  const pathname = usePathname();
  const router = useRouter();
  const supabase = createClient();
  const [profile, setProfile] = useState(null);
  const [today, setToday] = useState('');

  const pageTitle = PAGE_TITLES.find((t) => t.match.test(pathname))?.title || 'VEDA HMIS';

  useEffect(() => {
    setToday(new Date().toLocaleDateString('en-IN', { weekday: 'short', day: 'numeric', month: 'short', year: 'numeric' }));

    supabase.auth.getUser().then(async ({ data: { user } }) => {
      if (!user) return;
      const { data } = await supabase.from('profiles').select('*').eq('id', user.id).single();
      setProfile(data);
    });
  }, []);

  async function handleSignOut() {
    await supabase.auth.signOut();
    router.push('/login');
    router.refresh();
  }

  const sections = [...new Set(NAV_ITEMS.map((i) => i.section))];

  // Pick the single longest matching href across all items, so nested
  // routes (e.g. /payments and /payments/advance both being valid nav
  // targets) never highlight more than one item at once.
  const activeHref = NAV_ITEMS
    .map((i) => i.href)
    .filter((href) => pathname.startsWith(href))
    .sort((a, b) => b.length - a.length)[0];

  return (
    <div className="app-layout">
      <div className="sidebar">
        <div className="sb-logo">
          <div className="sb-logo-icon"><i className="ti ti-eye"></i></div>
          <div>
            <div className="sb-name">VEDA HMIS</div>
            <div className="sb-sub">Veda Eye Hospital</div>
          </div>
        </div>
        {sections.map((section) => (
          <div key={section}>
            <div className="sb-sec">{section}</div>
            {NAV_ITEMS.filter((i) => i.section === section).map((item) => (
              <Link
                key={item.href}
                href={item.href}
                className={`sb-item ${item.href === activeHref ? 'active' : ''}`}
              >
                <span className="sb-icon-wrap"><i className={`ti ${item.icon}`}></i></span>
                <span>{item.label}</span>
              </Link>
            ))}
          </div>
        ))}
      </div>

      <div className="main-area">
        <div className="topbar">
          <div>
            <div className="top-title">{pageTitle}</div>
            <div className="top-sub">Veda Eye Hospital</div>
          </div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 14 }}>
            <div style={{ textAlign: 'right' }}>
              <div style={{ fontSize: 11.5, color: 'var(--g500)', fontWeight: 500 }}>{today}</div>
              {profile && (
                <div style={{ fontSize: 11, color: 'var(--g400)' }}>
                  {profile.full_name} -- {profile.designation}
                </div>
              )}
            </div>
            {profile && (
              <div style={{
                width: 34, height: 34, borderRadius: '50%', flexShrink: 0,
                background: 'linear-gradient(135deg, var(--blue), var(--blue-dk))',
                color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center',
                fontFamily: 'var(--font-display-stack)', fontWeight: 700, fontSize: 13,
              }}>
                {profile.full_name?.charAt(0)?.toUpperCase() || '?'}
              </div>
            )}
            <div style={{ width: 1, height: 24, background: 'var(--g200)' }}></div>
            <button className="btn btn-sm" onClick={handleSignOut}>Sign out</button>
          </div>
        </div>
        <div className="content-area">{children}</div>
      </div>
    </div>
  );
}



JSEOF_99686504

echo "-- Installing deps & building --"
npm install --no-audit --no-fund
npm run build

echo "== Done. DB migrations (hospital_settings table) already applied live. =="
