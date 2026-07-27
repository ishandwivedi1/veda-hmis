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
// Templates use Handlebars {field} tokens. All formatting (currency,
// dates) happens in the *data-building* functions below, not in the
// template itself, so editors only ever see plain {tokens}, never
// format-string logic.

const DEFAULT_TEMPLATES = {
  invoice: '<div style="max-width: 800px; margin: 0 auto; padding: 24px; font-family: Arial, Helvetica, sans-serif; color: #1a1a1a; font-size: 13px;">\n\n  <!-- HEADER -->\n  <table style="width: 100%; border-collapse: collapse; margin-bottom: 6px;">\n    <tr>\n      <td style="width: 70px; vertical-align: top;">\n        <svg width="56" height="56" viewBox="0 0 100 100" xmlns="http://www.w3.org/2000/svg">\n          <path d="M10 50 Q50 15 90 50 Q50 85 10 50 Z" fill="none" stroke="#1e4e8c" stroke-width="6"/>\n          <circle cx="50" cy="50" r="16" fill="#1e4e8c"/>\n          <path d="M8 52 Q3 60 12 66 Q10 56 8 52 Z" fill="#a6791f"/>\n        </svg>\n      </td>\n      <td style="vertical-align: top;">\n        <div style="font-size: 26px; font-weight: 800; letter-spacing: .3px; text-decoration: underline;">{{hospital_name}}</div>\n        <div style="font-size: 12px; font-weight: 700; margin-top: 2px;">{{hospital_unit_line}}</div>\n        <div style="font-size: 11px; font-weight: 700;">REGN NO : {{hospital_regn_no}}</div>\n      </td>\n      <td style="text-align: right; vertical-align: top; font-size: 11px; line-height: 1.5;">\n        {{hospital_address_line1}}<br/>\n        {{hospital_address_line2}}<br/>\n        {{hospital_city_state_pin}}<br/>\n        <br/>\n        Tel: {{hospital_phone}}<br/>\n        <strong>{{hospital_email}}</strong>\n      </td>\n    </tr>\n  </table>\n\n  <div style="text-align: center; font-size: 16px; font-weight: 700; border-top: 1.5px solid #333; border-bottom: 1.5px solid #333; padding: 8px 0; margin: 10px 0 16px;">\n    OPD BILL/INVOICE\n  </div>\n\n  <!-- PATIENT / BILL INFO -->\n  <table style="width: 100%; border: 1.5px solid #333; border-collapse: collapse; margin-bottom: 18px;">\n    <tr>\n      <td style="width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9; border-right: 1px solid #999;">\n        <table style="width: 100%; font-size: 12px;">\n          <tr><td style="width: 130px; color: #444;">PATIENT ID</td><td>: <strong>{{patient_id}}</strong></td></tr>\n          <tr><td style="color: #444;">PATIENT NAME</td><td>: <strong>{{patient_name}}</strong></td></tr>\n          <tr><td style="color: #444;">MOBILE NUMBER</td><td>: <strong>{{patient_mobile}}</strong></td></tr>\n          <tr><td style="color: #444;">AGE/GENDER</td><td>: <strong>{{patient_age}} / {{patient_gender}}</strong></td></tr>\n          <tr><td style="color: #444;">PROCEDURE</td><td>: <strong>{{procedure}}</strong></td></tr>\n        </table>\n      </td>\n      <td style="width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9;">\n        <table style="width: 100%; font-size: 12px;">\n          <tr><td style="width: 140px; color: #444;">BILL NO</td><td>: <strong>{{bill_no}}</strong></td></tr>\n          <tr><td style="color: #444;">BILL DATE</td><td>: <strong>{{bill_date}}</strong></td></tr>\n          <tr><td style="color: #444;">VISIT DATE</td><td>: <strong>{{visit_date}}</strong></td></tr>\n          <tr><td colspan="2">&nbsp;</td></tr>\n          <tr><td style="color: #444;">DOCTOR NAME</td><td>: <strong>{{doctor_name}}</strong></td></tr>\n          <tr><td style="color: #444;">DOCTOR REGN NO</td><td>: <strong>{{doctor_regn_no}}</strong></td></tr>\n          <tr><td style="color: #444;">HOSPITAL REGN NO</td><td>: <strong>{{hospital_regn_no}}</strong></td></tr>\n        </table>\n      </td>\n    </tr>\n  </table>\n\n  <!-- ITEMS -->\n  <table style="width: 100%; border-collapse: collapse; margin-bottom: 4px; font-size: 12px;">\n    <thead>\n      <tr style="background: #e9edf2;">\n        <th style="border: 1px solid #999; padding: 8px; text-align: center; width: 50px;">S.NO</th>\n        <th style="border: 1px solid #999; padding: 8px; text-align: left;">Billing_Item</th>\n        <th style="border: 1px solid #999; padding: 8px; text-align: center; width: 70px;">QTY</th>\n        <th style="border: 1px solid #999; padding: 8px; text-align: right; width: 110px;">RATE</th>\n        <th style="border: 1px solid #999; padding: 8px; text-align: right; width: 120px;">AMOUNT</th>\n      </tr>\n    </thead>\n    <tbody>\n      {{#each items}}\n      <tr>\n        <td style="border: 1px solid #999; padding: 7px; text-align: center;">{{sno}}</td>\n        <td style="border: 1px solid #999; padding: 7px;">{{name}}</td>\n        <td style="border: 1px solid #999; padding: 7px; text-align: center;">{{qty}}</td>\n        <td style="border: 1px solid #999; padding: 7px; text-align: right;">{{rate}}</td>\n        <td style="border: 1px solid #999; padding: 7px; text-align: right;">{{amount}}</td>\n      </tr>\n      {{/each}}\n    </tbody>\n  </table>\n\n  <!-- TOTALS -->\n  <table style="width: 260px; margin: 14px 0 0 auto; border-collapse: collapse; font-size: 12px;">\n    <tr>\n      <td style="border: 1px solid #999; background: #e9edf2; padding: 6px 10px; font-weight: 700;">GROSS AMOUNT</td>\n      <td style="border: 1px solid #999; padding: 6px 10px; text-align: right;">{{gross_amount}}</td>\n    </tr>\n    <tr>\n      <td style="border: 1px solid #999; background: #e9edf2; padding: 6px 10px; font-weight: 700;">DISCOUNT</td>\n      <td style="border: 1px solid #999; padding: 6px 10px; text-align: right;">{{discount}}</td>\n    </tr>\n    <tr>\n      <td style="border: 1px solid #999; background: #e9edf2; padding: 6px 10px; font-weight: 700;">NET AMOUNT PAYABLE</td>\n      <td style="border: 1px solid #999; padding: 6px 10px; text-align: right; font-weight: 700;">{{net_amount}}</td>\n    </tr>\n  </table>\n\n  <!-- SIGNATURE + PAYMENT DETAILS -->\n  <table style="width: 100%; margin-top: 50px; border-collapse: collapse;">\n    <tr>\n      <td style="width: 45%; vertical-align: bottom; font-size: 12px;">\n        <div>AUTHORISED SIGNATURE</div>\n        <div>FOR {{hospital_name}}</div>\n      </td>\n      <td style="width: 55%; vertical-align: top;">\n        <div style="font-size: 12px; margin-bottom: 6px;">Payment Details</div>\n        <table style="width: 100%; border-collapse: collapse; font-size: 11.5px;">\n          <tr style="background: #e9edf2;">\n            <th style="border: 1px solid #999; padding: 6px;">Payment Date</th>\n            <th style="border: 1px solid #999; padding: 6px;">Ref Number</th>\n            <th style="border: 1px solid #999; padding: 6px;">Payment</th>\n          </tr>\n          {{#each payments}}\n          <tr>\n            <td style="border: 1px solid #999; padding: 6px; text-align: center;">{{date}}</td>\n            <td style="border: 1px solid #999; padding: 6px; text-align: center;">{{ref_number}}</td>\n            <td style="border: 1px solid #999; padding: 6px; text-align: right;">{{amount}}</td>\n          </tr>\n          {{/each}}\n          <tr>\n            <td colspan="2" style="border: 1px solid #999; padding: 6px; background: #e9edf2; font-weight: 700;">Payments Received</td>\n            <td style="border: 1px solid #999; padding: 6px; text-align: right; font-weight: 700;">{{total_paid}}</td>\n          </tr>\n        </table>\n      </td>\n    </tr>\n  </table>\n\n  <!-- TERMS -->\n  <div style="margin-top: 30px; font-size: 11.5px;">\n    <div style="font-weight: 700; margin-bottom: 4px;">Terms &amp; Conditions</div>\n    <div>{{terms_text}}</div>\n    <div style="margin-top: 4px;">For any Queries please contact us at {{hospital_phone}} or Email us at {{hospital_email}}</div>\n  </div>\n\n</div>\n',
};

