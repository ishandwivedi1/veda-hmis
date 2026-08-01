#!/bin/bash
set -e
echo "Deploying: OPD Case Sheet exam findings redesign + CDR/PTM label renames"

mkdir -p "$(dirname "app/print-templates/actions.js")"
cat > "app/print-templates/actions.js" << 'VEDA_EOF_MARKER'
'use server';

import { createClient } from '@/lib/supabase-server';
import Handlebars from 'handlebars';
import { matchInvestigationType, getFullFieldValues } from '@/app/(main)/investigation/investigation-types';

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
  invoice_opd: "<div style=\"max-width: 800px; margin: 0 auto; padding: 24px; font-family: Arial, Helvetica, sans-serif; color: #1a1a1a; font-size: 13px;\">\n\n  <!-- HEADER -->\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 6px;\">\n    <tr>\n      <td style=\"width: 100px; vertical-align: top;\">\n        {{{logo_html}}}\n      </td>\n      <td style=\"vertical-align: top;\">\n        <div style=\"font-size: 26px; font-weight: 800; letter-spacing: .3px; text-decoration: underline;\">{{hospital_name}}</div>\n        <div style=\"font-size: 12px; font-weight: 700; margin-top: 2px;\">{{hospital_unit_line}}</div>\n        <div style=\"font-size: 11px; font-weight: 700;\">REGN NO : {{hospital_regn_no}}</div>\n      </td>\n      <td style=\"text-align: right; vertical-align: top; font-size: 11px; line-height: 1.5;\">\n        {{hospital_address_line1}}<br/>\n        {{hospital_address_line2}}<br/>\n        {{hospital_city_state_pin}}<br/>\n        <br/>\n        Tel: {{hospital_phone}}<br/>\n        <strong>{{hospital_email}}</strong>\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; font-size: 16px; font-weight: 700; border-top: 1.5px solid #333; border-bottom: 1.5px solid #333; padding: 8px 0; margin: 10px 0 16px;\">\n    OPD BILL/INVOICE\n  </div>\n\n  <!-- PATIENT / BILL INFO -->\n  <table style=\"width: 100%; border: 1.5px solid #333; border-collapse: collapse; margin-bottom: 18px;\">\n    <tr>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9; border-right: 1px solid #999;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 130px; color: #444;\">PATIENT ID</td><td>: <strong>{{patient_id}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">PATIENT NAME</td><td>: <strong>{{patient_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">MOBILE NUMBER</td><td>: <strong>{{patient_mobile}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">AGE/GENDER</td><td>: <strong>{{patient_age}} / {{patient_gender}}</strong></td></tr>\n        </table>\n      </td>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 140px; color: #444;\">BILL NO</td><td>: <strong>{{bill_no}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">BILL DATE</td><td>: <strong>{{bill_date}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">VISIT DATE</td><td>: <strong>{{visit_date}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">HOSPITAL REGN NO</td><td>: <strong>{{hospital_regn_no}}</strong></td></tr>\n        </table>\n      </td>\n    </tr>\n  </table>\n\n  <!-- ITEMS -->\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 4px; font-size: 12px;\">\n    <thead>\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: center; width: 50px;\">S.NO</th>\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: left;\">Billing_Item</th>\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: center; width: 70px;\">QTY</th>\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: right; width: 110px;\">RATE</th>\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: right; width: 120px;\">AMOUNT</th>\n      </tr>\n    </thead>\n    <tbody>\n      {{#each items}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: center;\">{{sno}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px;\">{{name}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: center;\">{{qty}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: right;\">{{rate}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: right;\">{{amount}}</td>\n      </tr>\n      {{/each}}\n    </tbody>\n  </table>\n\n  <!-- TOTALS -->\n  <table style=\"width: 260px; margin: 14px 0 0 auto; border-collapse: collapse; font-size: 12px;\">\n    <tr>\n      <td style=\"border: 1px solid #999; background: #e9edf2; padding: 6px 10px; font-weight: 700;\">GROSS AMOUNT</td>\n      <td style=\"border: 1px solid #999; padding: 6px 10px; text-align: right;\">{{gross_amount}}</td>\n    </tr>\n    <tr>\n      <td style=\"border: 1px solid #999; background: #e9edf2; padding: 6px 10px; font-weight: 700;\">DISCOUNT</td>\n      <td style=\"border: 1px solid #999; padding: 6px 10px; text-align: right;\">{{discount}}</td>\n    </tr>\n    <tr>\n      <td style=\"border: 1px solid #999; background: #e9edf2; padding: 6px 10px; font-weight: 700;\">NET AMOUNT PAYABLE</td>\n      <td style=\"border: 1px solid #999; padding: 6px 10px; text-align: right; font-weight: 700;\">{{net_amount}}</td>\n    </tr>\n  </table>\n\n  <!-- SIGNATURE + PAYMENT DETAILS -->\n  <table style=\"width: 100%; margin-top: 50px; border-collapse: collapse;\">\n    <tr>\n      <td style=\"width: 45%; vertical-align: bottom; font-size: 12px;\">\n        <div>AUTHORISED SIGNATURE</div>\n        <div>FOR {{hospital_name}}</div>\n      </td>\n      <td style=\"width: 55%; vertical-align: top;\">\n        <div style=\"font-size: 12px; margin-bottom: 6px;\">Payment Details</div>\n        <table style=\"width: 100%; border-collapse: collapse; font-size: 11.5px;\">\n          <tr style=\"background: #e9edf2;\">\n            <th style=\"border: 1px solid #999; padding: 6px;\">Payment Date</th>\n            <th style=\"border: 1px solid #999; padding: 6px;\">Ref Number</th>\n            <th style=\"border: 1px solid #999; padding: 6px;\">Payment</th>\n          </tr>\n          {{#each payments}}\n          <tr>\n            <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{date}}</td>\n            <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{ref_number}}</td>\n            <td style=\"border: 1px solid #999; padding: 6px; text-align: right;\">{{amount}}</td>\n          </tr>\n          {{/each}}\n          <tr>\n            <td colspan=\"2\" style=\"border: 1px solid #999; padding: 6px; background: #e9edf2; font-weight: 700;\">Payments Received</td>\n            <td style=\"border: 1px solid #999; padding: 6px; text-align: right; font-weight: 700;\">{{total_paid}}</td>\n          </tr>\n        </table>\n      </td>\n    </tr>\n  </table>\n\n  <!-- TERMS -->\n  <div style=\"margin-top: 30px; font-size: 11.5px;\">\n    <div style=\"font-weight: 700; margin-bottom: 4px;\">Terms &amp; Conditions</div>\n    <div>{{terms_text}}</div>\n    <div style=\"margin-top: 4px;\">For any Queries please contact us at {{hospital_phone}} or Email us at {{hospital_email}}</div>\n  </div>\n\n</div>\n",
  invoice_surgery: "<div style=\"max-width: 800px; margin: 0 auto; padding: 24px; font-family: Arial, Helvetica, sans-serif; color: #1a1a1a; font-size: 13px;\">\n\n  <!-- HEADER -->\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 6px;\">\n    <tr>\n      <td style=\"width: 100px; vertical-align: top;\">\n        {{{logo_html}}}\n      </td>\n      <td style=\"vertical-align: top;\">\n        <div style=\"font-size: 26px; font-weight: 800; letter-spacing: .3px; text-decoration: underline;\">{{hospital_name}}</div>\n        <div style=\"font-size: 12px; font-weight: 700; margin-top: 2px;\">{{hospital_unit_line}}</div>\n        <div style=\"font-size: 11px; font-weight: 700;\">REGN NO : {{hospital_regn_no}}</div>\n      </td>\n      <td style=\"text-align: right; vertical-align: top; font-size: 11px; line-height: 1.5;\">\n        {{hospital_address_line1}}<br/>\n        {{hospital_address_line2}}<br/>\n        {{hospital_city_state_pin}}<br/>\n        <br/>\n        Tel: {{hospital_phone}}<br/>\n        <strong>{{hospital_email}}</strong>\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; font-size: 16px; font-weight: 700; border-top: 1.5px solid #333; border-bottom: 1.5px solid #333; padding: 8px 0; margin: 10px 0 16px;\">\n    SURGERY BILL\n  </div>\n\n  <!-- PATIENT / BILL INFO -->\n  <table style=\"width: 100%; border: 1.5px solid #333; border-collapse: collapse; margin-bottom: 18px;\">\n    <tr>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9; border-right: 1px solid #999;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 130px; color: #444;\">PATIENT ID</td><td>: <strong>{{patient_id}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">PATIENT NAME</td><td>: <strong>{{patient_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">MOBILE NUMBER</td><td>: <strong>{{patient_mobile}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">AGE/GENDER</td><td>: <strong>{{patient_age}} / {{patient_gender}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">SURGERY</td><td>: <strong>{{surgery_name}} ({{surgery_code}})</strong></td></tr>\n          <tr><td style=\"color: #444;\">OPERATED EYE</td><td>: <strong>{{eye}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">PACKAGE</td><td>: <strong>{{package_name}} ({{package_code}})</strong></td></tr>\n        </table>\n      </td>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 140px; color: #444;\">BILL NO</td><td>: <strong>{{bill_no}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">BILL DATE</td><td>: <strong>{{bill_date}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">VISIT DATE</td><td>: <strong>{{visit_date}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">DISCHARGE DATE</td><td>: <strong>{{discharge_date}}</strong></td></tr>\n          <tr><td colspan=\"2\">&nbsp;</td></tr>\n          <tr><td style=\"color: #444;\">DOCTOR NAME</td><td>: <strong>{{doctor_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">DOCTOR REGN NO</td><td>: <strong>{{doctor_regn_no}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">HOSPITAL REGN NO</td><td>: <strong>{{hospital_regn_no}}</strong></td></tr>\n        </table>\n      </td>\n    </tr>\n  </table>\n\n  <!-- ITEMS -->\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 4px; font-size: 12px;\">\n    <thead>\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: center; width: 50px;\">S.NO</th>\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: left;\">Billing_Item</th>\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: center; width: 70px;\">QTY</th>\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: right; width: 110px;\">RATE</th>\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: right; width: 120px;\">AMOUNT</th>\n      </tr>\n    </thead>\n    <tbody>\n      {{#each items}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: center;\">{{sno}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px;\">{{name}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: center;\">{{qty}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: right;\">{{rate}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: right;\">{{amount}}</td>\n      </tr>\n      {{/each}}\n    </tbody>\n  </table>\n\n  {{#if has_breakup}}\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 16px; font-size: 11.5px;\">\n    <thead>\n      <tr>\n        <th style=\"text-align: left; padding: 4px 8px; font-weight: 700; color: #555;\">Package Includes</th>\n        <th style=\"text-align: right; padding: 4px 8px; font-weight: 700; color: #555; width: 120px;\">Indicative Amount</th>\n      </tr>\n    </thead>\n    <tbody>\n      {{#each package_breakup}}\n      <tr>\n        <td style=\"padding: 3px 8px; color: #444;\">{{description}}</td>\n        <td style=\"padding: 3px 8px; text-align: right; color: #444;\">{{amount}}</td>\n      </tr>\n      {{/each}}\n    </tbody>\n  </table>\n  {{/if}}\n\n  <!-- TOTALS -->\n  <table style=\"width: 260px; margin: 14px 0 0 auto; border-collapse: collapse; font-size: 12px;\">\n    <tr>\n      <td style=\"border: 1px solid #999; background: #e9edf2; padding: 6px 10px; font-weight: 700;\">GROSS AMOUNT</td>\n      <td style=\"border: 1px solid #999; padding: 6px 10px; text-align: right;\">{{gross_amount}}</td>\n    </tr>\n    <tr>\n      <td style=\"border: 1px solid #999; background: #e9edf2; padding: 6px 10px; font-weight: 700;\">DISCOUNT</td>\n      <td style=\"border: 1px solid #999; padding: 6px 10px; text-align: right;\">{{discount}}</td>\n    </tr>\n    <tr>\n      <td style=\"border: 1px solid #999; background: #e9edf2; padding: 6px 10px; font-weight: 700;\">NET AMOUNT PAYABLE</td>\n      <td style=\"border: 1px solid #999; padding: 6px 10px; text-align: right; font-weight: 700;\">{{net_amount}}</td>\n    </tr>\n  </table>\n\n  <!-- SIGNATURE + PAYMENT DETAILS -->\n  <table style=\"width: 100%; margin-top: 50px; border-collapse: collapse;\">\n    <tr>\n      <td style=\"width: 45%; vertical-align: bottom; font-size: 12px;\">\n        <div>AUTHORISED SIGNATURE</div>\n        <div>FOR {{hospital_name}}</div>\n      </td>\n      <td style=\"width: 55%; vertical-align: top;\">\n        <div style=\"font-size: 12px; margin-bottom: 6px;\">Payment Details</div>\n        <table style=\"width: 100%; border-collapse: collapse; font-size: 11.5px;\">\n          <tr style=\"background: #e9edf2;\">\n            <th style=\"border: 1px solid #999; padding: 6px;\">Payment Date</th>\n            <th style=\"border: 1px solid #999; padding: 6px;\">Ref Number</th>\n            <th style=\"border: 1px solid #999; padding: 6px;\">Payment</th>\n          </tr>\n          {{#each payments}}\n          <tr>\n            <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{date}}</td>\n            <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{ref_number}}</td>\n            <td style=\"border: 1px solid #999; padding: 6px; text-align: right;\">{{amount}}</td>\n          </tr>\n          {{/each}}\n          <tr>\n            <td colspan=\"2\" style=\"border: 1px solid #999; padding: 6px; background: #e9edf2; font-weight: 700;\">Payments Received</td>\n            <td style=\"border: 1px solid #999; padding: 6px; text-align: right; font-weight: 700;\">{{total_paid}}</td>\n          </tr>\n        </table>\n      </td>\n    </tr>\n  </table>\n\n  <!-- TERMS -->\n  <div style=\"margin-top: 30px; font-size: 11.5px;\">\n    <div style=\"font-weight: 700; margin-bottom: 4px;\">Terms &amp; Conditions</div>\n    <div>{{terms_text}}</div>\n    <div style=\"margin-top: 4px;\">For any Queries please contact us at {{hospital_phone}} or Email us at {{hospital_email}}</div>\n  </div>\n\n</div>\n",
  receipt: "<div style=\"max-width: 650px; margin: 0 auto; padding: 24px; font-family: Arial, Helvetica, sans-serif; color: #1a1a1a; font-size: 13px;\">\n\n  <!-- HEADER -->\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 6px;\">\n    <tr>\n      <td style=\"width: 100px; vertical-align: top;\">{{{logo_html}}}</td>\n      <td style=\"vertical-align: top;\">\n        <div style=\"font-size: 22px; font-weight: 800; letter-spacing: .3px; text-decoration: underline;\">{{hospital_name}}</div>\n        <div style=\"font-size: 11px; font-weight: 700; margin-top: 2px;\">{{hospital_unit_line}}</div>\n        <div style=\"font-size: 10px; font-weight: 700;\">REGN NO : {{hospital_regn_no}}</div>\n      </td>\n      <td style=\"text-align: right; vertical-align: top; font-size: 10.5px; line-height: 1.5;\">\n        {{hospital_address_line1}}<br/>\n        {{hospital_address_line2}}<br/>\n        {{hospital_city_state_pin}}<br/>\n        Tel: {{hospital_phone}}\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; font-size: 16px; font-weight: 700; border-top: 1.5px solid #333; border-bottom: 1.5px solid #333; padding: 8px 0; margin: 10px 0 16px;\">\n    PAYMENT RECEIPT\n  </div>\n\n  <!-- RECEIVED FROM / RECEIPT INFO -->\n  <table style=\"width: 100%; border: 1.5px solid #333; border-collapse: collapse; margin-bottom: 16px;\">\n    <tr>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; border-right: 1px solid #999;\">\n        <div style=\"font-size: 10px; color: #666; text-transform: uppercase;\">Received From</div>\n        <div style=\"font-size: 14px; font-weight: 700;\">{{patient_name}}</div>\n        <div style=\"font-size: 11.5px; color: #444;\">{{patient_id}}</div>\n        <div style=\"font-size: 11.5px; color: #444;\">{{patient_mobile}}</div>\n      </td>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 90px; color: #444;\">Receipt No</td><td>: <strong>{{receipt_no}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">Date</td><td>: <strong>{{receipt_date}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">Type</td><td>: <strong>{{payment_type_label}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">Collected By</td><td>: <strong>{{collected_by}}</strong></td></tr>\n        </table>\n      </td>\n    </tr>\n  </table>\n\n  <!-- AMOUNT -->\n  <div style=\"background: #e3f5ec; border: 1.5px solid #157a4f; border-radius: 8px; padding: 14px; text-align: center; margin-bottom: 18px;\">\n    <div style=\"font-size: 10.5px; color: #157a4f; text-transform: uppercase; letter-spacing: .5px;\">Amount Received</div>\n    <div style=\"font-size: 26px; font-weight: 800; color: #157a4f;\">{{amount_received}}</div>\n    <div style=\"font-size: 11px; color: #157a4f; margin-top: 2px;\">{{amount_in_words}}</div>\n  </div>\n\n  {{#if hasAllocations}}\n  <div style=\"margin-bottom: 16px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; margin-bottom: 6px;\">Applied Against</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 12px;\">\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 6px; text-align: left;\">Invoice No</th>\n        <th style=\"border: 1px solid #999; padding: 6px; text-align: right;\">Amount Applied</th>\n      </tr>\n      {{#each allocations}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 6px;\">{{invoiceNumber}}</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: right;\">{{amount}}</td>\n      </tr>\n      {{/each}}\n    </table>\n  </div>\n  {{/if}}\n\n  <!-- PAYMENT MODES -->\n  <div style=\"margin-bottom: 16px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; margin-bottom: 6px;\">Payment Mode(s)</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 12px;\">\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 6px; text-align: left;\">Mode</th>\n        <th style=\"border: 1px solid #999; padding: 6px; text-align: right;\">Amount</th>\n      </tr>\n      {{#each modes}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 6px;\">{{mode}}</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: right;\">{{amount}}</td>\n      </tr>\n      {{/each}}\n    </table>\n  </div>\n\n  {{#if reference}}<div style=\"font-size: 11.5px; color: #444; margin-bottom: 4px;\">Reference: {{reference}}</div>{{/if}}\n  {{#if remarks}}<div style=\"font-size: 11.5px; color: #444; margin-bottom: 4px;\">Remarks: {{remarks}}</div>{{/if}}\n\n  <table style=\"width: 100%; margin-top: 50px;\">\n    <tr>\n      <td style=\"font-size: 12px;\">&nbsp;</td>\n      <td style=\"text-align: right; font-size: 12px;\">\n        <div>AUTHORISED SIGNATURE</div>\n        <div>FOR {{hospital_name}}</div>\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; margin-top: 24px; font-size: 10.5px; color: #999;\">\n    This is a computer-generated receipt.\n  </div>\n</div>\n",
  receipt_advance: "<div style=\"max-width: 650px; margin: 0 auto; padding: 24px; font-family: Arial, Helvetica, sans-serif; color: #1a1a1a; font-size: 13px;\">\n\n  <!-- HEADER -->\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 6px;\">\n    <tr>\n      <td style=\"width: 100px; vertical-align: top;\">{{{logo_html}}}</td>\n      <td style=\"vertical-align: top;\">\n        <div style=\"font-size: 22px; font-weight: 800; letter-spacing: .3px; text-decoration: underline;\">{{hospital_name}}</div>\n        <div style=\"font-size: 11px; font-weight: 700; margin-top: 2px;\">{{hospital_unit_line}}</div>\n        <div style=\"font-size: 10px; font-weight: 700;\">REGN NO : {{hospital_regn_no}}</div>\n      </td>\n      <td style=\"text-align: right; vertical-align: top; font-size: 10.5px; line-height: 1.5;\">\n        {{hospital_address_line1}}<br/>\n        {{hospital_address_line2}}<br/>\n        {{hospital_city_state_pin}}<br/>\n        Tel: {{hospital_phone}}\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; font-size: 16px; font-weight: 700; border-top: 1.5px solid #333; border-bottom: 1.5px solid #333; padding: 8px 0; margin: 10px 0 16px;\">\n    ADVANCE RECEIPT\n  </div>\n\n  <!-- RECEIVED FROM / RECEIPT INFO -->\n  <table style=\"width: 100%; border: 1.5px solid #333; border-collapse: collapse; margin-bottom: 16px;\">\n    <tr>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; border-right: 1px solid #999;\">\n        <div style=\"font-size: 10px; color: #666; text-transform: uppercase;\">Received From</div>\n        <div style=\"font-size: 14px; font-weight: 700;\">{{patient_name}}</div>\n        <div style=\"font-size: 11.5px; color: #444;\">{{patient_id}}</div>\n        <div style=\"font-size: 11.5px; color: #444;\">{{patient_mobile}}</div>\n      </td>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 90px; color: #444;\">Receipt No</td><td>: <strong>{{receipt_no}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">Date</td><td>: <strong>{{receipt_date}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">Type</td><td>: <strong>{{payment_type_label}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">Collected By</td><td>: <strong>{{collected_by}}</strong></td></tr>\n        </table>\n      </td>\n    </tr>\n  </table>\n\n  <!-- AMOUNT -->\n  <div style=\"background: #e3f5ec; border: 1.5px solid #157a4f; border-radius: 8px; padding: 14px; text-align: center; margin-bottom: 18px;\">\n    <div style=\"font-size: 10.5px; color: #157a4f; text-transform: uppercase; letter-spacing: .5px;\">Advance Amount Received</div>\n    <div style=\"font-size: 26px; font-weight: 800; color: #157a4f;\">{{amount_received}}</div>\n    <div style=\"font-size: 11px; color: #157a4f; margin-top: 2px;\">{{amount_in_words}}</div>\n  </div>\n\n  \n\n  <div style=\"background: #f6ecd7; border: 1px solid #a6791f; border-radius: 8px; padding: 10px 14px; font-size: 11.5px; color: #7d5a12; margin-bottom: 16px;\">\n    <i></i>This advance is held against {{patient_name}}\\'s account and will be adjusted against future invoices.\n  </div>\n\n  <!-- PAYMENT MODES -->\n  <div style=\"margin-bottom: 16px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; margin-bottom: 6px;\">Payment Mode(s)</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 12px;\">\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 6px; text-align: left;\">Mode</th>\n        <th style=\"border: 1px solid #999; padding: 6px; text-align: right;\">Amount</th>\n      </tr>\n      {{#each modes}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 6px;\">{{mode}}</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: right;\">{{amount}}</td>\n      </tr>\n      {{/each}}\n    </table>\n  </div>\n\n  {{#if reference}}<div style=\"font-size: 11.5px; color: #444; margin-bottom: 4px;\">Reference: {{reference}}</div>{{/if}}\n  {{#if remarks}}<div style=\"font-size: 11.5px; color: #444; margin-bottom: 4px;\">Remarks: {{remarks}}</div>{{/if}}\n\n  <table style=\"width: 100%; margin-top: 50px;\">\n    <tr>\n      <td style=\"font-size: 12px;\">&nbsp;</td>\n      <td style=\"text-align: right; font-size: 12px;\">\n        <div>AUTHORISED SIGNATURE</div>\n        <div>FOR {{hospital_name}}</div>\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; margin-top: 24px; font-size: 10.5px; color: #999;\">\n    This is a computer-generated receipt.\n  </div>\n</div>\n",
  opd_case_sheet: "<div style=\"max-width: 800px; margin: 0 auto; padding: 24px; font-family: Arial, Helvetica, sans-serif; color: #1a1a1a; font-size: 13px;\">\n\n  <!-- HEADER -->\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 6px;\">\n    <tr>\n      <td style=\"width: 100px; vertical-align: top;\">{{{logo_html}}}</td>\n      <td style=\"vertical-align: top;\">\n        <div style=\"font-size: 24px; font-weight: 800; letter-spacing: .3px; text-decoration: underline;\">{{hospital_name}}</div>\n        <div style=\"font-size: 11px; font-weight: 700; margin-top: 2px;\">{{hospital_unit_line}}</div>\n        <div style=\"font-size: 10px; font-weight: 700;\">REGN NO : {{hospital_regn_no}}</div>\n      </td>\n      <td style=\"text-align: right; vertical-align: top; font-size: 10.5px; line-height: 1.5;\">\n        {{hospital_address_line1}}<br/>\n        {{hospital_address_line2}}<br/>\n        {{hospital_city_state_pin}}<br/>\n        Tel: {{hospital_phone}}\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; font-size: 16px; font-weight: 700; border-top: 1.5px solid #333; border-bottom: 1.5px solid #333; padding: 8px 0; margin: 10px 0 16px;\">\n    OPD CASE SHEET\n  </div>\n\n  <!-- PATIENT / VISIT INFO -->\n  <table style=\"width: 100%; border: 1.5px solid #333; border-collapse: collapse; margin-bottom: 16px;\">\n    <tr>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9; border-right: 1px solid #999;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 110px; color: #444;\">PATIENT ID</td><td>: <strong>{{patient_id}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">NAME</td><td>: <strong>{{patient_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">AGE/GENDER</td><td>: <strong>{{patient_age}} / {{patient_gender}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">MOBILE</td><td>: <strong>{{patient_mobile}}</strong></td></tr>\n        </table>\n      </td>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 100px; color: #444;\">VISIT DATE</td><td>: <strong>{{visit_date}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">VISIT TYPE</td><td>: <strong>{{visit_type}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">DOCTOR</td><td>: <strong>{{doctor_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">DOCTOR REGN NO</td><td>: <strong>{{doctor_regn_no}}</strong></td></tr>\n        </table>\n      </td>\n    </tr>\n  </table>\n\n  <!-- CHIEF COMPLAINT -->\n  {{#if chief_complaint}}\n  <div style=\"margin-bottom: 14px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 3px;\">Chief Complaint</div>\n    <div style=\"font-size: 12.5px;\">{{chief_complaint}}{{#if hx_duration}} -- {{hx_duration}}{{/if}}{{#if hx_laterality}} ({{hx_laterality}}){{/if}}</div>\n    {{#if hx_hopi}}<div style=\"font-size: 12px; color: #444; margin-top: 3px;\">{{hx_hopi}}</div>{{/if}}\n  </div>\n  {{/if}}\n\n  <!-- STRUCTURED HISTORY -->\n  {{#if hasHistory}}\n  <div style=\"margin-bottom: 14px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 5px;\">History</div>\n    <table style=\"width: 100%; font-size: 12px; border-collapse: collapse;\">\n      {{#each historyLines}}\n      <tr>\n        <td style=\"padding: 2px 0; width: 130px; color: #444; vertical-align: top;\">{{label}}</td>\n        <td style=\"padding: 2px 0;\">{{text}}</td>\n      </tr>\n      {{/each}}\n    </table>\n  </div>\n  {{/if}}\n\n  <!-- VISION / IOP -->\n  {{#if hasVision}}\n  <div style=\"margin-bottom: 14px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 6px;\">Vision &amp; Intraocular Pressure</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 12px;\">\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 6px; text-align: left;\"></th>\n        <th style=\"border: 1px solid #999; padding: 6px;\">Right Eye (RE)</th>\n        <th style=\"border: 1px solid #999; padding: 6px;\">Left Eye (LE)</th>\n      </tr>\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 6px; font-weight: 600;\">Vision (Unaided)</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{re_vision_unaided}}</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{le_vision_unaided}}</td>\n      </tr>\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 6px; font-weight: 600;\">Vision (With Glasses)</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{re_vision_glasses}}</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{le_vision_glasses}}</td>\n      </tr>\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 6px; font-weight: 600;\">Vision (Pinhole)</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{re_vision_ph}}</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{le_vision_ph}}</td>\n      </tr>\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 6px; font-weight: 600;\">Vision (Near)</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{re_vision_near}}</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{le_vision_near}}</td>\n      </tr>\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 6px; font-weight: 600;\">IOP (mmHg){{#if iop_method}} -- {{iop_method}}{{/if}}</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{re_iop}}</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{le_iop}}</td>\n      </tr>\n    </table>\n  </div>\n  {{/if}}\n\n  {{#if hasDistRx}}\n  <div style=\"margin-bottom: 14px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 6px;\">Refraction (Final Rx) -- Distance</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 12px;\">\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 6px; text-align: left; width: 70px;\">Eye</th>\n        <th style=\"border: 1px solid #999; padding: 6px;\">SPH</th>\n        <th style=\"border: 1px solid #999; padding: 6px;\">CYL</th>\n        <th style=\"border: 1px solid #999; padding: 6px;\">AXIS</th>\n        <th style=\"border: 1px solid #999; padding: 6px;\">VA</th>\n      </tr>\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 6px; font-weight: 700;\">RE (OD)</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: center; font-weight: 600;\">{{dist_re_sph}}</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{dist_re_cyl}}</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{dist_re_axis}}</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{dist_re_va}}</td>\n      </tr>\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 6px; font-weight: 700;\">LE (OS)</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: center; font-weight: 600;\">{{dist_le_sph}}</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{dist_le_cyl}}</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{dist_le_axis}}</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{dist_le_va}}</td>\n      </tr>\n    </table>\n  </div>\n  {{/if}}\n\n  {{#if hasNearRx}}\n  <div style=\"margin-bottom: 14px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 6px;\">Refraction (Final Rx) -- Near</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 12px;\">\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 6px; text-align: left; width: 70px;\">Eye</th>\n        <th style=\"border: 1px solid #999; padding: 6px;\">SPH</th>\n        <th style=\"border: 1px solid #999; padding: 6px;\">CYL</th>\n        <th style=\"border: 1px solid #999; padding: 6px;\">AXIS</th>\n        <th style=\"border: 1px solid #999; padding: 6px;\">VA</th>\n      </tr>\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 6px; font-weight: 700;\">RE (OD)</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: center; font-weight: 600;\">{{near_re_sph}}</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{near_re_cyl}}</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{near_re_axis}}</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{near_re_va}}</td>\n      </tr>\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 6px; font-weight: 700;\">LE (OS)</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: center; font-weight: 600;\">{{near_le_sph}}</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{near_le_cyl}}</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{near_le_axis}}</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{near_le_va}}</td>\n      </tr>\n    </table>\n  </div>\n  {{/if}}\n\n  <!-- ADDITIONAL PRE-OP TESTS -->\n  {{#if hasAdditionalTests}}\n  <div style=\"margin-bottom: 14px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 5px;\">Additional Tests</div>\n    <table style=\"width: 100%; font-size: 12px; border-collapse: collapse;\">\n      {{#each additionalTests}}\n      <tr>\n        <td style=\"padding: 2px 0; width: 150px; color: #444;\">{{label}}</td>\n        <td style=\"padding: 2px 0;\">{{value}}</td>\n      </tr>\n      {{/each}}\n    </table>\n  </div>\n  {{/if}}\n\n  <!-- OPTOMETRY OBSERVATIONS -->\n  {{#if hasOptObservations}}\n  <div style=\"margin-bottom: 14px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 3px;\">Optometry Observations</div>\n    <div style=\"font-size: 12.5px;\">{{optObservations}}</div>\n  </div>\n  {{/if}}\n\n  <!-- EXAMINATION -->\n  {{#if hasExamination}}\n  <div style=\"margin-bottom: 14px;\">\n    <div style=\"font-size: 13px; font-weight: 700; text-transform: uppercase; color: #1e4e8c; border-bottom: 1.5px solid #1e4e8c; padding-bottom: 4px; margin-bottom: 10px;\">Examination Findings</div>\n\n    {{#if hasExternal}}\n    <div style=\"font-size: 11.5px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 6px;\">External Examination</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 12px; margin-bottom: 12px;\">\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 6px; text-align: left;\"></th>\n        <th style=\"border: 1px solid #999; padding: 6px;\">Right Eye (RE)</th>\n        <th style=\"border: 1px solid #999; padding: 6px;\">Left Eye (LE)</th>\n      </tr>\n      {{#each externalRows}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 6px; font-weight: 600;\">{{structure}}</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{re}}</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{le}}</td>\n      </tr>\n      {{/each}}\n    </table>\n    {{/if}}\n\n    {{#if hasAnterior}}\n    <div style=\"font-size: 11.5px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 6px;\">Anterior Segment</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 12px; margin-bottom: 12px;\">\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 6px; text-align: left;\"></th>\n        <th style=\"border: 1px solid #999; padding: 6px;\">Right Eye (RE)</th>\n        <th style=\"border: 1px solid #999; padding: 6px;\">Left Eye (LE)</th>\n      </tr>\n      {{#each anteriorRows}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 6px; font-weight: 600;\">{{structure}}</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{re}}</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{le}}</td>\n      </tr>\n      {{/each}}\n    </table>\n    {{/if}}\n\n    {{#if hasPosterior}}\n    <div style=\"font-size: 11.5px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 6px;\">Posterior Segment</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 12px; margin-bottom: 12px;\">\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 6px; text-align: left;\"></th>\n        <th style=\"border: 1px solid #999; padding: 6px;\">Right Eye (RE)</th>\n        <th style=\"border: 1px solid #999; padding: 6px;\">Left Eye (LE)</th>\n      </tr>\n      {{#each posteriorRows}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 6px; font-weight: 600;\">{{structure}}</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{re}}</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{le}}</td>\n      </tr>\n      {{/each}}\n    </table>\n    {{/if}}\n\n    {{#if hasGonioscopy}}\n    <div style=\"font-size: 11.5px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 6px;\">Gonioscopy</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 12px; margin-bottom: 12px;\">\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 6px; text-align: left;\"></th>\n        <th style=\"border: 1px solid #999; padding: 6px;\">Right Eye (RE)</th>\n        <th style=\"border: 1px solid #999; padding: 6px;\">Left Eye (LE)</th>\n      </tr>\n      {{#each gonioscopyRows}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 6px; font-weight: 600;\">{{structure}}</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{re}}</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{le}}</td>\n      </tr>\n      {{/each}}\n    </table>\n    {{/if}}\n\n    {{#unless hasExternal}}{{#unless hasAnterior}}{{#unless hasPosterior}}{{#unless hasGonioscopy}}\n    <div style=\"font-size: 12px; color: #666; margin-bottom: 6px;\">External Examination and Anterior Segment -- all findings within normal limits. No Posterior Segment or Gonioscopy data recorded.</div>\n    {{/unless}}{{/unless}}{{/unless}}{{/unless}}\n\n    {{#if hasExamExtra}}\n    <table style=\"width: 100%; font-size: 12px; border-collapse: collapse;\">\n      {{#each examExtra}}\n      <tr>\n        <td style=\"padding: 2px 0; width: 150px; color: #444;\">{{label}}</td>\n        <td style=\"padding: 2px 0;\">{{value}}</td>\n      </tr>\n      {{/each}}\n    </table>\n    {{/if}}\n  </div>\n  {{/if}}\n\n  <!-- DIAGNOSIS -->\n  {{#if hasDiagnoses}}\n  <div style=\"margin-bottom: 14px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 6px;\">Diagnosis</div>\n    <ul style=\"margin: 0; padding-left: 18px; font-size: 12.5px;\">\n      {{#each diagnoses}}\n      <li>{{name}} -- {{eye}}{{#if notes}} ({{notes}}){{/if}}</li>\n      {{/each}}\n    </ul>\n  </div>\n  {{/if}}\n\n  <!-- PRESCRIPTION -->\n  {{#if hasPrescriptions}}\n  <div style=\"margin-bottom: 14px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 6px;\">Prescription (Rx)</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 12px;\">\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 6px; text-align: left;\">Medicine</th>\n        <th style=\"border: 1px solid #999; padding: 6px;\">Eye</th>\n        <th style=\"border: 1px solid #999; padding: 6px;\">Dosage</th>\n        <th style=\"border: 1px solid #999; padding: 6px;\">Frequency</th>\n        <th style=\"border: 1px solid #999; padding: 6px;\">Duration</th>\n      </tr>\n      {{#each prescriptions}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 6px;\">{{drug}}</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{eye}}</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{dosage}}</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{frequency}}</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{duration}}</td>\n      </tr>\n      {{/each}}\n    </table>\n  </div>\n  {{/if}}\n\n  <!-- ADVICE -->\n  {{#if advice}}\n  <div style=\"margin-bottom: 14px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 3px;\">Advice</div>\n    <div style=\"font-size: 12.5px; white-space: pre-wrap;\">{{advice}}</div>\n  </div>\n  {{/if}}\n\n  <!-- FOLLOW UP -->\n  {{#if followup_text}}\n  <div style=\"background: #e7eff8; border: 1px solid #1e4e8c; border-radius: 8px; padding: 10px 14px; font-size: 12.5px; color: #123a66; margin-bottom: 16px;\">\n    <strong>Follow-up:</strong> {{followup_text}}\n  </div>\n  {{/if}}\n\n  <table style=\"width: 100%; margin-top: 40px;\">\n    <tr>\n      <td style=\"font-size: 12px;\">&nbsp;</td>\n      <td style=\"text-align: right; font-size: 12px;\">\n        <div>{{doctor_name}}</div>\n        <div style=\"font-size: 10.5px; color: #666;\">Reg No: {{doctor_regn_no}}</div>\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; margin-top: 20px; font-size: 10.5px; color: #999;\">\n    For any Queries please contact us at {{hospital_phone}} or Email us at {{hospital_email}}\n  </div>\n</div>\n",
  glasses_prescription: `<div style="max-width: 650px; margin: 0 auto; padding: 24px; font-family: Arial, Helvetica, sans-serif; color: #1a1a1a; font-size: 13px;">

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
    <div style="font-size: 12px; font-weight: 700; text-transform: uppercase; color: #1e4e8c; margin-bottom: 6px;">Distance</div>
    <table style="width: 100%; border-collapse: collapse; font-size: 13px;">
      <tr style="background: #e9edf2;">
        <th style="border: 1px solid #999; padding: 8px; text-align: left; width: 70px;">Eye</th>
        <th style="border: 1px solid #999; padding: 8px;">SPH</th>
        <th style="border: 1px solid #999; padding: 8px;">CYL</th>
        <th style="border: 1px solid #999; padding: 8px;">AXIS</th>
        <th style="border: 1px solid #999; padding: 8px;">VA</th>
      </tr>
      <tr>
        <td style="border: 1px solid #999; padding: 8px; font-weight: 700;">RE (OD)</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center; font-weight: 600;">{{dist_re_sph}}</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center;">{{dist_re_cyl}}</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center;">{{dist_re_axis}}</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center;">{{dist_re_va}}</td>
      </tr>
      <tr>
        <td style="border: 1px solid #999; padding: 8px; font-weight: 700;">LE (OS)</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center; font-weight: 600;">{{dist_le_sph}}</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center;">{{dist_le_cyl}}</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center;">{{dist_le_axis}}</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center;">{{dist_le_va}}</td>
      </tr>
    </table>
  </div>
  {{/if}}

  {{#if hasNearRx}}
  <div style="margin-bottom: 16px;">
    <div style="font-size: 12px; font-weight: 700; text-transform: uppercase; color: #1e4e8c; margin-bottom: 6px;">Near</div>
    <table style="width: 100%; border-collapse: collapse; font-size: 13px;">
      <tr style="background: #e9edf2;">
        <th style="border: 1px solid #999; padding: 8px; text-align: left; width: 70px;">Eye</th>
        <th style="border: 1px solid #999; padding: 8px;">SPH</th>
        <th style="border: 1px solid #999; padding: 8px;">CYL</th>
        <th style="border: 1px solid #999; padding: 8px;">AXIS</th>
        <th style="border: 1px solid #999; padding: 8px;">VA</th>
      </tr>
      <tr>
        <td style="border: 1px solid #999; padding: 8px; font-weight: 700;">RE (OD)</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center; font-weight: 600;">{{near_re_sph}}</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center;">{{near_re_cyl}}</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center;">{{near_re_axis}}</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center;">{{near_re_va}}</td>
      </tr>
      <tr>
        <td style="border: 1px solid #999; padding: 8px; font-weight: 700;">LE (OS)</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center; font-weight: 600;">{{near_le_sph}}</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center;">{{near_le_cyl}}</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center;">{{near_le_axis}}</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center;">{{near_le_va}}</td>
      </tr>
    </table>
  </div>
  {{/if}}

  {{#unless hasDistRx}}{{#unless hasNearRx}}
  <div style="padding: 20px; text-align: center; color: #9ca3af; font-size: 12px; border: 1px dashed #d1d5db; border-radius: 8px; margin-bottom: 16px;">
    No Final Rx recorded for this assessment.
  </div>
  {{/unless}}{{/unless}}

  <table style="width: 60%; margin-bottom: 20px; font-size: 12px;">
    <tr>
      <td style="padding: 4px 0; color: #444;">IPD (Interpupillary Distance)</td>
      <td style="padding: 4px 0; text-align: right; font-weight: 700;">{{ipd}}</td>
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
    IOL BIOMETRY &amp; POWER CALCULATION REPORT
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
          <tr><td style="color: #444; padding: 2px 0;">SURGEON</td><td style="padding: 2px 0;">: <strong>{{surgeon_name}}</strong></td></tr>
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
            <table style="width: 100%; font-size: 11.5px;">
              <tr><td style="color: #555; padding: 1px 0;">Axial Length</td><td style="text-align: right; font-weight: 600;">{{axl}} mm</td></tr>
              <tr><td style="color: #555; padding: 1px 0;">K1</td><td style="text-align: right; font-weight: 600;">{{k1}} D</td></tr>
              <tr><td style="color: #555; padding: 1px 0;">K2</td><td style="text-align: right; font-weight: 600;">{{k2}} D</td></tr>
              <tr><td style="color: #555; padding: 1px 0;">ACD</td><td style="text-align: right; font-weight: 600;">{{acd}} mm</td></tr>
              <tr><td style="color: #555; padding: 1px 0;">Lens Thickness</td><td style="text-align: right; font-weight: 600;">{{lt}} mm</td></tr>
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
            <table style="width: 100%; font-size: 11.5px;">
              <tr><td style="color: #555; padding: 1px 0;">Axial Length</td><td style="text-align: right; font-weight: 600;">{{axl}} mm</td></tr>
              <tr><td style="color: #555; padding: 1px 0;">K1</td><td style="text-align: right; font-weight: 600;">{{k1}} D</td></tr>
              <tr><td style="color: #555; padding: 1px 0;">K2</td><td style="text-align: right; font-weight: 600;">{{k2}} D</td></tr>
              <tr><td style="color: #555; padding: 1px 0;">ACD</td><td style="text-align: right; font-weight: 600;">{{acd}} mm</td></tr>
              <tr><td style="color: #555; padding: 1px 0;">Lens Thickness</td><td style="text-align: right; font-weight: 600;">{{lt}} mm</td></tr>
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

  <!-- IOL POWER CALCULATION -->
  {{#if hasFormulaResults}}
  <div style="font-size: 13px; font-weight: 700; color: #1e4e8c; margin-bottom: 8px; text-transform: uppercase;">IOL Power Calculation</div>
  <table style="width: 100%; border-collapse: collapse; margin-bottom: 18px; font-size: 12px;">
    <tr style="background: #e9edf2;">
      <th style="border: 1px solid #999; padding: 7px; text-align: left;">Formula</th>
      <th style="border: 1px solid #999; padding: 7px; text-align: center;">IOL Power</th>
      <th style="border: 1px solid #999; padding: 7px; text-align: center;">Predicted Refraction</th>
    </tr>
    {{#each formulaResults}}
    <tr style="{{#if isSelected}}background: #f0fdf4; font-weight: 700;{{/if}}">
      <td style="border: 1px solid #999; padding: 7px;">{{name}}{{#if isSelected}} <span style="color: #16a34a;">(Selected)</span>{{/if}}</td>
      <td style="border: 1px solid #999; padding: 7px; text-align: center;">{{power}} D</td>
      <td style="border: 1px solid #999; padding: 7px; text-align: center;">{{refraction}}</td>
    </tr>
    {{/each}}
  </table>
  {{/if}}

  <!-- FINAL APPROVED PLAN -->
  <div style="font-size: 13px; font-weight: 700; color: #16a34a; margin-bottom: 8px; text-transform: uppercase;">Final Approved Plan</div>
  <table style="width: 100%; border: 1.5px solid #16a34a; border-collapse: collapse; margin-bottom: 18px; background: #f0fdf4;">
    <tr>
      <td style="padding: 10px 14px; font-size: 12px;">
        <table style="width: 100%; font-size: 12px;">
          <tr><td style="width: 160px; color: #444; padding: 3px 0;">Final IOL Power</td><td style="padding: 3px 0;"><strong>{{final_iol_power}} D</strong></td></tr>
          <tr><td style="color: #444; padding: 3px 0;">Formula Used</td><td style="padding: 3px 0;"><strong>{{final_iol_formula}}</strong></td></tr>
          <tr><td style="color: #444; padding: 3px 0;">IOL Category</td><td style="padding: 3px 0;"><strong>{{final_iol_category}}</strong></td></tr>
          <tr><td style="color: #444; padding: 3px 0;">Lens</td><td style="padding: 3px 0;"><strong>{{final_iol_lens}}</strong></td></tr>
          <tr><td style="color: #444; padding: 3px 0;">Target Refraction</td><td style="padding: 3px 0;"><strong>{{target_refraction}}</strong></td></tr>
          {{#if surgeon_notes}}
          <tr><td style="color: #444; padding: 3px 0; vertical-align: top;">Surgeon Notes</td><td style="padding: 3px 0;">{{surgeon_notes}}</td></tr>
          {{/if}}
          <tr><td style="color: #444; padding: 3px 0;">Approved On</td><td style="padding: 3px 0;">{{approved_date}}</td></tr>
        </table>
      </td>
    </tr>
  </table>

  <table style="width: 100%; margin-top: 40px; border-collapse: collapse;">
    <tr>
      <td style="width: 100%; text-align: right; font-size: 12px; vertical-align: bottom;">
        <div style="border-top: 1px solid #9ca3af; padding-top: 6px; width: 220px; margin-left: auto;">
          <div style="font-weight: 600;">{{surgeon_name}}</div>
          <div style="font-size: 10px; color: #9ca3af;">Reg No: {{surgeon_regn_no}}</div>
        </div>
      </td>
    </tr>
  </table>

  <div style="text-align: center; margin-top: 24px; font-size: 10.5px; color: #999;">
    For any Queries please contact us at {{hospital_phone}} or Email us at {{hospital_email}}
  </div>
</div>
`,
  discharge_summary: "<div style=\"max-width: 780px; margin: 0 auto; padding: 24px; font-family: Arial, Helvetica, sans-serif; color: #1a1a1a; font-size: 13px;\">\n\n  <!-- HEADER -->\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 6px;\">\n    <tr>\n      <td style=\"width: 100px; vertical-align: top;\">{{{logo_html}}}</td>\n      <td style=\"vertical-align: top;\">\n        <div style=\"font-size: 24px; font-weight: 800; letter-spacing: .3px; text-decoration: underline; color: #0f766e;\">{{hospital_name}}</div>\n        <div style=\"font-size: 11px; font-weight: 700; margin-top: 2px;\">{{hospital_unit_line}}</div>\n        <div style=\"font-size: 10px; font-weight: 700;\">REGN NO : {{hospital_regn_no}}</div>\n      </td>\n      <td style=\"text-align: right; vertical-align: top; font-size: 10.5px; line-height: 1.5;\">\n        {{hospital_address_line1}}<br/>\n        {{hospital_address_line2}}<br/>\n        {{hospital_city_state_pin}}<br/>\n        Tel: {{hospital_phone}}\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; font-size: 16px; font-weight: 700; border-top: 1.5px solid #0f766e; border-bottom: 1.5px solid #0f766e; padding: 8px 0; margin: 10px 0 16px; color: #0f766e;\">\n    DISCHARGE SUMMARY\n  </div>\n\n  <!-- PATIENT / SURGEON INFO -->\n  <table style=\"width: 100%; border: 1.5px solid #333; border-collapse: collapse; margin-bottom: 16px;\">\n    <tr>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9; border-right: 1px solid #999;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 100px; color: #444;\">PATIENT ID</td><td>: <strong>{{patient_id}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">NAME</td><td>: <strong>{{patient_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">AGE/GENDER</td><td>: <strong>{{patient_age}} / {{patient_gender}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">MOBILE</td><td>: <strong>{{patient_mobile}}</strong></td></tr>\n        </table>\n      </td>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 100px; color: #444;\">SURGEON</td><td>: <strong>Dr. {{surgeon_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">ADMISSION</td><td>: <strong>{{admission_date}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">SURGERY DATE</td><td>: <strong>{{surgery_date}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">DISCHARGE DATE</td><td>: <strong>{{discharge_date}}</strong></td></tr>\n        </table>\n      </td>\n    </tr>\n  </table>\n\n  <!-- PROCEDURE SUMMARY -->\n  <div style=\"margin-bottom: 14px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; text-transform: uppercase; color: #0f766e; border-bottom: 1px solid #e5e7eb; padding-bottom: 4px; margin-bottom: 8px;\">Procedure Summary</div>\n    <div style=\"font-size: 13px; padding: 2px 0;\">Procedure: <strong>{{procedure_name}}</strong> ({{eye}})</div>\n    {{#each iol_lines}}\n    <div style=\"font-size: 13px; padding: 2px 0;\">IOL ({{eye}}): <strong>{{text}}</strong></div>\n    {{/each}}\n  </div>\n\n  <!-- MEDICATIONS -->\n  <div style=\"margin-bottom: 14px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; text-transform: uppercase; color: #0f766e; border-bottom: 1px solid #e5e7eb; padding-bottom: 4px; margin-bottom: 8px;\">Medications</div>\n    {{#unless hasMedications}}<div style=\"font-size: 12px; color: #9ca3af;\">None prescribed.</div>{{/unless}}\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 12px;\">\n      <tbody>\n        {{#each medications}}\n        <tr>\n          <td style=\"padding: 4px 8px 4px 0; font-weight: 600;\">{{name}}</td>\n          <td style=\"padding: 4px 0; color: #4b5563;\">{{sig}}</td>\n        </tr>\n        {{/each}}\n      </tbody>\n    </table>\n  </div>\n\n  {{#if hasDischargeNotes}}\n  <div style=\"margin-bottom: 14px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; text-transform: uppercase; color: #0f766e; border-bottom: 1px solid #e5e7eb; padding-bottom: 4px; margin-bottom: 8px;\">Discharge Notes (Doctor)</div>\n    <div style=\"font-size: 13px; white-space: pre-wrap;\">{{discharge_notes}}</div>\n  </div>\n  {{/if}}\n\n  <div style=\"margin-bottom: 14px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; text-transform: uppercase; color: #0f766e; border-bottom: 1px solid #e5e7eb; padding-bottom: 4px; margin-bottom: 8px;\">Discharge Instructions</div>\n    <div style=\"font-size: 13px; white-space: pre-wrap;\">{{discharge_instructions}}</div>\n  </div>\n\n  <div style=\"margin-bottom: 14px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; text-transform: uppercase; color: #0f766e; border-bottom: 1px solid #e5e7eb; padding-bottom: 4px; margin-bottom: 8px;\">Follow-up Schedule</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 12px;\">\n      <thead>\n        <tr style=\"background: #f0fdfa;\">\n          <th style=\"text-align: left; padding: 5px 8px; color: #0f766e;\">Visit</th>\n          <th style=\"text-align: left; padding: 5px 8px; color: #0f766e;\">Date</th>\n          <th style=\"text-align: left; padding: 5px 8px; color: #0f766e;\">Status</th>\n        </tr>\n      </thead>\n      <tbody>\n        {{#each followups}}\n        <tr>\n          <td style=\"padding: 4px 8px;\">{{visit_label}}</td>\n          <td style=\"padding: 4px 8px; color: #4b5563;\">{{date}}</td>\n          <td style=\"padding: 4px 8px; color: #4b5563;\">{{status}}</td>\n        </tr>\n        {{/each}}\n      </tbody>\n    </table>\n  </div>\n\n  <div style=\"margin-top: 50px; display: flex; justify-content: flex-end;\">\n    <div style=\"text-align: center; border-top: 1px solid #9ca3af; padding-top: 6px; width: 220px;\">\n      <div style=\"font-size: 12px; font-weight: 600;\">Dr. {{surgeon_name}}</div>\n      <div style=\"font-size: 10px; color: #9ca3af;\">Signature</div>\n    </div>\n  </div>\n\n  <div style=\"margin-top: 30px; text-align: center; font-size: 11px; color: #9ca3af;\">\n    This is a computer-generated discharge summary -- {{hospital_name}}.\n  </div>\n</div>\n",
  investigation_report: "<div style=\"max-width: 780px; margin: 0 auto; padding: 24px; font-family: Arial, Helvetica, sans-serif; color: #1a1a1a; font-size: 13px;\">\n\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 6px;\">\n    <tr>\n      <td style=\"width: 100px; vertical-align: top;\">{{{logo_html}}}</td>\n      <td style=\"vertical-align: top;\">\n        <div style=\"font-size: 24px; font-weight: 800; letter-spacing: .3px; text-decoration: underline;\">{{hospital_name}}</div>\n        <div style=\"font-size: 11px; font-weight: 700; margin-top: 2px;\">{{hospital_unit_line}}</div>\n        <div style=\"font-size: 10px; font-weight: 700;\">REGN NO : {{hospital_regn_no}}</div>\n      </td>\n      <td style=\"text-align: right; vertical-align: top; font-size: 10.5px; line-height: 1.5;\">\n        {{hospital_address_line1}}<br/>\n        {{hospital_address_line2}}<br/>\n        {{hospital_city_state_pin}}<br/>\n        Tel: {{hospital_phone}}\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; font-size: 16px; font-weight: 700; border-top: 1.5px solid #333; border-bottom: 1.5px solid #333; padding: 8px 0; margin: 10px 0 16px;\">\n    INVESTIGATION REPORT\n  </div>\n\n  <table style=\"width: 100%; border: 1.5px solid #333; border-collapse: collapse; margin-bottom: 16px;\">\n    <tr>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9; border-right: 1px solid #999;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 100px; color: #444;\">PATIENT ID</td><td>: <strong>{{patient_id}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">NAME</td><td>: <strong>{{patient_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">AGE/GENDER</td><td>: <strong>{{patient_age}} / {{patient_gender}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">MOBILE</td><td>: <strong>{{patient_mobile}}</strong></td></tr>\n        </table>\n      </td>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 110px; color: #444;\">INVESTIGATION</td><td>: <strong>{{investigation_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">TYPE</td><td>: <strong>{{investigation_type}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">EYE</td><td>: <strong>{{eye}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">ORDERED BY</td><td>: <strong>Dr. {{doctor_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">ORDERED ON</td><td>: <strong>{{ordered_date}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">COMPLETED ON</td><td>: <strong>{{completed_date}}</strong></td></tr>\n        </table>\n      </td>\n    </tr>\n  </table>\n\n  {{#if isUnable}}\n  <div style=\"background: #fef2f2; border: 1px solid #b91c1c; border-radius: 8px; padding: 10px 14px; font-size: 12.5px; color: #b91c1c; margin-bottom: 16px;\">\n    <strong>Unable to perform:</strong> {{unable_reason}}\n  </div>\n  {{else}}\n\n  <div style=\"margin-bottom: 16px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; text-transform: uppercase; color: #444; border-bottom: 1px solid #e5e7eb; padding-bottom: 4px; margin-bottom: 8px;\">Findings</div>\n    {{#if hasFields}}\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 12.5px;\">\n      <tbody>\n        {{#each fields}}\n        <tr>\n          <td style=\"padding: 5px 8px 5px 0; width: 45%; color: #444; border-bottom: 1px solid #f3f4f6;\">{{label}}</td>\n          <td style=\"padding: 5px 0; font-weight: 600; border-bottom: 1px solid #f3f4f6;\">{{value}}</td>\n        </tr>\n        {{/each}}\n      </tbody>\n    </table>\n    {{else}}\n    <div style=\"font-size: 12px; color: #9ca3af;\">No measurements recorded.</div>\n    {{/if}}\n  </div>\n\n  {{#if hasNotes}}\n  <div style=\"margin-bottom: 16px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; text-transform: uppercase; color: #444; border-bottom: 1px solid #e5e7eb; padding-bottom: 4px; margin-bottom: 8px;\">Notes</div>\n    <div style=\"font-size: 13px; white-space: pre-wrap;\">{{result_notes}}</div>\n  </div>\n  {{/if}}\n  {{/if}}\n\n  <table style=\"width: 100%; margin-top: 50px; border-collapse: collapse;\">\n    <tr>\n      <td style=\"width: 50%; vertical-align: bottom; font-size: 12px;\">\n        <div style=\"border-top: 1px solid #9ca3af; padding-top: 6px; width: 200px;\">\n          <div style=\"font-weight: 600;\">{{technician_name}}</div>\n          <div style=\"font-size: 10px; color: #9ca3af;\">Performed by</div>\n        </div>\n      </td>\n      {{#if hasVerifiedBy}}\n      <td style=\"width: 50%; vertical-align: bottom; text-align: right; font-size: 12px;\">\n        <div style=\"border-top: 1px solid #9ca3af; padding-top: 6px; width: 200px; margin-left: auto;\">\n          <div style=\"font-weight: 600;\">{{verified_by_name}}</div>\n          <div style=\"font-size: 10px; color: #9ca3af;\">Verified by</div>\n        </div>\n      </td>\n      {{/if}}\n    </tr>\n  </table>\n\n  <div style=\"margin-top: 30px; text-align: center; font-size: 10.5px; color: #999;\">\n    This is a computer-generated report -- {{hospital_name}}.\n  </div>\n</div>\n"
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
  { key: 'consent_form', name: 'Consent Form', description: 'Coming soon.', comingSoon: true },
  { key: 'discharge_summary', name: 'Discharge Summary', description: 'Printed at Post-op discharge -- procedure, IOL, medications, instructions, follow-up schedule.' },
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
  visit: { created_at: '2026-06-01T00:00:00Z' },
  doctor: { full_name: 'Dr. Nisha Bachkheti', registration_no: 'UKMC-3436' },
  lineItems: [{ service_name: 'OPD Consultation', qty: 1, rate: 300, disc: 0, net: 300, dept: 'Consultation' }],
  payments: [{ created_at: '2026-06-03T00:00:00Z', receipt_number: 'VEH/RECEIPT/-0054', amount: 300 }],
  packageName: null, packageCode: null, surgeryName: null, surgeryCode: null, surgeryEye: null, dischargeDate: null, packageBreakup: [],
};

const SAMPLE_SURGERY_RAW = {
  ...SAMPLE_OPD_RAW,
  invoice: { invoice_number: 'VEH-BILL-0200', created_at: '2026-06-10T00:00:00Z', gross: 35000, gst: 0, net: 35000, paid: 35000, purpose: 'Surgery Package' },
  lineItems: [{ service_name: 'Cataract Surgery Package', qty: 1, rate: 35000, disc: 0, net: 35000, dept: 'Surgery' }],
  payments: [{ created_at: '2026-06-10T00:00:00Z', receipt_number: 'VEH/RECEIPT/-0091', amount: 35000 }],
  packageName: 'Cataract Surgery -- Standard IOL Package', packageCode: 'PKG001',
  surgeryName: 'Phaco Cataract Surgery', surgeryCode: 'SUR012', surgeryEye: 'OD',
  dischargeDate: '2026-06-11T00:00:00Z',
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
  },
  iopReadings: [{ eye: 'RE', value: 18 }, { eye: 'LE', value: 16 }],
  examination: {
    external_findings: {}, anterior_findings: { Lens: { re: 'NS2', le: 'NS1', re_custom: '', le_custom: '' } }, posterior_findings: { without: { Disc: { re: 'Healthy', le: 'Healthy' }, CDR: { re: '0.4', le: '0.3' } }, with: {} },
    gonioscopy_findings: { without: { angle_re: 'Open Angle', angle_le: 'Open Angle' }, with: {} },
  },
  diagnoses: [{ name: 'Immature Cataract', eye: 'OU', notes: null }],
  prescriptions: [{ drug_name: 'CMC 0.5%', eye: 'BE', dosage: '1 drop', frequency: 'QID', duration: '1 month' }],
  followup: { after_period: '2 weeks', visit_type: 'Follow-up', instructions: null },
};

// Deliberately includes one eye with SPH-only (no CYL/AXIS) so the
// preview shows how a spherical-only Rx renders cleanly.
const SAMPLE_GLASSES_RX_RAW = {
  patient: { patient_code: 'VEH-P-00031', first_name: 'Dharam', last_name: '', age: 39, gender: 'Male' },
  assessment: {
    created_at: '2026-06-01T00:00:00Z', va_scale: 'Snellen', ref_pd: '62mm',
    ref_final_re_dist_sph: '-2.00', ref_final_re_dist_cyl: '-0.50', ref_final_re_dist_axis: '90', ref_final_re_dist_va: '6/6',
    ref_final_le_dist_sph: '-1.50', ref_final_le_dist_cyl: '', ref_final_le_dist_axis: '', ref_final_le_dist_va: '6/6',
    ref_final_re_near_sph: '+1.00', ref_final_re_near_cyl: '-0.50', ref_final_re_near_axis: '90', ref_final_re_near_va: 'N6',
    ref_final_le_near_sph: '+1.00', ref_final_le_near_cyl: '', ref_final_le_near_axis: '', ref_final_le_near_va: 'N6',
  },
  optometrist: { full_name: 'Rohit Pratap' },
  doctor: { full_name: 'Dr. Nisha Bachkheti', registration_no: 'UKMC-3436' },
};

const SAMPLE_BIOMETRY_RAW = {
  patient: { uhid: 'VEH000031', first_name: 'Dharam', last_name: '', age: 68, gender: 'Male' },
  visit: { visit_number: 'VN26-000112' },
  record: {
    procedure_name: 'Phacoemulsification with IOL', surgical_eye: 'RE', status: 'Approved',
    created_at: '2026-06-01T00:00:00Z', approved_at: '2026-06-02T00:00:00Z',
    measurements: {
      re: [{ device: 'ZEISS IOLMaster 700', axl: '23.45', k1: '43.25', k2: '44.10', acd: '3.12', lt: '4.50', wtw: '11.80' }],
      le: [{ device: 'ZEISS IOLMaster 700', axl: '23.38', k1: '43.40', k2: '44.05', acd: '3.08', lt: '4.48', wtw: '11.75' }],
    },
    formula_results: [
      { name: 'Barrett Universal II', power: '21.5', refraction: '-0.15' },
      { name: 'SRK/T', power: '21.0', refraction: '-0.30' },
    ],
    selected_formula: 'Barrett Universal II',
    final_iol_power: '21.5', final_iol_category: 'Monofocal', target_refraction: '-0.15 D',
    surgeon_notes: 'Aim for slight myopia. Standard monofocal, no toric correction needed.',
  },
  surgeon: { full_name: 'Dr. Nisha Bachkheti', registration_no: 'UKMC-3436' },
  catalogItem: { brand: 'Alcon', model: 'AcrySof IQ', manufacturer: 'Alcon Laboratories' },
};

// ── Renders the actual invoice HTML for a given invoiceId. Picks the
//    OPD or Surgery variant based on whether any line item was billed
//    under the Surgery department (package billing tags its line item
//    dept: 'Surgery' -- see billing/new/new-invoice-tab.js). ──
export async function renderInvoiceHtml(invoiceId, includeBreakup = false) {
  const supabase = await createClient();

  const { data: invoice, error } = await supabase
    .from('invoices')
    .select('*, patients(uhid, first_name, last_name, mobile, age, gender), visits(id, created_at, doctor_id, profiles:doctor_id(full_name, registration_no))')
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
    .select('amount, payments(receipt_number, collected_at)')
    .eq('invoice_id', invoiceId);
  const payments = (allocations || []).map((a) => ({
    amount: a.amount, receipt_number: a.payments?.receipt_number, created_at: a.payments?.collected_at,
  }));

  const isSurgery = (rawLineItems || []).some((li) => li.dept === 'Surgery');

  let packageName = null;
  let packageCode = null;
  let surgeryName = null;
  let surgeryCode = null;
  let surgeryEye = null;
  let surgeonForBill = null; // Surgery Bill shows the operating surgeon, not the visit's consulting doctor
  let packageBreakup = [];
  let breakupAvailable = false;
  let dischargeDate = null;
  if (isSurgery && invoice.visit_id) {
    // The package/surgery header shown on the bill must reflect what was
    // actually billed on THIS invoice, not whatever the surgical case's
    // package currently is -- a patient's package can be changed after
    // billing (Counselling supports this), or a case can be rebilled
    // under a different package entirely, and past invoices must not
    // silently start showing today's package on reprint. The billed
    // package name/code therefore comes straight from this invoice's own
    // Surgery line item, which is immutable once created.
    const surgeryLine = (rawLineItems || []).find((li) => li.dept === 'Surgery');
    packageName = surgeryLine?.service_name || null;
    packageCode = surgeryLine?.service_code || null;

    const { data: surgicalCase } = await supabase
      .from('surgical_cases')
      .select('id, procedure_name, eye, surgeon_id')
      .eq('visit_id', invoice.visit_id)
      .neq('status', 'Cancelled')
      .maybeSingle();

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
    if (surgicalCase) {
      // The package's own line-item breakup is tied to whatever package
      // was actually billed, not the case's current one either.
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
    doctor: isSurgery ? (surgeonForBill || invoice.visits?.profiles) : invoice.visits?.profiles,
    lineItems: lineItems || [],
    payments,
    packageName,
    packageCode,
    surgeryName,
    surgeryCode,
    surgeryEye,
    dischargeDate,
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

function buildInvoiceContext(settings, { patient, invoice, visit, doctor, lineItems, payments, packageName, packageCode, surgeryName, surgeryCode, surgeryEye, dischargeDate, packageBreakup }) {
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
    eye: surgeryEye || '--',
    package_name: packageName || '--',
    package_code: packageCode || '--',
    discharge_date: fmtDate(dischargeDate),

    bill_no: invoice.invoice_number,
    bill_date: fmtDate(invoice.created_at),
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

  const hasDistRx = !!(assessment?.ref_final_re_dist_sph || assessment?.ref_final_le_dist_sph);
  const hasNearRx = !!(assessment?.ref_final_re_near_sph || assessment?.ref_final_le_near_sph);

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

    patient_id: patient.patient_code || '--',
    patient_name: `${patient.first_name || ''} ${patient.last_name || ''}`.trim(),
    patient_age: patient.age ?? '--',
    patient_gender: patient.gender || '--',

    rx_date: fmtDate(assessment?.created_at),
    va_scale: assessment?.va_scale || 'Snellen',

    hasDistRx,
    dist_re_sph: distRe.sph, dist_re_cyl: distRe.cyl, dist_re_axis: distRe.axis, dist_re_va: distRe.va,
    dist_le_sph: distLe.sph, dist_le_cyl: distLe.cyl, dist_le_axis: distLe.axis, dist_le_va: distLe.va,

    hasNearRx,
    near_re_sph: nearRe.sph, near_re_cyl: nearRe.cyl, near_re_axis: nearRe.axis, near_re_va: nearRe.va,
    near_le_sph: nearLe.sph, near_le_cyl: nearLe.cyl, near_le_axis: nearLe.axis, near_le_va: nearLe.va,

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
    axl: s.axl || '--', k1: s.k1 || '--', k2: s.k2 || '--', acd: s.acd || '--', lt: s.lt || '--', wtw: s.wtw || '--',
  }));
}

function buildBiometryReportContext(settings, { patient, visit, record, surgeon, catalogItem }) {
  const reSets = buildBiometryReadingSets(record.measurements?.re);
  const leSets = buildBiometryReadingSets(record.measurements?.le);

  const formulaResults = (record.formula_results || []).map((r) => ({
    name: r.name, power: r.power || '--', refraction: r.refraction || '--',
    isSelected: r.name === record.selected_formula,
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
    report_date: fmtDate(record.approved_at || record.created_at),

    procedure_name: record.procedure_name || '--',
    surgical_eye: EYE_LABEL[record.surgical_eye] || record.surgical_eye || '--',
    surgeon_name: surgeon?.full_name || '--',
    surgeon_regn_no: surgeon?.registration_no || '--',

    hasReReadings: reSets.length > 0,
    reSets,
    hasLeReadings: leSets.length > 0,
    leSets,

    hasFormulaResults: formulaResults.length > 0,
    formulaResults,

    isApproved: record.status === 'Approved',
    final_iol_power: record.final_iol_power || '--',
    final_iol_formula: record.selected_formula || '--',
    final_iol_category: record.final_iol_category || '--',
    final_iol_lens: catalogItem ? `${catalogItem.brand || ''} -- ${catalogItem.model || ''}${catalogItem.manufacturer ? ` (${catalogItem.manufacturer})` : ''}`.trim() : '--',
    target_refraction: record.target_refraction || '--',
    surgeon_notes: record.surgeon_notes || null,
    approved_date: record.approved_at ? fmtDate(record.approved_at) : '--',
  };
}

export async function renderBiometryReportHtml(recordId) {
  const supabase = await createClient();

  const { data: record, error } = await supabase
    .from('biometry_records')
    .select('*, visits(id, visit_number, patients(uhid, first_name, last_name, age, gender)), master_iol_catalog(brand, model, manufacturer)')
    .eq('id', recordId)
    .single();
  if (error || !record) return { error: 'Biometry record not found.' };

  // The report is only printable once approved, so prefer whoever
  // actually approved the plan (approved_by is guaranteed set at that
  // point) over surgeon_id, which is only set from the visit's assigned
  // doctor at record-creation time and is often still empty.
  let surgeon = null;
  const doctorProfileId = record.approved_by || record.surgeon_id;
  if (doctorProfileId) {
    const { data: doc } = await supabase.from('profiles').select('full_name, registration_no').eq('id', doctorProfileId).maybeSingle();
    surgeon = doc;
  }

  const settings = await getHospitalSettings();
  const context = buildBiometryReportContext(settings, {
    patient: record.visits?.patients || {},
    visit: record.visits,
    record,
    surgeon,
    catalogItem: record.master_iol_catalog,
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

const EXAM_STRUCT_LABEL = { CDR: 'C>D Ratio' };

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
// and the legacy flat shape from before dilation staging existed.
function summarizeExamRegionPivoted(findingsJson, structs, mode) {
  const isStaged = findingsJson && (findingsJson.without || findingsJson.with);
  const stages = isStaged
    ? [['without', 'Without Dilation'], ['with', 'With Dilation']]
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
// anything recorded, same "any data" rule as Posterior.
function buildGonioscopyRows(gonioFindings) {
  const rows = [];
  [['without', 'Without Dilation'], ['with', 'With Dilation']].forEach(([stageKey, stageLabel]) => {
    const stageData = gonioFindings?.[stageKey];
    if (!stageData) return;
    GONIO_ROW_DEFS.forEach(({ key, label }) => {
      const re = stageData[`${key}_re`];
      const le = stageData[`${key}_le`];
      if (!re && !le) return;
      rows.push({ structure: `${label} (${stageLabel})`, re: re || '--', le: le || '--' });
    });
  });
  return rows;
}

function buildOpdCaseSheetContext(settings, { patient, encounter, visit, doctor, assessment, iopReadings, examination, diagnoses, prescriptions, followup }) {
  const reIop = iopReadings.find((r) => r.eye === 'RE' || r.eye === 'OD')?.value;
  const leIop = iopReadings.find((r) => r.eye === 'LE' || r.eye === 'OS')?.value;

  const distRe = buildRxCells(assessment, 'ref_final_re_dist');
  const distLe = buildRxCells(assessment, 'ref_final_le_dist');
  const nearRe = buildRxCells(assessment, 'ref_final_re_near');
  const nearLe = buildRxCells(assessment, 'ref_final_le_near');
  const hasDistRx = !!(assessment?.ref_final_re_dist_sph || assessment?.ref_final_le_dist_sph);
  const hasNearRx = !!(assessment?.ref_final_re_near_sph || assessment?.ref_final_le_near_sph);

  const followupParts = [];
  if (followup?.after_period) followupParts.push(followup.after_period);
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

    hasVision: !!assessment,
    re_vision_unaided: assessment?.re_dist_unaided || '--',
    le_vision_unaided: assessment?.le_dist_unaided || '--',
    re_vision_glasses: assessment?.re_dist_glasses || '--',
    le_vision_glasses: assessment?.le_dist_glasses || '--',
    re_vision_ph: assessment?.re_dist_ph || '--',
    le_vision_ph: assessment?.le_dist_ph || '--',
    re_vision_near: assessment?.re_near_unaided || '--',
    le_vision_near: assessment?.le_near_unaided || '--',
    re_iop: reIop != null ? `${reIop}` : '--',
    le_iop: leIop != null ? `${leIop}` : '--',
    iop_method: assessment?.iop_method || null,
    hasDistRx,
    dist_re_sph: distRe.sph, dist_re_cyl: distRe.cyl, dist_re_axis: distRe.axis, dist_re_va: distRe.va,
    dist_le_sph: distLe.sph, dist_le_cyl: distLe.cyl, dist_le_axis: distLe.axis, dist_le_va: distLe.va,
    hasNearRx,
    near_re_sph: nearRe.sph, near_re_cyl: nearRe.cyl, near_re_axis: nearRe.axis, near_re_va: nearRe.va,
    near_le_sph: nearLe.sph, near_le_cyl: nearLe.cyl, near_le_axis: nearLe.axis, near_le_va: nearLe.va,
    hasAdditionalTests: additionalTests.length > 0,
    additionalTests,
    hasOptObservations: false,
    optObservations: '',

    hasExamination: externalRows.length > 0 || anteriorRows.length > 0 || posteriorRows.length > 0 || gonioscopyRows.length > 0 || examExtra.length > 0,
    hasExternal: externalRows.length > 0,
    externalRows,
    hasAnterior: anteriorRows.length > 0,
    anteriorRows,
    hasPosterior: posteriorRows.length > 0,
    posteriorRows,
    hasGonioscopy: gonioscopyRows.length > 0,
    gonioscopyRows,
    hasExamExtra: examExtra.length > 0,
    examExtra,

    hasDiagnoses: diagnoses.length > 0,
    diagnoses: diagnoses.map((d) => ({ name: d.name, eye: d.eye, notes: d.notes })),

    hasPrescriptions: prescriptions.length > 0,
    prescriptions: prescriptions.map((p) => ({ drug: p.drug, eye: p.eye, dosage: p.dosage, frequency: p.frequency, duration: p.duration })),

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
    .select('*, surgical_cases(procedure_name, eye, visit_id, patients:patient_id(uhid, first_name, last_name, mobile, age, gender), profiles:surgeon_id(full_name))')
    .eq('id', episodeId)
    .single();
  if (error || !episode) return { error: 'Episode not found.' };
  if (!episode.discharge_date) return { error: "This patient hasn't been discharged yet." };

  const sc = episode.surgical_cases;

  const [{ data: intraop }, { data: biometry }, { data: meds }, { data: followups }] = await Promise.all([
    supabase.from('ot_intraop_records').select('implant_power, implant_manufacturer, implant_model').eq('ot_schedule_id', episode.ot_schedule_id).maybeSingle(),
    supabase.from('biometry_records').select('final_iol_power, final_iol_category, surgical_eye').eq('visit_id', sc?.visit_id).eq('status', 'Approved'),
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
    biometry: biometry || [],
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
    admission_date: fmtDate(episode.admission_date),
    surgery_date: fmtDate(episode.surgery_date),
    discharge_date: fmtDate(episode.discharge_date),

    procedure_name: procedureName, eye,
    iol_lines: biometry.map((p) => ({
      eye: p.surgical_eye,
      text: `${intraop?.implant_power || p.final_iol_power} D -- ${p.final_iol_category}${intraop?.implant_manufacturer ? ` -- ${intraop.implant_manufacturer} ${intraop.implant_model || ''}` : ''}`,
    })),

    hasMedications: meds.length > 0,
    medications: meds.map((m) => ({ name: m.name, sig: m.sig })),

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

VEDA_EOF_MARKER

mkdir -p "$(dirname "app/consultation/[id]/examination-tab.js")"
cat > "app/consultation/[id]/examination-tab.js" << 'VEDA_EOF_MARKER'
'use client';

import { useState, useEffect, useRef } from 'react';
import { saveExamination } from '@/app/(main)/consultation/actions';

const EXT_STRUCTS = ['Lids', 'Adnexa', 'Lacrimal', 'Motility'];
const EXT_TEMPLATES = {
  Lids: ['Normal', 'Blepharitis', 'Ptosis', 'Entropion', 'Ectropion', 'Chalazion', 'Stye'],
  Adnexa: ['Normal', 'Swelling', 'Mass'],
  Lacrimal: ['Patent', 'Watering', 'Blocked', 'Dacryocystitis'],
  Motility: ['Full', 'Restriction', 'Squint', 'Nystagmus'],
};
const ANT_STRUCTS = ['Conjunctiva', 'Cornea', 'Anterior Chamber', 'Iris', 'Pupil', 'Lens'];
const ANT_TEMPLATES = {
  Conjunctiva: ['Normal', 'Congested', 'PCVO', 'Pterygium', 'Subconjunctival haemorrhage'],
  Cornea: ['Clear', 'Scar', 'Ulcer', 'Edema', 'Pterygium', 'Guttata', 'Keratitis'],
  'Anterior Chamber': ['Deep & Quiet', 'Shallow', 'Cells+', 'Hypopyon', 'Hyphema'],
  Iris: ['Normal Pattern', 'Rubeosis', 'Heterochromia', 'Synechiae'],
  Pupil: ['Round & Reactive', 'RAPD', 'Irregular', 'Fixed & Dilated'],
  Lens: ['Clear', 'NS1', 'NS2', 'NS3', 'NS4', 'PSC', 'Cortical', 'Mature', 'Hypermature', 'PCIOL', 'Aphakia'],
};

// Posterior Segment struct list differs by dilation stage: a full exam
// under dilation, but only Disc (+ a CDR estimate) makes sense to
// record without dilation.
const POST_STRUCTS_WITH = ['Vitreous', 'Disc', 'CDR', 'Macula', 'Vessels', 'Peripheral Retina'];
const POST_STRUCTS_WITHOUT = ['Disc', 'CDR'];
const POST_TEMPLATES = {
  Vitreous: ['Clear', 'Haze', 'Haemorrhage', 'PVD'],
  Disc: ['Healthy', 'Pale', 'Cupped', 'Swollen', 'Tilted'],
  Macula: ['Normal', 'ARMD', 'CSME', 'Macular Hole', 'Epiretinal Membrane', 'Scar'],
  Vessels: ['Normal', 'Arteriovenous nipping', 'Disc collaterals'],
  'Peripheral Retina': ['Attached', 'Lattice', 'Tear', 'Detachment', 'Laser Marks'],
  CDR: ['0.1', '0.2', '0.3', '0.4', '0.5', '0.6', '0.7', '0.8', '0.9', 'GOA'],
};
// Structs rendered as a dropdown instead of the usual pill row.
const POST_SELECT_STRUCTS = ['CDR'];

const REGIONS = {
  external: { structs: EXT_STRUCTS, templates: EXT_TEMPLATES, icon: 'ti-user', color: 'var(--g400)', title: 'External Examination', staged: false },
  anterior: { structs: ANT_STRUCTS, templates: ANT_TEMPLATES, icon: 'ti-microscope', color: 'var(--teal)', title: 'Anterior Segment', staged: false },
  posterior: {
    structsByStage: { without: POST_STRUCTS_WITHOUT, with: POST_STRUCTS_WITH },
    templates: POST_TEMPLATES, selectStructs: POST_SELECT_STRUCTS,
    icon: 'ti-eye', color: 'var(--purple)', title: 'Posterior Segment', staged: true,
  },
};

// ── GONIOSCOPY (replaces the old Glaucoma section entirely) ──
const ANGLE_OPTIONS = ['Open Angle', 'Occludable', 'Closed Angle', 'Synechiae', 'Iris Process'];
const PTM_OPTIONS = ['+1', '+2', '+3'];
const IRIS_CONFIG_OPTIONS = ['Concave', 'Convex', 'Regular'];
const GONIO_FIELDS = [
  { key: 'angle', label: 'Angle Configuration', options: ANGLE_OPTIONS },
  { key: 'ptm', label: 'PTM Pigmentation', options: PTM_OPTIONS },
  { key: 'iris', label: 'Iris Configuration', options: IRIS_CONFIG_OPTIONS },
];
function emptyGonioStage() {
  const s = { copy_re_to_le: false };
  GONIO_FIELDS.forEach((f) => { s[`${f.key}_re`] = ''; s[`${f.key}_le`] = ''; });
  return s;
}
function emptyGonioState() {
  return { without: emptyGonioStage(), with: emptyGonioStage() };
}
function normalizeGonioStage(raw) {
  const s = emptyGonioStage();
  if (!raw) return s;
  s.copy_re_to_le = !!raw.copy_re_to_le;
  GONIO_FIELDS.forEach((f) => {
    s[`${f.key}_re`] = raw[`${f.key}_re`] || '';
    s[`${f.key}_le`] = raw[`${f.key}_le`] || '';
  });
  return s;
}
function normalizeGonioFindings(raw) {
  const isStaged = raw && (raw.without || raw.with);
  if (isStaged) return { without: normalizeGonioStage(raw.without), with: normalizeGonioStage(raw.with) };
  // Nothing staged yet (brand new record) -- both passes start empty.
  return emptyGonioState();
}

const STAGES = [
  { key: 'without', label: 'Without Dilation' },
  { key: 'with', label: 'With Dilation' },
];

function emptyRegionState(structs) {
  const state = {};
  structs.forEach((s) => { state[s] = { re: '', le: '', re_custom: '', le_custom: '' }; });
  return state;
}

function normalizeFindings(raw, structs) {
  const out = {};
  structs.forEach((s) => {
    const v = raw?.[s] || {};
    out[s] = { re: v.re || '', le: v.le || '', re_custom: v.re_custom || '', le_custom: v.le_custom || '' };
  });
  return out;
}

// External & Anterior are a single pass now (no dilation stage). Some
// records saved while this was still staged have {without, with} --
// read "without" first (it was always the primary/first pass), and
// otherwise fall back to "with" so nothing already recorded is lost.
// New saves are written flat going forward.
function normalizeFlatFindings(raw, structs) {
  const source = raw && (raw.without || raw.with) ? (raw.without || raw.with) : raw;
  return { ...emptyRegionState(structs), ...normalizeFindings(source, structs) };
}

// Posterior Segment keeps the two-pass without/with dilation split, but
// the struct list differs per stage (see structsByStage). Legacy flat
// data (from before staging existed) used the full struct set, so it's
// treated as the "with dilation" pass -- mapping it to "without"
// (Disc/CDR only) would silently drop Vitreous/Macula/Vessels/Periphery.
function emptyStagedRegionState(structsByStage) {
  return { without: emptyRegionState(structsByStage.without), with: emptyRegionState(structsByStage.with) };
}
function normalizeStagedFindings(raw, structsByStage) {
  const isStaged = raw && (raw.without || raw.with);
  if (isStaged) {
    return {
      without: { ...emptyRegionState(structsByStage.without), ...normalizeFindings(raw.without, structsByStage.without) },
      with: { ...emptyRegionState(structsByStage.with), ...normalizeFindings(raw.with, structsByStage.with) },
    };
  }
  return {
    without: emptyRegionState(structsByStage.without),
    with: { ...emptyRegionState(structsByStage.with), ...normalizeFindings(raw, structsByStage.with) },
  };
}

// Storage key stays 'CDR' (matches the DB column/struct list), but
// displays as "C>D Ratio" everywhere -- on screen and in print.
const STRUCT_DISPLAY_LABEL = { CDR: 'C>D Ratio' };

function StructRow({ struct, templates, eyeState, onSelect, onCustom, asSelect }) {
  const options = templates[struct] || [];
  const displayLabel = STRUCT_DISPLAY_LABEL[struct] || struct;

  if (asSelect) {
    return (
      <div style={{ display: 'grid', gridTemplateColumns: '110px 1fr', gap: 8, alignItems: 'center', padding: '6px 0', borderBottom: '1px solid var(--g100)' }}>
        <div style={{ fontSize: 12, fontWeight: 600, color: 'var(--g700)' }}>{displayLabel}</div>
        <select className="fi fi-sm" style={{ maxWidth: 160 }} value={eyeState.value} onChange={(e) => onSelect(e.target.value)}>
          <option value="">--</option>
          {options.map((opt) => <option key={opt} value={opt}>{opt}</option>)}
        </select>
      </div>
    );
  }

  return (
    <div style={{ display: 'grid', gridTemplateColumns: '110px 1fr', gap: 8, alignItems: 'center', padding: '6px 0', borderBottom: '1px solid var(--g100)' }}>
      <div style={{ fontSize: 12, fontWeight: 600, color: 'var(--g700)' }}>{displayLabel}</div>
      <div style={{ display: 'flex', flexWrap: 'wrap', gap: 4, alignItems: 'center' }}>
        {options.map((opt) => (
          <div
            key={opt}
            onClick={() => onSelect(opt)}
            style={{
              padding: '3px 9px', borderRadius: 20, fontSize: 11, fontWeight: 600, cursor: 'pointer',
              border: `1.5px solid ${eyeState.value === opt ? 'var(--blue)' : 'var(--g200)'}`,
              background: eyeState.value === opt ? 'var(--blue)' : '#fff',
              color: eyeState.value === opt ? '#fff' : 'var(--g600)',
            }}
          >
            {opt}
          </div>
        ))}
        <input
          type="text"
          className="fi fi-sm"
          style={{ width: 100 }}
          placeholder="Custom..."
          value={eyeState.custom}
          onChange={(e) => onCustom(e.target.value)}
        />
      </div>
    </div>
  );
}

function StageToggle({ stage, onChange }) {
  return (
    <div style={{ display: 'flex', gap: 2, background: 'var(--g100)', borderRadius: 6, padding: 2 }} onClick={(e) => e.stopPropagation()}>
      {STAGES.map((s) => (
        <button
          key={s.key}
          type="button"
          onClick={() => onChange(s.key)}
          style={{
            padding: '3px 9px', borderRadius: 4, fontSize: 10.5, fontWeight: 600, border: 'none', cursor: 'pointer',
            background: stage === s.key ? '#fff' : 'transparent',
            color: stage === s.key ? 'var(--blue)' : 'var(--g500)',
            boxShadow: stage === s.key ? '0 1px 3px rgba(0,0,0,.1)' : 'none',
          }}
        >
          {s.label}
        </button>
      ))}
    </div>
  );
}

function RegionSection({ regionKey, region, open, onToggle, status, stagedState, stage, onStageChange, onSelect, onCustom, onAllNormal, allNormalOn }) {
  const staged = region.staged;
  const state = staged ? stagedState[stage] : stagedState;
  const structs = staged ? region.structsByStage[stage] : region.structs;
  const selectStructs = region.selectStructs || [];

  return (
    <div className="card" style={{ padding: 0, overflow: 'hidden', marginBottom: 12 }}>
      <div
        style={{ padding: '12px 16px', background: 'var(--g50)', borderBottom: open ? '1px solid var(--g200)' : 'none', display: 'flex', alignItems: 'center', justifyContent: 'space-between', cursor: 'pointer', flexWrap: 'wrap', gap: 8 }}
        onClick={onToggle}
      >
        <div style={{ fontSize: 13, fontWeight: 700, color: 'var(--g800)', display: 'flex', alignItems: 'center', gap: 8 }}>
          <i className={`ti ${region.icon}`} style={{ color: region.color }}></i>
          {region.title}
          <span className={`badge ${status === 'Normal' ? 'b-green' : status === 'In progress' ? 'b-amber' : 'b-gray'}`}>{status}</span>
        </div>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
          {staged && <StageToggle stage={stage} onChange={onStageChange} />}
          <button
            type="button"
            className="btn btn-sm"
            style={{ background: allNormalOn ? 'var(--green)' : '#fff', color: allNormalOn ? '#fff' : 'var(--green)', border: '1.5px solid var(--green)' }}
            onClick={(e) => { e.stopPropagation(); onAllNormal(); }}
          >
            <i className={`ti ti-${allNormalOn ? 'square-check' : 'square'}`}></i> All Normal
          </button>
          <i className={`ti ti-chevron-${open ? 'up' : 'down'}`} style={{ color: 'var(--g400)' }}></i>
        </div>
      </div>
      {open && (
        <div style={{ padding: 16, background: staged && stage === 'with' ? 'var(--purple-lt)' : '#fff', transition: 'background .15s ease' }}>
          {staged && (
            <div style={{ fontSize: 11, fontWeight: 700, color: stage === 'with' ? 'var(--purple)' : 'var(--g500)', marginBottom: 10 }}>
              <i className="ti ti-droplet"></i> Recording: {STAGES.find((s) => s.key === stage)?.label}
            </div>
          )}
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 20 }}>
            {['re', 'le'].map((eye) => (
              <div key={eye}>
                <div style={{ fontSize: 11, fontWeight: 700, color: eye === 're' ? 'var(--blue)' : 'var(--teal)', marginBottom: 6, padding: '4px 8px', background: eye === 're' ? 'var(--blue-lt)' : 'var(--teal-lt)', borderRadius: 6, display: 'inline-block' }}>
                  <i className="ti ti-eye" style={{ fontSize: 11 }}></i> {eye === 're' ? 'Right Eye (OD)' : 'Left Eye (OS)'}
                </div>
                {structs.map((struct) => (
                  <StructRow
                    key={struct}
                    struct={struct}
                    templates={region.templates}
                    asSelect={selectStructs.includes(struct)}
                    eyeState={{ value: state[struct]?.[eye] || '', custom: state[struct]?.[`${eye}_custom`] || '' }}
                    onSelect={(val) => onSelect(struct, eye, val)}
                    onCustom={(val) => onCustom(struct, eye, val)}
                  />
                ))}
              </div>
            ))}
          </div>
        </div>
      )}
    </div>
  );
}

export default function ExaminationTab({ examination, encounterId, onSaved }) {
  const [regionState, setRegionState] = useState({
    external: emptyRegionState(EXT_STRUCTS),
    anterior: emptyRegionState(ANT_STRUCTS),
    posterior: emptyStagedRegionState(REGIONS.posterior.structsByStage),
  });
  const [regionStage, setRegionStage] = useState({ posterior: 'without' });
  const [status, setStatus] = useState({ external: 'Not started', anterior: 'Not started', posterior: 'Not started', gonioscopy: 'Not started' });
  const [open, setOpen] = useState({ external: true, anterior: false, posterior: false, gonioscopy: false, remarks: false });
  // Tracks whether "All Normal" is currently toggled on, so it can be
  // unticked (reverts fields to empty) instead of being a one-way action.
  // External/Anterior: one flag. Posterior: one per stage, since Without
  // and With Dilation are recorded and toggled independently.
  const [allNormalOn, setAllNormalOn] = useState({ external: false, anterior: false, posterior: { without: false, with: false } });

  const [gonioStage, setGonioStage] = useState('without');
  const [gonioState, setGonioState] = useState(emptyGonioState());
  const [remarksRe, setRemarksRe] = useState('');
  const [remarksLe, setRemarksLe] = useState('');

  // 'idle' | 'pending' | 'saving' | 'saved' | 'error'
  const [saveState, setSaveState] = useState('idle');
  const saveTimer = useRef(null);
  const skipNextAutosave = useRef(true);
  const loadedExamId = useRef(null);

  useEffect(() => {
    if (!examination) return;
    skipNextAutosave.current = true;
    loadedExamId.current = examination.id;
    setRegionState({
      external: normalizeFlatFindings(examination.external_findings, EXT_STRUCTS),
      anterior: normalizeFlatFindings(examination.anterior_findings, ANT_STRUCTS),
      posterior: normalizeStagedFindings(examination.posterior_findings, REGIONS.posterior.structsByStage),
    });
    setStatus({
      external: examination.external_status || 'Not started',
      anterior: examination.anterior_status || 'Not started',
      posterior: examination.posterior_status || 'Not started',
      gonioscopy: examination.glaucoma_status || 'Not started',
    });
    setGonioState(normalizeGonioFindings(examination.gonioscopy_findings));
    setRemarksRe(examination.remarks_re || '');
    setRemarksLe(examination.remarks_le || '');
  }, [examination]);

  function markDirty(region) {
    setStatus((prev) => (prev[region] === 'Not started' ? { ...prev, [region]: 'In progress' } : prev));
  }

  function handleSelect(region, struct, eye, val) {
    setRegionState((prev) => {
      if (!REGIONS[region].staged) {
        return { ...prev, [region]: { ...prev[region], [struct]: { ...prev[region][struct], [eye]: val } } };
      }
      const stage = regionStage[region];
      return { ...prev, [region]: { ...prev[region], [stage]: { ...prev[region][stage], [struct]: { ...prev[region][stage][struct], [eye]: val } } } };
    });
    markDirty(region);
  }

  function handleCustom(region, struct, eye, val) {
    setRegionState((prev) => {
      if (!REGIONS[region].staged) {
        return { ...prev, [region]: { ...prev[region], [struct]: { ...prev[region][struct], [`${eye}_custom`]: val } } };
      }
      const stage = regionStage[region];
      return { ...prev, [region]: { ...prev[region], [stage]: { ...prev[region][stage], [struct]: { ...prev[region][stage][struct], [`${eye}_custom`]: val } } } };
    });
    markDirty(region);
  }

  // Toggle -- clicking again unticks it: fields clear back to empty and
  // status reverts to Not started, rather than being a one-way action.
  function handleAllNormal(region) {
    const { templates, staged } = REGIONS[region];
    const stage = staged ? regionStage[region] : null;
    const structs = staged ? REGIONS[region].structsByStage[stage] : REGIONS[region].structs;
    const isOn = staged ? allNormalOn[region][stage] : allNormalOn[region];

    let next;
    if (isOn) {
      next = emptyRegionState(structs);
    } else {
      next = {};
      structs.forEach((s) => {
        // CDR has no sensible "normal" default (it's a measured ratio),
        // so All Normal skips it and leaves it for the doctor to enter.
        const normalVal = (REGIONS.posterior.selectStructs || []).includes(s) ? '' : (templates[s]?.[0] || '');
        next[s] = { re: normalVal, le: normalVal, re_custom: '', le_custom: '' };
      });
    }

    setRegionState((prev) => (staged
      ? { ...prev, [region]: { ...prev[region], [stage]: next } }
      : { ...prev, [region]: next }));
    setStatus((prev) => ({ ...prev, [region]: isOn ? 'Not started' : 'Normal' }));
    setAllNormalOn((prev) => (staged
      ? { ...prev, [region]: { ...prev[region], [stage]: !isOn } }
      : { ...prev, [region]: !isOn }));
  }

  function applyFavorite(fav) {
    if (fav === 'normal') { handleAllNormal('external'); handleAllNormal('anterior'); handleAllNormal('posterior'); }
    else if (fav === 'cataract') { handleAllNormal('external'); handleAllNormal('anterior'); handleAllNormal('posterior'); setOpen((p) => ({ ...p, anterior: true })); }
    else if (fav === 'glaucoma') { setOpen((p) => ({ ...p, gonioscopy: true })); }
    else if (fav === 'postop') { handleAllNormal('anterior'); handleAllNormal('posterior'); }
  }

  // Autosave: debounced ~1.2s after the last change to any field. No
  // Save button -- this is the only way examination findings get
  // written.
  useEffect(() => {
    if (!examination) return;
    if (skipNextAutosave.current) { skipNextAutosave.current = false; return; }

    setSaveState('pending');
    if (saveTimer.current) clearTimeout(saveTimer.current);
    const examIdAtSchedule = examination.id;

    saveTimer.current = setTimeout(async () => {
      setSaveState('saving');
      const gonioHasData = ['without', 'with'].some((st) => GONIO_FIELDS.some((f) => gonioState[st][`${f.key}_re`] || gonioState[st][`${f.key}_le`]));
      const fields = {
        external_findings: regionState.external,
        external_status: status.external,
        anterior_findings: regionState.anterior,
        anterior_status: status.anterior,
        posterior_findings: regionState.posterior,
        posterior_status: status.posterior,
        gonioscopy_findings: gonioState,
        glaucoma_status: gonioHasData ? 'Done' : status.gonioscopy,
        remarks_re: remarksRe, remarks_le: remarksLe,
      };
      const result = await saveExamination(examIdAtSchedule, encounterId, fields);
      if (loadedExamId.current !== examIdAtSchedule) return; // switched encounters mid-flight
      setSaveState(result.error ? 'error' : 'saved');
      if (!result.error && onSaved) onSaved();
    }, 1200);

    return () => clearTimeout(saveTimer.current);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [regionState, status, gonioState, remarksRe, remarksLe]);

  // Live-mirrors RE into LE for all 3 fields at once while "Copy RE
  // Value to LE" is checked -- same pattern as the Optometry Refraction
  // section, but one switch for the whole section instead of per-field.
  function setGonioField(fieldKey, eye, val) {
    setGonioState((prev) => {
      const stageState = { ...prev[gonioStage], [`${fieldKey}_${eye}`]: val };
      if (eye === 're' && prev[gonioStage].copy_re_to_le) {
        stageState[`${fieldKey}_le`] = val;
      }
      return { ...prev, [gonioStage]: stageState };
    });
    markDirty('gonioscopy');
  }

  function toggleGonioCopy(checked) {
    setGonioState((prev) => {
      const stageState = { ...prev[gonioStage], copy_re_to_le: checked };
      if (checked) GONIO_FIELDS.forEach((f) => { stageState[`${f.key}_le`] = prev[gonioStage][`${f.key}_re`]; });
      return { ...prev, [gonioStage]: stageState };
    });
  }

  return (
    <div>
      <div className="msg-info" style={{ background: 'var(--blue-lt)', color: 'var(--blue)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
        <i className="ti ti-info-circle"></i> Exception-based documentation. Click <strong>All Normal</strong> to auto-populate normal findings, then change only what&apos;s abnormal (click it again to untick and clear back to empty). Posterior Segment is recorded in two passes -- <strong>Without Dilation</strong> (Disc + CDR only) and <strong>With Dilation</strong> (full segment) -- switch using the toggle in its header.
      </div>

      <div className="card" style={{ padding: '10px 14px', marginBottom: 12 }}>
        <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase', marginBottom: 6 }}>Favorites</div>
        <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
          <button type="button" className="btn btn-sm" onClick={() => applyFavorite('normal')}><i className="ti ti-star"></i> Normal Routine</button>
          <button type="button" className="btn btn-sm" onClick={() => applyFavorite('cataract')}><i className="ti ti-eye"></i> Routine Cataract</button>
          <button type="button" className="btn btn-sm" onClick={() => applyFavorite('glaucoma')}><i className="ti ti-activity"></i> Gonioscopy Follow-up</button>
          <button type="button" className="btn btn-sm" onClick={() => applyFavorite('postop')}><i className="ti ti-calendar-check"></i> Post-op Review</button>
        </div>
      </div>

      {['external', 'anterior', 'posterior'].map((key) => (
        <RegionSection
          key={key}
          regionKey={key}
          region={REGIONS[key]}
          open={open[key]}
          onToggle={() => setOpen((p) => ({ ...p, [key]: !p[key] }))}
          status={status[key]}
          stagedState={regionState[key]}
          stage={regionStage[key]}
          onStageChange={(stage) => setRegionStage((p) => ({ ...p, [key]: stage }))}
          onSelect={(struct, eye, val) => handleSelect(key, struct, eye, val)}
          onCustom={(struct, eye, val) => handleCustom(key, struct, eye, val)}
          onAllNormal={() => handleAllNormal(key)}
          allNormalOn={REGIONS[key].staged ? allNormalOn[key][regionStage[key]] : allNormalOn[key]}
        />
      ))}

      {/* GONIOSCOPY (formerly "Glaucoma Assessment") -- Angle / PTM / Iris
          Configuration, each split RE and LE with a Copy RE to LE option.
          No "All Normal" (not exception-based). */}
      <div className="card" style={{ padding: 0, overflow: 'hidden', marginBottom: 12 }}>
        <div style={{ padding: '12px 16px', background: 'var(--g50)', borderBottom: open.gonioscopy ? '1px solid var(--g200)' : 'none', display: 'flex', alignItems: 'center', justifyContent: 'space-between', cursor: 'pointer', flexWrap: 'wrap', gap: 8 }} onClick={() => setOpen((p) => ({ ...p, gonioscopy: !p.gonioscopy }))}>
          <div style={{ fontSize: 13, fontWeight: 700, color: 'var(--g800)', display: 'flex', alignItems: 'center', gap: 8 }}>
            <i className="ti ti-activity" style={{ color: 'var(--amber)' }}></i> Gonioscopy
            <span className={`badge ${status.gonioscopy === 'Done' ? 'b-green' : status.gonioscopy === 'In progress' ? 'b-amber' : 'b-gray'}`}>{status.gonioscopy}</span>
          </div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
            <StageToggle stage={gonioStage} onChange={setGonioStage} />
            <i className={`ti ti-chevron-${open.gonioscopy ? 'up' : 'down'}`} style={{ color: 'var(--g400)' }}></i>
          </div>
        </div>
        {open.gonioscopy && (
          <div style={{ padding: 16, background: gonioStage === 'with' ? 'var(--purple-lt)' : '#fff', transition: 'background .15s ease' }}>
            <div style={{ fontSize: 11, fontWeight: 700, color: gonioStage === 'with' ? 'var(--purple)' : 'var(--g500)', marginBottom: 10 }}>
              <i className="ti ti-droplet"></i> Recording: {STAGES.find((s) => s.key === gonioStage)?.label}
            </div>
            {(() => {
              const stageState = gonioState[gonioStage];
              const copying = stageState.copy_re_to_le;
              return (
                <>
                  <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 20, marginBottom: 12 }}>
                    {['re', 'le'].map((eye) => (
                      <div key={eye}>
                        <div style={{ fontSize: 11, fontWeight: 700, color: eye === 're' ? 'var(--blue)' : 'var(--teal)', marginBottom: 8, padding: '4px 8px', background: eye === 're' ? 'var(--blue-lt)' : 'var(--teal-lt)', borderRadius: 6, display: 'inline-block' }}>
                          <i className="ti ti-eye" style={{ fontSize: 11 }}></i> {eye === 're' ? 'Right Eye (RE / OD) -- Oculus Dexter' : 'Left Eye (LE / OS) -- Oculus Sinister'}
                        </div>
                        {GONIO_FIELDS.map((f) => (
                          <div key={f.key} style={{ marginBottom: 10 }}>
                            <label className="flbl">{f.label}</label>
                            <select
                              className="fi fi-sm"
                              disabled={eye === 'le' && copying}
                              value={stageState[`${f.key}_${eye}`]}
                              onChange={(e) => setGonioField(f.key, eye, e.target.value)}
                            >
                              <option value="">--</option>
                              {f.options.map((opt) => <option key={opt} value={opt}>{opt}</option>)}
                            </select>
                          </div>
                        ))}
                      </div>
                    ))}
                  </div>
                  <label style={{ display: 'flex', alignItems: 'center', gap: 6, fontSize: 11.5, fontWeight: 600, color: 'var(--g600)', cursor: 'pointer' }}>
                    <input type="checkbox" checked={copying} onChange={(e) => toggleGonioCopy(e.target.checked)} />
                    Copy RE Value to LE (Angle, PTM &amp; Iris Configuration)
                  </label>
                </>
              );
            })()}
          </div>
        )}
      </div>

      {/* CLINICAL REMARKS -- stays a single entry, not split by dilation stage */}
      <div className="card" style={{ padding: 0, overflow: 'hidden', marginBottom: 12 }}>
        <div style={{ padding: '12px 16px', background: 'var(--g50)', borderBottom: open.remarks ? '1px solid var(--g200)' : 'none', display: 'flex', alignItems: 'center', justifyContent: 'space-between', cursor: 'pointer' }} onClick={() => setOpen((p) => ({ ...p, remarks: !p.remarks }))}>
          <div style={{ fontSize: 13, fontWeight: 700, color: 'var(--g800)', display: 'flex', alignItems: 'center', gap: 8 }}>
            <i className="ti ti-notes" style={{ color: 'var(--g500)' }}></i> Clinical Remarks
          </div>
          <i className={`ti ti-chevron-${open.remarks ? 'up' : 'down'}`} style={{ color: 'var(--g400)' }}></i>
        </div>
        {open.remarks && (
          <div style={{ padding: 16 }}>
            <div className="msg-warn" style={{ background: 'var(--amber-lt)', color: 'var(--amber)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
              <i className="ti ti-alert-triangle"></i> Remarks supplement structured findings, they do not replace them.
            </div>
            <div style={{ marginBottom: 12 }}>
              <label className="flbl">Right Eye</label>
              <textarea className="fi fi-sm" rows={2} value={remarksRe} onChange={(e) => setRemarksRe(e.target.value)} placeholder="Additional observations for RE..." />
            </div>
            <div>
              <label className="flbl">Left Eye</label>
              <textarea className="fi fi-sm" rows={2} value={remarksLe} onChange={(e) => setRemarksLe(e.target.value)} placeholder="Additional observations for LE..." />
            </div>
          </div>
        )}
      </div>

      <div style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 12, color: 'var(--g500)' }}>
        {saveState === 'pending' && <><i className="ti ti-clock"></i> Unsaved changes...</>}
        {saveState === 'saving' && <><i className="ti ti-loader-2"></i> Saving...</>}
        {saveState === 'saved' && <span style={{ color: 'var(--green)' }}><i className="ti ti-check"></i> Saved</span>}
        {saveState === 'error' && <span style={{ color: 'var(--red)' }}><i className="ti ti-alert-triangle"></i> Couldn&apos;t save -- check your connection</span>}
      </div>
    </div>
  );
}

VEDA_EOF_MARKER

echo "Done. Files updated:"
echo "  app/print-templates/actions.js"
echo "  app/consultation/[id]/examination-tab.js"