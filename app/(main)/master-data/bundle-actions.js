'use server';

// Master lists a screen needs on open, in ONE request (run in parallel on
// the server) instead of one request per list. Functions are unchanged.

import { getDiagnosesMaster, getDrugs, getServices, getSurgeries, getDosageOptions, getActivePatientInstructionTemplates } from './actions';
import { getDoctorsMaster, getIopMethods, getClinicalObservations, getPatientInstructionTemplates, getHistoryOptions, getIolCatalog, getSurgicalConsumablesMaster, getPackages, getDrugTypes, getVendorsMaster, amIAdmin, getMasterAuditLog } from './actions';
import * as M from './actions'; // save dispatch (allow-listed below)

// Doctor consultation form: was 6 requests on every open.
export async function getConsultationMastersBundle() {
  return Promise.all([getDiagnosesMaster(), getDrugs(), getServices(), getSurgeries(), getDosageOptions(), getActivePatientInstructionTemplates()]);
}

// Post-op review form: was 2 requests on every open.
export async function getPostopReviewMastersBundle() {
  return Promise.all([getDrugs(), getDosageOptions()]);
}

// ── Clinical & Financial Masters (speed-up, 23 Oct 2026) ──
// These pages used to load their lists ONE AFTER ANOTHER (9 and 8
// requests), then repeat all of that after every save. Now: opening the
// page is one request, and every save returns the refreshed lists in the
// same response. Same functions underneath; saves are allow-listed and
// each is already a callable server action in its own right.

export async function getClinicalMastersBundle() {
  const [diagnoses, doctors, surgeries, iopMethods, observations, patientInstructions, historyOptions, iolCatalog, surgicalConsumables] = await Promise.all([
    getDiagnosesMaster(), getDoctorsMaster(), getSurgeries(), getIopMethods(), getClinicalObservations(),
    getPatientInstructionTemplates(), getHistoryOptions(), getIolCatalog(), getSurgicalConsumablesMaster(),
  ]);
  return { diagnoses, doctors, surgeries, iopMethods, observations, patientInstructions, historyOptions, iolCatalog, surgicalConsumables };
}

export async function getFinancialMastersBundle(auditTable) {
  const [services, packages, drugs, drugTypes, dosageOptions, surgeries, vendors, isAdmin] = await Promise.all([
    getServices(), getPackages(), getDrugs(), getDrugTypes(), getDosageOptions(), getSurgeries(), getVendorsMaster(), amIAdmin(),
  ]);
  const auditLog = isAdmin ? await getMasterAuditLog(auditTable) : [];
  return { services, packages, drugs, drugTypes, dosageOptions, surgeries, vendors, isAdmin, auditLog };
}

const CLINICAL_SAVES = [
  'toggleStatus',
  'addDiagnosisMaster', 'updateDiagnosisMaster', 'deleteDiagnosisMaster',
  'addSurgery', 'updateSurgery', 'deleteSurgery',
  'addIopMethod', 'updateIopMethod', 'deleteIopMethod',
  'addClinicalObservation', 'updateClinicalObservation', 'deleteClinicalObservation',
  'addPatientInstructionTemplate', 'updatePatientInstructionTemplate', 'deletePatientInstructionTemplate',
  'addHistoryOption', 'updateHistoryOption', 'deleteHistoryOption',
  'addIolCatalogItem', 'updateIolCatalogItem', 'deleteIolCatalogItem',
  'addSurgicalConsumable', 'updateSurgicalConsumable', 'deleteSurgicalConsumable',
];
const FINANCIAL_SAVES = [
  'toggleStatus',
  'addService', 'updateService', 'deleteService',
  'addPackage', 'updatePackage', 'deletePackage',
  'addPackageLineItem', 'updatePackageLineItem', 'removePackageLineItem',
  'addDrug', 'updateDrug', 'deleteDrug',
  'addDrugType', 'updateDrugType', 'updateDrugTypeOcular', 'updateDrugTypeCountable', 'deleteDrugType',
  'addDosageOption', 'removeDosageOption',
  'addVendorMaster', 'updateVendorMaster', 'deleteVendorMaster',
];

async function runAllowed(list, name, args) {
  if (!list.includes(name) || typeof M[name] !== 'function') return { error: 'Unknown action.' };
  return (await M[name](...(Array.isArray(args) ? args : []))) || {};
}

// One save + the refreshed Clinical Masters lists, in one request.
export async function clinicalMastersSave(name, args) {
  const result = await runAllowed(CLINICAL_SAVES, name, args);
  if (result.error) return result;
  return { ...result, bundle: await getClinicalMastersBundle() };
}

// One save + the refreshed Financial Masters lists, in one request.
export async function financialMastersSave(name, args, auditTable) {
  const result = await runAllowed(FINANCIAL_SAVES, name, args);
  if (result.error) return result;
  return { ...result, bundle: await getFinancialMastersBundle(auditTable) };
}