const PRINT_TEMPLATE_CATALOG = [
  { key: 'invoice', name: 'OPD Bill / Invoice', description: 'Printed for every invoice (Billing module -> Print).' },
  { key: 'receipt', name: 'Payment Receipt', description: 'Coming soon.', comingSoon: true },
  { key: 'investigation_report', name: 'Investigation Report', description: 'Coming soon.', comingSoon: true },
  { key: 'opd_summary', name: 'OPD Patient Summary', description: 'Coming soon.', comingSoon: true },
  { key: 'consent_form', name: 'Consent Form', description: 'Coming soon.', comingSoon: true },
  { key: 'discharge_summary', name: 'Discharge Summary', description: 'Coming soon.', comingSoon: true },
];

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

// ── Sample data for the admin preview pane -- deliberately fake/generic
//    so editors can see the layout without needing a real invoice. ──
export async function getSampleData(key) {
  if (key === 'invoice') return buildInvoiceContext(SAMPLE_INVOICE_RAW);
  return {};
}

const SAMPLE_INVOICE_RAW = {
  patient: { patient_code: 'VEH-P-00031', first_name: 'Dharam', last_name: '', mobile: '+919758041970', age: 39, gender: 'Male' },
  invoice: { invoice_number: 'VEH-BILL-0143', created_at: '2026-06-04T00:00:00Z', gross: 300, gst: 0, net: 300, paid: 300, purpose: 'OPD Services' },
  visit: { created_at: '2026-06-01T00:00:00Z' },
  doctor: { full_name: 'Dr. Nisha Bachkheti', registration_no: 'UKMC-3436' },
  lineItems: [{ service_name: 'OPD Consultation', qty: 1, rate: 300, disc: 0, net: 300 }],
  payments: [{ created_at: '2026-06-03T00:00:00Z', receipt_number: 'VEH/RECEIPT/-0054', amount: 300 }],
};

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

