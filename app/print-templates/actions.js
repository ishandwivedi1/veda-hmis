'use server';

import { createClient } from '@/lib/supabase-server';
import Handlebars from 'handlebars';
import { matchInvestigationType, getFullFieldValues } from '@/app/(main)/investigation/investigation-types';
import { plainFrequency, groupPrescriptionsForPrint } from '@/lib/prescriptionFormatting';

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
  invoice_opd: "<div style=\"max-width: 800px; margin: 0 auto; padding: 24px; font-family: Arial, Helvetica, sans-serif; color: #1a1a1a; font-size: 13px;\">\n\n  <!-- HEADER -->\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 6px;\">\n    <tr>\n      <td style=\"width: 100px; vertical-align: top;\">\n        {{{logo_html}}}\n      </td>\n      <td style=\"vertical-align: top;\">\n        <div style=\"font-size: 26px; font-weight: 800; letter-spacing: .3px; text-decoration: underline;\">{{hospital_name}}</div>\n        <div style=\"font-size: 12px; font-weight: 700; margin-top: 2px;\">{{hospital_unit_line}}</div>\n        <div style=\"font-size: 11px; font-weight: 700;\">REGN NO : {{hospital_regn_no}}</div>\n      </td>\n      <td style=\"text-align: right; vertical-align: top; font-size: 11px; line-height: 1.5;\">\n        {{hospital_address_line1}}<br/>\n        {{hospital_address_line2}}<br/>\n        {{hospital_city_state_pin}}<br/>\n        <br/>\n        Tel: {{hospital_phone}}<br/>\n        <strong>{{hospital_email}}</strong>\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; font-size: 16px; font-weight: 700; border-top: 1.5px solid #333; border-bottom: 1.5px solid #333; padding: 8px 0; margin: 10px 0 16px;\">\n    OPD BILL/INVOICE\n  </div>\n\n  <!-- PATIENT / BILL INFO -->\n  <table style=\"width: 100%; border: 1.5px solid #333; border-collapse: collapse; margin-bottom: 18px;\">\n    <tr>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9; border-right: 1px solid #999;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 130px; color: #444;\">PATIENT ID</td><td>: <strong>{{patient_id}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">VISIT ID</td><td>: <strong>{{visit_number}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">PATIENT NAME</td><td>: <strong>{{patient_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">MOBILE NUMBER</td><td>: <strong>{{patient_mobile}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">AGE/GENDER</td><td>: <strong>{{patient_age}} / {{patient_gender}}</strong></td></tr>\n        </table>\n      </td>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 140px; color: #444;\">BILL NO</td><td>: <strong>{{bill_no}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">BILL DATE</td><td>: <strong>{{bill_date}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">VISIT DATE</td><td>: <strong>{{visit_date}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">HOSPITAL REGN NO</td><td>: <strong>{{hospital_regn_no}}</strong></td></tr>\n        </table>\n      </td>\n    </tr>\n  </table>\n\n  <!-- ITEMS -->\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 4px; font-size: 12px;\">\n    <thead>\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: center; width: 50px;\">S.NO</th>\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: left;\">Billing_Item</th>\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: center; width: 70px;\">QTY</th>\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: right; width: 110px;\">RATE</th>\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: right; width: 120px;\">AMOUNT</th>\n      </tr>\n    </thead>\n    <tbody>\n      {{#each items}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: center;\">{{sno}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px;\">{{name}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: center;\">{{qty}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: right;\">{{rate}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: right;\">{{amount}}</td>\n      </tr>\n      {{/each}}\n    </tbody>\n  </table>\n\n  <!-- TOTALS -->\n  <table style=\"width: 260px; margin: 14px 0 0 auto; border-collapse: collapse; font-size: 12px;\">\n    <tr>\n      <td style=\"border: 1px solid #999; background: #e9edf2; padding: 6px 10px; font-weight: 700;\">GROSS AMOUNT</td>\n      <td style=\"border: 1px solid #999; padding: 6px 10px; text-align: right;\">{{gross_amount}}</td>\n    </tr>\n    <tr>\n      <td style=\"border: 1px solid #999; background: #e9edf2; padding: 6px 10px; font-weight: 700;\">DISCOUNT</td>\n      <td style=\"border: 1px solid #999; padding: 6px 10px; text-align: right;\">{{discount}}</td>\n    </tr>\n    <tr>\n      <td style=\"border: 1px solid #999; background: #e9edf2; padding: 6px 10px; font-weight: 700;\">NET AMOUNT PAYABLE</td>\n      <td style=\"border: 1px solid #999; padding: 6px 10px; text-align: right; font-weight: 700;\">{{net_amount}}</td>\n    </tr>\n  </table>\n\n  <!-- SIGNATURE + PAYMENT DETAILS -->\n  <table style=\"width: 100%; margin-top: 50px; border-collapse: collapse;\">\n    <tr>\n      <td style=\"width: 45%; vertical-align: bottom; font-size: 12px;\">\n        <div>AUTHORISED SIGNATURE</div>\n        <div>FOR {{hospital_name}}</div>\n      </td>\n      <td style=\"width: 55%; vertical-align: top;\">\n        <div style=\"font-size: 12px; margin-bottom: 6px;\">Payment Details</div>\n        <table style=\"width: 100%; border-collapse: collapse; font-size: 11.5px;\">\n          <tr style=\"background: #e9edf2;\">\n            <th style=\"border: 1px solid #999; padding: 6px;\">Payment Date</th>\n            <th style=\"border: 1px solid #999; padding: 6px;\">Ref Number</th>\n            <th style=\"border: 1px solid #999; padding: 6px;\">Payment</th>\n          </tr>\n          {{#each payments}}\n          <tr>\n            <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{date}}</td>\n            <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{ref_number}}</td>\n            <td style=\"border: 1px solid #999; padding: 6px; text-align: right;\">{{amount}}</td>\n          </tr>\n          {{/each}}\n          <tr>\n            <td colspan=\"2\" style=\"border: 1px solid #999; padding: 6px; background: #e9edf2; font-weight: 700;\">Payments Received</td>\n            <td style=\"border: 1px solid #999; padding: 6px; text-align: right; font-weight: 700;\">{{total_paid}}</td>\n          </tr>\n        </table>\n      </td>\n    </tr>\n  </table>\n\n  <!-- TERMS -->\n  <div style=\"margin-top: 30px; font-size: 11.5px;\">\n    <div style=\"font-weight: 700; margin-bottom: 4px;\">Terms &amp; Conditions</div>\n    <div>{{terms_text}}</div>\n    <div style=\"margin-top: 4px;\">For any Queries please contact us at {{hospital_phone}} or Email us at {{hospital_email}}</div>\n  </div>\n\n</div>\n",
  invoice_surgery: "<div style=\"max-width: 800px; margin: 0 auto; padding: 24px; font-family: Arial, Helvetica, sans-serif; color: #1a1a1a; font-size: 13px;\">\n\n  <!-- HEADER -->\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 6px;\">\n    <tr>\n      <td style=\"width: 100px; vertical-align: top;\">\n        {{{logo_html}}}\n      </td>\n      <td style=\"vertical-align: top;\">\n        <div style=\"font-size: 26px; font-weight: 800; letter-spacing: .3px; text-decoration: underline;\">{{hospital_name}}</div>\n        <div style=\"font-size: 12px; font-weight: 700; margin-top: 2px;\">{{hospital_unit_line}}</div>\n        <div style=\"font-size: 11px; font-weight: 700;\">REGN NO : {{hospital_regn_no}}</div>\n      </td>\n      <td style=\"text-align: right; vertical-align: top; font-size: 11px; line-height: 1.5;\">\n        {{hospital_address_line1}}<br/>\n        {{hospital_address_line2}}<br/>\n        {{hospital_city_state_pin}}<br/>\n        <br/>\n        Tel: {{hospital_phone}}<br/>\n        <strong>{{hospital_email}}</strong>\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; font-size: 16px; font-weight: 700; border-top: 1.5px solid #333; border-bottom: 1.5px solid #333; padding: 8px 0; margin: 10px 0 16px;\">\n    SURGERY BILL\n  </div>\n\n  <!-- PATIENT / BILL INFO -->\n  <table style=\"width: 100%; border: 1.5px solid #333; border-collapse: collapse; margin-bottom: 18px;\">\n    <tr>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9; border-right: 1px solid #999;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 130px; color: #444;\">PATIENT ID</td><td>: <strong>{{patient_id}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">VISIT ID</td><td>: <strong>{{visit_number}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">PATIENT NAME</td><td>: <strong>{{patient_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">MOBILE NUMBER</td><td>: <strong>{{patient_mobile}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">AGE/GENDER</td><td>: <strong>{{patient_age}} / {{patient_gender}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">SURGERY</td><td>: <strong>{{surgery_name}} ({{surgery_code}})</strong></td></tr>\n          <tr><td style=\"color: #444;\">OPERATED EYE</td><td>: <strong>{{eye}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">PACKAGE</td><td>: <strong>{{package_name}} ({{package_code}})</strong></td></tr>\n        </table>\n      </td>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 140px; color: #444;\">BILL NO</td><td>: <strong>{{bill_no}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">BILL DATE</td><td>: <strong>{{bill_date}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">VISIT DATE</td><td>: <strong>{{visit_date}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">DISCHARGE DATE</td><td>: <strong>{{discharge_date}}</strong></td></tr>\n          <tr><td colspan=\"2\">&nbsp;</td></tr>\n          <tr><td style=\"color: #444;\">DOCTOR NAME</td><td>: <strong>{{doctor_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">DOCTOR REGN NO</td><td>: <strong>{{doctor_regn_no}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">HOSPITAL REGN NO</td><td>: <strong>{{hospital_regn_no}}</strong></td></tr>\n        </table>\n      </td>\n    </tr>\n  </table>\n\n  <!-- ITEMS -->\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 4px; font-size: 12px;\">\n    <thead>\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: center; width: 50px;\">S.NO</th>\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: left;\">Billing_Item</th>\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: center; width: 70px;\">QTY</th>\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: right; width: 110px;\">RATE</th>\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: right; width: 120px;\">AMOUNT</th>\n      </tr>\n    </thead>\n    <tbody>\n      {{#each items}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: center;\">{{sno}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px;\">{{name}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: center;\">{{qty}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: right;\">{{rate}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: right;\">{{amount}}</td>\n      </tr>\n      {{/each}}\n    </tbody>\n  </table>\n\n  {{#if has_breakup}}\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 16px; font-size: 11.5px;\">\n    <thead>\n      <tr>\n        <th style=\"text-align: left; padding: 4px 8px; font-weight: 700; color: #555;\">Package Includes</th>\n        <th style=\"text-align: right; padding: 4px 8px; font-weight: 700; color: #555; width: 120px;\">Indicative Amount</th>\n      </tr>\n    </thead>\n    <tbody>\n      {{#each package_breakup}}\n      <tr>\n        <td style=\"padding: 3px 8px; color: #444;\">{{description}}</td>\n        <td style=\"padding: 3px 8px; text-align: right; color: #444;\">{{amount}}</td>\n      </tr>\n      {{/each}}\n    </tbody>\n  </table>\n  {{/if}}\n\n  <!-- TOTALS -->\n  <table style=\"width: 260px; margin: 14px 0 0 auto; border-collapse: collapse; font-size: 12px;\">\n    <tr>\n      <td style=\"border: 1px solid #999; background: #e9edf2; padding: 6px 10px; font-weight: 700;\">GROSS AMOUNT</td>\n      <td style=\"border: 1px solid #999; padding: 6px 10px; text-align: right;\">{{gross_amount}}</td>\n    </tr>\n    <tr>\n      <td style=\"border: 1px solid #999; background: #e9edf2; padding: 6px 10px; font-weight: 700;\">DISCOUNT</td>\n      <td style=\"border: 1px solid #999; padding: 6px 10px; text-align: right;\">{{discount}}</td>\n    </tr>\n    <tr>\n      <td style=\"border: 1px solid #999; background: #e9edf2; padding: 6px 10px; font-weight: 700;\">NET AMOUNT PAYABLE</td>\n      <td style=\"border: 1px solid #999; padding: 6px 10px; text-align: right; font-weight: 700;\">{{net_amount}}</td>\n    </tr>\n  </table>\n\n  <!-- SIGNATURE + PAYMENT DETAILS -->\n  <table style=\"width: 100%; margin-top: 50px; border-collapse: collapse;\">\n    <tr>\n      <td style=\"width: 45%; vertical-align: bottom; font-size: 12px;\">\n        <div>AUTHORISED SIGNATURE</div>\n        <div>FOR {{hospital_name}}</div>\n      </td>\n      <td style=\"width: 55%; vertical-align: top;\">\n        <div style=\"font-size: 12px; margin-bottom: 6px;\">Payment Details</div>\n        <table style=\"width: 100%; border-collapse: collapse; font-size: 11.5px;\">\n          <tr style=\"background: #e9edf2;\">\n            <th style=\"border: 1px solid #999; padding: 6px;\">Payment Date</th>\n            <th style=\"border: 1px solid #999; padding: 6px;\">Ref Number</th>\n            <th style=\"border: 1px solid #999; padding: 6px;\">Payment</th>\n          </tr>\n          {{#each payments}}\n          <tr>\n            <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{date}}</td>\n            <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{ref_number}}</td>\n            <td style=\"border: 1px solid #999; padding: 6px; text-align: right;\">{{amount}}</td>\n          </tr>\n          {{/each}}\n          <tr>\n            <td colspan=\"2\" style=\"border: 1px solid #999; padding: 6px; background: #e9edf2; font-weight: 700;\">Payments Received</td>\n            <td style=\"border: 1px solid #999; padding: 6px; text-align: right; font-weight: 700;\">{{total_paid}}</td>\n          </tr>\n        </table>\n      </td>\n    </tr>\n  </table>\n\n  <!-- TERMS -->\n  <div style=\"margin-top: 30px; font-size: 11.5px;\">\n    <div style=\"font-weight: 700; margin-bottom: 4px;\">Terms &amp; Conditions</div>\n    <div>{{terms_text}}</div>\n    <div style=\"margin-top: 4px;\">For any Queries please contact us at {{hospital_phone}} or Email us at {{hospital_email}}</div>\n  </div>\n\n</div>\n",
  receipt: "<div style=\"max-width: 650px; margin: 0 auto; padding: 24px; font-family: Arial, Helvetica, sans-serif; color: #1a1a1a; font-size: 13px;\">\n\n  <!-- HEADER -->\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 6px;\">\n    <tr>\n      <td style=\"width: 100px; vertical-align: top;\">{{{logo_html}}}</td>\n      <td style=\"vertical-align: top;\">\n        <div style=\"font-size: 22px; font-weight: 800; letter-spacing: .3px; text-decoration: underline;\">{{hospital_name}}</div>\n        <div style=\"font-size: 11px; font-weight: 700; margin-top: 2px;\">{{hospital_unit_line}}</div>\n        <div style=\"font-size: 10px; font-weight: 700;\">REGN NO : {{hospital_regn_no}}</div>\n      </td>\n      <td style=\"text-align: right; vertical-align: top; font-size: 10.5px; line-height: 1.5;\">\n        {{hospital_address_line1}}<br/>\n        {{hospital_address_line2}}<br/>\n        {{hospital_city_state_pin}}<br/>\n        Tel: {{hospital_phone}}\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; font-size: 16px; font-weight: 700; border-top: 1.5px solid #333; border-bottom: 1.5px solid #333; padding: 8px 0; margin: 10px 0 16px;\">\n    PAYMENT RECEIPT\n  </div>\n\n  <!-- RECEIVED FROM / RECEIPT INFO -->\n  <table style=\"width: 100%; border: 1.5px solid #333; border-collapse: collapse; margin-bottom: 16px;\">\n    <tr>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; border-right: 1px solid #999;\">\n        <div style=\"font-size: 10px; color: #666; text-transform: uppercase;\">Received From</div>\n        <div style=\"font-size: 14px; font-weight: 700;\">{{patient_name}}</div>\n        <div style=\"font-size: 11.5px; color: #444;\">{{patient_id}}</div>\n        <div style=\"font-size: 11.5px; color: #444;\">{{patient_mobile}}</div>\n      </td>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 90px; color: #444;\">Receipt No</td><td>: <strong>{{receipt_no}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">Date</td><td>: <strong>{{receipt_date}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">Type</td><td>: <strong>{{payment_type_label}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">Collected By</td><td>: <strong>{{collected_by}}</strong></td></tr>\n        </table>\n      </td>\n    </tr>\n  </table>\n\n  <!-- AMOUNT -->\n  <div style=\"background: #e3f5ec; border: 1.5px solid #157a4f; border-radius: 8px; padding: 14px; text-align: center; margin-bottom: 18px;\">\n    <div style=\"font-size: 10.5px; color: #157a4f; text-transform: uppercase; letter-spacing: .5px;\">Amount Received</div>\n    <div style=\"font-size: 26px; font-weight: 800; color: #157a4f;\">{{amount_received}}</div>\n    <div style=\"font-size: 11px; color: #157a4f; margin-top: 2px;\">{{amount_in_words}}</div>\n  </div>\n\n  {{#if hasAllocations}}\n  <div style=\"margin-bottom: 16px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; margin-bottom: 6px;\">Applied Against</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 12px;\">\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 6px; text-align: left;\">Invoice No</th>\n        <th style=\"border: 1px solid #999; padding: 6px; text-align: right;\">Amount Applied</th>\n      </tr>\n      {{#each allocations}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 6px;\">{{invoiceNumber}}</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: right;\">{{amount}}</td>\n      </tr>\n      {{/each}}\n    </table>\n  </div>\n  {{/if}}\n\n  <!-- PAYMENT MODES -->\n  <div style=\"margin-bottom: 16px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; margin-bottom: 6px;\">Payment Mode(s)</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 12px;\">\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 6px; text-align: left;\">Mode</th>\n        <th style=\"border: 1px solid #999; padding: 6px; text-align: right;\">Amount</th>\n      </tr>\n      {{#each modes}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 6px;\">{{mode}}</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: right;\">{{amount}}</td>\n      </tr>\n      {{/each}}\n    </table>\n  </div>\n\n  {{#if reference}}<div style=\"font-size: 11.5px; color: #444; margin-bottom: 4px;\">Reference: {{reference}}</div>{{/if}}\n  {{#if remarks}}<div style=\"font-size: 11.5px; color: #444; margin-bottom: 4px;\">Remarks: {{remarks}}</div>{{/if}}\n\n  <table style=\"width: 100%; margin-top: 50px;\">\n    <tr>\n      <td style=\"font-size: 12px;\">&nbsp;</td>\n      <td style=\"text-align: right; font-size: 12px;\">\n        <div>AUTHORISED SIGNATURE</div>\n        <div>FOR {{hospital_name}}</div>\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; margin-top: 24px; font-size: 10.5px; color: #999;\">\n    This is a computer-generated receipt.\n  </div>\n</div>\n",
  receipt_advance: "<div style=\"max-width: 650px; margin: 0 auto; padding: 24px; font-family: Arial, Helvetica, sans-serif; color: #1a1a1a; font-size: 13px;\">\n\n  <!-- HEADER -->\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 6px;\">\n    <tr>\n      <td style=\"width: 100px; vertical-align: top;\">{{{logo_html}}}</td>\n      <td style=\"vertical-align: top;\">\n        <div style=\"font-size: 22px; font-weight: 800; letter-spacing: .3px; text-decoration: underline;\">{{hospital_name}}</div>\n        <div style=\"font-size: 11px; font-weight: 700; margin-top: 2px;\">{{hospital_unit_line}}</div>\n        <div style=\"font-size: 10px; font-weight: 700;\">REGN NO : {{hospital_regn_no}}</div>\n      </td>\n      <td style=\"text-align: right; vertical-align: top; font-size: 10.5px; line-height: 1.5;\">\n        {{hospital_address_line1}}<br/>\n        {{hospital_address_line2}}<br/>\n        {{hospital_city_state_pin}}<br/>\n        Tel: {{hospital_phone}}\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; font-size: 16px; font-weight: 700; border-top: 1.5px solid #333; border-bottom: 1.5px solid #333; padding: 8px 0; margin: 10px 0 16px;\">\n    ADVANCE RECEIPT\n  </div>\n\n  <!-- RECEIVED FROM / RECEIPT INFO -->\n  <table style=\"width: 100%; border: 1.5px solid #333; border-collapse: collapse; margin-bottom: 16px;\">\n    <tr>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; border-right: 1px solid #999;\">\n        <div style=\"font-size: 10px; color: #666; text-transform: uppercase;\">Received From</div>\n        <div style=\"font-size: 14px; font-weight: 700;\">{{patient_name}}</div>\n        <div style=\"font-size: 11.5px; color: #444;\">{{patient_id}}</div>\n        <div style=\"font-size: 11.5px; color: #444;\">{{patient_mobile}}</div>\n      </td>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 90px; color: #444;\">Receipt No</td><td>: <strong>{{receipt_no}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">Date</td><td>: <strong>{{receipt_date}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">Type</td><td>: <strong>{{payment_type_label}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">Collected By</td><td>: <strong>{{collected_by}}</strong></td></tr>\n        </table>\n      </td>\n    </tr>\n  </table>\n\n  <!-- AMOUNT -->\n  <div style=\"background: #e3f5ec; border: 1.5px solid #157a4f; border-radius: 8px; padding: 14px; text-align: center; margin-bottom: 18px;\">\n    <div style=\"font-size: 10.5px; color: #157a4f; text-transform: uppercase; letter-spacing: .5px;\">Advance Amount Received</div>\n    <div style=\"font-size: 26px; font-weight: 800; color: #157a4f;\">{{amount_received}}</div>\n    <div style=\"font-size: 11px; color: #157a4f; margin-top: 2px;\">{{amount_in_words}}</div>\n  </div>\n\n  \n\n  <div style=\"background: #f6ecd7; border: 1px solid #a6791f; border-radius: 8px; padding: 10px 14px; font-size: 11.5px; color: #7d5a12; margin-bottom: 16px;\">\n    <i></i>This advance is held against {{patient_name}}\\'s account and will be adjusted against future invoices.\n  </div>\n\n  <!-- PAYMENT MODES -->\n  <div style=\"margin-bottom: 16px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; margin-bottom: 6px;\">Payment Mode(s)</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 12px;\">\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 6px; text-align: left;\">Mode</th>\n        <th style=\"border: 1px solid #999; padding: 6px; text-align: right;\">Amount</th>\n      </tr>\n      {{#each modes}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 6px;\">{{mode}}</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: right;\">{{amount}}</td>\n      </tr>\n      {{/each}}\n    </table>\n  </div>\n\n  {{#if reference}}<div style=\"font-size: 11.5px; color: #444; margin-bottom: 4px;\">Reference: {{reference}}</div>{{/if}}\n  {{#if remarks}}<div style=\"font-size: 11.5px; color: #444; margin-bottom: 4px;\">Remarks: {{remarks}}</div>{{/if}}\n\n  <table style=\"width: 100%; margin-top: 50px;\">\n    <tr>\n      <td style=\"font-size: 12px;\">&nbsp;</td>\n      <td style=\"text-align: right; font-size: 12px;\">\n        <div>AUTHORISED SIGNATURE</div>\n        <div>FOR {{hospital_name}}</div>\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; margin-top: 24px; font-size: 10.5px; color: #999;\">\n    This is a computer-generated receipt.\n  </div>\n</div>\n",
  opd_case_sheet: "<style>\n  @media print {\n    @page { size: A4; margin: {{#if hide_header}}{{header_space_cm}}cm{{else}}8mm{{/if}} 10mm 8mm 10mm; }\n  }\n</style>\n<div style=\"max-width: 800px; margin: 0 auto; padding: 10px 16px; font-family: Arial, Helvetica, sans-serif; color: #000; font-size: 10.5px; line-height: 1.3;\">\n\n  {{#unless hide_header}}\n  <!-- HEADER -->\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 3px;\">\n    <tr>\n      <td style=\"width: 100px; vertical-align: top;\">{{{logo_html}}}</td>\n      <td style=\"vertical-align: top;\">\n        <div style=\"font-size: 16px; font-weight: 800; letter-spacing: .3px; text-decoration: underline;\">{{hospital_name}}</div>\n        <div style=\"font-size: 9px; font-weight: 700; margin-top: 2px;\">{{hospital_unit_line}}</div>\n        <div style=\"font-size: 8.5px; font-weight: 700;\">REGN NO : {{hospital_regn_no}}</div>\n      </td>\n      <td style=\"text-align: right; vertical-align: top; font-size: 9px; line-height: 1.5;\">\n        {{hospital_address_line1}}<br/>\n        {{hospital_address_line2}}<br/>\n        {{hospital_city_state_pin}}<br/>\n        Tel: {{hospital_phone}}\n      </td>\n    </tr>\n  </table>\n  {{/unless}}\n  {{#if hide_header}}<!-- Blank space for the pad's pre-printed header is reserved by the @page top margin above, so it repeats on every printed page, not just the first. -->{{/if}}\n\n  <div style=\"text-align: center; font-size: 13px; font-weight: 700; border-top: 1.5px solid #333; border-bottom: 1.5px solid #333; padding: 4px 0; margin: 5px 0 6px;\">\n    OPD CASE SHEET\n  </div>\n\n  <!-- PATIENT / VISIT INFO -->\n  <table style=\"width: 100%; border: 1.5px solid #333; border-collapse: collapse; margin-bottom: 8px;\">\n    <tr>\n      <td style=\"width: 50%; padding: 5px 10px; vertical-align: top; font-size: 10px; line-height: 1.35; border-right: 1px solid #999;\">\n        <table style=\"width: 100%; font-size: 10px;\">\n          <tr><td style=\"width: 110px; color: #222;\">PATIENT ID</td><td>: <strong>{{patient_id}}</strong></td></tr>\n          <tr><td style=\"color: #222;\">NAME</td><td>: <strong>{{patient_name}}</strong></td></tr>\n          <tr><td style=\"color: #222;\">AGE/GENDER</td><td>: <strong>{{patient_age}} / {{patient_gender}}</strong></td></tr>\n          <tr><td style=\"color: #222;\">MOBILE</td><td>: <strong>{{patient_mobile}}</strong></td></tr>\n        </table>\n      </td>\n      <td style=\"width: 50%; padding: 5px 10px; vertical-align: top; font-size: 10px; line-height: 1.35;\">\n        <table style=\"width: 100%; font-size: 10px;\">\n          <tr><td style=\"width: 100px; color: #222;\">VISIT DATE</td><td>: <strong>{{visit_date}}</strong></td></tr>\n          <tr><td style=\"color: #222;\">VISIT TYPE</td><td>: <strong>{{visit_type}}</strong></td></tr>\n          <tr><td style=\"color: #222;\">DOCTOR</td><td>: <strong>{{doctor_name}}</strong></td></tr>\n          <tr><td style=\"color: #222;\">DOCTOR REGN NO</td><td>: <strong>{{doctor_regn_no}}</strong></td></tr>\n        </table>\n      </td>\n    </tr>\n  </table>\n\n  <!-- CHIEF COMPLAINT -->\n  {{#if chief_complaint}}\n  <div style=\"margin-bottom: 6px;\">\n    <div style=\"font-size: 11px; font-weight: 800; text-transform: uppercase; letter-spacing: .4px; color: #1a3a5c; margin: 14px 0 6px; padding-bottom: 4px; border-bottom: 1.5px solid #c7d2e0;\">Chief Complaint</div>\n    <div style=\"font-size: 10.5px;\">{{chief_complaint}}{{#if hx_duration}} -- {{hx_duration}}{{/if}}{{#if hx_laterality}} ({{hx_laterality}}){{/if}}</div>\n    {{#if hx_hopi}}<div style=\"font-size: 10px; color: #222; margin-top: 3px;\">{{hx_hopi}}</div>{{/if}}\n  </div>\n  {{/if}}\n\n  <!-- STRUCTURED HISTORY -->\n  {{#if hasHistory}}\n  <div style=\"margin-bottom: 6px;\">\n    <div style=\"font-size: 11px; font-weight: 800; text-transform: uppercase; letter-spacing: .4px; color: #1a3a5c; margin: 14px 0 6px; padding-bottom: 4px; border-bottom: 1.5px solid #c7d2e0;\">History</div>\n    <table style=\"width: 100%; font-size: 10px; border-collapse: collapse;\">\n      {{#each historyLines}}\n      <tr>\n        <td style=\"padding: 2px 0; width: 130px; color: #222; vertical-align: top;\">{{label}}</td>\n        <td style=\"padding: 2px 0;\">{{text}}</td>\n      </tr>\n      {{/each}}\n    </table>\n  </div>\n  {{/if}}\n\n  <!-- VISION / IOP -->\n  {{#if hasVision}}\n  <div style=\"margin-bottom: 6px;\">\n    <div style=\"font-size: 11px; font-weight: 800; text-transform: uppercase; letter-spacing: .4px; color: #1a3a5c; margin: 14px 0 6px; padding-bottom: 4px; border-bottom: 1.5px solid #c7d2e0;\">Vision &amp; Intraocular Pressure</div>\n    <div style=\"display: flex; gap: 10px;\">\n      {{#if hasVaSection}}\n      <div style=\"{{#if hasIop}}flex: 1; min-width: 0;{{else}}width: 100%;{{/if}}\">\n        <table style=\"width: 100%; border-collapse: collapse; font-size: 10px;\">\n          <tr style=\"background: #e9edf2;\">\n            <th style=\"border: 1px solid #999; padding: 3px; text-align: left; width: 42%;\"></th>\n            <th style=\"border: 1px solid #999; padding: 3px; width: 29%;\">Right Eye (RE)</th>\n            <th style=\"border: 1px solid #999; padding: 3px; width: 29%;\">Left Eye (LE)</th>\n          </tr>\n          {{#if hasViUnaided}}\n          <tr>\n            <td style=\"border: 1px solid #999; padding: 3px; font-weight: 600;\">Unaided</td>\n            <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{re_vision_unaided}}</td>\n            <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{le_vision_unaided}}</td>\n          </tr>\n          {{/if}}\n          {{#if hasViGlasses}}\n          <tr>\n            <td style=\"border: 1px solid #999; padding: 3px; font-weight: 600;\">With Glasses</td>\n            <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{re_vision_glasses}}</td>\n            <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{le_vision_glasses}}</td>\n          </tr>\n          {{/if}}\n          {{#if hasViPh}}\n          <tr>\n            <td style=\"border: 1px solid #999; padding: 3px; font-weight: 600;\">Pinhole</td>\n            <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{re_vision_ph}}</td>\n            <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{le_vision_ph}}</td>\n          </tr>\n          {{/if}}\n          {{#if hasViNear}}\n          <tr>\n            <td style=\"border: 1px solid #999; padding: 3px; font-weight: 600;\">Near</td>\n            <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{re_vision_near}}</td>\n            <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{le_vision_near}}</td>\n          </tr>\n          {{/if}}\n        </table>\n      </div>\n      {{/if}}\n      {{#if hasIop}}\n      <div style=\"{{#if hasVaSection}}flex: 1; min-width: 0; border-left: 1px dashed #ccc; padding-left: 10px;{{else}}width: 100%;{{/if}}\">\n        <table style=\"width: 100%; border-collapse: collapse; font-size: 10px;\">\n          <tr style=\"background: #e9edf2;\">\n            <th style=\"border: 1px solid #999; padding: 3px; text-align: left; width: 42%;\"></th>\n            <th style=\"border: 1px solid #999; padding: 3px; width: 29%;\">Right (OD)</th>\n            <th style=\"border: 1px solid #999; padding: 3px; width: 29%;\">Left (OS)</th>\n          </tr>\n          <tr>\n            <td style=\"border: 1px solid #999; padding: 3px; font-weight: 600;\">IOP (mmHg){{#if iop_method}}<br/><span style=\"font-size: 8px; font-weight: 400; color: #333;\">({{iop_method}})</span>{{/if}}</td>\n            <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{re_iop}}</td>\n            <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{le_iop}}</td>\n          </tr>\n        </table>\n      </div>\n      {{/if}}\n    </div>\n  </div>\n  {{/if}}\n\n  {{#if hasDistRx}}\n  <div style=\"margin-bottom: 6px;\">\n    <div style=\"font-size: 11px; font-weight: 800; text-transform: uppercase; letter-spacing: .4px; color: #1a3a5c; margin: 14px 0 6px; padding-bottom: 4px; border-bottom: 1.5px solid #c7d2e0;\">Refraction (Final Rx)</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 9.5px;\">\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 3px; text-align: left; width: 90px;\" rowspan=\"2\"></th>\n        <th style=\"border: 1px solid #999; padding: 3px;\" colspan=\"5\">Right Eye (RE)</th>\n        <th style=\"border: 1px solid #999; padding: 3px; border-left: 2px solid #999;\" colspan=\"5\">Left Eye (LE)</th>\n      </tr>\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 3px; width: 8%;\">SPH</th>\n        <th style=\"border: 1px solid #999; padding: 3px; width: 8%;\">CYL</th>\n        <th style=\"border: 1px solid #999; padding: 3px; width: 8%;\">AXIS</th>\n        <th style=\"border: 1px solid #999; padding: 3px; width: 8%;\">PRISM</th>\n        <th style=\"border: 1px solid #999; padding: 3px; width: 8%;\">VISION</th>\n        <th style=\"border: 1px solid #999; padding: 3px; width: 8%; border-left: 2px solid #999;\">SPH</th>\n        <th style=\"border: 1px solid #999; padding: 3px; width: 8%;\">CYL</th>\n        <th style=\"border: 1px solid #999; padding: 3px; width: 8%;\">AXIS</th>\n        <th style=\"border: 1px solid #999; padding: 3px; width: 8%;\">PRISM</th>\n        <th style=\"border: 1px solid #999; padding: 3px; width: 8%;\">VISION</th>\n      </tr>\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 3px; font-weight: 700;\">Dist.</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center; font-weight: 600;\">{{dist_re_sph}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{dist_re_cyl}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{dist_re_axis}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{dist_re_prism}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{dist_re_va}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center; font-weight: 600; border-left: 2px solid #999;\">{{dist_le_sph}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{dist_le_cyl}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{dist_le_axis}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{dist_le_prism}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{dist_le_va}}</td>\n      </tr>\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 3px; font-weight: 700;\">NEAR ADD</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center; font-weight: 600;\" colspan=\"4\">{{near_add_re}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{#if hasNearRx}}{{near_re_va}}{{else}}--{{/if}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center; font-weight: 600; border-left: 2px solid #999;\" colspan=\"4\">{{near_add_le}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{#if hasNearRx}}{{near_le_va}}{{else}}--{{/if}}</td>\n      </tr>\n    </table>\n  </div>\n  {{else}}\n  {{#if hasNearRx}}\n  <div style=\"margin-bottom: 6px;\">\n    <div style=\"font-size: 11px; font-weight: 800; text-transform: uppercase; letter-spacing: .4px; color: #1a3a5c; margin: 14px 0 6px; padding-bottom: 4px; border-bottom: 1.5px solid #c7d2e0;\">Refraction (Final Rx)</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 9.5px;\">\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 3px; text-align: left; width: 90px;\" rowspan=\"2\"></th>\n        <th style=\"border: 1px solid #999; padding: 3px;\" colspan=\"5\">Right Eye (RE)</th>\n        <th style=\"border: 1px solid #999; padding: 3px; border-left: 2px solid #999;\" colspan=\"5\">Left Eye (LE)</th>\n      </tr>\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 3px; width: 8%;\">SPH</th>\n        <th style=\"border: 1px solid #999; padding: 3px; width: 8%;\">CYL</th>\n        <th style=\"border: 1px solid #999; padding: 3px; width: 8%;\">AXIS</th>\n        <th style=\"border: 1px solid #999; padding: 3px; width: 8%;\">PRISM</th>\n        <th style=\"border: 1px solid #999; padding: 3px; width: 8%;\">VISION</th>\n        <th style=\"border: 1px solid #999; padding: 3px; width: 8%; border-left: 2px solid #999;\">SPH</th>\n        <th style=\"border: 1px solid #999; padding: 3px; width: 8%;\">CYL</th>\n        <th style=\"border: 1px solid #999; padding: 3px; width: 8%;\">AXIS</th>\n        <th style=\"border: 1px solid #999; padding: 3px; width: 8%;\">PRISM</th>\n        <th style=\"border: 1px solid #999; padding: 3px; width: 8%;\">VISION</th>\n      </tr>\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 3px; font-weight: 700;\">NEAR ADD</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center; font-weight: 600;\" colspan=\"4\">{{near_add_re}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{near_re_va}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center; font-weight: 600; border-left: 2px solid #999;\" colspan=\"4\">{{near_add_le}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{near_le_va}}</td>\n      </tr>\n    </table>\n  </div>\n  {{/if}}\n  {{/if}}\n\n  {{#if hasGlassesSection}}\n  <table style=\"width: 100%; margin-bottom: 6px; font-size: 10px;\">\n    {{#if glasses_prescribed}}\n    <tr>\n      <td style=\"padding: 2px 0; color: #222; width: 130px;\">GLASSES PRESCRIBED</td>\n      <td style=\"padding: 2px 0; font-weight: 700;\">: YES</td>\n    </tr>\n    {{/if}}\n    {{#if hasGlassesType}}\n    <tr>\n      <td style=\"padding: 2px 0; color: #222; width: 130px;\">TYPE OF GLASS</td>\n      <td style=\"padding: 2px 0; font-weight: 700;\">: {{glasses_type}}</td>\n    </tr>\n    {{/if}}\n    {{#if hasGlassesRemarks}}\n    <tr>\n      <td style=\"padding: 2px 0; color: #222; width: 130px; vertical-align: top;\">REMARKS</td>\n      <td style=\"padding: 2px 0;\">: {{glasses_remarks}}</td>\n    </tr>\n    {{/if}}\n  </table>\n  {{/if}}\n\n  <!-- ADDITIONAL PRE-OP TESTS -->\n  {{#if hasAdditionalTests}}\n  <div style=\"margin-bottom: 6px;\">\n    <div style=\"font-size: 11px; font-weight: 800; text-transform: uppercase; letter-spacing: .4px; color: #1a3a5c; margin: 14px 0 6px; padding-bottom: 4px; border-bottom: 1.5px solid #c7d2e0;\">Additional Tests</div>\n    <table style=\"width: 100%; font-size: 10px; border-collapse: collapse;\">\n      {{#each additionalTests}}\n      <tr>\n        <td style=\"padding: 2px 0; width: 150px; color: #222;\">{{label}}</td>\n        <td style=\"padding: 2px 0;\">{{value}}</td>\n      </tr>\n      {{/each}}\n    </table>\n  </div>\n  {{/if}}\n\n  <!-- OPTOMETRY OBSERVATIONS -->\n  {{#if hasOptObservations}}\n  <div style=\"margin-bottom: 6px;\">\n    <div style=\"font-size: 11px; font-weight: 800; text-transform: uppercase; letter-spacing: .4px; color: #1a3a5c; margin: 14px 0 6px; padding-bottom: 4px; border-bottom: 1.5px solid #c7d2e0;\">Optometry Observations</div>\n    <div style=\"font-size: 10.5px;\">{{optObservations}}</div>\n  </div>\n  {{/if}}\n\n  <!-- EXAMINATION -->\n  {{#if hasExamination}}\n  <div style=\"margin-bottom: 6px;\">\n    <div style=\"font-size: 11px; font-weight: 800; text-transform: uppercase; letter-spacing: .4px; color: #1a3a5c; margin: 14px 0 6px; padding-bottom: 4px; border-bottom: 1.5px solid #c7d2e0;\">Examination Findings</div>\n\n    {{#each examPairs}}\n    <div style=\"display: flex; gap: 10px;\">\n      <div style=\"{{#if right}}flex: 1; min-width: 0;{{else}}width: 100%;{{/if}}\">\n        <div style=\"font-size: 9.5px; font-weight: 700; text-transform: uppercase; letter-spacing: .3px; color: #35507a; margin: 6px 0 4px; padding: 2px 0 2px 8px; border-left: 3px solid #7f9cc4;\">{{left.label}}</div>\n        <table style=\"width: 100%; border-collapse: collapse; font-size: 9.5px; margin-bottom: 5px;\">\n          <tr style=\"background: #e9edf2;\">\n            <th style=\"border: 1px solid #999; padding: 3px; text-align: left; width: 42%;\"></th>\n            <th style=\"border: 1px solid #999; padding: 3px; width: 29%;\">{{left.reHeader}}</th>\n            <th style=\"border: 1px solid #999; padding: 3px; width: 29%;\">{{left.leHeader}}</th>\n          </tr>\n          {{#each left.rows}}\n          <tr>\n            <td style=\"border: 1px solid #999; padding: 3px; font-weight: 600;\">{{structure}}</td>\n            <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{re}}</td>\n            <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{le}}</td>\n          </tr>\n          {{/each}}\n        </table>\n      </div>\n      {{#if right}}\n      <div style=\"flex: 1; min-width: 0; border-left: 1px dashed #ccc; padding-left: 10px;\">\n        <div style=\"font-size: 9.5px; font-weight: 700; text-transform: uppercase; letter-spacing: .3px; color: #35507a; margin: 6px 0 4px; padding: 2px 0 2px 8px; border-left: 3px solid #7f9cc4;\">{{right.label}}</div>\n        <table style=\"width: 100%; border-collapse: collapse; font-size: 9.5px; margin-bottom: 5px;\">\n          <tr style=\"background: #e9edf2;\">\n            <th style=\"border: 1px solid #999; padding: 3px; text-align: left; width: 42%;\"></th>\n            <th style=\"border: 1px solid #999; padding: 3px; width: 29%;\">{{right.reHeader}}</th>\n            <th style=\"border: 1px solid #999; padding: 3px; width: 29%;\">{{right.leHeader}}</th>\n          </tr>\n          {{#each right.rows}}\n          <tr>\n            <td style=\"border: 1px solid #999; padding: 3px; font-weight: 600;\">{{structure}}</td>\n            <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{re}}</td>\n            <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{le}}</td>\n          </tr>\n          {{/each}}\n        </table>\n      </div>\n      {{/if}}\n    </div>\n    {{/each}}\n\n    {{#unless hasExternal}}{{#unless hasAnterior}}{{#unless hasPosterior}}{{#unless hasApplanation}}{{#unless hasGonioscopy}}\n    <div style=\"font-size: 10px; color: #333; margin-bottom: 3px;\">No examination findings recorded.</div>\n    {{/unless}}{{/unless}}{{/unless}}{{/unless}}{{/unless}}\n\n    {{#if hasExamExtra}}\n    <div style=\"font-size: 11px; font-weight: 800; text-transform: uppercase; letter-spacing: .4px; color: #1a3a5c; margin: 14px 0 6px; padding-bottom: 4px; border-bottom: 1.5px solid #c7d2e0;\">Clinical Remarks</div>\n    <table style=\"width: 100%; font-size: 10px; border-collapse: collapse;\">\n      {{#each examExtra}}\n      <tr>\n        <td style=\"padding: 2px 0; width: 150px; color: #222;\">{{label}}</td>\n        <td style=\"padding: 2px 0;\">{{value}}</td>\n      </tr>\n      {{/each}}\n    </table>\n    {{/if}}\n  </div>\n  {{/if}}\n\n  <!-- DIAGNOSIS -->\n  {{#if hasDiagnoses}}\n  <div style=\"margin-bottom: 6px;\">\n    <div style=\"font-size: 11px; font-weight: 800; text-transform: uppercase; letter-spacing: .4px; color: #1a3a5c; margin: 14px 0 6px; padding-bottom: 4px; border-bottom: 1.5px solid #c7d2e0;\">Diagnosis</div>\n    <ul style=\"margin: 0; padding-left: 18px; font-size: 10.5px;\">\n      {{#each diagnoses}}\n      <li>{{name}} -- {{eye}}{{#if notes}} ({{notes}}){{/if}}</li>\n      {{/each}}\n    </ul>\n  </div>\n  {{/if}}\n\n  <!-- SURGERY ADVISED -->\n  {{#if hasSurgery}}\n  <div style=\"margin-bottom: 6px;\">\n    <div style=\"font-size: 11px; font-weight: 800; text-transform: uppercase; letter-spacing: .4px; color: #1a3a5c; margin: 14px 0 6px; padding-bottom: 4px; border-bottom: 1.5px solid #c7d2e0;\">Surgery Advised</div>\n    <div style=\"font-size: 10.5px;\">{{surgery_procedure_name}} -- {{surgery_eye}}</div>\n  </div>\n  {{/if}}\n\n  <!-- PRESCRIPTION -->\n  {{#if hasPrescriptions}}\n  <div style=\"margin-bottom: 6px;\">\n    <div style=\"font-size: 11px; font-weight: 800; text-transform: uppercase; letter-spacing: .4px; color: #1a3a5c; margin: 14px 0 6px; padding-bottom: 4px; border-bottom: 1.5px solid #c7d2e0;\">Prescription (Rx)</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 10px;\">\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 3px; text-align: left;\">Medicine</th>\n        <th style=\"border: 1px solid #999; padding: 3px;\">Eye</th>\n        <th style=\"border: 1px solid #999; padding: 3px;\">Dosage</th>\n        <th style=\"border: 1px solid #999; padding: 3px;\">Frequency</th>\n        <th style=\"border: 1px solid #999; padding: 3px;\">Duration</th>\n      </tr>\n      {{#each prescriptions}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 3px;\">{{drug}}{{#if isTaper}} <span style=\"font-size: 8.5px; font-weight: 700; color: #7c3aed; text-transform: uppercase;\">(Taper)</span>{{/if}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{eye}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{dosage}}</td>\n        {{#if isTaper}}\n        <td colspan=\"2\" style=\"border: 1px solid #999; padding: 3px; text-align: center; font-size: 9px;\">{{frequency}}</td>\n        {{else}}\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{frequency}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{duration}}</td>\n        {{/if}}\n      </tr>\n      {{/each}}\n    </table>\n  </div>\n  {{/if}}\n\n  <!-- ADVICE -->\n  {{#if advice}}\n  <div style=\"margin-bottom: 6px;\">\n    <div style=\"font-size: 11px; font-weight: 800; text-transform: uppercase; letter-spacing: .4px; color: #1a3a5c; margin: 14px 0 6px; padding-bottom: 4px; border-bottom: 1.5px solid #c7d2e0;\">Advice</div>\n    <div style=\"font-size: 10.5px; white-space: pre-wrap;\">{{advice}}</div>\n  </div>\n  {{/if}}\n\n  <!-- FOLLOW UP -->\n  {{#if followup_text}}\n  <div style=\"background: #e7eff8; border: 1px solid #1e4e8c; border-radius: 8px; padding: 5px 10px; font-size: 10.5px; color: #123a66; margin-bottom: 8px;\">\n    <strong>Follow-up:</strong> {{followup_text}}\n  </div>\n  {{/if}}\n\n  <table style=\"width: 100%; margin-top: 14px;\">\n    <tr>\n      <td style=\"font-size: 10px;\">&nbsp;</td>\n      <td style=\"text-align: right; font-size: 10px;\">\n        <div style=\"height: 40px;\">&nbsp;</div>\n        <div style=\"border-top: 1px solid #333; width: 200px; margin-left: auto; padding-top: 3px;\">{{doctor_name}}</div>\n        <div style=\"font-size: 9px; color: #333;\">Reg No: {{doctor_regn_no}}</div>\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; margin-top: 8px; font-size: 9px; color: #999;\">\n    For any Queries please contact us at {{hospital_phone}} or Email us at {{hospital_email}}\n  </div>\n</div>\n",
  glasses_prescription: `<div style="max-width: 650px; margin: 0 auto; padding: 24px; font-family: Arial, Helvetica, sans-serif; color: #1a1a1a; font-size: 13px;">

  {{#if hide_header}}
  <!-- Header hidden -- printing on pre-printed letterhead / prescription
       pad. Blank space left at the top matches the pad's own header
       height so the printed content starts below it. -->
  <div style="height: {{header_space_cm}}cm;"></div>
  {{else}}
  <!-- HEADER -->
  <table style="width: 100%; border-collapse: collapse; margin-bottom: 6px;">
    <tr>
      <td style="width: 100px; vertical-align: top;">{{{logo_html}}}</td>
      <td style="vertical-align: top;">
        <div style="font-size: 22px; font-weight: 800; letter-spacing: .3px; text-decoration: underline;">{{hospital_name}}</div>
        <div style="font-size: 11px; font-weight: 700; margin-top: 2px;">{{hospital_unit_line}}</div>
        <div style="font-size: 10px; font-weight: 700;">REGN NO : {{hospital_regn_no}}</div>
      </td>
      <td style="text-align: right; vertical-align: top; font-size: 10.5px; line-height: 1.5;">
        {{hospital_address_line1}}<br/>
        {{hospital_address_line2}}<br/>
        {{hospital_city_state_pin}}<br/>
        Tel: {{hospital_phone}}
      </td>
    </tr>
  </table>
  {{/if}}

  <div style="text-align: center; font-size: 16px; font-weight: 700; letter-spacing: .5px; border-top: 1.5px solid #1e4e8c; border-bottom: 1.5px solid #1e4e8c; padding: 8px 0; margin: 10px 0 16px; color: #1e4e8c;">
    SPECTACLE PRESCRIPTION
  </div>

  <!-- PATIENT / RX INFO -->
  <table style="width: 100%; border: 1.5px solid #333; border-collapse: collapse; margin-bottom: 18px;">
    <tr>
      <td style="width: 60%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9; border-right: 1px solid #999;">
        <table style="width: 100%; font-size: 12px;">
          <tr><td style="width: 100px; color: #444;">PATIENT ID</td><td>: <strong>{{patient_id}}</strong></td></tr>
          <tr><td style="color: #444;">NAME</td><td>: <strong>{{patient_name}}</strong></td></tr>
          <tr><td style="color: #444;">AGE/GENDER</td><td>: <strong>{{patient_age}} / {{patient_gender}}</strong></td></tr>
        </table>
      </td>
      <td style="width: 40%; padding: 10px 14px; vertical-align: top;">
        <table style="width: 100%; font-size: 12px;">
          <tr><td style="width: 60px; color: #444;">DATE</td><td>: <strong>{{rx_date}}</strong></td></tr>
          <tr><td style="color: #444;">VA SCALE</td><td>: <strong>{{va_scale}}</strong></td></tr>
        </table>
      </td>
    </tr>
  </table>

  {{#if hasDistRx}}
  <div style="margin-bottom: 16px;">
    <table style="width: 100%; border-collapse: collapse; font-size: 12px;">
      <tr style="background: #e9edf2;">
        <th style="border: 1px solid #999; padding: 8px; text-align: left; width: 80px;" rowspan="2"></th>
        <th style="border: 1px solid #999; padding: 6px;" colspan="5">RIGHT EYE</th>
        <th style="border: 1px solid #999; padding: 6px; border-left: 3px solid #1e4e8c;" colspan="5">LEFT EYE</th>
      </tr>
      <tr style="background: #e9edf2;">
        <th style="border: 1px solid #999; padding: 6px;">SPH</th>
        <th style="border: 1px solid #999; padding: 6px;">CYL</th>
        <th style="border: 1px solid #999; padding: 6px;">AXIS</th>
        <th style="border: 1px solid #999; padding: 6px;">PRISM</th>
        <th style="border: 1px solid #999; padding: 6px;">VISION</th>
        <th style="border: 1px solid #999; padding: 6px; border-left: 3px solid #1e4e8c;">SPH</th>
        <th style="border: 1px solid #999; padding: 6px;">CYL</th>
        <th style="border: 1px solid #999; padding: 6px;">AXIS</th>
        <th style="border: 1px solid #999; padding: 6px;">PRISM</th>
        <th style="border: 1px solid #999; padding: 6px;">VISION</th>
      </tr>
      <tr>
        <td style="border: 1px solid #999; padding: 8px; font-weight: 700;">DISTANCE</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center; font-weight: 600;">{{dist_re_sph}}</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center;">{{dist_re_cyl}}</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center;">{{dist_re_axis}}</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center;">{{dist_re_prism}}</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center;">{{dist_re_va}}</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center; font-weight: 600; border-left: 3px solid #1e4e8c;">{{dist_le_sph}}</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center;">{{dist_le_cyl}}</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center;">{{dist_le_axis}}</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center;">{{dist_le_prism}}</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center;">{{dist_le_va}}</td>
      </tr>
      <tr>
        <td style="border: 1px solid #999; padding: 8px; font-weight: 700;">NEAR ADD</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center; font-weight: 600;" colspan="4">{{add_re}}</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center;">{{#if hasNearRx}}{{near_re_va}}{{else}}--{{/if}}</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center; font-weight: 600; border-left: 3px solid #1e4e8c;" colspan="4">{{add_le}}</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center;">{{#if hasNearRx}}{{near_le_va}}{{else}}--{{/if}}</td>
      </tr>
    </table>
  </div>
  {{else}}
  {{#if hasNearRx}}
  <div style="margin-bottom: 16px;">
    <table style="width: 100%; border-collapse: collapse; font-size: 12px;">
      <tr style="background: #e9edf2;">
        <th style="border: 1px solid #999; padding: 8px; text-align: left; width: 80px;" rowspan="2"></th>
        <th style="border: 1px solid #999; padding: 6px;" colspan="5">RIGHT EYE</th>
        <th style="border: 1px solid #999; padding: 6px; border-left: 3px solid #1e4e8c;" colspan="5">LEFT EYE</th>
      </tr>
      <tr style="background: #e9edf2;">
        <th style="border: 1px solid #999; padding: 6px;">SPH</th>
        <th style="border: 1px solid #999; padding: 6px;">CYL</th>
        <th style="border: 1px solid #999; padding: 6px;">AXIS</th>
        <th style="border: 1px solid #999; padding: 6px;">PRISM</th>
        <th style="border: 1px solid #999; padding: 6px;">VISION</th>
        <th style="border: 1px solid #999; padding: 6px; border-left: 3px solid #1e4e8c;">SPH</th>
        <th style="border: 1px solid #999; padding: 6px;">CYL</th>
        <th style="border: 1px solid #999; padding: 6px;">AXIS</th>
        <th style="border: 1px solid #999; padding: 6px;">PRISM</th>
        <th style="border: 1px solid #999; padding: 6px;">VISION</th>
      </tr>
      <tr>
        <td style="border: 1px solid #999; padding: 8px; font-weight: 700;">NEAR</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center; font-weight: 600;">{{near_re_sph}}</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center;">{{near_re_cyl}}</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center;">{{near_re_axis}}</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center;">{{near_re_prism}}</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center;">{{near_re_va}}</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center; font-weight: 600; border-left: 3px solid #1e4e8c;">{{near_le_sph}}</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center;">{{near_le_cyl}}</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center;">{{near_le_axis}}</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center;">{{near_le_prism}}</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center;">{{near_le_va}}</td>
      </tr>
    </table>
  </div>
  {{/if}}
  {{/if}}

  {{#unless hasDistRx}}{{#unless hasNearRx}}
  <div style="padding: 20px; text-align: center; color: #9ca3af; font-size: 12px; border: 1px dashed #d1d5db; border-radius: 8px; margin-bottom: 16px;">
    No Final Rx recorded for this assessment.
  </div>
  {{/unless}}{{/unless}}

  {{#if glasses_prescribed}}
  <table style="width: 100%; margin-bottom: 16px; font-size: 12px;">
    <tr>
      <td style="padding: 4px 0; color: #444; width: 45%;">GLASSES PRESCRIBED</td>
      <td style="padding: 4px 0; font-weight: 700;">: YES</td>
    </tr>
    {{#if glasses_type}}
    <tr>
      <td style="padding: 4px 0; color: #444;">TYPE OF GLASS</td>
      <td style="padding: 4px 0; font-weight: 700;">: {{glasses_type}}</td>
    </tr>
    {{/if}}
    {{#if glasses_remarks}}
    <tr>
      <td style="padding: 4px 0; color: #444; vertical-align: top;">REMARKS</td>
      <td style="padding: 4px 0;">: {{glasses_remarks}}</td>
    </tr>
    {{/if}}
  </table>
  {{/if}}

  <table style="width: 100%; margin-bottom: 16px; font-size: 12px;">
    <tr>
      <td style="padding: 4px 0; color: #444; width: 45%;">IPD (Interpupillary Distance)</td>
      <td style="padding: 4px 0; font-weight: 700;">: {{ipd}}</td>
    </tr>
  </table>

  <div style="background: #eef2f7; border-left: 3px solid #1e4e8c; padding: 8px 12px; font-size: 11.5px; color: #444; margin-bottom: 30px;">
    This prescription is valid for 6 months from the date of issue. Please carry this slip to your optician.
  </div>

  <table style="width: 100%; margin-top: 40px; border-collapse: collapse;">
    <tr>
      <td style="width: 50%; font-size: 12px; vertical-align: bottom;">
        <div style="border-top: 1px solid #9ca3af; padding-top: 6px; width: 200px;">
          <div style="font-weight: 600;">{{optometrist_name}}</div>
          <div style="font-size: 10px; color: #9ca3af;">Optometrist</div>
        </div>
      </td>
      <td style="width: 50%; text-align: right; font-size: 12px; vertical-align: bottom;">
        <div style="border-top: 1px solid #9ca3af; padding-top: 6px; width: 200px; margin-left: auto;">
          <div style="font-weight: 600;">{{doctor_name}}</div>
          <div style="font-size: 10px; color: #9ca3af;">Reg No: {{doctor_regn_no}}</div>
        </div>
      </td>
    </tr>
  </table>

  <div style="text-align: center; margin-top: 24px; font-size: 10.5px; color: #999;">
    For any Queries please contact us at {{hospital_phone}} or Email us at {{hospital_email}}
  </div>
</div>
`,
  biometry_report: `<div style="max-width: 720px; margin: 0 auto; padding: 24px; font-family: Arial, Helvetica, sans-serif; color: #1a1a1a; font-size: 13px;">

  <!-- HEADER -->
  <table style="width: 100%; border-collapse: collapse; margin-bottom: 6px;">
    <tr>
      <td style="width: 100px; vertical-align: top;">{{{logo_html}}}</td>
      <td style="vertical-align: top;">
        <div style="font-size: 22px; font-weight: 800; letter-spacing: .3px; text-decoration: underline;">{{hospital_name}}</div>
        <div style="font-size: 11px; font-weight: 700; margin-top: 2px;">{{hospital_unit_line}}</div>
        <div style="font-size: 10px; font-weight: 700;">REGN NO : {{hospital_regn_no}}</div>
      </td>
      <td style="text-align: right; vertical-align: top; font-size: 10.5px; line-height: 1.5;">
        {{hospital_address_line1}}<br/>
        {{hospital_address_line2}}<br/>
        {{hospital_city_state_pin}}<br/>
        Tel: {{hospital_phone}}
      </td>
    </tr>
  </table>

  <div style="text-align: center; font-size: 16px; font-weight: 700; letter-spacing: .5px; border-top: 1.5px solid #1e4e8c; border-bottom: 1.5px solid #1e4e8c; padding: 8px 0; margin: 10px 0 16px; color: #1e4e8c;">
    IOL BIOMETRY REPORT
  </div>

  <!-- PATIENT / SURGICAL INFO -->
  <table style="width: 100%; border: 1.5px solid #333; border-collapse: collapse; margin-bottom: 18px;">
    <tr>
      <td style="width: 55%; padding: 10px 14px; vertical-align: top; font-size: 12px; border-right: 1px solid #999;">
        <table style="width: 100%; font-size: 12px;">
          <tr><td style="width: 100px; color: #444; padding: 2px 0;">PATIENT ID</td><td style="padding: 2px 0;">: <strong>{{patient_id}}</strong></td></tr>
          <tr><td style="color: #444; padding: 2px 0;">NAME</td><td style="padding: 2px 0;">: <strong>{{patient_name}}</strong></td></tr>
          <tr><td style="color: #444; padding: 2px 0;">AGE/GENDER</td><td style="padding: 2px 0;">: <strong>{{patient_age}} / {{patient_gender}}</strong></td></tr>
          <tr><td style="color: #444; padding: 2px 0;">VISIT NO</td><td style="padding: 2px 0;">: <strong>{{visit_number}}</strong></td></tr>
        </table>
      </td>
      <td style="width: 45%; padding: 10px 14px; vertical-align: top; font-size: 12px;">
        <table style="width: 100%; font-size: 12px;">
          <tr><td style="width: 90px; color: #444; padding: 2px 0;">DATE</td><td style="padding: 2px 0;">: <strong>{{report_date}}</strong></td></tr>
          <tr><td style="color: #444; padding: 2px 0;">PROCEDURE</td><td style="padding: 2px 0;">: <strong>{{procedure_name}}</strong></td></tr>
          <tr><td style="color: #444; padding: 2px 0;">EYE</td><td style="padding: 2px 0;">: <strong>{{surgical_eye}}</strong></td></tr>
        </table>
      </td>
    </tr>
  </table>

  <!-- BIOMETRY READINGS -->
  <div style="font-size: 13px; font-weight: 700; color: #1e4e8c; margin-bottom: 8px; text-transform: uppercase;">Biometry Readings</div>
  <table style="width: 100%; border-collapse: collapse; margin-bottom: 18px;">
    <tr>
      <td style="width: 50%; vertical-align: top; padding-right: 8px;">
        <div style="background: #e9edf2; padding: 6px 10px; font-size: 12px; font-weight: 700; border-radius: 6px 6px 0 0;">Right Eye (RE / OD) -- Oculus Dexter</div>
        <div style="border: 1px solid #999; border-top: none; border-radius: 0 0 6px 6px; padding: 8px 10px;">
          {{#if hasReReadings}}
          {{#each reSets}}
          <div style="margin-bottom: 8px; padding-bottom: 8px; {{#unless @last}}border-bottom: 1px dashed #ccc;{{/unless}}">
            <div style="font-size: 11px; font-weight: 700; color: #1e4e8c; margin-bottom: 4px;"><i>Device:</i> {{device}}</div>
            <table style="width: 100%; font-size: 11.5px;">
              <tr><td style="color: #555; padding: 1px 0;">Axial Length</td><td style="text-align: right; font-weight: 600;">{{axl}} mm</td></tr>
              <tr><td style="color: #555; padding: 1px 0;">K1</td><td style="text-align: right; font-weight: 600;">{{k1}} D</td></tr>
              <tr><td style="color: #555; padding: 1px 0;">K2</td><td style="text-align: right; font-weight: 600;">{{k2}} D</td></tr>
              <tr><td style="color: #555; padding: 1px 0;">ACD</td><td style="text-align: right; font-weight: 600;">{{acd}} mm</td></tr>
              <tr><td style="color: #555; padding: 1px 0;">White-to-White</td><td style="text-align: right; font-weight: 600;">{{wtw}} mm</td></tr>
            </table>
          </div>
          {{/each}}
          {{else}}
          <div style="font-size: 11.5px; color: #9ca3af;">No readings recorded.</div>
          {{/if}}
        </div>
      </td>
      <td style="width: 50%; vertical-align: top; padding-left: 8px;">
        <div style="background: #e9edf2; padding: 6px 10px; font-size: 12px; font-weight: 700; border-radius: 6px 6px 0 0;">Left Eye (LE / OS) -- Oculus Sinister</div>
        <div style="border: 1px solid #999; border-top: none; border-radius: 0 0 6px 6px; padding: 8px 10px;">
          {{#if hasLeReadings}}
          {{#each leSets}}
          <div style="margin-bottom: 8px; padding-bottom: 8px; {{#unless @last}}border-bottom: 1px dashed #ccc;{{/unless}}">
            <div style="font-size: 11px; font-weight: 700; color: #1e4e8c; margin-bottom: 4px;"><i>Device:</i> {{device}}</div>
            <table style="width: 100%; font-size: 11.5px;">
              <tr><td style="color: #555; padding: 1px 0;">Axial Length</td><td style="text-align: right; font-weight: 600;">{{axl}} mm</td></tr>
              <tr><td style="color: #555; padding: 1px 0;">K1</td><td style="text-align: right; font-weight: 600;">{{k1}} D</td></tr>
              <tr><td style="color: #555; padding: 1px 0;">K2</td><td style="text-align: right; font-weight: 600;">{{k2}} D</td></tr>
              <tr><td style="color: #555; padding: 1px 0;">ACD</td><td style="text-align: right; font-weight: 600;">{{acd}} mm</td></tr>
              <tr><td style="color: #555; padding: 1px 0;">White-to-White</td><td style="text-align: right; font-weight: 600;">{{wtw}} mm</td></tr>
            </table>
          </div>
          {{/each}}
          {{else}}
          <div style="font-size: 11.5px; color: #9ca3af;">No readings recorded.</div>
          {{/if}}
        </div>
      </td>
    </tr>
  </table>

  <!-- IOL RECOMMENDATIONS -->
  {{#if hasRecommendations}}
  <div style="font-size: 13px; font-weight: 700; color: #1e4e8c; margin-bottom: 8px; text-transform: uppercase;">IOL Recommendations (from device printout)</div>
  <table style="width: 100%; border-collapse: collapse; margin-bottom: 18px; font-size: 12px;">
    <tr style="background: #e9edf2;">
      <th style="border: 1px solid #999; padding: 7px; text-align: left;">Brand / Model</th>
      <th style="border: 1px solid #999; padding: 7px; text-align: center;">RE Power</th>
      <th style="border: 1px solid #999; padding: 7px; text-align: center;">LE Power</th>
    </tr>
    {{#each recommendations}}
    <tr>
      <td style="border: 1px solid #999; padding: 7px;">{{brandModel}}</td>
      <td style="border: 1px solid #999; padding: 7px; text-align: center;">{{rePower}}</td>
      <td style="border: 1px solid #999; padding: 7px; text-align: center;">{{lePower}}</td>
    </tr>
    {{/each}}
  </table>
  {{/if}}

  <!-- NOTES -->
  {{#if hasNotes}}
  <div style="font-size: 13px; font-weight: 700; color: #1e4e8c; margin-bottom: 8px; text-transform: uppercase;">Notes</div>
  <div style="border: 1px solid #999; border-radius: 6px; padding: 10px 14px; font-size: 12.5px; white-space: pre-wrap; margin-bottom: 18px;">{{notes}}</div>
  {{/if}}

  <table style="width: 100%; margin-top: 40px; border-collapse: collapse;">
    <tr>
      <td style="width: 100%; text-align: right; font-size: 12px; vertical-align: bottom;">
        <div style="border-top: 1px solid #9ca3af; padding-top: 6px; width: 220px; margin-left: auto;">
          <div style="font-weight: 600;">{{verified_by_name}}</div>
          <div style="font-size: 10px; color: #9ca3af;">Recorded / Verified By{{#if verified_by_regn_no}} -- Reg No: {{verified_by_regn_no}}{{/if}}</div>
        </div>
      </td>
    </tr>
  </table>

  <div style="text-align: center; margin-top: 24px; font-size: 10.5px; color: #999;">
    For any Queries please contact us at {{hospital_phone}} or Email us at {{hospital_email}}
  </div>
</div>
`,
  discharge_summary: "<div style=\"max-width: 780px; margin: 0 auto; padding: 24px; font-family: Arial, Helvetica, sans-serif; color: #1a1a1a; font-size: 13px;\">\n\n  <!-- HEADER -->\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 6px;\">\n    <tr>\n      <td style=\"width: 100px; vertical-align: top;\">{{{logo_html}}}</td>\n      <td style=\"vertical-align: top;\">\n        <div style=\"font-size: 24px; font-weight: 800; letter-spacing: .3px; text-decoration: underline; color: #0f766e;\">{{hospital_name}}</div>\n        <div style=\"font-size: 11px; font-weight: 700; margin-top: 2px;\">{{hospital_unit_line}}</div>\n        <div style=\"font-size: 10px; font-weight: 700;\">REGN NO : {{hospital_regn_no}}</div>\n      </td>\n      <td style=\"text-align: right; vertical-align: top; font-size: 10.5px; line-height: 1.5;\">\n        {{hospital_address_line1}}<br/>\n        {{hospital_address_line2}}<br/>\n        {{hospital_city_state_pin}}<br/>\n        Tel: {{hospital_phone}}\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; font-size: 16px; font-weight: 700; border-top: 1.5px solid #0f766e; border-bottom: 1.5px solid #0f766e; padding: 8px 0; margin: 10px 0 16px; color: #0f766e;\">\n    DISCHARGE SUMMARY\n  </div>\n\n  <!-- PATIENT / SURGEON INFO -->\n  <table style=\"width: 100%; border: 1.5px solid #333; border-collapse: collapse; margin-bottom: 16px;\">\n    <tr>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9; border-right: 1px solid #999;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 100px; color: #444;\">PATIENT ID</td><td>: <strong>{{patient_id}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">NAME</td><td>: <strong>{{patient_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">AGE/GENDER</td><td>: <strong>{{patient_age}} / {{patient_gender}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">MOBILE</td><td>: <strong>{{patient_mobile}}</strong></td></tr>\n        </table>\n      </td>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 100px; color: #444;\">SURGEON</td><td>: <strong>Dr. {{surgeon_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">DOCTOR REGN NO</td><td>: <strong>{{surgeon_regn_no}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">ADMISSION</td><td>: <strong>{{admission_date}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">SURGERY DATE</td><td>: <strong>{{surgery_date}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">DISCHARGE DATE</td><td>: <strong>{{discharge_date}}</strong></td></tr>\n        </table>\n      </td>\n    </tr>\n  </table>\n\n  <!-- PROCEDURE SUMMARY -->\n  <div style=\"margin-bottom: 14px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; text-transform: uppercase; color: #0f766e; border-bottom: 1px solid #e5e7eb; padding-bottom: 4px; margin-bottom: 8px;\">Procedure Summary</div>\n    <div style=\"font-size: 13px; padding: 2px 0;\">Procedure: <strong>{{procedure_name}}</strong> ({{eye}})</div>\n    {{#each iol_lines}}\n    <div style=\"font-size: 13px; padding: 2px 0;\">IOL ({{eye}}): <strong>{{text}}</strong></div>\n    {{/each}}\n  </div>\n\n  <!-- MEDICATIONS -->\n  <div style=\"margin-bottom: 14px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; text-transform: uppercase; color: #0f766e; border-bottom: 1px solid #e5e7eb; padding-bottom: 4px; margin-bottom: 8px;\">Medications</div>\n    {{#unless hasMedications}}<div style=\"font-size: 12px; color: #9ca3af;\">None prescribed.</div>{{/unless}}\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 12px;\">\n      <tbody>\n        {{#each medications}}\n        <tr>\n          <td style=\"padding: 4px 8px 4px 0; font-weight: 600;\">{{name}}</td>\n          <td style=\"padding: 4px 8px 4px 0; color: #4b5563; white-space: nowrap;\">{{eye}}</td>\n          <td style=\"padding: 4px 0; color: #4b5563;\">{{sig}}</td>\n        </tr>\n        {{/each}}\n      </tbody>\n    </table>\n  </div>\n\n  {{#if hasDischargeNotes}}\n  <div style=\"margin-bottom: 14px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; text-transform: uppercase; color: #0f766e; border-bottom: 1px solid #e5e7eb; padding-bottom: 4px; margin-bottom: 8px;\">Discharge Notes (Doctor)</div>\n    <div style=\"font-size: 13px; white-space: pre-wrap;\">{{discharge_notes}}</div>\n  </div>\n  {{/if}}\n\n  <div style=\"margin-bottom: 14px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; text-transform: uppercase; color: #0f766e; border-bottom: 1px solid #e5e7eb; padding-bottom: 4px; margin-bottom: 8px;\">Discharge Instructions</div>\n    <div style=\"font-size: 13px; white-space: pre-wrap;\">{{discharge_instructions}}</div>\n  </div>\n\n  <div style=\"margin-bottom: 14px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; text-transform: uppercase; color: #0f766e; border-bottom: 1px solid #e5e7eb; padding-bottom: 4px; margin-bottom: 8px;\">Follow-up Schedule</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 12px;\">\n      <thead>\n        <tr style=\"background: #f0fdfa;\">\n          <th style=\"text-align: left; padding: 5px 8px; color: #0f766e;\">Visit</th>\n          <th style=\"text-align: left; padding: 5px 8px; color: #0f766e;\">Date</th>\n          <th style=\"text-align: left; padding: 5px 8px; color: #0f766e;\">Status</th>\n        </tr>\n      </thead>\n      <tbody>\n        {{#each followups}}\n        <tr>\n          <td style=\"padding: 4px 8px;\">{{visit_label}}</td>\n          <td style=\"padding: 4px 8px; color: #4b5563;\">{{date}}</td>\n          <td style=\"padding: 4px 8px; color: #4b5563;\">{{status}}</td>\n        </tr>\n        {{/each}}\n      </tbody>\n    </table>\n  </div>\n\n  <div style=\"margin-top: 50px; display: flex; justify-content: flex-end;\">\n    <div style=\"text-align: center; border-top: 1px solid #9ca3af; padding-top: 6px; width: 220px;\">\n      <div style=\"font-size: 12px; font-weight: 600;\">Dr. {{surgeon_name}}</div>\n      <div style=\"font-size: 10.5px; color: #444;\">Regn No: {{surgeon_regn_no}}</div>\n      <div style=\"font-size: 10px; color: #9ca3af; margin-top: 2px;\">Signature</div>\n    </div>\n  </div>\n\n  <div style=\"margin-top: 30px; text-align: center; font-size: 11px; color: #9ca3af;\">\n    This is a computer-generated discharge summary -- {{hospital_name}}.\n  </div>\n</div>\n",
  investigation_report: "<div style=\"max-width: 780px; margin: 0 auto; padding: 24px; font-family: Arial, Helvetica, sans-serif; color: #1a1a1a; font-size: 13px;\">\n\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 6px;\">\n    <tr>\n      <td style=\"width: 100px; vertical-align: top;\">{{{logo_html}}}</td>\n      <td style=\"vertical-align: top;\">\n        <div style=\"font-size: 24px; font-weight: 800; letter-spacing: .3px; text-decoration: underline;\">{{hospital_name}}</div>\n        <div style=\"font-size: 11px; font-weight: 700; margin-top: 2px;\">{{hospital_unit_line}}</div>\n        <div style=\"font-size: 10px; font-weight: 700;\">REGN NO : {{hospital_regn_no}}</div>\n      </td>\n      <td style=\"text-align: right; vertical-align: top; font-size: 10.5px; line-height: 1.5;\">\n        {{hospital_address_line1}}<br/>\n        {{hospital_address_line2}}<br/>\n        {{hospital_city_state_pin}}<br/>\n        Tel: {{hospital_phone}}\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; font-size: 16px; font-weight: 700; border-top: 1.5px solid #333; border-bottom: 1.5px solid #333; padding: 8px 0; margin: 10px 0 16px;\">\n    INVESTIGATION REPORT\n  </div>\n\n  <table style=\"width: 100%; border: 1.5px solid #333; border-collapse: collapse; margin-bottom: 16px;\">\n    <tr>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9; border-right: 1px solid #999;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 100px; color: #444;\">PATIENT ID</td><td>: <strong>{{patient_id}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">NAME</td><td>: <strong>{{patient_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">AGE/GENDER</td><td>: <strong>{{patient_age}} / {{patient_gender}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">MOBILE</td><td>: <strong>{{patient_mobile}}</strong></td></tr>\n        </table>\n      </td>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 110px; color: #444;\">INVESTIGATION</td><td>: <strong>{{investigation_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">TYPE</td><td>: <strong>{{investigation_type}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">EYE</td><td>: <strong>{{eye}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">ORDERED BY</td><td>: <strong>Dr. {{doctor_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">ORDERED ON</td><td>: <strong>{{ordered_date}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">COMPLETED ON</td><td>: <strong>{{completed_date}}</strong></td></tr>\n        </table>\n      </td>\n    </tr>\n  </table>\n\n  {{#if isUnable}}\n  <div style=\"background: #fef2f2; border: 1px solid #b91c1c; border-radius: 8px; padding: 10px 14px; font-size: 12.5px; color: #b91c1c; margin-bottom: 16px;\">\n    <strong>Unable to perform:</strong> {{unable_reason}}\n  </div>\n  {{else}}\n\n  <div style=\"margin-bottom: 16px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; text-transform: uppercase; color: #444; border-bottom: 1px solid #e5e7eb; padding-bottom: 4px; margin-bottom: 8px;\">Findings</div>\n    {{#if hasFields}}\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 12.5px;\">\n      <tbody>\n        {{#each fields}}\n        <tr>\n          <td style=\"padding: 5px 8px 5px 0; width: 45%; color: #444; border-bottom: 1px solid #f3f4f6;\">{{label}}</td>\n          <td style=\"padding: 5px 0; font-weight: 600; border-bottom: 1px solid #f3f4f6;\">{{value}}</td>\n        </tr>\n        {{/each}}\n      </tbody>\n    </table>\n    {{else}}\n    <div style=\"font-size: 12px; color: #9ca3af;\">No measurements recorded.</div>\n    {{/if}}\n  </div>\n\n  {{#if hasNotes}}\n  <div style=\"margin-bottom: 16px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; text-transform: uppercase; color: #444; border-bottom: 1px solid #e5e7eb; padding-bottom: 4px; margin-bottom: 8px;\">Notes</div>\n    <div style=\"font-size: 13px; white-space: pre-wrap;\">{{result_notes}}</div>\n  </div>\n  {{/if}}\n  {{/if}}\n\n  <table style=\"width: 100%; margin-top: 50px; border-collapse: collapse;\">\n    <tr>\n      <td style=\"width: 50%; vertical-align: bottom; font-size: 12px;\">\n        <div style=\"border-top: 1px solid #9ca3af; padding-top: 6px; width: 200px;\">\n          <div style=\"font-weight: 600;\">{{technician_name}}</div>\n          <div style=\"font-size: 10px; color: #9ca3af;\">Performed by</div>\n        </div>\n      </td>\n      {{#if hasVerifiedBy}}\n      <td style=\"width: 50%; vertical-align: bottom; text-align: right; font-size: 12px;\">\n        <div style=\"border-top: 1px solid #9ca3af; padding-top: 6px; width: 200px; margin-left: auto;\">\n          <div style=\"font-weight: 600;\">{{verified_by_name}}</div>\n          <div style=\"font-size: 10px; color: #9ca3af;\">Verified by</div>\n        </div>\n      </td>\n      {{/if}}\n    </tr>\n  </table>\n\n  <div style=\"margin-top: 30px; text-align: center; font-size: 10.5px; color: #999;\">\n    This is a computer-generated report -- {{hospital_name}}.\n  </div>\n</div>\n",
  medicine_prescription: "<div style=\"max-width: 780px; margin: 0 auto; padding: 24px; font-family: Arial, Helvetica, sans-serif; color: #1a1a1a; font-size: 13px;\">\n\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 6px;\">\n    <tr>\n      <td style=\"width: 100px; vertical-align: top;\">{{{logo_html}}}</td>\n      <td style=\"vertical-align: top;\">\n        <div style=\"font-size: 24px; font-weight: 800; letter-spacing: .3px; text-decoration: underline;\">{{hospital_name}}</div>\n        <div style=\"font-size: 11px; font-weight: 700; margin-top: 2px;\">{{hospital_unit_line}}</div>\n        <div style=\"font-size: 10px; font-weight: 700;\">REGN NO : {{hospital_regn_no}}</div>\n      </td>\n      <td style=\"text-align: right; vertical-align: top; font-size: 10.5px; line-height: 1.5;\">\n        {{hospital_address_line1}}<br/>\n        {{hospital_address_line2}}<br/>\n        {{hospital_city_state_pin}}<br/>\n        Tel: {{hospital_phone}}\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; font-size: 16px; font-weight: 700; border-top: 1.5px solid #333; border-bottom: 1.5px solid #333; padding: 8px 0; margin: 10px 0 16px;\">\n    MEDICINE PRESCRIPTION\n  </div>\n\n  <table style=\"width: 100%; border: 1.5px solid #333; border-collapse: collapse; margin-bottom: 16px;\">\n    <tr>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9; border-right: 1px solid #999;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 110px; color: #444;\">PATIENT ID</td><td>: <strong>{{patient_id}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">NAME</td><td>: <strong>{{patient_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">AGE/GENDER</td><td>: <strong>{{patient_age}} / {{patient_gender}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">MOBILE</td><td>: <strong>{{patient_mobile}}</strong></td></tr>\n        </table>\n      </td>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 110px; color: #444;\">VISIT NO</td><td>: <strong>{{visit_number}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">DATE</td><td>: <strong>{{print_date}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">DOCTOR</td><td>: <strong>Dr. {{doctor_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">DOCTOR REGN NO</td><td>: <strong>{{doctor_regn_no}}</strong></td></tr>\n        </table>\n      </td>\n    </tr>\n  </table>\n\n  {{#if hasPrescriptions}}\n  <div style=\"margin-bottom: 14px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 6px;\">Medicines Prescribed</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 12.5px;\">\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 7px; text-align: left;\">Medicine</th>\n        <th style=\"border: 1px solid #999; padding: 7px;\">Eye</th>\n        <th style=\"border: 1px solid #999; padding: 7px;\">Dosage</th>\n        <th style=\"border: 1px solid #999; padding: 7px;\">How Often</th>\n        <th style=\"border: 1px solid #999; padding: 7px;\">Duration</th>\n      </tr>\n      {{#each prescriptions}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 7px; font-weight: 600;\">{{drug}}{{#if isTaper}} <span style=\"font-size: 9px; font-weight: 700; color: #7c3aed; text-transform: uppercase;\">(Taper)</span>{{/if}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: center;\">{{eye}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: center;\">{{dosage}}</td>\n        {{#if isTaper}}\n        <td colspan=\"2\" style=\"border: 1px solid #999; padding: 7px; text-align: center; font-size: 11.5px;\">{{frequency}}</td>\n        {{else}}\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: center;\">{{frequency}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: center;\">{{duration}}</td>\n        {{/if}}\n      </tr>\n      {{/each}}\n    </table>\n  </div>\n  {{else}}\n  <div style=\"font-size: 12.5px; color: #9ca3af; margin-bottom: 14px;\">No medicines prescribed for this visit.</div>\n  {{/if}}\n\n  <div style=\"background: #eef4fb; border: 1px solid #1e4e8c; border-radius: 8px; padding: 10px 14px; font-size: 12px; color: #123a66; margin-bottom: 20px;\">\n    Please take medicines exactly as instructed above. If you have any doubt about how to use a medicine, ask the pharmacist before you leave.\n  </div>\n\n  <table style=\"width: 100%; margin-top: 40px;\">\n    <tr>\n      <td style=\"font-size: 12px;\">&nbsp;</td>\n      <td style=\"text-align: right; font-size: 12px;\">\n        <div>Dr. {{doctor_name}}</div>\n        <div style=\"font-size: 10.5px; color: #666;\">Reg No: {{doctor_regn_no}}</div>\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; margin-top: 20px; font-size: 10.5px; color: #999;\">\n    For any Queries please contact us at {{hospital_phone}} or Email us at {{hospital_email}}\n  </div>\n</div>\n",
  medical_fitness_form: `<div style="max-width: 780px; margin: 0 auto; padding: 24px; font-family: Arial, Helvetica, sans-serif; color: #1a1a1a; font-size: 12.5px; line-height: 1.5;">

  <table style="width: 100%; border-collapse: collapse; margin-bottom: 6px;">
    <tr>
      <td style="width: 90px; vertical-align: top;">{{{logo_html}}}</td>
      <td style="vertical-align: top;">
        <div style="font-size: 20px; font-weight: 800; letter-spacing: .3px; text-decoration: underline;">{{hospital_name}}</div>
        <div style="font-size: 10px; font-weight: 700; margin-top: 2px;">{{hospital_unit_line}}</div>
        <div style="font-size: 9px; font-weight: 700;">REGN NO : {{hospital_regn_no}}</div>
      </td>
      <td style="text-align: right; vertical-align: top; font-size: 9.5px; line-height: 1.5;">
        {{hospital_address_line1}}<br/>
        {{hospital_address_line2}}<br/>
        {{hospital_city_state_pin}}<br/>
        Tel: {{hospital_phone}}
      </td>
    </tr>
  </table>

  <div style="text-align: center; border-top: 1.5px solid #333; border-bottom: 1.5px solid #333; padding: 8px 0; margin: 10px 0 14px;">
    <div style="font-size: 15px; font-weight: 700;">Medical Fitness Form for Eye Surgery</div>
    <div style="font-size: 13px; font-weight: 600; margin-top: 2px;">नेत्र सर्जरी हेतु चिकित्सकीय फिटनेस प्रमाणपत्र</div>
  </div>

  <table style="width: 100%; border: 1.5px solid #333; border-collapse: collapse; margin-bottom: 14px;">
    <tr>
      <td style="width: 50%; padding: 8px 12px; font-size: 12px; border-right: 1px solid #999;">PATIENT NAME/ रोगी का नाम: <strong>{{patient_name}}</strong></td>
      <td style="width: 50%; padding: 8px 12px; font-size: 12px;">AGE/आयु: <strong>{{patient_age}}</strong></td>
    </tr>
    <tr>
      <td style="padding: 8px 12px; font-size: 12px; border-right: 1px solid #999; border-top: 1px solid #999;">UHID/रजिस्ट्रेशन संख्या: <strong>{{patient_uhid}}</strong></td>
      <td style="padding: 8px 12px; font-size: 12px; border-top: 1px solid #999;">GENDER/ लिंग: <strong>{{patient_gender}}</strong></td>
    </tr>
    <tr>
      <td colspan="2" style="padding: 8px 12px; font-size: 12px; border-top: 1px solid #999;">TYPE OF SURGERY/ शल्य चिकित्सा का प्रकार: <strong>{{surgery_type}}</strong></td>
    </tr>
  </table>

  <div style="margin-bottom: 10px;">
    <div style="font-weight: 700; font-size: 12.5px; margin-bottom: 4px;">1. SYSTEMIC HISTORY / सामान्य चिकित्सा इतिहास</div>
    <table style="width: 100%; border-collapse: collapse; font-size: 12px;">
      <tr>
        <td style="width: 50%; padding: 2px 0;">{{box_diabetes}} Diabetes / मधुमेह</td>
        <td style="width: 50%; padding: 2px 0;">{{box_hypertension}} Hypertension / उच्च रक्तचाप</td>
      </tr>
      <tr>
        <td style="padding: 2px 0;">{{box_heart}} Heart Disease / हृदय रोग</td>
        <td style="padding: 2px 0;">{{box_thyroid}} Thyroid Disorder/ थायराइड विकार</td>
      </tr>
      <tr>
        <td style="padding: 2px 0;">{{box_asthma}} Asthma / दमा रोग</td>
        <td style="padding: 2px 0;">{{box_kidney}} Kidney Disease/ गुर्दे की बीमारी</td>
      </tr>
    </table>
    <div style="padding: 2px 0;">{{box_systemic_other}} Other: {{systemic_other_text}}</div>
  </div>

  <div style="margin-bottom: 10px;">
    <div style="font-weight: 700; font-size: 12.5px; margin-bottom: 4px;">2. PREVIOUS SURGERY /HOSPITALIZATION/ पूर्व सर्जरी / अस्पताल में भर्ती</div>
    <div style="min-height: 30px; border-bottom: 1px solid #999; font-size: 12px; white-space: pre-wrap;">{{previous_surgery}}</div>
  </div>

  <div style="margin-bottom: 10px;">
    <div style="font-weight: 700; font-size: 12.5px; margin-bottom: 4px;">3. CURRENT MEDICATIONS/ वर्तमान दवाइयां</div>
    <table style="width: 100%; border-collapse: collapse; font-size: 12px;">
      <tr>
        <td style="width: 60%; padding: 2px 0;">{{box_med_antidiabetic}} Anti-diabetic medicines / Insulin</td>
        <td style="width: 40%; padding: 2px 0;">{{box_med_bp}} Blood pressure medicines</td>
      </tr>
    </table>
    <div style="padding: 2px 0;">{{box_med_bloodthinners}} Blood thinners (Aspirin / Clopidogrel / Warfarin etc.)</div>
    <div style="padding: 2px 0;">{{box_med_other}} Other medicines: {{med_other_text}}</div>
  </div>

  <div style="margin-bottom: 10px;">
    <div style="font-weight: 700; font-size: 12.5px; margin-bottom: 4px;">4. DRUG ALLERGIES/ दवाओं से एलर्जी</div>
    <div style="padding: 2px 0;">{{box_allergy_none}} No Known Allergy</div>
    <div style="padding: 2px 0;">{{box_allergy_yes}} Yes / हां &rarr; {{allergy_details}}</div>
    {{#if allergy_notes}}<div style="padding: 2px 0; font-size: 11.5px; color: #444;">Notes: {{allergy_notes}}</div>{{/if}}
  </div>

  <div style="margin-bottom: 10px;">
    <div style="font-weight: 700; font-size: 12.5px; margin-bottom: 4px;">5. VITAL SIGNS/ महत्वपूर्ण शारीरिक संकेत</div>
    <table style="width: 100%; border-collapse: collapse; font-size: 12px;">
      <tr>
        <td style="width: 50%; padding: 2px 0;">Blood Pressure: <strong>{{vital_bp}}</strong> mmHg</td>
        <td style="width: 50%; padding: 2px 0;">Pulse: <strong>{{vital_pulse}}</strong> / min</td>
      </tr>
      <tr>
        <td style="padding: 2px 0;">SpO&#8322;: <strong>{{vital_spo2}}</strong> %</td>
        <td style="padding: 2px 0;">Blood Sugar (if diabetic): <strong>{{vital_blood_sugar}}</strong> mg/dl</td>
      </tr>
    </table>
    {{#if vital_notes}}<div style="padding: 2px 0; font-size: 11.5px; color: #444;">Notes: {{vital_notes}}</div>{{/if}}
  </div>

  <div style="margin-bottom: 12px;">
    <div style="font-weight: 700; font-size: 12.5px; margin-bottom: 4px;">6. INVESTIGATIONS/ जांच</div>
    <table style="width: 100%; border-collapse: collapse; font-size: 12px;">
      <tr>
        <td style="width: 50%; padding: 2px 0;">Hemoglobin (Hb): <strong>{{inv_hb}}</strong></td>
        <td style="width: 50%; padding: 2px 0;">Random Blood Sugar (RBS): <strong>{{inv_rbs}}</strong></td>
      </tr>
      <tr>
        <td style="padding: 2px 0;">Fasting Blood Sugar (FBS): <strong>{{inv_fbs}}</strong></td>
        <td style="padding: 2px 0;">PPBS: <strong>{{inv_ppbs}}</strong></td>
      </tr>
      <tr>
        <td style="padding: 2px 0;">HIV I &amp; II: {{box_hiv_nonreactive}} Non-Reactive &nbsp; {{box_hiv_reactive}} Reactive</td>
        <td style="padding: 2px 0;">HBsAg: {{box_hbsag_nonreactive}} Non-Reactive &nbsp; {{box_hbsag_reactive}} Reactive</td>
      </tr>
    </table>
    <div style="padding: 2px 0;">Other: {{inv_other}}</div>
  </div>

  <div style="border-top: 1px solid #999; padding-top: 10px;">
    <div style="font-weight: 700; font-size: 12.5px; margin-bottom: 6px;">7. PHYSICIAN CERTIFICATION/ चिकित्सक प्रमाणन</div>
    <div style="font-size: 11.5px; margin-bottom: 4px;">
      I have examined the patient and certify that the patient is medically <strong>{{fitness_word}}</strong> for cataract surgery under local / topical anesthesia.
    </div>
    <div style="font-size: 11.5px; margin-bottom: 10px;">
      मैंने रोगी का परीक्षण किया है और प्रमाणित करता / करती हूं कि रोगी लोकल / टॉपिकल एनेस्थीसिया में मोतीयाबिंद सर्जरी के लिए चिकित्सकीय रूप से <strong>{{fitness_word_hi}}</strong> है।
    </div>
    {{#if fitness_notes}}
    <div style="font-size: 11.5px; margin-bottom: 10px; color: #b91c1c;"><strong>Remarks:</strong> {{fitness_notes}}</div>
    {{/if}}

    <table style="width: 100%; border-collapse: collapse; font-size: 12px; margin-top: 10px;">
      <tr>
        <td style="width: 50%; padding: 4px 0;">Doctor Name / चिकित्सक का नाम: <strong>{{doctor_name}}</strong></td>
        <td style="width: 50%; padding: 4px 0;">Qualification / योग्यता: <strong>{{doctor_qualification}}</strong></td>
      </tr>
      <tr>
        <td style="padding: 4px 0;">Registration Number / पंजीकरण संख्या: <strong>{{doctor_regn_no}}</strong></td>
        <td style="padding: 4px 0;">Date / दिनांक: <strong>{{cert_date}}</strong></td>
      </tr>
    </table>

    <div style="margin-top: 30px;">
      Signature / हस्ताक्षर: ______________________
    </div>
  </div>

</div>
`
};

const PRINT_TEMPLATE_CATALOG = [
  { key: 'invoice_opd', name: 'OPD Bill / Invoice', description: 'Printed for OPD invoices (Billing module -> Print).' },
  { key: 'invoice_surgery', name: 'Surgery Bill / Invoice', description: 'Printed for invoices containing a surgical package.' },
  { key: 'receipt', name: 'Payment Receipt', description: 'Printed for a payment collected against one or more invoices.' },
  { key: 'receipt_advance', name: 'Advance Receipt', description: 'Printed when an advance is collected, before it is applied to any invoice.' },
  { key: 'opd_case_sheet', name: 'OPD Case Sheet', description: 'Handed to the patient after an OPD consultation -- complaint, findings, diagnosis, prescription, advice, follow-up.' },
  { key: 'glasses_prescription', name: 'Glasses Prescription', description: 'Printed from the Optometry screen -- Final Rx spectacle prescription for the patient / optician.' },
  { key: 'biometry_report', name: 'Biometry Report', description: 'Printed from Surgeon Approval (Biometry) -- raw biometry readings, IOL power calculation, and the final approved plan.' },
  { key: 'investigation_report', name: 'Investigation Report', description: 'Printed for a completed investigation -- findings, notes, technician/verifier sign-off.' },
  { key: 'medicine_prescription', name: 'Medicine Prescription', description: 'Printed from Pharmacy -- the medicine list on its own, independent of the bill, for the patient to keep or take elsewhere.' },
  { key: 'consent_form', name: 'Consent Form', description: 'Coming soon.', comingSoon: true },
  { key: 'discharge_summary', name: 'Discharge Summary', description: 'Printed at Post-op discharge -- procedure, IOL, medications, instructions, follow-up schedule.' },
  { key: 'external_tests_requisition', name: 'External Tests Requisition', description: 'Printed from Surgical Journey -- list of external tests (blood work, HIV test, etc) for the patient to take to an outside lab.' },
  { key: 'medical_fitness_form', name: 'Medical Fitness Form (Cataract Surgery)', description: 'Bilingual pre-op fitness certificate, printed from Medical Fitness once the doctor gives clearance -- goes in the patient file.' },
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
    return `<img src="${settings.logo_data_url}" style="width: 88px; height: 88px; object-fit: contain;" />`;
  }
  // Fallback mark if no logo has been uploaded yet.
  return `<svg width="88" height="88" viewBox="0 0 100 100" xmlns="http://www.w3.org/2000/svg">
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
  if (key === 'receipt') return buildReceiptContext(settings, SAMPLE_RECEIPT_RAW);
  if (key === 'receipt_advance') return buildReceiptContext(settings, SAMPLE_ADVANCE_RAW);
  if (key === 'opd_case_sheet') return buildOpdCaseSheetContext(settings, SAMPLE_CASE_SHEET_RAW);
  if (key === 'glasses_prescription') return buildGlassesPrescriptionContext(settings, SAMPLE_GLASSES_RX_RAW);
  if (key === 'biometry_report') return buildBiometryReportContext(settings, SAMPLE_BIOMETRY_RAW);
  if (key === 'discharge_summary') return buildDischargeSummaryContext(settings, SAMPLE_DISCHARGE_RAW);
  if (key === 'investigation_report') return SAMPLE_INVESTIGATION_CONTEXT(settings);
  return {};
}

const SAMPLE_DISCHARGE_RAW = {
  patient: { uhid: 'VEH-00004', first_name: 'Utkarsh', last_name: 'Prakash', mobile: '9876543210', age: 62, gender: 'M' },
  surgeon: { full_name: 'Nisha Bachkheti' },
  procedureName: 'Phaco Cataract Surgery', eye: 'OD',
  episode: {
    admission_date: '2026-06-10', surgery_date: '2026-06-10', discharge_date: '2026-06-11',
    discharge_notes: 'Uneventful surgery. Patient tolerated procedure well.',
    discharge_instructions: 'Avoid rubbing the eye. No water contact for 1 week. Use dark glasses outdoors. Report immediately for redness, pain, or sudden vision loss.',
  },
  intraop: { implant_power: '21.5', implant_manufacturer: 'Alcon', implant_model: 'AcrySof IQ' },
  biometry: [{ surgical_eye: 'OD', final_iol_power: '21.5', final_iol_category: 'Monofocal' }],
  meds: [
    { name: 'Moxifloxacin 0.5%', sig: '1 drop QID x 1 week, then taper' },
    { name: 'Prednisolone Acetate 1%', sig: '1 drop QID x 2 weeks, then taper' },
  ],
  followups: [
    { visit_label: 'Post-op Day 1', scheduled_date: '2026-06-12', status: 'Completed' },
    { visit_label: 'Post-op Week 1', scheduled_date: '2026-06-18', status: 'Scheduled' },
    { visit_label: 'Post-op Month 1', scheduled_date: '2026-07-11', status: 'Scheduled' },
  ],
};

function SAMPLE_INVESTIGATION_CONTEXT(settings) {
  return {
    hospital_name: settings.name, hospital_unit_line: settings.unit_line, hospital_regn_no: settings.regn_no,
    hospital_address_line1: settings.address_line1, hospital_address_line2: settings.address_line2,
    hospital_city_state_pin: settings.city_state_pin, hospital_phone: settings.phone, hospital_email: settings.email,
    logo_html: logoHtml(settings),
    patient_id: 'VEH-00004', patient_name: 'Utkarsh Prakash', patient_age: 62, patient_gender: 'M', patient_mobile: '9876543210',
    investigation_name: 'OCT Macula', investigation_type: 'OCT', eye: 'OD',
    doctor_name: 'Nisha Bachkheti', ordered_date: '04 Jun 2026', completed_date: '05 Jun 2026',
    isUnable: false, unable_reason: null,
    hasFields: true,
    fields: [
      { label: 'Central Macular Thickness (OD)', value: '245 um' },
      { label: 'RNFL Thickness', value: 'Average 85 um' },
      { label: 'Signal Strength', value: '8/10' },
    ],
    hasNotes: true, result_notes: 'Scan quality good. No macular edema noted.',
    technician_name: 'Rohit Pratap', hasVerifiedBy: true, verified_by_name: 'Nisha Bachkheti',
  };
}

const SAMPLE_OPD_RAW = {
  patient: { patient_code: 'VEH-P-00031', first_name: 'Dharam', last_name: '', mobile: '+919758041970', age: 39, gender: 'Male' },
  invoice: { invoice_number: 'VEH-BILL-0143', created_at: '2026-06-04T00:00:00Z', gross: 300, gst: 0, net: 300, paid: 300, purpose: 'OPD Services' },
  visit: { created_at: '2026-06-01T00:00:00Z', visit_number: 'V26-000042' },
  doctor: { full_name: 'Dr. Nisha Bachkheti', registration_no: 'UKMC-3436' },
  lineItems: [{ service_name: 'OPD Consultation', qty: 1, rate: 300, disc: 0, net: 300, dept: 'Consultation' }],
  payments: [{ created_at: '2026-06-03T00:00:00Z', receipt_number: 'VEH/RECEIPT/-0054', amount: 300 }],
  packageName: null, packageCode: null, surgeryName: null, surgeryCode: null, surgeryEye: null, packageBreakup: [],
};

const SAMPLE_SURGERY_RAW = {
  ...SAMPLE_OPD_RAW,
  invoice: { invoice_number: 'VEH-BILL-0200', created_at: '2026-06-10T00:00:00Z', gross: 35000, gst: 0, net: 35000, paid: 35000, purpose: 'Surgery Package' },
  lineItems: [{ service_name: 'Cataract Surgery Package', qty: 1, rate: 35000, disc: 0, net: 35000, dept: 'Surgery' }],
  payments: [{ created_at: '2026-06-10T00:00:00Z', receipt_number: 'VEH/RECEIPT/-0091', amount: 35000 }],
  packageName: 'Cataract Surgery -- Standard IOL Package', packageCode: 'PKG001',
  surgeryName: 'Phaco Cataract Surgery', surgeryCode: 'SUR012', surgeryEye: 'OD',
  packageBreakup: [
    { description: 'Surgeon fee', amount: 15000 },
    { description: 'IOL (Standard Monofocal)', amount: 8000 },
    { description: 'OT charges', amount: 7000 },
    { description: 'Consumables & disposables', amount: 3000 },
    { description: 'Pre-op investigations', amount: 2000 },
  ],
};

const SAMPLE_RECEIPT_RAW = {
  patient: { patient_code: 'VEH-P-00031', first_name: 'Dharam', last_name: '', mobile: '+919758041970' },
  payment: {
    receipt_number: 'VEH/RECEIPT/-0054', collected_at: '2026-06-03T00:00:00Z', total_amount: 300,
    payment_type: 'invoice_payment', reference: null, remarks: null,
  },
  collector: { full_name: 'Front Desk' },
  modes: [{ mode: 'Cash', amount: 300 }],
  allocations: [{ amount: 300, invoices: { invoice_number: 'VEH-BILL-0143' } }],
};

const SAMPLE_ADVANCE_RAW = {
  ...SAMPLE_RECEIPT_RAW,
  payment: {
    receipt_number: 'VEH/RECEIPT/-0060', collected_at: '2026-06-15T00:00:00Z', total_amount: 10000,
    payment_type: 'advance', reference: null, remarks: null,
  },
  modes: [{ mode: 'UPI', amount: 10000 }],
  allocations: [],
};

const SAMPLE_CASE_SHEET_RAW = {
  patient: { patient_code: 'VEH-P-00031', first_name: 'Dharam', last_name: '', mobile: '+919758041970', age: 39, gender: 'Male' },
  encounter: {
    chief_complaint: 'Diminution of vision', hx_duration: '3 months', hx_laterality: 'Both eyes', hx_hopi: 'Gradual, painless, progressive blurring of vision, worse for distance.',
    ocular_history: ['Diabetic Retinopathy screening -- 2024'], medical_history: ['Diabetes Mellitus Type 2'], family_history: ['Glaucoma -- father'],
    drug_history: ['Metformin 500mg BD'], allergy: ['Sulfa drugs'],
    patient_instructions: 'Use prescribed eye drops as directed. Avoid rubbing the eyes. Wear dark glasses outdoors.',
  },
  visit: { created_at: '2026-06-01T00:00:00Z', visit_type: 'New Consultation' },
  doctor: { full_name: 'Dr. Nisha Bachkheti', registration_no: 'UKMC-3436' },
  assessment: {
    re_dist_unaided: '6/18', le_dist_unaided: '6/12', re_dist_glasses: '6/9', le_dist_glasses: '6/6',
    re_dist_ph: '6/6', le_dist_ph: '6/6', re_near_unaided: 'N8', le_near_unaided: 'N6',
    ref_final_re_dist_sph: '-2.00', ref_final_re_dist_cyl: '-0.50', ref_final_re_dist_axis: '90', ref_final_re_dist_va: '6/6',
    ref_final_le_dist_sph: '-1.50', ref_final_le_dist_cyl: '', ref_final_le_dist_axis: '', ref_final_le_dist_va: '6/6',
    ref_final_re_near_sph: '+1.00', ref_final_re_near_cyl: '', ref_final_re_near_axis: '', ref_final_re_near_va: 'N6',
    ref_final_le_near_sph: '+1.00', ref_final_le_near_cyl: '', ref_final_le_near_axis: '', ref_final_le_near_va: 'N6',
    iop_method: 'NCT', add_k1_re: '43.5', add_k1_le: '43.7', add_k2_re: '44.2', add_k2_le: '44.4', add_axial_length_re: '23.4 mm', add_axial_length_le: '23.3 mm',
    glasses_prescribed: true, glasses_type: 'Bifocal', glasses_remarks: 'Glass prescribed, review after 6 months',
  },
  iopReadings: [{ eye: 'RE', value: 18 }, { eye: 'LE', value: 16 }],
  examination: {
    external_findings: {}, anterior_findings: { Lens: { re: 'NS2', le: 'NS1', re_custom: '', le_custom: '' } }, posterior_findings: { without: { Disc: { re: 'Healthy', le: 'Healthy' }, CDR: { re: '0.4', le: '0.3' } }, with: {} },
    applanation_re: '16', applanation_le: '15',
    gonioscopy_findings: { angle_re: 'Open Angle', angle_le: 'Open Angle' },
  },
  diagnoses: [{ name: 'Immature Cataract', eye: 'OU', notes: null }],
  prescriptions: [{ drug_name: 'CMC 0.5%', eye: 'BE', dosage: '1 drop', frequency: 'QID', duration: '1 month' }],
  followup: { after_period: '1 month', visit_type: 'Follow-up', instructions: null },
};

// Deliberately includes one eye with SPH-only (no CYL/AXIS) so the
// preview shows how a spherical-only Rx renders cleanly.
const SAMPLE_GLASSES_RX_RAW = {
  patient: { patient_code: 'VEH-P-00031', first_name: 'Dharam', last_name: '', age: 39, gender: 'Male' },
  assessment: {
    created_at: '2026-06-01T00:00:00Z', va_scale: 'Snellen', ref_pd: '62mm',
    ref_final_re_dist_sph: '-2.00', ref_final_re_dist_cyl: '-0.50', ref_final_re_dist_axis: '90', ref_final_re_dist_va: '6/6', ref_final_re_dist_prism: '',
    ref_final_le_dist_sph: '-1.50', ref_final_le_dist_cyl: '', ref_final_le_dist_axis: '', ref_final_le_dist_va: '6/6', ref_final_le_dist_prism: '',
    ref_final_re_near_sph: '+1.00', ref_final_re_near_cyl: '-0.50', ref_final_re_near_axis: '90', ref_final_re_near_va: 'N6', ref_final_re_near_prism: '',
    ref_final_le_near_sph: '+1.00', ref_final_le_near_cyl: '', ref_final_le_near_axis: '', ref_final_le_near_va: 'N6', ref_final_le_near_prism: '',
    ref_final_re_add: '+2.50', ref_final_le_add: '+2.50',
    glasses_prescribed: true, glasses_type: 'Bifocal', glasses_remarks: 'Glass prescribed, review after 6 months',
  },
  optometrist: { full_name: 'Rohit Pratap' },
  doctor: { full_name: 'Dr. Nisha Bachkheti', registration_no: 'UKMC-3436' },
};

const SAMPLE_BIOMETRY_RAW = {
  patient: { uhid: 'VEH000031', first_name: 'Dharam', last_name: '', age: 68, gender: 'Male' },
  visit: { visit_number: 'VN26-000112' },
  record: {
    procedure_name: 'Phacoemulsification with IOL', surgical_eye: 'RE', status: 'Measured',
    created_at: '2026-06-01T00:00:00Z', verified_at: '2026-06-01T00:00:00Z',
    measurements: {
      re: [{ device: 'ZEISS IOLMaster 700', axl: '23.45', k1: '43.25', k2: '44.10', acd: '3.12', wtw: '11.80' }],
      le: [{ device: 'ZEISS IOLMaster 700', axl: '23.38', k1: '43.40', k2: '44.05', acd: '3.08', wtw: '11.75' }],
    },
    verify_remarks: 'Optical biometry unreliable on RE due to dense cataract -- Manual A-Scan cross-checked.',
  },
  verifiedBy: { full_name: 'Dr. Nisha Bachkheti', registration_no: 'UKMC-3436' },
  recommendations: [
    { master_iol_catalog: { brand: 'Alcon', model: 'AcrySof IQ' }, re_power: '21.5', le_power: '21.0' },
    { master_iol_catalog: { brand: 'Johnson & Johnson', model: 'Tecnis Eyhance' }, re_power: '21.5', le_power: '21.0' },
  ],
};

// ── Resolves the TRUE original collection date(s) behind an
// 'advance_adjustment' payment, for print purposes only -- it never
// modifies any ledger data. An advance balance is pooled per patient,
// not earmarked to any specific invoice or receipt, so this walks the
// patient's full advance timeline in collected_at order and attributes
// each adjustment back to the specific original 'advance' receipt(s) it
// drew down, FIFO (oldest advance consumed first) -- the same order the
// balance is actually depleted in. Returns a map of
// adjustment-payment-id -> [{ receipt_number, collected_at, amount }].
async function resolveAdvanceAdjustmentOrigins(supabase, patientId) {
  const { data: timeline } = await supabase
    .from('payments')
    .select('id, receipt_number, collected_at, total_amount, payment_type')
    .eq('patient_id', patientId)
    .in('payment_type', ['advance', 'advance_adjustment'])
    .order('collected_at', { ascending: true });

  const chunks = []; // original advance receipts with remaining unconsumed balance
  const originsByAdjustmentId = {};

  (timeline || []).forEach((p) => {
    const amount = Number(p.total_amount || 0);
    if (p.payment_type === 'advance') {
      chunks.push({ receipt_number: p.receipt_number, collected_at: p.collected_at, remaining: amount });
      return;
    }
    let toConsume = amount;
    const contributions = [];
    for (const chunk of chunks) {
      if (toConsume <= 0) break;
      if (chunk.remaining <= 0) continue;
      const take = Math.min(chunk.remaining, toConsume);
      chunk.remaining -= take;
      toConsume -= take;
      contributions.push({ receipt_number: chunk.receipt_number, collected_at: chunk.collected_at, amount: take });
    }
    // apply_advance_adjustment already checks the balance before
    // allowing this, so this shouldn't happen -- but if the timeline
    // somehow runs short, don't silently drop the remainder; fall back
    // to the adjustment's own date for whatever couldn't be matched
    // rather than understating the payment total on the bill.
    if (toConsume > 0.01) {
      contributions.push({ receipt_number: p.receipt_number, collected_at: p.collected_at, amount: toConsume });
    }
    originsByAdjustmentId[p.id] = contributions;
  });

  return originsByAdjustmentId;
}

// ── Renders the actual invoice HTML for a given invoiceId. Picks the
//    OPD or Surgery variant based on whether any line item was billed
//    under the Surgery department (package billing tags its line item
//    dept: 'Surgery' -- see billing/new/new-invoice-tab.js). ──
export async function renderInvoiceHtml(invoiceId, includeBreakup = false) {
  const supabase = await createClient();

  const { data: invoice, error } = await supabase
    .from('invoices')
    .select('*, patients(uhid, first_name, last_name, mobile, age, gender), visits(id, visit_number, created_at, doctor_id, profiles:doctor_id(full_name, registration_no))')
    .eq('id', invoiceId)
    .single();
  if (error || !invoice) return { error: 'Invoice not found.' };

  const { data: rawLineItems } = await supabase.from('invoice_line_items').select('*').eq('invoice_id', invoiceId).order('id');

  // The invoice itself stays itemized (individual medicine names/rates
  // visible in Invoice Details) -- no pharmacy license yet, so only the
  // printed/PDF copy collapses every Pharmacy-dept line into one "OPD
  // Procedure Consumables" line at qty 1 for the combined total.
  const pharmacyLines = (rawLineItems || []).filter((li) => li.dept === 'Pharmacy');
  const nonPharmacyLines = (rawLineItems || []).filter((li) => li.dept !== 'Pharmacy');
  const pharmacyTotal = pharmacyLines.reduce((s, li) => s + Number(li.net), 0);
  const lineItems = pharmacyLines.length > 0
    ? [...nonPharmacyLines, { service_name: 'OPD Procedure Consumables', dept: 'Pharmacy', qty: 1, rate: pharmacyTotal, disc: 0, net: pharmacyTotal }]
    : nonPharmacyLines;

  const { data: allocations } = await supabase
    .from('payment_allocations')
    .select('amount, payments(id, receipt_number, collected_at, payment_type)')
    .eq('invoice_id', invoiceId);
  let payments = (allocations || []).map((a) => ({
    amount: a.amount, receipt_number: a.payments?.receipt_number, created_at: a.payments?.collected_at,
    payment_type: a.payments?.payment_type, payment_id: a.payments?.id,
  }));

  // An 'advance_adjustment' payment record is created the moment the
  // advance is APPLIED to an invoice (apply_advance_adjustment RPC),
  // dated "now" -- correct for accounting (the original "Advance
  // Collected" ledger entry is deliberately never touched, per Section
  // 22.11), but wrong to print as-is: the patient may well have paid
  // the advance days or weeks before it got applied here, and a bill
  // showing the application date as "when they paid" is a genuine
  // mismatch against what actually happened. Resolve it back to the
  // real original collection date/receipt before printing.
  if (payments.some((p) => p.payment_type === 'advance_adjustment') && invoice.patient_id) {
    const origins = await resolveAdvanceAdjustmentOrigins(supabase, invoice.patient_id);
    payments = payments.flatMap((p) => {
      if (p.payment_type !== 'advance_adjustment') return [p];
      const contributions = origins[p.payment_id];
      if (!contributions || contributions.length === 0) return [p];
      // A pooled advance balance can span more than one original
      // receipt -- split into one printed line per original receipt it
      // actually drew from, each with that receipt's own date.
      return contributions.map((c) => ({ amount: c.amount, receipt_number: c.receipt_number, created_at: c.collected_at }));
    });
  }

  const isSurgery = (rawLineItems || []).some((li) => li.dept === 'Surgery');

  let packageName = null;
  let packageCode = null;
  let surgeryName = null;
  let surgeryCode = null;
  let surgeryEye = null;
  let surgeonForBill = null; // Surgery Bill shows the operating surgeon, not the visit's consulting doctor
  let packageBreakup = [];
  let breakupAvailable = false;
  if (isSurgery) {
    // The package/surgery header shown on the bill must reflect what was
    // actually billed on THIS invoice, not whatever the surgical case's
    // package currently is -- a patient's package can be changed after
    // billing (Counselling supports this), or a case can be rebilled
    // under a different package entirely, and past invoices must not
    // silently start showing today's package on reprint. The billed
    // package name/code therefore comes straight from this invoice's own
    // Surgery line item, which is immutable once created -- no visit_id
    // needed for this part at all.
    const surgeryLine = (rawLineItems || []).find((li) => li.dept === 'Surgery');
    packageName = surgeryLine?.service_name || null;
    packageCode = surgeryLine?.service_code || null;

    // Enrichment only -- a surgical case registered directly (OT
    // Schedule's "Register Surgery Directly") or billed without a visit
    // selected has no visit_id to look this up by. That's fine: the
    // manual_surgery_* fields below (always saved at billing time,
    // whether prefilled from a case or typed by hand) cover exactly
    // this situation, which is why they exist.
    let surgicalCase = null;
    if (invoice.visit_id) {
      const { data } = await supabase
        .from('surgical_cases')
        .select('id, procedure_name, eye, surgeon_id')
        .eq('visit_id', invoice.visit_id)
        .neq('status', 'Cancelled')
        .maybeSingle();
      surgicalCase = data;
    }

    // Surgery/Eye/Doctor are always editable in New Invoice now (whether
    // prefilled from a case or entered by hand), and whatever was
    // confirmed at billing time is saved onto the invoice itself
    // (manual_surgery_*). That takes priority over the surgical case,
    // which is live data that can keep changing after the bill was
    // printed -- same reasoning as the package name/code above.
    surgeryName = invoice.manual_surgery_name || surgicalCase?.procedure_name || null;
    surgeryEye = invoice.manual_surgery_eye || surgicalCase?.eye || null;
    const surgeonId = invoice.manual_surgeon_id || surgicalCase?.surgeon_id || null;
    if (surgeonId) {
      const { data: surgeon } = await supabase.from('profiles').select('full_name, registration_no').eq('id', surgeonId).maybeSingle();
      surgeonForBill = surgeon || null;
    }
    if (surgeryName) {
      // surgical_cases stores the surgery as free text (matched from the
      // Clinical Masters -- Surgery list at the time it was picked), not
      // a foreign key, so the code is looked up by name here.
      const { data: surgery } = await supabase.from('master_surgeries').select('code').eq('name', surgeryName).maybeSingle();
      surgeryCode = surgery?.code || null;
    }
    // Breakup lookup is keyed off packageCode (the invoice's own line
    // item, always available for a surgery invoice) -- not the
    // surgical case, so this works regardless of whether one was found.
    if (packageCode) {
      const { data: pkgForBreakup } = await supabase.from('master_packages').select('id').eq('code', packageCode).maybeSingle();
      if (pkgForBreakup) {
        const { data: breakupItems } = await supabase
          .from('package_line_items')
          .select('description, amount')
          .eq('package_id', pkgForBreakup.id)
          .order('sort_order');
        breakupAvailable = (breakupItems || []).length > 0;
        // Only actually included in the printed HTML when explicitly
        // requested (e.g. an insurance copy) -- most prints should stay
        // as the single package line item, no itemized breakup.
        if (includeBreakup) packageBreakup = breakupItems || [];
      }
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
    doctor: isSurgery ? (surgeonForBill || invoice.visits?.profiles) : invoice.visits?.profiles,
    lineItems: lineItems || [],
    payments,
    packageName,
    packageCode,
    surgeryName,
    surgeryCode,
    surgeryEye,
    packageBreakup,
  });

  const templateKey = isSurgery ? 'invoice_surgery' : 'invoice_opd';
  const template = await getPrintTemplate(templateKey);
  const compiled = Handlebars.compile(template.html);
  return { html: compiled(context), breakupAvailable };
}

function inr(n) {
  return `Rs. ${Number(n || 0).toFixed(2)}`;
}
function fmtDate(d) {
  if (!d) return '--';
  return new Date(d).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: '2-digit', month: 'short', year: 'numeric' });
}

// Same mapping used in OT Intraop's workspace -- kept identical so an eye
// code reads the same way everywhere in the app, including on printouts.
const EYE_LABEL = { RE: 'Right (OD)', LE: 'Left (OS)', Both: 'Both (OU)', OD: 'Right (OD)', OS: 'Left (OS)', OU: 'Both (OU)' };
function fmtEye(code) {
  if (!code) return '--';
  return EYE_LABEL[code] || code;
}

function buildInvoiceContext(settings, { patient, invoice, visit, doctor, lineItems, payments, packageName, packageCode, surgeryName, surgeryCode, surgeryEye, packageBreakup }) {
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
    surgery_name: surgeryName || '--',
    surgery_code: surgeryCode || '--',
    eye: fmtEye(surgeryEye),
    package_name: packageName || '--',
    package_code: packageCode || '--',
    // Discharge date always mirrors the visit date -- day-care surgery
    // discharge happens the same day, and the printed bill should never
    // show a different (or missing) date from a separately recorded
    // recovery episode.
    discharge_date: fmtDate(visit?.created_at),

    bill_no: invoice.invoice_number,
    bill_date: fmtDate(invoice.created_at),
    visit_number: visit?.visit_number || '--',
    visit_date: fmtDate(visit?.created_at),
    doctor_name: doctor?.full_name || '--',
    doctor_regn_no: doctor?.registration_no || '--',

    items: (lineItems || []).map((li, idx) => ({
      sno: idx + 1,
      name: (li.dept === 'Surgery' && li.service_code) ? `${li.service_name} (${li.service_code})` : li.service_name,
      qty: li.qty, rate: inr(li.rate), amount: inr(li.net),
    })),
    gross_amount: inr(invoice.gross),
    discount: inr(totalDisc),
    net_amount: inr(invoice.net),

    // Optional itemized breakup of what a surgery package includes --
    // not part of the accounting (the invoice still has one net line
    // item for the package), just a printed reference so staff can show
    // a patient what's covered when asked. Only present when a package
    // with a saved breakup was actually billed.
    has_breakup: (packageBreakup || []).length > 0,
    package_breakup: (packageBreakup || []).map((b) => ({ description: b.description, amount: inr(b.amount) })),

    payments: (payments || []).map((p) => ({
      date: fmtDate(p.created_at), ref_number: p.receipt_number || '--', amount: inr(p.amount),
    })),
    total_paid: inr(totalPaid),
  };
}

const PAYMENT_TYPE_LABEL = { invoice_payment: 'Payment', advance: 'Advance Collection', advance_adjustment: 'Advance Adjustment' };

// ── Renders the actual receipt HTML for a given paymentId. Picks the
//    Advance Receipt variant when payment_type is 'advance' (a fresh
//    advance collection, not yet applied to any invoice); everything
//    else (a regular payment, or an advance being adjusted against an
//    invoice) uses the standard Payment Receipt. ──
export async function renderReceiptHtml(paymentId) {
  const supabase = await createClient();

  const { data: payment, error } = await supabase
    .from('payments')
    .select('*, patients(uhid, first_name, last_name, mobile), profiles:collected_by(full_name)')
    .eq('id', paymentId)
    .single();
  if (error || !payment) return { error: 'Receipt not found.' };

  const { data: modes } = await supabase.from('payment_modes').select('*').eq('payment_id', paymentId);
  const { data: allocations } = await supabase
    .from('payment_allocations')
    .select('*, invoices(invoice_number)')
    .eq('payment_id', paymentId);

  const settings = await getHospitalSettings();
  const context = buildReceiptContext(settings, {
    patient: {
      patient_code: payment.patients?.uhid, first_name: payment.patients?.first_name, last_name: payment.patients?.last_name,
      mobile: payment.patients?.mobile,
    },
    payment,
    collector: payment.profiles,
    modes: modes || [],
    allocations: allocations || [],
  });

  const templateKey = payment.payment_type === 'advance' ? 'receipt_advance' : 'receipt';
  const template = await getPrintTemplate(templateKey);
  const compiled = Handlebars.compile(template.html);
  return { html: compiled(context) };
}

function buildReceiptContext(settings, { patient, payment, collector, modes, allocations }) {
  return {
    hospital_name: settings.name || 'VEDA EYE HOSPITAL',
    hospital_unit_line: settings.unit_line || '',
    hospital_regn_no: settings.regn_no || '',
    hospital_address_line1: settings.address_line1 || '',
    hospital_address_line2: settings.address_line2 || '',
    hospital_city_state_pin: settings.city_state_pin || '',
    hospital_phone: settings.phone || '',
    hospital_email: settings.email || '',
    logo_html: logoHtml(settings),

    patient_name: `${patient.first_name || ''} ${patient.last_name || ''}`.trim(),
    patient_id: patient.patient_code || '--',
    patient_mobile: patient.mobile || '--',

    receipt_no: payment.receipt_number,
    receipt_date: fmtDate(payment.collected_at),
    payment_type_label: PAYMENT_TYPE_LABEL[payment.payment_type] || payment.payment_type,
    collected_by: collector?.full_name || '--',

    amount_received: inr(payment.total_amount),
    amount_in_words: amountInWords(payment.total_amount),

    hasAllocations: (allocations || []).length > 0,
    allocations: (allocations || []).map((a) => ({ invoiceNumber: a.invoices?.invoice_number || '--', amount: inr(a.amount) })),

    modes: (modes || []).map((m) => ({ mode: m.mode, amount: inr(m.amount) })),

    reference: payment.reference || null,
    remarks: payment.remarks || null,
  };
}

const ONES = ['', 'One', 'Two', 'Three', 'Four', 'Five', 'Six', 'Seven', 'Eight', 'Nine', 'Ten',
  'Eleven', 'Twelve', 'Thirteen', 'Fourteen', 'Fifteen', 'Sixteen', 'Seventeen', 'Eighteen', 'Nineteen'];
const TENS = ['', '', 'Twenty', 'Thirty', 'Forty', 'Fifty', 'Sixty', 'Seventy', 'Eighty', 'Ninety'];

function twoDigitWords(n) {
  if (n < 20) return ONES[n];
  return `${TENS[Math.floor(n / 10)]}${n % 10 ? ' ' + ONES[n % 10] : ''}`;
}
function threeDigitWords(n) {
  if (n < 100) return twoDigitWords(n);
  return `${ONES[Math.floor(n / 100)]} Hundred${n % 100 ? ' ' + twoDigitWords(n % 100) : ''}`;
}

// Indian numbering (lakh/crore), matching how amounts are normally
// written out on Indian receipts.
function amountInWords(amount) {
  let n = Math.round(Number(amount || 0));
  if (n === 0) return 'Rupees Zero Only';
  const parts = [];
  const crore = Math.floor(n / 10000000); n %= 10000000;
  const lakh = Math.floor(n / 100000); n %= 100000;
  const thousand = Math.floor(n / 1000); n %= 1000;
  const hundred = n;
  if (crore) parts.push(`${threeDigitWords(crore)} Crore`);
  if (lakh) parts.push(`${threeDigitWords(lakh)} Lakh`);
  if (thousand) parts.push(`${threeDigitWords(thousand)} Thousand`);
  if (hundred) parts.push(threeDigitWords(hundred));
  return `Rupees ${parts.join(' ')} Only`;
}

// ── Renders a simple referral slip listing external investigations
//    requested for a surgical case (blood work, HIV test, etc -- not
//    done in-house) -- handed to the patient to get done elsewhere.
//    Self-contained rather than going through the editable
//    print_templates table, since this is a short, fixed-format slip. ──
export async function renderExternalInvestigationReferralHtml(caseId) {
  const supabase = await createClient();

  const { data: sc, error } = await supabase
    .from('surgical_cases')
    .select('id, procedure_name, eye, created_at, patients:patient_id(uhid, first_name, last_name, age, gender, mobile), profiles:surgeon_id(full_name, registration_no)')
    .eq('id', caseId)
    .single();
  if (error || !sc) return { error: 'Case not found.' };

  const { data: tests } = await supabase
    .from('external_investigations')
    .select('test_name, created_at')
    .eq('surgical_case_id', caseId)
    .order('created_at', { ascending: true });

  if (!tests || tests.length === 0) return { error: 'No external investigations have been added for this case yet.' };

  const settings = await getHospitalSettings();
  const patient = sc.patients;

  const rows = tests.map((t, i) => `
    <tr>
      <td style="border: 1px solid #999; padding: 8px; text-align: center; width: 40px;">${i + 1}</td>
      <td style="border: 1px solid #999; padding: 8px;">${t.test_name}</td>
      <td style="border: 1px solid #999; padding: 8px;"></td>
    </tr>`).join('');

  const html = `
<div style="max-width: 780px; margin: 0 auto; padding: 24px; font-family: Arial, Helvetica, sans-serif; color: #1a1a1a; font-size: 13px;">
  <table style="width: 100%; border-collapse: collapse; margin-bottom: 6px;">
    <tr>
      <td style="width: 100px; vertical-align: top;">${logoHtml(settings)}</td>
      <td style="vertical-align: top;">
        <div style="font-size: 24px; font-weight: 800; letter-spacing: .3px; text-decoration: underline;">${settings.name || ''}</div>
        <div style="font-size: 11px; font-weight: 700; margin-top: 2px;">${settings.unit_line || ''}</div>
        <div style="font-size: 10px; font-weight: 700;">REGN NO : ${settings.regn_no || ''}</div>
      </td>
      <td style="text-align: right; vertical-align: top; font-size: 10.5px; line-height: 1.5;">
        ${settings.address_line1 || ''}<br/>
        ${settings.address_line2 || ''}<br/>
        ${settings.city_state_pin || ''}<br/>
        Tel: ${settings.phone || ''}
      </td>
    </tr>
  </table>

  <div style="text-align: center; font-size: 16px; font-weight: 700; border-top: 1.5px solid #333; border-bottom: 1.5px solid #333; padding: 8px 0; margin: 10px 0 16px;">
    INVESTIGATION REFERRAL
  </div>

  <table style="width: 100%; border: 1.5px solid #333; border-collapse: collapse; margin-bottom: 18px;">
    <tr>
      <td style="width: 60%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9; border-right: 1px solid #999;">
        <table style="width: 100%; font-size: 12px;">
          <tr><td style="width: 110px; color: #444;">PATIENT ID</td><td>: <strong>${patient?.uhid || '--'}</strong></td></tr>
          <tr><td style="color: #444;">NAME</td><td>: <strong>${patient?.first_name || ''} ${patient?.last_name || ''}</strong></td></tr>
          <tr><td style="color: #444;">AGE/GENDER</td><td>: <strong>${patient?.age ?? '--'} / ${patient?.gender || '--'}</strong></td></tr>
          <tr><td style="color: #444;">MOBILE</td><td>: <strong>${patient?.mobile || '--'}</strong></td></tr>
        </table>
      </td>
      <td style="width: 40%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9;">
        <table style="width: 100%; font-size: 12px;">
          <tr><td style="width: 60px; color: #444;">DATE</td><td>: <strong>${fmtDate(new Date().toISOString())}</strong></td></tr>
        </table>
      </td>
    </tr>
  </table>

  <div style="font-size: 12px; margin-bottom: 10px;">The following investigations are requested. Please get these done and bring the reports on your next visit.</div>

  <table style="width: 100%; border-collapse: collapse; font-size: 12.5px; margin-bottom: 30px;">
    <thead>
      <tr style="background: #e9edf2;">
        <th style="border: 1px solid #999; padding: 8px;">S.NO</th>
        <th style="border: 1px solid #999; padding: 8px; text-align: left;">Investigation</th>
        <th style="border: 1px solid #999; padding: 8px; text-align: left; width: 160px;">Report / Remarks</th>
      </tr>
    </thead>
    <tbody>${rows}</tbody>
  </table>

  <table style="width: 100%; margin-top: 50px;">
    <tr>
      <td style="font-size: 12px;">&nbsp;</td>
      <td style="text-align: right; font-size: 12px;">
        <div>Dr. ${sc.profiles?.full_name || ''}</div>
        <div style="font-size: 10.5px; color: #666;">Reg No: ${sc.profiles?.registration_no || ''}</div>
      </td>
    </tr>
  </table>

  <div style="text-align: center; margin-top: 20px; font-size: 10.5px; color: #999;">
    For any Queries please contact us at ${settings.phone || ''} or Email us at ${settings.email || ''}
  </div>
</div>`;

  return { html };
}

// ── Renders the OPD Case Sheet for a given encounterId -- the
//    patient-facing handout: chief complaint, vision/IOP/refraction,
//    diagnosis, prescription, advice, and follow-up. ──
export async function renderOpdCaseSheetHtml(encounterId) {
  const supabase = await createClient();

  const { data: encounter, error } = await supabase
    .from('encounters')
    .select('*, visits(id, created_at, visit_type, doctor_id, patients(uhid, first_name, last_name, mobile, age, gender), profiles:doctor_id(full_name, registration_no))')
    .eq('id', encounterId)
    .single();
  if (error || !encounter) return { error: 'Consultation not found.' };

  const visit = encounter.visits;

  const { data: assessment } = await supabase
    .from('optometry_assessments')
    .select('*')
    .eq('visit_id', visit?.id)
    .order('created_at', { ascending: false })
    .limit(1)
    .maybeSingle();

  let iopReadings = [];
  if (assessment) {
    const { data: readings } = await supabase.from('optometry_iop_readings').select('eye, value').eq('assessment_id', assessment.id);
    iopReadings = readings || [];
  }

  const { data: examination } = await supabase.from('clinical_examinations').select('*').eq('encounter_id', encounterId).maybeSingle();

  const { data: diagnoses } = await supabase.from('diagnoses').select('*').eq('encounter_id', encounterId).order('created_at');
  const { data: prescriptions } = await supabase.from('prescriptions').select('*').eq('encounter_id', encounterId).order('created_at');
  const { data: followup } = await supabase.from('plan_followups').select('*').eq('encounter_id', encounterId).maybeSingle();

  // Surgery advice -- if this encounter marked the patient for surgery,
  // it should show on the case sheet: what was advised, which eye, and
  // the patient's decision at the time.
  const { data: surgicalCase } = await supabase
    .from('surgical_cases')
    .select('procedure_name, eye, decision')
    .eq('encounter_id', encounterId)
    .neq('status', 'Cancelled')
    .order('created_at', { ascending: false })
    .limit(1)
    .maybeSingle();

  const settings = await getHospitalSettings();
  const context = buildOpdCaseSheetContext(settings, {
    patient: {
      patient_code: visit?.patients?.uhid, first_name: visit?.patients?.first_name, last_name: visit?.patients?.last_name,
      mobile: visit?.patients?.mobile, age: visit?.patients?.age, gender: visit?.patients?.gender,
    },
    encounter,
    visit,
    doctor: visit?.profiles,
    assessment,
    iopReadings,
    examination,
    diagnoses: diagnoses || [],
    prescriptions: (prescriptions || []).map((r) => ({ ...r, drug: r.drug_name })),
    followup,
    surgicalCase,
  });

  const template = await getPrintTemplate('opd_case_sheet');
  const compiled = Handlebars.compile(template.html);
  return { html: compiled(context) };
}

// ── GLASSES PRESCRIPTION -- printed from the Optometry screen. Always
//    the Final Rx (the accepted prescription, not the working
//    Objective/Subjective values). Rows are only shown when at least
//    one eye has an SPH recorded; CYL/AXIS are shown blank (not "0.00")
//    when only the spherical power was given, since axis is meaningless
//    without a cylinder. ──
function fmtRxVal(v) {
  return v || '--';
}

// Falls back Final Rx -> Subjective -> Objective when the earlier one
// wasn't filled in for that eye/distance -- for the internal OPD case
// sheet only. A patient's Distance refraction is very often recorded
// in the Subjective or Objective tab and never re-typed into Final Rx,
// which otherwise makes it silently vanish from the printed sheet even
// though it was genuinely measured. Falls back per whole row (not per
// individual SPH/CYL/AXIS field) so figures from different refraction
// types are never mixed together in one row, and the source actually
// used is labeled on the printout rather than implied to be "Final".
// A distance/near refraction row can be entirely valid with SPH left
// blank (plano/zero) while the real correction sits in CYL+AXIS -- pure
// astigmatism with no spherical component is clinically common. Only
// checking SPH for "was this row filled in" silently drops exactly
// that case, so every field is checked here.
function rowHasData(assessment, prefix) {
  return !!(assessment?.[`${prefix}_sph`] || assessment?.[`${prefix}_cyl`] || assessment?.[`${prefix}_axis`] || assessment?.[`${prefix}_va`]);
}

const REFRACTION_SOURCE_LABEL = { final: 'Final Rx', subj: 'Subjective', obj: 'Objective (Auto-Rx)' };
function pickRxRow(assessment, eye, distNear) {
  for (const type of ['final', 'subj', 'obj']) {
    const prefix = `ref_${type}_${eye}_${distNear}`;
    if (rowHasData(assessment, prefix)) {
      return { cells: buildRxCells(assessment, prefix), source: type };
    }
  }
  return { cells: buildRxCells(assessment, `ref_final_${eye}_${distNear}`), source: 'final' };
}

function buildRxCells(assessment, prefix) {
  const sph = assessment?.[`${prefix}_sph`];
  const cyl = assessment?.[`${prefix}_cyl`];
  const axis = assessment?.[`${prefix}_axis`];
  const va = assessment?.[`${prefix}_va`];
  return {
    sph: fmtRxVal(sph),
    // Only spherical power is common in real prescriptions -- axis is
    // meaningless without a cylinder, so both stay blank together.
    cyl: cyl ? cyl : '--',
    axis: cyl ? fmtRxVal(axis) : '--',
    va: fmtRxVal(va),
  };
}

function buildGlassesPrescriptionContext(settings, { patient, assessment, optometrist, doctor }) {
  const distRe = buildRxCells(assessment, 'ref_final_re_dist');
  const distLe = buildRxCells(assessment, 'ref_final_le_dist');
  const nearRe = buildRxCells(assessment, 'ref_final_re_near');
  const nearLe = buildRxCells(assessment, 'ref_final_le_near');

  const hasDistRx = rowHasData(assessment, 'ref_final_re_dist') || rowHasData(assessment, 'ref_final_le_dist');
  const hasNearRx = rowHasData(assessment, 'ref_final_re_near') || rowHasData(assessment, 'ref_final_le_near');

  return {
    hospital_name: settings.name || 'VEDA EYE HOSPITAL',
    hospital_unit_line: settings.unit_line || '',
    hospital_regn_no: settings.regn_no || '',
    hospital_address_line1: settings.address_line1 || '',
    hospital_address_line2: settings.address_line2 || '',
    hospital_city_state_pin: settings.city_state_pin || '',
    hospital_phone: settings.phone || '',
    hospital_email: settings.email || '',
    logo_html: logoHtml(settings),

    // Printing on a pre-printed prescription pad (hospital header already
    // on the paper) -- hide the digital header and leave blank space
    // matching the pad's own header height instead.
    hide_header: !!settings.glasses_rx_hide_header,
    header_space_cm: settings.print_letterhead_space_cm ?? 5,

    patient_id: patient.patient_code || '--',
    patient_name: `${patient.first_name || ''} ${patient.last_name || ''}`.trim(),
    patient_age: patient.age ?? '--',
    patient_gender: patient.gender || '--',

    rx_date: fmtDate(assessment?.created_at),
    va_scale: assessment?.va_scale || 'Snellen',

    hasDistRx,
    dist_re_sph: distRe.sph, dist_re_cyl: distRe.cyl, dist_re_axis: distRe.axis, dist_re_va: distRe.va,
    dist_le_sph: distLe.sph, dist_le_cyl: distLe.cyl, dist_le_axis: distLe.axis, dist_le_va: distLe.va,
    dist_re_prism: assessment?.ref_final_re_dist_prism || '--',
    dist_le_prism: assessment?.ref_final_le_dist_prism || '--',

    hasNearRx,
    near_re_sph: nearRe.sph, near_re_cyl: nearRe.cyl, near_re_axis: nearRe.axis, near_re_va: nearRe.va,
    near_le_sph: nearLe.sph, near_le_cyl: nearLe.cyl, near_le_axis: nearLe.axis, near_le_va: nearLe.va,
    near_re_prism: assessment?.ref_final_re_near_prism || '--',
    near_le_prism: assessment?.ref_final_le_near_prism || '--',
    add_re: assessment?.ref_final_re_add || '--',
    add_le: assessment?.ref_final_le_add || '--',

    glasses_prescribed: !!assessment?.glasses_prescribed,
    glasses_type: assessment?.glasses_type || '',
    glasses_remarks: assessment?.glasses_remarks || '',

    ipd: assessment?.ref_pd || '--',
    optometrist_name: optometrist?.full_name || '--',
    doctor_name: doctor?.full_name || '--',
    doctor_regn_no: doctor?.registration_no || '--',
  };
}

export async function renderGlassesPrescriptionHtml(assessmentId) {
  const supabase = await createClient();

  const { data: assessment, error } = await supabase
    .from('optometry_assessments')
    .select('*, visits(id, doctor_id, patients(uhid, first_name, last_name, age, gender), profiles:doctor_id(full_name, registration_no)), profiles:recorded_by(full_name)')
    .eq('id', assessmentId)
    .single();
  if (error || !assessment) return { error: 'Optometry assessment not found.' };

  const visit = assessment.visits;
  const settings = await getHospitalSettings();
  const context = buildGlassesPrescriptionContext(settings, {
    patient: {
      patient_code: visit?.patients?.uhid, first_name: visit?.patients?.first_name, last_name: visit?.patients?.last_name,
      age: visit?.patients?.age, gender: visit?.patients?.gender,
    },
    assessment,
    optometrist: assessment.profiles,
    doctor: visit?.profiles,
  });

  const template = await getPrintTemplate('glasses_prescription');
  const compiled = Handlebars.compile(template.html);
  return { html: compiled(context) };
}

// ── BIOMETRY REPORT -- printed from Surgeon Approval once the IOL plan
//    is approved. Shows the raw biometry readings (per eye, per device --
//    a technician may have taken more than one reading, e.g. a manual
//    A-scan fallback for a dense cataract) alongside the calculated
//    formula results and the final approved plan. ──
function buildBiometryReadingSets(sets) {
  return (Array.isArray(sets) ? sets : []).map((s) => ({
    device: s.device || 'Unspecified device',
    axl: s.axl || '--', k1: s.k1 || '--', k2: s.k2 || '--', acd: s.acd || '--', wtw: s.wtw || '--',
  }));
}

function buildBiometryReportContext(settings, { patient, visit, record, verifiedBy, recommendations }) {
  const reSets = buildBiometryReadingSets(record.measurements?.re);
  const leSets = buildBiometryReadingSets(record.measurements?.le);

  const recRows = (recommendations || []).map((r) => ({
    brandModel: `${r.master_iol_catalog?.brand || ''} ${r.master_iol_catalog?.model || ''}`.trim() || '--',
    rePower: r.re_power ?? '--',
    lePower: r.le_power ?? '--',
  }));

  const EYE_LABEL = { RE: 'Right Eye (RE / OD)', LE: 'Left Eye (LE / OS)', Both: 'Both Eyes (OU)', OD: 'Right Eye (RE / OD)', OS: 'Left Eye (LE / OS)', OU: 'Both Eyes (OU)' };

  return {
    hospital_name: settings.name || 'VEDA EYE HOSPITAL',
    hospital_unit_line: settings.unit_line || '',
    hospital_regn_no: settings.regn_no || '',
    hospital_address_line1: settings.address_line1 || '',
    hospital_address_line2: settings.address_line2 || '',
    hospital_city_state_pin: settings.city_state_pin || '',
    hospital_phone: settings.phone || '',
    hospital_email: settings.email || '',
    logo_html: logoHtml(settings),

    patient_id: patient.uhid || '--',
    patient_name: `${patient.first_name || ''} ${patient.last_name || ''}`.trim(),
    patient_age: patient.age ?? '--',
    patient_gender: patient.gender || '--',
    visit_number: visit?.visit_number || '--',
    report_date: fmtDate(record.verified_at || record.created_at),

    procedure_name: record.procedure_name || '--',
    surgical_eye: EYE_LABEL[record.surgical_eye] || record.surgical_eye || '--',
    verified_by_name: verifiedBy?.full_name || '--',
    verified_by_regn_no: verifiedBy?.registration_no || null,

    hasReReadings: reSets.length > 0,
    reSets,
    hasLeReadings: leSets.length > 0,
    leSets,

    hasRecommendations: recRows.length > 0,
    recommendations: recRows,

    hasNotes: !!(record.verify_remarks && record.verify_remarks.trim()),
    notes: record.verify_remarks || '',
  };
}

export async function renderBiometryReportHtml(recordId) {
  const supabase = await createClient();

  const { data: record, error } = await supabase
    .from('biometry_records')
    .select('*, visits(id, visit_number, patients(uhid, first_name, last_name, age, gender))')
    .eq('id', recordId)
    .single();
  if (error || !record) return { error: 'Biometry record not found.' };

  let verifiedBy = null;
  if (record.verified_by) {
    const { data: doc } = await supabase.from('profiles').select('full_name, registration_no').eq('id', record.verified_by).maybeSingle();
    verifiedBy = doc;
  }

  const { data: recommendations } = await supabase
    .from('biometry_iol_recommendations')
    .select('*, master_iol_catalog(brand, model)')
    .eq('biometry_record_id', recordId)
    .order('created_at', { ascending: true });

  const settings = await getHospitalSettings();
  const context = buildBiometryReportContext(settings, {
    patient: record.visits?.patients || {},
    visit: record.visits,
    record,
    verifiedBy,
    recommendations: recommendations || [],
  });

  const template = await getPrintTemplate('biometry_report');
  const compiled = Handlebars.compile(template.html);
  return { html: compiled(context) };
}

// Each structure's first/baseline template option is its "normal" value
// (mirrors EXT_TEMPLATES/ANT_TEMPLATES/POST_TEMPLATES in the Examination
// tab -- kept in sync manually since the template lists live client-side).
const EXAM_NORMAL_VALUE = {
  Lids: 'Normal', Adnexa: 'Normal', Lacrimal: 'Patent', Motility: 'Full',
  Conjunctiva: 'Normal', Cornea: 'Clear', 'Anterior Chamber': 'Deep & Quiet', Iris: 'Normal Pattern', Pupil: 'Round & Reactive', Lens: 'Clear',
  Vitreous: 'Clear', Disc: 'Healthy', Macula: 'Normal', Vessels: 'Normal', 'Peripheral Retina': 'Attached',
};

const EXAM_STRUCT_LABEL = { CDR: 'C.D Ratio' };

// Pivoted RE/LE rows (label | RE | LE), matching the Vision & Intraocular
// Pressure table's layout rather than one row per eye.
//
// mode 'abnormalOnly' (External Examination, Anterior Segment): a
// structure is only shown when at least one eye deviates from normal --
// a case sheet listing every structure as "Normal" is noise. The other
// eye still shows "Normal" alongside it for a complete row.
//
// mode 'anyData' (Posterior Segment): shown whenever either eye has
// anything recorded at all, normal or not -- Posterior/CDR findings are
// specialist, surgery-relevant readings a doctor wants on the printed
// record regardless of whether they happen to be normal.
//
// Handles both the current staged shape ({without:{...}, with:{...}})
// and the legacy flat shape from before dilatation staging existed.
function summarizeExamRegionPivoted(findingsJson, structs, mode) {
  const isStaged = findingsJson && (findingsJson.without || findingsJson.with);
  const stages = isStaged
    ? [['without', 'Without Dilatation'], ['with', 'With Dilatation']]
    : [[null, null]];

  const rows = [];
  stages.forEach(([stageKey, stageLabel]) => {
    const stageData = stageKey ? findingsJson[stageKey] : findingsJson;
    structs.forEach((struct) => {
      const f = stageData?.[struct] || {};
      const reRaw = f.re || '';
      const leRaw = f.le || '';
      const reCustom = f.re_custom || '';
      const leCustom = f.le_custom || '';
      const normal = EXAM_NORMAL_VALUE[struct];
      const reIsNormal = (!reRaw || reRaw === normal) && !reCustom;
      const leIsNormal = (!leRaw || leRaw === normal) && !leCustom;

      if (mode === 'abnormalOnly') {
        if (reIsNormal && leIsNormal) return;
        rows.push({
          structure: (EXAM_STRUCT_LABEL[struct] || struct) + (stageLabel ? ` (${stageLabel})` : ''),
          re: [reRaw, reCustom].filter(Boolean).join(' -- ') || 'Normal',
          le: [leRaw, leCustom].filter(Boolean).join(' -- ') || 'Normal',
        });
      } else {
        if (!reRaw && !leRaw && !reCustom && !leCustom) return;
        rows.push({
          structure: (EXAM_STRUCT_LABEL[struct] || struct) + (stageLabel ? ` (${stageLabel})` : ''),
          re: [reRaw, reCustom].filter(Boolean).join(' -- ') || '--',
          le: [leRaw, leCustom].filter(Boolean).join(' -- ') || '--',
        });
      }
    });
  });
  return rows;
}

const GONIO_ROW_DEFS = [
  { key: 'angle', label: 'Angle Configuration' },
  { key: 'ptm', label: 'PTM Pigmentation' },
  { key: 'iris', label: 'Iris Configuration' },
];

// Same pivoted RE/LE shape as summarizeExamRegionPivoted, but Gonioscopy
// is stored flat ({angle_re, angle_le, ...}) rather than per-structure,
// so it needs its own row builder. Shown whenever either eye has
// anything recorded.
function buildGonioscopyRows(gonioFindings) {
  const rows = [];
  if (!gonioFindings) return rows;
  // Gonioscopy used to be recorded in two passes (without/with dilatation);
  // it's now a single flat pass. Legacy staged records: read "without"
  // first (it was always the primary pass), falling back to "with" so
  // nothing already recorded is lost.
  const flat = (gonioFindings.without || gonioFindings.with) ? (gonioFindings.without || gonioFindings.with) : gonioFindings;
  GONIO_ROW_DEFS.forEach(({ key, label }) => {
    const re = flat[`${key}_re`];
    const le = flat[`${key}_le`];
    if (!re && !le) return;
    rows.push({ structure: label, re: re || '--', le: le || '--' });
  });
  return rows;
}

// Frequency-shorthand translation and taper-schedule grouping is
// imported at the top of this file (lib/prescriptionFormatting.js).

function buildOpdCaseSheetContext(settings, { patient, encounter, visit, doctor, assessment, iopReadings, examination, diagnoses, prescriptions, followup, surgicalCase }) {
  const reIop = iopReadings.find((r) => r.eye === 'RE' || r.eye === 'OD')?.value;
  const leIop = iopReadings.find((r) => r.eye === 'LE' || r.eye === 'OS')?.value;

  // Refraction on the case sheet mirrors the finalized optometry
  // prescription exactly -- Final Rx only, no fallback to
  // Subjective/Objective. Those remain measurement tabs, not what's
  // actually being prescribed to the patient.
  const distRe = buildRxCells(assessment, 'ref_final_re_dist');
  const distLe = buildRxCells(assessment, 'ref_final_le_dist');
  const nearRe = buildRxCells(assessment, 'ref_final_re_near');
  const nearLe = buildRxCells(assessment, 'ref_final_le_near');
  const cellHasData = (c) => c.sph !== '--' || c.cyl !== '--' || c.axis !== '--' || c.va !== '--';
  const hasDistRx = cellHasData(distRe) || cellHasData(distLe);
  const hasNearRx = cellHasData(nearRe) || cellHasData(nearLe);

  const followupParts = [];
  if (followup?.after_period) {
    followupParts.push(followup.after_period);
  } else if (followup?.followup_date) {
    followupParts.push(new Date(`${followup.followup_date}T00:00:00`).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' }));
  }
  if (followup?.visit_type) followupParts.push(`(${followup.visit_type})`);
  if (followup?.instructions) followupParts.push(`-- ${followup.instructions}`);

  // ── HISTORY -- Chief Complaint already existed; Ocular/Medical/Family/
  // Drug History and Allergy were captured on the encounter but never
  // made it onto the printed case sheet. ──
  const historyLines = [
    { label: 'Ocular History', items: encounter.ocular_history },
    { label: 'Medical History', items: encounter.medical_history },
    { label: 'Family History', items: encounter.family_history },
    { label: 'Drug History', items: encounter.drug_history },
    { label: 'Allergy', items: encounter.allergy },
  ].filter((h) => h.items && h.items.length > 0).map((h) => ({ label: h.label, text: h.items.join(', ') }));

  // ── OPTOMETRY -- previously only unaided/glasses vision, IOP, and
  // final refraction ("readings") made it onto the case sheet. Pinhole,
  // near vision, IOP method, additional pre-op tests, and the
  // optometrist's own recorded observations were captured but never
  // printed. ──
  const additionalTests = [
    { label: 'K1 (RE/LE)', value: (assessment?.add_k1_re || assessment?.add_k1_le) ? `${assessment?.add_k1_re || '--'} / ${assessment?.add_k1_le || '--'}` : null },
    { label: 'K2 (RE/LE)', value: (assessment?.add_k2_re || assessment?.add_k2_le) ? `${assessment?.add_k2_re || '--'} / ${assessment?.add_k2_le || '--'}` : null },
    { label: 'Axial Length (RE/LE)', value: (assessment?.add_axial_length_re || assessment?.add_axial_length_le) ? `${assessment?.add_axial_length_re || '--'} / ${assessment?.add_axial_length_le || '--'}` : null },
    { label: 'Pachymetry (RE/LE)', value: (assessment?.add_pachymetry_re || assessment?.add_pachymetry_le) ? `${assessment?.add_pachymetry_re || '--'} / ${assessment?.add_pachymetry_le || '--'}` : null },
    { label: 'Schirmer (RE/LE)', value: (assessment?.add_schirmer_re || assessment?.add_schirmer_le) ? `${assessment?.add_schirmer_re || '--'} / ${assessment?.add_schirmer_le || '--'}` : null },
    { label: 'Color Vision (RE/LE)', value: (assessment?.add_color_vision_re || assessment?.add_color_vision_le) ? `${assessment?.add_color_vision_re || '--'} / ${assessment?.add_color_vision_le || '--'}` : null },
    { label: 'Syringing (RE/LE)', value: (assessment?.add_syringing_re || assessment?.add_syringing_le) ? `${assessment?.add_syringing_re || '--'} / ${assessment?.add_syringing_le || '--'}` : null },
  ].filter((t) => t.value);

  // ── EXAMINATION -- doctor's own clinical exam (External / Anterior /
  // Posterior Segment) was captured but not printed at all. Normal
  // findings are deliberately left off -- only what's actually abnormal
  // is worth a doctor's or reviewer's attention on the printed sheet. ──
  const externalRows = examination ? summarizeExamRegionPivoted(examination.external_findings, ['Lids', 'Adnexa', 'Lacrimal', 'Motility'], 'abnormalOnly') : [];
  const anteriorRows = examination ? summarizeExamRegionPivoted(examination.anterior_findings, ['Conjunctiva', 'Cornea', 'Anterior Chamber', 'Iris', 'Pupil', 'Lens'], 'abnormalOnly') : [];
  const posteriorRows = examination ? summarizeExamRegionPivoted(examination.posterior_findings, ['Vitreous', 'Disc', 'CDR', 'Macula', 'Vessels', 'Peripheral Retina'], 'anyData') : [];
  const hasApplanation = !!(examination?.applanation_re || examination?.applanation_le);
  const gonioscopyRows = examination ? buildGonioscopyRows(examination.gonioscopy_findings) : [];

  const examExtra = [
    { label: 'Remarks (RE)', value: examination?.remarks_re },
    { label: 'Remarks (LE)', value: examination?.remarks_le },
  ].filter((e) => e.value);

  return {
    hospital_name: settings.name || 'VEDA EYE HOSPITAL',
    hospital_unit_line: settings.unit_line || '',
    hospital_regn_no: settings.regn_no || '',
    hospital_address_line1: settings.address_line1 || '',
    hospital_address_line2: settings.address_line2 || '',
    hospital_city_state_pin: settings.city_state_pin || '',
    hospital_phone: settings.phone || '',
    hospital_email: settings.email || '',
    logo_html: logoHtml(settings),

    // Printing on a pre-printed letterhead (hospital header already on
    // the paper) -- hide the digital header and leave blank space
    // matching the letterhead's own header height instead.
    hide_header: !!settings.case_sheet_hide_header,
    header_space_cm: settings.print_letterhead_space_cm ?? 5,

    patient_id: patient.patient_code || '--',
    patient_name: `${patient.first_name || ''} ${patient.last_name || ''}`.trim(),
    patient_mobile: patient.mobile || '--',
    patient_age: patient.age ?? '--',
    patient_gender: patient.gender || '--',

    visit_date: fmtDate(visit?.created_at),
    visit_type: visit?.visit_type || '--',
    doctor_name: doctor?.full_name || '--',
    doctor_regn_no: doctor?.registration_no || '--',

    chief_complaint: encounter.chief_complaint || (encounter.chief_complaint_chips || []).join(', ') || null,
    hx_duration: encounter.hx_duration || null,
    hx_laterality: encounter.hx_laterality || null,
    hx_hopi: encounter.hx_hopi || null,
    hasHistory: historyLines.length > 0,
    historyLines,

    hasVision: !!(assessment?.re_dist_unaided || assessment?.le_dist_unaided || assessment?.re_dist_glasses || assessment?.le_dist_glasses || assessment?.re_dist_ph || assessment?.le_dist_ph || assessment?.re_near_unaided || assessment?.le_near_unaided || reIop != null || leIop != null),
    hasViUnaided: !!(assessment?.re_dist_unaided || assessment?.le_dist_unaided),
    re_vision_unaided: assessment?.re_dist_unaided || '--',
    le_vision_unaided: assessment?.le_dist_unaided || '--',
    hasViGlasses: !!(assessment?.re_dist_glasses || assessment?.le_dist_glasses),
    re_vision_glasses: assessment?.re_dist_glasses || '--',
    le_vision_glasses: assessment?.le_dist_glasses || '--',
    hasViPh: !!(assessment?.re_dist_ph || assessment?.le_dist_ph),
    re_vision_ph: assessment?.re_dist_ph || '--',
    le_vision_ph: assessment?.le_dist_ph || '--',
    hasViNear: !!(assessment?.re_near_unaided || assessment?.le_near_unaided),
    re_vision_near: assessment?.re_near_unaided || '--',
    le_vision_near: assessment?.le_near_unaided || '--',
    hasIop: reIop != null || leIop != null,
    re_iop: reIop != null ? `${reIop}` : '--',
    le_iop: leIop != null ? `${leIop}` : '--',
    iop_method: assessment?.iop_method || null,
    hasVaSection: !!(assessment?.re_dist_unaided || assessment?.le_dist_unaided || assessment?.re_dist_glasses || assessment?.le_dist_glasses || assessment?.re_dist_ph || assessment?.le_dist_ph || assessment?.re_near_unaided || assessment?.le_near_unaided),
    hasDistRx,
    dist_re_sph: distRe.sph, dist_re_cyl: distRe.cyl, dist_re_axis: distRe.axis, dist_re_va: distRe.va,
    dist_le_sph: distLe.sph, dist_le_cyl: distLe.cyl, dist_le_axis: distLe.axis, dist_le_va: distLe.va,
    dist_re_prism: assessment?.ref_final_re_dist_prism || '--',
    dist_le_prism: assessment?.ref_final_le_dist_prism || '--',
    hasNearRx,
    near_re_sph: nearRe.sph, near_re_cyl: nearRe.cyl, near_re_axis: nearRe.axis, near_re_va: nearRe.va,
    near_le_sph: nearLe.sph, near_le_cyl: nearLe.cyl, near_le_axis: nearLe.axis, near_le_va: nearLe.va,
    near_re_prism: assessment?.ref_final_re_near_prism || '--',
    near_le_prism: assessment?.ref_final_le_near_prism || '--',
    near_add_re: assessment?.ref_final_re_add || '--',
    near_add_le: assessment?.ref_final_le_add || '--',
    hasGlassesSection: !!(assessment?.glasses_type || assessment?.glasses_remarks || assessment?.glasses_prescribed),
    glasses_prescribed: !!assessment?.glasses_prescribed,
    hasGlassesType: !!assessment?.glasses_type,
    glasses_type: assessment?.glasses_type || '--',
    hasGlassesRemarks: !!assessment?.glasses_remarks,
    glasses_remarks: assessment?.glasses_remarks || '',
    hasAdditionalTests: additionalTests.length > 0,
    additionalTests,
    hasOptObservations: false,
    optObservations: '',

    hasExamination: externalRows.length > 0 || anteriorRows.length > 0 || posteriorRows.length > 0 || hasApplanation || gonioscopyRows.length > 0 || examExtra.length > 0,
    hasExternal: externalRows.length > 0,
    externalRows,
    hasAnterior: anteriorRows.length > 0,
    anteriorRows,
    hasPosterior: posteriorRows.length > 0,
    posteriorRows,
    hasApplanation,
    applanation_re: examination?.applanation_re || '--',
    applanation_le: examination?.applanation_le || '--',
    hasGonioscopy: gonioscopyRows.length > 0,
    gonioscopyRows,
    hasExamExtra: examExtra.length > 0,
    examExtra,
    // Only sections that actually have data enter this list, in a fixed
    // clinical order -- then paired two-per-row for the print layout.
    // A section with nothing recorded never appears, not even as a
    // blank/placeholder column, and an odd one out spans the full row.
    examPairs: (() => {
      const sections = [];
      if (externalRows.length) sections.push({ label: 'External Examination', rows: externalRows, reHeader: 'Right Eye (RE)', leHeader: 'Left Eye (LE)' });
      if (anteriorRows.length) sections.push({ label: 'Anterior Segment', rows: anteriorRows, reHeader: 'Right Eye (RE)', leHeader: 'Left Eye (LE)' });
      if (posteriorRows.length) sections.push({ label: 'Posterior Segment', rows: posteriorRows, reHeader: 'Right Eye (RE)', leHeader: 'Left Eye (LE)' });
      if (hasApplanation) {
        sections.push({
          label: 'Applanation Tonometry (IOP)',
          rows: [{ structure: 'IOP (mmHg)', re: examination?.applanation_re || '--', le: examination?.applanation_le || '--' }],
          reHeader: 'Right (OD)', leHeader: 'Left (OS)',
        });
      }
      if (gonioscopyRows.length) sections.push({ label: 'Gonioscopy', rows: gonioscopyRows, reHeader: 'Right Eye (RE)', leHeader: 'Left Eye (LE)' });

      const pairs = [];
      for (let i = 0; i < sections.length; i += 2) pairs.push({ left: sections[i], right: sections[i + 1] || null });
      return pairs;
    })(),

    hasDiagnoses: diagnoses.length > 0,
    diagnoses: diagnoses.map((d) => ({ name: d.name, eye: d.eye, notes: d.notes })),

    // Surgery advice, if this encounter marked the patient for surgery
    // -- shows what was advised and which eye. Patient Decision is
    // intentionally not printed on the case sheet.
    hasSurgery: !!surgicalCase,
    surgery_procedure_name: surgicalCase?.procedure_name || null,
    surgery_eye: EYE_LABEL[surgicalCase?.eye] || surgicalCase?.eye || null,

    hasPrescriptions: prescriptions.length > 0,
    prescriptions: groupPrescriptionsForPrint(prescriptions),

    advice: encounter.patient_instructions || null,
    followup_text: followupParts.length > 0 ? followupParts.join(' ') : null,
  };
}

// ── DISCHARGE SUMMARY -- printed from Post-op / Recovery once a patient
//    has been discharged. Mirrors what used to be a hardcoded page
//    (app/discharge-summary-print) so it's now editable like every
//    other print template and picks up hospital branding/logo. ──
export async function renderDischargeSummaryHtml(episodeId) {
  const supabase = await createClient();

  const { data: episode, error } = await supabase
    .from('recovery_episodes')
    .select('*, surgical_cases(procedure_name, eye, visit_id, patients:patient_id(uhid, first_name, last_name, mobile, age, gender), profiles:surgeon_id(full_name, registration_no))')
    .eq('id', episodeId)
    .single();
  if (error || !episode) return { error: 'Episode not found.' };
  if (!episode.discharge_date) return { error: "This patient hasn't been discharged yet." };

  const sc = episode.surgical_cases;

  const [{ data: intraop }, { data: approval }, { data: meds }, { data: followups }] = await Promise.all([
    supabase.from('ot_intraop_records').select('implant_power, implant_manufacturer, implant_model').eq('ot_schedule_id', episode.ot_schedule_id).maybeSingle(),
    // Planned IOL comes from the surgeon's IOL Approval now, not
    // biometry_records (which no longer has any "approved" concept).
    supabase.from('iol_approvals').select('power, eye, master_iol_catalog(brand, model, category)').eq('surgical_case_id', sc?.id).eq('status', 'Approved').maybeSingle(),
    supabase.from('recovery_medications').select('*').eq('recovery_episode_id', episodeId).order('added_at'),
    supabase.from('recovery_followups').select('*').eq('recovery_episode_id', episodeId).order('scheduled_date'),
  ]);

  const settings = await getHospitalSettings();
  const context = buildDischargeSummaryContext(settings, {
    patient: sc?.patients,
    surgeon: sc?.profiles,
    procedureName: sc?.procedure_name,
    eye: sc?.eye,
    episode,
    intraop,
    biometry: approval ? [approval] : [],
    meds: meds || [],
    followups: followups || [],
  });

  const template = await getPrintTemplate('discharge_summary');
  const compiled = Handlebars.compile(template.html);
  return { html: compiled(context) };
}

function buildDischargeSummaryContext(settings, { patient, surgeon, procedureName, eye, episode, intraop, biometry, meds, followups }) {
  return {
    hospital_name: settings.name, hospital_unit_line: settings.unit_line, hospital_regn_no: settings.regn_no,
    hospital_address_line1: settings.address_line1, hospital_address_line2: settings.address_line2,
    hospital_city_state_pin: settings.city_state_pin, hospital_phone: settings.phone, hospital_email: settings.email,
    logo_html: logoHtml(settings),

    patient_id: patient?.uhid, patient_name: `${patient?.first_name || ''} ${patient?.last_name || ''}`.trim(),
    patient_age: patient?.age, patient_gender: patient?.gender, patient_mobile: patient?.mobile,

    surgeon_name: surgeon?.full_name || '--',
    surgeon_regn_no: surgeon?.registration_no || '--',
    admission_date: fmtDate(episode.admission_date),
    surgery_date: fmtDate(episode.surgery_date),
    discharge_date: fmtDate(episode.discharge_date),

    procedure_name: procedureName, eye,
    iol_lines: biometry.map((p) => ({
      eye: p.eye,
      text: `${intraop?.implant_power || p.power} D -- ${p.master_iol_catalog?.category || ''}${intraop?.implant_manufacturer ? ` -- ${intraop.implant_manufacturer} ${intraop.implant_model || ''}` : ''}`,
    })),

    hasMedications: meds.length > 0,
    medications: meds.map((m) => ({ name: m.name, sig: m.sig, eye: m.eye || 'Oral' })),

    hasDischargeNotes: !!episode.discharge_notes,
    discharge_notes: episode.discharge_notes,
    discharge_instructions: episode.discharge_instructions || 'As advised by the surgeon.',

    followups: followups.map((f) => ({ visit_label: f.visit_label, date: fmtDate(f.scheduled_date), status: f.status })),
  };
}

// ── INVESTIGATION REPORT -- printed for a completed (or unable-to-
//    perform) investigation order. Field labels mirror exactly what
//    the Investigation Workspace saves (investigation-types.js), so
//    the printed report always matches what's on screen. ──
export async function renderInvestigationHtml(orderId) {
  const supabase = await createClient();

  const { data: order, error } = await supabase
    .from('investigation_orders')
    .select('*, encounters(visit_id, doctor_id, visits(patients(uhid, first_name, last_name, mobile, age, gender)), profiles:doctor_id(full_name))')
    .eq('id', orderId)
    .single();
  if (error || !order) return { error: 'Investigation not found.' };

  const [{ data: completedBy }, { data: verifiedBy }] = await Promise.all([
    order.completed_by ? supabase.from('profiles').select('full_name').eq('id', order.completed_by).maybeSingle() : Promise.resolve({ data: null }),
    order.verified_by ? supabase.from('profiles').select('full_name').eq('id', order.verified_by).maybeSingle() : Promise.resolve({ data: null }),
  ]);

  const settings = await getHospitalSettings();
  const patient = order.encounters?.visits?.patients;
  const type = matchInvestigationType(order.name);
  const fields = getFullFieldValues(type, order.result_data);

  const context = {
    hospital_name: settings.name, hospital_unit_line: settings.unit_line, hospital_regn_no: settings.regn_no,
    hospital_address_line1: settings.address_line1, hospital_address_line2: settings.address_line2,
    hospital_city_state_pin: settings.city_state_pin, hospital_phone: settings.phone, hospital_email: settings.email,
    logo_html: logoHtml(settings),

    patient_id: patient?.uhid, patient_name: `${patient?.first_name || ''} ${patient?.last_name || ''}`.trim(),
    patient_age: patient?.age, patient_gender: patient?.gender, patient_mobile: patient?.mobile,

    investigation_name: order.name, investigation_type: type, eye: order.eye,
    doctor_name: order.encounters?.profiles?.full_name || '--',
    ordered_date: fmtDate(order.created_at), completed_date: order.completed_at ? fmtDate(order.completed_at) : '--',

    isUnable: order.status === 'Cancelled' && !!order.unable_reason,
    unable_reason: order.unable_reason,

    hasFields: fields.length > 0,
    fields,

    hasNotes: !!order.result_notes,
    result_notes: order.result_notes,

    technician_name: completedBy?.full_name || '--',
    hasVerifiedBy: !!verifiedBy?.full_name,
    verified_by_name: verifiedBy?.full_name || null,
  };

  const template = await getPrintTemplate('investigation_report');
  const compiled = Handlebars.compile(template.html);
  return { html: compiled(context) };
}

// ── MEDICINE PRESCRIPTION -- printed from Pharmacy, independent of
//    the bill. This is the patient-facing dosage sheet: what to take,
//    how much, how often (in plain language, not medical shorthand),
//    and for how long -- not prices or invoice numbers. Reuses the
//    same plainFrequency()/groupPrescriptionsForPrint() logic as the
//    OPD Case Sheet's own Prescription section, so the two always
//    read identically wherever a patient sees them. ──
export async function renderMedicinePrescriptionHtml(visitId) {
  const supabase = await createClient();

  const { data: visit, error } = await supabase
    .from('visits')
    .select('id, visit_number, doctor_id, patients(uhid, first_name, last_name, age, gender, mobile), profiles:doctor_id(full_name, registration_no)')
    .eq('id', visitId)
    .single();
  if (error || !visit) return { error: 'Visit not found.' };

  const { data: rows } = await supabase
    .from('prescriptions')
    .select('drug_name, eye, dosage, frequency, duration, taper_group_id, taper_step, encounters!inner(visit_id)')
    .eq('encounters.visit_id', visitId)
    .order('created_at', { ascending: true });

  const prescriptions = groupPrescriptionsForPrint(
    (rows || []).map((r) => ({ drug: r.drug_name, eye: r.eye, dosage: r.dosage, frequency: r.frequency, duration: r.duration, taper_group_id: r.taper_group_id, taper_step: r.taper_step }))
  );

  const settings = await getHospitalSettings();
  const patient = visit.patients;

  const context = {
    hospital_name: settings.name, hospital_unit_line: settings.unit_line, hospital_regn_no: settings.regn_no,
    hospital_address_line1: settings.address_line1, hospital_address_line2: settings.address_line2,
    hospital_city_state_pin: settings.city_state_pin, hospital_phone: settings.phone, hospital_email: settings.email,
    logo_html: logoHtml(settings),

    patient_id: patient?.uhid || '--', patient_name: `${patient?.first_name || ''} ${patient?.last_name || ''}`.trim(),
    patient_age: patient?.age ?? '--', patient_gender: patient?.gender || '--', patient_mobile: patient?.mobile || '--',
    visit_number: visit.visit_number || '--',
    print_date: fmtDate(new Date().toISOString()),

    doctor_name: visit.profiles?.full_name || '--',
    doctor_regn_no: visit.profiles?.registration_no || '--',

    hasPrescriptions: prescriptions.length > 0,
    prescriptions,
  };

  const template = await getPrintTemplate('medicine_prescription');
  const compiled = Handlebars.compile(template.html);
  return { html: compiled(context) };
}

// ── MEDICAL FITNESS FORM -- bilingual pre-op certificate, printed from
// the Medical Fitness module once a decision is made. Checkboxes are
// rendered as filled/empty Unicode box characters based on form_data. ──
function chk(flag) {
  return flag ? '\u2611' : '\u2610';
}

export async function renderMedicalFitnessFormHtml(referralId) {
  const supabase = await createClient();

  const { data: referral, error } = await supabase
    .from('medical_fitness_referrals')
    .select('*, visits(patients(first_name, last_name, uhid, age, gender)), surgical_cases(procedure_name)')
    .eq('id', referralId)
    .single();
  if (error || !referral) return { error: 'Referral not found.' };

  const patient = referral.visits?.patients;
  const fd = referral.form_data || {};
  const sys = fd.systemicHistory || {};
  const med = fd.currentMedications || {};
  const allergy = fd.allergies || {};
  const vitals = fd.vitals || {};
  const inv = fd.investigations || {};
  const cert = fd.certification || {};

  const settings = await getHospitalSettings();

  const context = {
    hospital_name: settings.name, hospital_unit_line: settings.unit_line, hospital_regn_no: settings.regn_no,
    hospital_address_line1: settings.address_line1, hospital_address_line2: settings.address_line2,
    hospital_city_state_pin: settings.city_state_pin, hospital_phone: settings.phone,
    logo_html: logoHtml(settings),

    patient_name: `${patient?.first_name || ''} ${patient?.last_name || ''}`.trim() || '--',
    patient_age: patient?.age ?? '--', patient_gender: patient?.gender || '--', patient_uhid: patient?.uhid || '--',
    surgery_type: referral.surgical_cases?.procedure_name || '--',

    box_diabetes: chk(sys.diabetes), box_hypertension: chk(sys.hypertension),
    box_heart: chk(sys.heartDisease), box_thyroid: chk(sys.thyroid),
    box_asthma: chk(sys.asthma), box_kidney: chk(sys.kidneyDisease),
    box_systemic_other: chk(!!sys.other), systemic_other_text: sys.other || '',

    previous_surgery: fd.previousSurgeryHistory || '',

    box_med_antidiabetic: chk(med.antiDiabetic), box_med_bp: chk(med.bpMedicines),
    box_med_bloodthinners: chk(med.bloodThinners),
    box_med_other: chk(!!med.other), med_other_text: med.other || '',

    box_allergy_none: chk(allergy.none), box_allergy_yes: chk(allergy.yes), allergy_details: allergy.details || '',
    allergy_notes: allergy.notes || '',

    vital_bp: vitals.bp || '--', vital_pulse: vitals.pulse || '--',
    vital_spo2: vitals.spo2 || '--', vital_blood_sugar: vitals.bloodSugar || '--',
    vital_notes: vitals.notes || '',

    inv_hb: inv.hb || '--', inv_rbs: inv.rbs || '--', inv_fbs: inv.fbs || '--', inv_ppbs: inv.ppbs || '--',
    box_hiv_nonreactive: chk(inv.hiv === 'Non-Reactive'), box_hiv_reactive: chk(inv.hiv === 'Reactive'),
    box_hbsag_nonreactive: chk(inv.hbsag === 'Non-Reactive'), box_hbsag_reactive: chk(inv.hbsag === 'Reactive'),
    inv_other: inv.other || '--',

    fitness_word: referral.status === 'Not Fit' ? 'not fit' : 'fit',
    fitness_word_hi: referral.status === 'Not Fit' ? '\u0905\u0928\u092b\u093f\u091f' : '\u092b\u093f\u091f',
    fitness_notes: referral.fitness_notes || '',

    doctor_name: cert.doctorName || '--', doctor_qualification: cert.qualification || '--',
    doctor_regn_no: cert.registrationNo || '--',
    cert_date: referral.cleared_at ? fmtDate(referral.cleared_at) : fmtDate(new Date().toISOString()),
  };

  const template = await getPrintTemplate('medical_fitness_form');
  const compiled = Handlebars.compile(template.html);
  return { html: compiled(context) };
}