// ── Renders the actual invoice HTML for a given invoiceId ──
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

  const context = buildInvoiceContext({
    patient: {
      patient_code: invoice.patients?.uhid, first_name: invoice.patients?.first_name, last_name: invoice.patients?.last_name,
      mobile: invoice.patients?.mobile, age: invoice.patients?.age, gender: invoice.patients?.gender,
    },
    invoice,
    visit: invoice.visits,
    doctor: invoice.visits?.profiles,
    lineItems: lineItems || [],
    payments: payments || [],
  });

  const template = await getPrintTemplate('invoice');
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

function buildInvoiceContext({ patient, invoice, visit, doctor, lineItems, payments }) {
  const totalPaid = (payments || []).reduce((s, p) => s + Number(p.amount || 0), 0);
  const totalDisc = (lineItems || []).reduce((s, li) => s + Number(li.disc || 0), 0);
  return {
    hospital_name: 'VEDA EYE HOSPITAL',
    hospital_unit_line: 'A UNIT OF VEDA MEDITECH OPC PVT LTD',
    hospital_regn_no: 'UK/HDR/DRA/2026/1014',
    hospital_address_line1: 'Kankhal Road, Vishnu Garden Lane 1,',
    hospital_address_line2: 'Above Sharma Imaging, Singhdwar,',
    hospital_city_state_pin: 'Haridwar, Uttarakhand-PIN:249404',
    hospital_phone: '01334-322523/+91-9084736880',
    hospital_email: 'admin@vedaeyehospital.com',
    terms_text: 'Invoice due & Payable on Receipt.',

    patient_id: patient.patient_code || '--',
    patient_name: `${patient.first_name || ''} ${patient.last_name || ''}`.trim(),
    patient_mobile: patient.mobile || '--',
    patient_age: patient.age ?? '--',
    patient_gender: patient.gender || '--',
    procedure: invoice.purpose || 'OPD Services',

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
