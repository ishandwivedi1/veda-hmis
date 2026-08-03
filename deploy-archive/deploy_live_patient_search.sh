#!/bin/bash
set -e
echo "Deploying: live patient-search-as-you-type across all patient search boxes"

mkdir -p "$(dirname "app/(main)/visits/new/page.js")"
cat > "app/(main)/visits/new/page.js" << 'VEDA_EOF_MARKER'
'use client';

import { useState, useEffect, Suspense } from 'react';
import { useRouter, useSearchParams } from 'next/navigation';
import { searchPatientsForBooking, getDoctors } from '@/app/(main)/appointments/actions';
import { createWalkInVisit, getSurgeryTypeOptions, getPatientById } from '@/app/(main)/visits/actions';

export default function NewVisitPage() {
  return (
    <Suspense fallback={<div style={{ textAlign: 'center', marginTop: 60, color: 'var(--g500)' }}>Loading...</div>}>
      <NewVisitForm />
    </Suspense>
  );
}

function NewVisitForm() {
  const searchParams = useSearchParams();
  const prefillPatientId = searchParams.get('patientId');

  const [searchQuery, setSearchQuery] = useState('');
  const [searchResults, setSearchResults] = useState([]);
  const [selectedPatient, setSelectedPatient] = useState(null);
  const [searched, setSearched] = useState(false);
  const [prefillLoading, setPrefillLoading] = useState(!!prefillPatientId);
  const [prefillError, setPrefillError] = useState('');

  const [doctors, setDoctors] = useState([]);
  const [doctorId, setDoctorId] = useState('');
  const [visitType, setVisitType] = useState('New Consultation');
  const [referralSource, setReferralSource] = useState('Walk-in');
  const [priority, setPriority] = useState('Routine');
  const [surgeryTypes, setSurgeryTypes] = useState([]);
  const [surgeryType, setSurgeryType] = useState('');

  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);
  const router = useRouter();

  useEffect(() => {
    getDoctors().then(setDoctors);
    getSurgeryTypeOptions().then(setSurgeryTypes);
  }, []);

  useEffect(() => {
    if (!prefillPatientId) return;
    let cancelled = false;
    setPrefillLoading(true);
    getPatientById(prefillPatientId).then((patient) => {
      if (cancelled) return;
      setPrefillLoading(false);
      if (patient) {
        setSelectedPatient(patient);
      } else {
        setPrefillError('Could not load that patient -- search for them below instead.');
      }
    });
    return () => { cancelled = true; };
  }, [prefillPatientId]);

  async function handleSearch() {
    if (!searchQuery.trim()) return;
    const results = await searchPatientsForBooking(searchQuery.trim());
    setSearchResults(results);
    setSearched(true);
  }

  // Live search as the user types -- no need to press the Search button.
  useEffect(() => {
    const q = searchQuery.trim();
    if (q.length < 2) { setSearchResults([]); setSearched(false); return; }
    const t = setTimeout(async () => {
      const results = await searchPatientsForBooking(q);
      setSearchResults(results);
      setSearched(true);
    }, 300);
    return () => clearTimeout(t);
  }, [searchQuery]);

  function goToFullRegistration() {
    const isMobile = /^\d{6,}$/.test(searchQuery.trim());
    const params = new URLSearchParams({
      returnTo: 'visit',
      prefillFirstName: isMobile ? '' : searchQuery.trim().split(' ')[0] || '',
      prefillLastName: isMobile ? '' : searchQuery.trim().split(' ').slice(1).join(' ') || '',
      prefillMobile: isMobile ? searchQuery.trim() : '',
    });
    router.push(`/patients/new?${params.toString()}`);
  }

  function pickPatient(p) {
    setSelectedPatient(p);
    setSearchResults([]);
    setSearchQuery('');
  }

  async function handleSubmit(e) {
    e.preventDefault();
    setError('');

    if (!selectedPatient) {
      setError('Search and select a registered patient.');
      return;
    }
    if (visitType === 'Surgery' && !surgeryType) {
      setError('Select the type of surgery.');
      return;
    }

    setLoading(true);
    const result = await createWalkInVisit({
      patientId: selectedPatient.id,
      doctorId: doctorId || null,
      visitType,
      referralSource,
      priority,
      surgeryType,
    });
    setLoading(false);

    if (result.error) {
      setError(result.error);
      return;
    }

    router.push('/front-office-dashboard?visitCreated=1');
  }

  return (
    <div style={{ maxWidth: 560, margin: '0 auto' }}>
      <div className="card">
        <div style={{ fontSize: 18, fontWeight: 700, marginBottom: 4 }}>
          <i className="ti ti-door-enter" style={{ color: 'var(--blue)', marginRight: 6 }}></i>Create Walk-in Visit
        </div>
        <div style={{ fontSize: 12, color: 'var(--g500)', marginBottom: 20 }}>
          For patients arriving without a prior appointment.
        </div>

        {error && <div className="msg-err">{error}</div>}
        {prefillError && <div className="msg-err">{prefillError}</div>}

        <form onSubmit={handleSubmit}>
          <div style={{ marginBottom: 16 }}>
            <label className="flbl">Find patient (name, UHID, or mobile) *</label>
            {prefillLoading ? (
              <div style={{ padding: '8px 12px', color: 'var(--g500)', fontSize: 13 }}>
                <i className="ti ti-loader-2"></i> Loading patient...
              </div>
            ) : selectedPatient ? (
              <div
                style={{
                  display: 'flex',
                  justifyContent: 'space-between',
                  alignItems: 'center',
                  background: 'var(--blue-lt)',
                  padding: '8px 12px',
                  borderRadius: 8,
                }}
              >
                <span>
                  <strong>{selectedPatient.first_name} {selectedPatient.last_name}</strong>
                  {' -- '}
                  {selectedPatient.uhid}
                </span>
                <button
                  type="button"
                  className="btn"
                  style={{ padding: '4px 10px' }}
                  onClick={() => setSelectedPatient(null)}
                >
                  Change
                </button>
              </div>
            ) : (
              <>
                <div style={{ display: 'flex', gap: 8 }}>
                  <input
                    className="fi"
                    value={searchQuery}
                    onChange={(e) => { setSearchQuery(e.target.value); setSearched(false); }}
                    placeholder="Type to search..."
                  />
                  <button type="button" className="btn" onClick={handleSearch}>
                    Search
                  </button>
                </div>
                {searchResults.length > 0 && (
                  <div style={{ border: '1px solid var(--g200)', borderRadius: 8, marginTop: 6 }}>
                    {searchResults.map((p) => (
                      <div
                        key={p.id}
                        onClick={() => pickPatient(p)}
                        style={{
                          padding: '8px 12px',
                          cursor: 'pointer',
                          borderBottom: '1px solid var(--g100)',
                          fontSize: 13,
                        }}
                      >
                        <strong>{p.first_name} {p.last_name}</strong> -- {p.uhid} -- {p.mobile}
                      </div>
                    ))}
                  </div>
                )}
                {searched && searchResults.length === 0 && (
                  <div style={{ fontSize: 12, marginTop: 8 }}>
                    No match for &quot;{searchQuery || 'that search'}&quot;.{' '}
                    <button
                      type="button"
                      onClick={goToFullRegistration}
                      style={{ color: 'var(--blue)', background: 'none', border: 'none', padding: 0, cursor: 'pointer', textDecoration: 'underline', fontSize: 12 }}
                    >
                      Register this patient
                    </button>
                  </div>
                )}
              </>
            )}
          </div>

          <div style={{ display: 'grid', gridTemplateColumns: visitType === 'Surgery' ? '1fr 1fr 1fr' : '1fr 1fr', gap: 12, marginBottom: 12 }}>
            <div>
              <label className="flbl">Visit type</label>
              <select className="fi" value={visitType} onChange={(e) => { setVisitType(e.target.value); if (e.target.value !== 'Surgery') setSurgeryType(''); }}>
                <option>New Consultation</option>
                <option>Follow-up</option>
                <option>Investigation Only</option>
                <option>Post-operative Review</option>
                <option>Emergency</option>
                <option>Surgery</option>
              </select>
            </div>
            {visitType === 'Surgery' && (
              <div>
                <label className="flbl">Type of surgery</label>
                <select className="fi" value={surgeryType} onChange={(e) => setSurgeryType(e.target.value)}>
                  <option value="">-- Select --</option>
                  {surgeryTypes.map((s) => <option key={s.id} value={s.name}>{s.name}</option>)}
                </select>
              </div>
            )}
            <div>
              <label className="flbl">Doctor</label>
              <select className="fi" value={doctorId} onChange={(e) => setDoctorId(e.target.value)}>
                <option value="">-- Any / Not decided --</option>
                {doctors.map((d) => (
                  <option key={d.id} value={d.id}>
                    {d.full_name}
                  </option>
                ))}
              </select>
            </div>
          </div>

          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12, marginBottom: 20 }}>
            <div>
              <label className="flbl">Referral source</label>
              <select className="fi" value={referralSource} onChange={(e) => setReferralSource(e.target.value)}>
                <option>Walk-in</option>
                <option>Doctor referral</option>
                <option>Camp / outreach</option>
                <option>Previous patient</option>
              </select>
            </div>
            <div>
              <label className="flbl">Priority</label>
              <select className="fi" value={priority} onChange={(e) => setPriority(e.target.value)}>
                <option>Routine</option>
                <option>Urgent</option>
                <option>Emergency</option>
              </select>
            </div>
          </div>

          <div style={{ display: 'flex', gap: 8 }}>
            <button type="submit" className="btn btn-primary" disabled={loading}>
              {loading ? 'Creating...' : 'Create Visit'}
            </button>
            <button type="button" className="btn" onClick={() => router.push('/front-office-dashboard')}>
              Cancel
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}



VEDA_EOF_MARKER

mkdir -p "$(dirname "app/(main)/billing/new/new-invoice-tab.js")"
cat > "app/(main)/billing/new/new-invoice-tab.js" << 'VEDA_EOF_MARKER'
'use client';

import { useState, useEffect, useRef } from 'react';
import { useRouter, useSearchParams } from 'next/navigation';
import {
  searchPatientsForInvoice,
  getMostRecentVisitForPatient,
  getVisitWithPatient,
  getInvoicesForVisit,
  createInvoiceForVisit,
  getInvoiceById,
  getServiceCatalog,
  addLineItem,
  getTodaysVisitsForBilling,
  getInvestigationOrdersForBilling,
  markInvestigationOrdersBilled,
  getPrescriptionsForBilling,
  markPrescriptionsBilled,
  getBiometryForBilling,
  markBiometryBilled,
  getProceduresForBilling,
  markProceduresBilled,
  getPackageForBilling,
  markPackageBilled,
  getSurgeryBillingOptions,
  setManualSurgeryDetails,
} from '../actions';

const DEPARTMENTS = ['Consultation', 'Investigation', 'Biometry', 'Minor Procedure', 'Surgery', 'Pharmacy'];
const DEFAULT_PURPOSE = 'Consultation';

// Mirrors add_invoice_line_item's math exactly, so the running totals
// shown before committing match what the database will compute.
function computeLine(svc, qty, discType, discValue) {
  const gross = svc.rate * qty;
  let disc = 0;
  if (discType === 'pct') disc = Math.round((gross * discValue / 100) * 100) / 100;
  else if (discType === 'fixed') disc = Math.min(discValue, gross);
  const taxable = gross - disc;
  const gst = Math.round((taxable * svc.gst_pct / 100) * 100) / 100;
  const net = taxable + gst;
  return { gross, disc, gst, net };
}

export default function NewInvoiceTab() {
  const [searchQuery, setSearchQuery] = useState('');
  const [searchResults, setSearchResults] = useState([]);

  // Context: who we're billing. Never written to the database by
  // itself -- picking, browsing, or changing your mind is always free.
  const [contextPatient, setContextPatient] = useState(null);
  const [contextVisit, setContextVisit] = useState(null);
  const [existingInvoices, setExistingInvoices] = useState([]);

  // Draft line items live only in this component's state until
  // Finalize or Save Draft. Nothing is persisted before that.
  const [draftLines, setDraftLines] = useState([]);
  const [packageBreakup, setPackageBreakup] = useState(null);

  // Surgery Billing panel -- Surgery / Operated Eye / Doctor. Locked
  // (read-only) when fetched from an existing surgical_case (the
  // automatic route from OT/Counselling); editable when billing Surgery
  // manually with no linked case.
  const [surgeryName, setSurgeryName] = useState('');
  const [surgeryEyeField, setSurgeryEyeField] = useState('');
  const [surgeryDoctorId, setSurgeryDoctorId] = useState('');
  const [surgeryOptions, setSurgeryOptions] = useState([]);
  const [surgeryDoctorOptions, setSurgeryDoctorOptions] = useState([]);
  const nextTempId = useRef(1);

  const [catalog, setCatalog] = useState([]);
  const [dept, setDept] = useState('');
  const [selectedServiceCode, setSelectedServiceCode] = useState('');
  const [qty, setQty] = useState(1);
  const [rate, setRate] = useState('');
  const [gstPct, setGstPct] = useState('');
  const [discType, setDiscType] = useState('none');
  const [discValue, setDiscValue] = useState('');
  const [discReason, setDiscReason] = useState('');

  const [error, setError] = useState('');
  const [submitting, setSubmitting] = useState(false);
  const [todaysVisits, setTodaysVisits] = useState([]);
  const [unmatchedInvestigations, setUnmatchedInvestigations] = useState([]);
  const [unmatchedPrescriptions, setUnmatchedPrescriptions] = useState([]);
  const [unmatchedBiometry, setUnmatchedBiometry] = useState([]);
  const [unmatchedProcedures, setUnmatchedProcedures] = useState([]);
  const router = useRouter();
  const searchParams = useSearchParams();
  const urlVisitId = searchParams.get('visitId');
  const urlInvOrderIds = searchParams.get('invOrderIds');
  const urlRxIds = searchParams.get('rxIds');
  const urlBioIds = searchParams.get('bioIds');
  const urlProcIds = searchParams.get('procIds');
  const urlPkgCaseId = searchParams.get('pkgCaseId');
  const contextLoadedFor = useRef(null);
  const invOrdersLoadedFor = useRef(null);
  const rxLoadedFor = useRef(null);
  const bioLoadedFor = useRef(null);
  const procLoadedFor = useRef(null);
  const pkgLoadedFor = useRef(null);

  useEffect(() => {
    getServiceCatalog().then(setCatalog);
    getTodaysVisitsForBilling().then(setTodaysVisits);
    getSurgeryBillingOptions().then(({ surgeries, doctors }) => { setSurgeryOptions(surgeries); setSurgeryDoctorOptions(doctors); });
  }, []);

  useEffect(() => {
    if (!urlVisitId) return;
    if (contextLoadedFor.current === urlVisitId) return;
    contextLoadedFor.current = urlVisitId;
    (async () => {
      const details = await getVisitWithPatient(urlVisitId);
      if (details.error) { setError(details.error); return; }
      setContextPatient(details.visit.patients);
      setContextVisit(details.visit);
      const invResult = await getInvoicesForVisit(urlVisitId);
      setExistingInvoices(invResult.invoices || []);
    })();
  }, [urlVisitId]);

  // Prefill from Front Office's "Prescribed Investigations" widget --
  // waits for the visit/patient context above to land first (it needs
  // patient to exist before there's anywhere to add lines to), then
  // turns each selected investigation order into a draft line item.
  useEffect(() => {
    if (!urlInvOrderIds || !contextPatient) return;
    if (invOrdersLoadedFor.current === urlInvOrderIds) return;
    invOrdersLoadedFor.current = urlInvOrderIds;
    (async () => {
      const ids = urlInvOrderIds.split(',').filter(Boolean);
      const result = await getInvestigationOrdersForBilling(ids);
      if (result.error) { setError(result.error); return; }

      const matched = (result.items || []).filter((i) => i.matched);
      const unmatched = (result.items || []).filter((i) => !i.matched);
      setUnmatchedInvestigations(unmatched);

      setDraftLines((prev) => [
        ...prev,
        ...matched.map((i) => {
          const computed = computeLine({ rate: i.rate, gst_pct: i.gstPct }, 1, 'none', 0);
          return {
            tempId: nextTempId.current++,
            sourceInvOrderId: i.invOrderId,
            serviceCode: i.serviceCode, serviceName: `${i.name} (${i.eye})`, dept: 'Investigation',
            qty: 1, rate: i.rate, gstPct: i.gstPct,
            discType: 'none', discValue: 0, discReason: '',
            ...computed,
          };
        }),
      ]);
    })();
  }, [urlInvOrderIds, contextPatient]);

  // Prefill from Front Office's "Prescribed Minor Procedures" widget --
  // same pattern as investigations above, matched against the Minor
  // Procedure department of the service catalog.
  useEffect(() => {
    if (!urlProcIds || !contextPatient) return;
    if (procLoadedFor.current === urlProcIds) return;
    procLoadedFor.current = urlProcIds;
    (async () => {
      const ids = urlProcIds.split(',').filter(Boolean);
      const result = await getProceduresForBilling(ids);
      if (result.error) { setError(result.error); return; }

      const matched = (result.items || []).filter((i) => i.matched);
      const unmatched = (result.items || []).filter((i) => !i.matched);
      setUnmatchedProcedures(unmatched);

      setDraftLines((prev) => [
        ...prev,
        ...matched.map((i) => {
          const computed = computeLine({ rate: i.rate, gst_pct: i.gstPct }, 1, 'none', 0);
          return {
            tempId: nextTempId.current++,
            sourceProcId: i.procedureId,
            serviceCode: i.serviceCode, serviceName: `${i.name} (${i.eye})`, dept: 'Minor Procedure',
            qty: 1, rate: i.rate, gstPct: i.gstPct,
            discType: 'none', discValue: 0, discReason: '',
            ...computed,
          };
        }),
      ]);
    })();
  }, [urlProcIds, contextPatient]);

  // Prefill from Front Office's "Prescribed Medicines" widget -- same
  // pattern as investigations above, matched against the drug catalog.
  // Stored itemized (one line per drug) so Invoice Details still shows
  // exactly what was billed -- the print/PDF copy is what collapses
  // these into a single "OPD Procedure Consumables" line, since there's
  // no pharmacy license yet to show individual drug names externally.
  useEffect(() => {
    if (!urlRxIds || !contextPatient) return;
    if (rxLoadedFor.current === urlRxIds) return;
    rxLoadedFor.current = urlRxIds;
    (async () => {
      const ids = urlRxIds.split(',').filter(Boolean);
      const result = await getPrescriptionsForBilling(ids);
      if (result.error) { setError(result.error); return; }

      const matched = (result.items || []).filter((i) => i.matched);
      const unmatched = (result.items || []).filter((i) => !i.matched);
      setUnmatchedPrescriptions(unmatched);

      setDraftLines((prev) => [
        ...prev,
        ...matched.map((i) => {
          const computed = computeLine({ rate: i.rate, gst_pct: i.gstPct }, 1, 'none', 0);
          return {
            tempId: nextTempId.current++,
            sourceRxId: i.rxId,
            serviceCode: i.serviceCode, serviceName: `${i.name}${i.eye ? ' (' + i.eye + ')' : ''}`, dept: 'Pharmacy',
            qty: 1, rate: i.rate, gstPct: i.gstPct,
            discType: 'none', discValue: 0, discReason: '',
            ...computed,
          };
        }),
      ]);
    })();
  }, [urlRxIds, contextPatient]);

  // Prefill from Front Office's "Biometry" widget -- always exactly one
  // fixed-price line, no name-matching needed.
  useEffect(() => {
    if (!urlBioIds || !contextPatient) return;
    if (bioLoadedFor.current === urlBioIds) return;
    bioLoadedFor.current = urlBioIds;
    (async () => {
      const ids = urlBioIds.split(',').filter(Boolean);
      const result = await getBiometryForBilling(ids);
      if (result.error) { setError(result.error); return; }

      const matched = (result.items || []).filter((i) => i.matched);
      const unmatched = (result.items || []).filter((i) => !i.matched);
      setUnmatchedBiometry(unmatched);

      setDraftLines((prev) => [
        ...prev,
        ...matched.map((i) => {
          const computed = computeLine({ rate: i.rate, gst_pct: i.gstPct }, 1, 'none', 0);
          return {
            tempId: nextTempId.current++,
            sourceBioId: i.bioId,
            serviceCode: i.serviceCode, serviceName: i.name, dept: 'Biometry',
            qty: 1, rate: i.rate, gstPct: i.gstPct,
            discType: 'none', discValue: 0, discReason: '',
            ...computed,
          };
        }),
      ]);
    })();
  }, [urlBioIds, contextPatient]);

  // Prefill from Front Office's "Package Billing" widget -- the package
  // locked in Counselling, billed the same way as everything else
  // (through this screen -> Finalize -> Collect Payment), unlike the
  // old auto-pay Package Billing tab.
  useEffect(() => {
    if (!urlPkgCaseId || !contextPatient) return;
    if (pkgLoadedFor.current === urlPkgCaseId) return;
    pkgLoadedFor.current = urlPkgCaseId;
    (async () => {
      const result = await getPackageForBilling(urlPkgCaseId);
      if (result.error) { setError(result.error); return; }
      if (!result.item) return;
      const i = result.item;
      setPackageBreakup(i.breakup && i.breakup.length > 0 ? i.breakup : null);
      setSurgeryName(i.surgeryName || '');
      setSurgeryEyeField(i.surgeryEye || '');
      setSurgeryDoctorId(i.surgeonId || '');
      const computed = computeLine({ rate: i.rate, gst_pct: i.gstPct }, 1, 'none', 0);
      setDraftLines((prev) => [
        ...prev,
        {
          tempId: nextTempId.current++,
          sourcePkgCaseId: i.caseId,
          serviceCode: i.serviceCode, serviceName: i.name, dept: 'Surgery',
          qty: 1, rate: i.rate, gstPct: i.gstPct,
          discType: 'none', discValue: 0, discReason: '',
          ...computed,
        },
      ]);
    })();
  }, [urlPkgCaseId, contextPatient]);

  const servicesForDept = catalog.filter((s) => s.dept === dept);

  async function handleSearch() {
    if (!searchQuery.trim()) return;
    const results = await searchPatientsForInvoice(searchQuery.trim());
    setSearchResults(results);
  }

  // Live search as the user types -- no need to press the Search button.
  useEffect(() => {
    const q = searchQuery.trim();
    if (q.length < 2) { setSearchResults([]); return; }
    const t = setTimeout(async () => {
      setSearchResults(await searchPatientsForInvoice(q));
    }, 300);
    return () => clearTimeout(t);
  }, [searchQuery]);

  async function pickPatient(p) {
    setError('');
    setSearchResults([]);
    setSearchQuery('');
    setContextPatient(p);
    const visit = await getMostRecentVisitForPatient(p.id);
    setContextVisit(visit);
    if (visit) {
      const invResult = await getInvoicesForVisit(visit.id);
      setExistingInvoices(invResult.invoices || []);
    } else {
      setExistingInvoices([]);
    }
  }

  async function pickVisit(v) {
    setError('');
    setContextPatient(v.patients);
    setContextVisit(v);
    const invResult = await getInvoicesForVisit(v.id);
    setExistingInvoices(invResult.invoices || []);
  }

  function handleDeptChange(e) {
    setDept(e.target.value);
    setSelectedServiceCode('');
    setRate('');
    setGstPct('');
  }

  function handleServiceChange(e) {
    const code = e.target.value;
    setSelectedServiceCode(code);
    const svc = catalog.find((s) => s.code === code);
    setRate(svc ? svc.rate : '');
    setGstPct(svc ? svc.gst_pct : '');
  }

  function handleAddLine() {
    setError('');
    if (!selectedServiceCode) { setError('Select department and service.'); return; }
    if (discType !== 'none' && !discReason.trim()) { setError('A discount reason is required whenever a discount is applied.'); return; }

    const svc = catalog.find((s) => s.code === selectedServiceCode);
    const q = parseInt(qty, 10) || 1;
    const dv = parseFloat(discValue) || 0;
    const computed = computeLine(svc, q, discType, dv);

    setDraftLines((prev) => [...prev, {
      tempId: nextTempId.current++,
      serviceCode: svc.code, serviceName: svc.name, dept: svc.dept,
      qty: q, rate: svc.rate, gstPct: svc.gst_pct,
      discType, discValue: dv, discReason,
      ...computed,
    }]);

    setDept(''); setSelectedServiceCode(''); setQty(1); setRate(''); setGstPct('');
    setDiscType('none'); setDiscValue(''); setDiscReason('');
  }

  function handleRemoveLine(tempId) {
    setDraftLines((prev) => prev.filter((l) => l.tempId !== tempId));
  }

  // The one moment anything gets written -- creates the invoice, then
  // every draft line item on it, in order.
  async function commitInvoice() {
    setError('');
    if (draftLines.length === 0) { setError('Add at least one line item before saving.'); return null; }
    setSubmitting(true);

    // purpose drives the "Department" shown in Billing Dashboard /
    // Revenue by Department -- it must reflect what's actually being
    // billed, not always default to Consultation. Surgery takes
    // priority if present (it's what also decides which print template
    // renders), otherwise whichever department was billed first.
    const deptsPresent = draftLines.map((l) => l.dept);
    const purpose = deptsPresent.includes('Surgery') ? 'Surgery' : (deptsPresent[0] || DEFAULT_PURPOSE);

    const created = await createInvoiceForVisit(contextPatient.id, contextVisit?.id || null, purpose);
    if (created.error) { setSubmitting(false); setError(created.error); return null; }

    for (const line of draftLines) {
      const result = await addLineItem(created.invoice.id, line.serviceCode, line.qty, line.discType, line.discValue, line.discReason);
      if (result.error) {
        setSubmitting(false);
        setError(`Invoice created, but failed adding ${line.serviceName}: ${result.error}. Finish it from Invoice Details.`);
        return null;
      }
    }

    const details = await getInvoiceById(created.invoice.id);

    const billedInvOrderIds = draftLines.map((l) => l.sourceInvOrderId).filter(Boolean);
    if (billedInvOrderIds.length > 0) await markInvestigationOrdersBilled(billedInvOrderIds, created.invoice.id);
    const billedProcIds = draftLines.map((l) => l.sourceProcId).filter(Boolean);
    if (billedProcIds.length > 0) await markProceduresBilled(billedProcIds, created.invoice.id);

    const billedRxIds = draftLines.map((l) => l.sourceRxId).filter(Boolean);
    if (billedRxIds.length > 0) await markPrescriptionsBilled(billedRxIds);

    const billedBioIds = draftLines.map((l) => l.sourceBioId).filter(Boolean);
    if (billedBioIds.length > 0) await markBiometryBilled(billedBioIds, created.invoice.id);

    const billedPkgCaseId = draftLines.find((l) => l.sourcePkgCaseId)?.sourcePkgCaseId;
    if (billedPkgCaseId) await markPackageBilled(billedPkgCaseId, created.invoice.id);

    // Fields are always editable now (whether prefilled from a case via
    // the automatic route, or entered by hand), so whatever's in the
    // form at commit time is what should print -- save it whenever a
    // Surgery line was actually added. dept has already been reset by
    // now (cleared after each Add), so this checks the actual lines
    // added rather than current form state.
    const hasSurgeryLine = draftLines.some((l) => l.dept === 'Surgery');
    if (hasSurgeryLine && surgeryName) {
      await setManualSurgeryDetails(created.invoice.id, surgeryName, surgeryEyeField, surgeryDoctorId);
    }

    setSubmitting(false);
    return details.invoice;
  }

  async function handleFinalize() {
    const inv = await commitInvoice();
    if (!inv) return;
    if (Number(inv.net) <= 0) {
      // Nothing to collect (e.g. fully discounted) -- the invoice is
      // already Paid, so there's no payment to send anyone to.
      router.push(`/billing/details?q=${contextPatient.uhid}`);
      return;
    }
    router.push(`/payments/collect?patientId=${contextPatient.id}&invoiceId=${inv.id}`);
  }

  async function handleSaveDraft() {
    const inv = await commitInvoice();
    if (!inv) return;
    router.push('/billing/details');
  }

  function startOver() {
    setContextPatient(null);
    setContextVisit(null);
    setExistingInvoices([]);
    setDraftLines([]);
    setUnmatchedInvestigations([]);
    setUnmatchedPrescriptions([]);
    setUnmatchedBiometry([]);
    setSurgeryName('');
    setSurgeryEyeField('');
    setSurgeryDoctorId('');
    contextLoadedFor.current = null;
    invOrdersLoadedFor.current = null;
    rxLoadedFor.current = null;
    bioLoadedFor.current = null;
    procLoadedFor.current = null;
    pkgLoadedFor.current = null;
    router.push('/billing/new');
  }

  const totals = draftLines.reduce((acc, l) => ({
    gross: acc.gross + l.gross, gst: acc.gst + l.gst, net: acc.net + l.net,
  }), { gross: 0, gst: 0, net: 0 });

  return (
    <div style={{ display: 'grid', gridTemplateColumns: '2fr 1fr', gap: 20 }}>
      <div className="card">
        <div className="card-title" style={{ marginBottom: 10 }}>
          <i className="ti ti-file-plus" style={{ color: 'var(--blue)' }}></i> New Invoice
        </div>

        {error && <div className="msg-err">{error}</div>}

        {!contextPatient ? (
          <div>
            <label className="flbl">Find patient (name, UHID, or mobile)</label>
            <div style={{ display: 'flex', gap: 8 }}>
              <input className="fi" value={searchQuery} onChange={(e) => setSearchQuery(e.target.value)} placeholder="Type to search..." />
              <button className="btn btn-primary" onClick={handleSearch}><i className="ti ti-search"></i> Search</button>
            </div>
            {searchResults.length > 0 && (
              <div style={{ border: '1px solid var(--g200)', borderRadius: 8, marginTop: 8 }}>
                {searchResults.map((p) => (
                  <div key={p.id} onClick={() => pickPatient(p)} style={{ padding: '8px 12px', cursor: 'pointer', borderBottom: '1px solid var(--g100)', fontSize: 13 }}>
                    <strong>{p.first_name} {p.last_name}</strong> -- {p.uhid} -- {p.mobile}
                  </div>
                ))}
              </div>
            )}
          </div>
        ) : (
          <div>
            {existingInvoices.length > 0 && (
              <div className="msg-info" style={{ background: 'var(--blue-lt)', color: 'var(--blue)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
                <i className="ti ti-info-circle"></i> This visit also has {existingInvoices.length} other invoice{existingInvoices.length > 1 ? 's' : ''}
                {contextVisit && <> -- <a href={`/billing/cancel?visitId=${contextVisit.id}`} style={{ color: 'var(--blue)', fontWeight: 600 }}>view / modify them</a></>}
              </div>
            )}
            {unmatchedInvestigations.length > 0 && (
              <div className="msg-err" style={{ fontSize: 12, marginBottom: 12 }}>
                <i className="ti ti-alert-triangle"></i> {unmatchedInvestigations.length} prescribed investigation{unmatchedInvestigations.length > 1 ? 's' : ''} couldn&apos;t be matched to a priced service and weren&apos;t added automatically -- add manually below: {unmatchedInvestigations.map((i) => i.name).join(', ')}
              </div>
            )}
            {unmatchedPrescriptions.length > 0 && (
              <div className="msg-err" style={{ fontSize: 12, marginBottom: 12 }}>
                <i className="ti ti-alert-triangle"></i> {unmatchedPrescriptions.length} prescribed medicine{unmatchedPrescriptions.length > 1 ? 's' : ''} couldn&apos;t be matched to a priced drug and weren&apos;t added automatically -- add manually below: {unmatchedPrescriptions.map((i) => i.name).join(', ')}
              </div>
            )}
            {unmatchedProcedures.length > 0 && (
              <div className="msg-err" style={{ fontSize: 12, marginBottom: 12 }}>
                <i className="ti ti-alert-triangle"></i> {unmatchedProcedures.length} prescribed minor procedure{unmatchedProcedures.length > 1 ? 's' : ''} couldn&apos;t be matched to a priced service and weren&apos;t added automatically -- add manually below: {unmatchedProcedures.map((i) => i.name).join(', ')}
              </div>
            )}
            {unmatchedBiometry.length > 0 && (
              <div className="msg-err" style={{ fontSize: 12, marginBottom: 12 }}>
                <i className="ti ti-alert-triangle"></i> No active "Biometry" service found in Financial Masters -- add the charge manually below.
              </div>
            )}
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', background: 'var(--blue-lt)', padding: '8px 12px', borderRadius: 8, marginBottom: 16 }}>
              <span>
                <strong>{contextPatient.first_name} {contextPatient.last_name}</strong> -- {contextPatient.uhid}
                <span style={{ marginLeft: 8 }} className="badge b-gray">Draft -- not saved yet</span>
              </span>
              <button className="btn btn-sm" onClick={startOver}>Change / New</button>
            </div>

            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginBottom: 8 }}>
              <div>
                <label className="flbl">Department *</label>
                <select className="fi" value={dept} onChange={handleDeptChange}>
                  <option value="">-- Select --</option>
                  {DEPARTMENTS.map((d) => <option key={d} value={d}>{d}</option>)}
                </select>
              </div>
              <div>
                <label className="flbl">Service *</label>
                <select className="fi" value={selectedServiceCode} onChange={handleServiceChange} disabled={!dept}>
                  <option value="">{dept ? '-- Select --' : '-- Select dept first --'}</option>
                  {servicesForDept.map((s) => <option key={s.code} value={s.code}>{s.name}</option>)}
                </select>
              </div>
            </div>

            {(dept === 'Surgery' || draftLines.some((l) => l.dept === 'Surgery')) && (
              <div style={{ border: '1px solid var(--g200)', borderRadius: 8, padding: '10px 12px', marginBottom: 8 }}>
                <div style={{ fontSize: 12, fontWeight: 700, color: 'var(--g600)', marginBottom: 8 }}>
                  <i className="ti ti-scalpel"></i> Surgery Billing Details
                  <span style={{ fontWeight: 400, color: 'var(--g400)', marginLeft: 6 }}>(prefilled from patient record where available -- edit if needed)</span>
                </div>
                <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 8 }}>
                  <div>
                    <label className="flbl">Surgery</label>
                    <select className="fi fi-sm" value={surgeryName} onChange={(e) => setSurgeryName(e.target.value)}>
                      <option value="">-- Select surgery --</option>
                      {surgeryOptions.map((s) => <option key={s.id} value={s.name}>{s.name}</option>)}
                    </select>
                  </div>
                  <div>
                    <label className="flbl">Operated Eye</label>
                    <select className="fi fi-sm" value={surgeryEyeField} onChange={(e) => setSurgeryEyeField(e.target.value)}>
                      <option value="">-- Select --</option>
                      <option value="OD">Right (OD)</option>
                      <option value="OS">Left (OS)</option>
                      <option value="OU">Both (OU)</option>
                    </select>
                  </div>
                  <div>
                    <label className="flbl">Doctor</label>
                    <select className="fi fi-sm" value={surgeryDoctorId} onChange={(e) => setSurgeryDoctorId(e.target.value)}>
                      <option value="">-- Select doctor --</option>
                      {surgeryDoctorOptions.map((d) => <option key={d.id} value={d.id}>{d.full_name}</option>)}
                    </select>
                  </div>
                </div>
                <div style={{ fontSize: 10.5, color: 'var(--g400)', marginTop: 6 }}>
                  Package is billed as the line item below (Service dropdown, filtered to Surgery) -- these three fields print on the Surgery Bill alongside it.
                </div>
              </div>
            )}

            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 8, marginBottom: 8 }}>
              <div>
                <label className="flbl">Qty</label>
                <input type="number" className="fi" value={qty} onChange={(e) => setQty(e.target.value)} min={1} />
              </div>
              <div>
                <label className="flbl">Unit rate (Rs.)</label>
                <input className="fi" value={rate} readOnly style={{ background: 'var(--g50)' }} />
              </div>
              <div>
                <label className="flbl">GST %</label>
                <input className="fi" value={gstPct} readOnly style={{ background: 'var(--g50)' }} />
              </div>
            </div>

            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 2fr', gap: 8, marginBottom: 10 }}>
              <select className="fi" value={discType} onChange={(e) => setDiscType(e.target.value)}>
                <option value="none">No discount</option>
                <option value="pct">Percentage (%)</option>
                <option value="fixed">Fixed (Rs.)</option>
              </select>
              <input type="number" className="fi" value={discValue} onChange={(e) => setDiscValue(e.target.value)} placeholder="Discount value" disabled={discType === 'none'} />
              <input className="fi" value={discReason} onChange={(e) => setDiscReason(e.target.value)} placeholder="Reason (required if discounted)" disabled={discType === 'none'} />
            </div>

            <button className="btn btn-primary btn-sm" onClick={handleAddLine} style={{ marginBottom: 16 }}>
              <i className="ti ti-plus"></i> Add line item
            </button>

            {packageBreakup && (
              <div style={{ border: '1px solid var(--g200)', borderRadius: 8, padding: '10px 12px', marginBottom: 16, background: 'var(--g50)' }}>
                <div style={{ fontSize: 12, fontWeight: 700, color: 'var(--g600)', marginBottom: 6 }}>
                  <i className="ti ti-list-details"></i> Package Breakup <span style={{ fontWeight: 400, color: 'var(--g400)' }}>(reference only -- the invoice still bills the package as one line item; won't print unless "Include package breakup" is chosen when printing)</span>
                </div>
                {packageBreakup.map((b, idx) => (
                  <div key={idx} style={{ display: 'flex', justifyContent: 'space-between', fontSize: 12, padding: '2px 0' }}>
                    <span style={{ color: 'var(--g600)' }}>{b.description}</span>
                    <span style={{ fontWeight: 600 }}>Rs.{Number(b.amount).toLocaleString('en-IN')}</span>
                  </div>
                ))}
              </div>
            )}

            <table className="tbl">
              <thead><tr><th>Service</th><th>Qty</th><th>Rate</th><th>Disc</th><th>GST</th><th>Net</th><th></th></tr></thead>
              <tbody>
                {draftLines.map((li) => (
                  <tr key={li.tempId}>
                    <td>{li.serviceName}{(li.sourceInvOrderId || li.sourceRxId || li.sourceBioId || li.sourceProcId || li.sourcePkgCaseId) && <span className="badge b-purple" style={{ marginLeft: 6, fontSize: 9 }}>Prescribed</span>}</td>
                    <td>{li.qty}</td>
                    <td>Rs.{li.rate}</td>
                    <td>{li.disc > 0 ? `Rs.${li.disc}` : '--'}</td>
                    <td>Rs.{li.gst.toFixed(2)}</td>
                    <td style={{ fontWeight: 600 }}>Rs.{li.net.toFixed(2)}</td>
                    <td><button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={() => handleRemoveLine(li.tempId)}>Remove</button></td>
                  </tr>
                ))}
                {draftLines.length === 0 && (
                  <tr><td colSpan={7} style={{ padding: 16, textAlign: 'center', color: 'var(--g400)' }}>No line items yet -- nothing is saved until you finalize or save draft.</td></tr>
                )}
              </tbody>
            </table>

            <div style={{ display: 'flex', gap: 8, marginTop: 16 }}>
              <button className="btn btn-green" onClick={handleFinalize} disabled={submitting}>
                <i className="ti ti-circle-check"></i> {submitting ? 'Saving...' : 'Finalize invoice'}
              </button>
              <button className="btn" onClick={handleSaveDraft} disabled={submitting}>
                <i className="ti ti-device-floppy"></i> {submitting ? 'Saving...' : 'Save draft'}
              </button>
            </div>
          </div>
        )}
      </div>

      <div>
        {!urlVisitId && (
          <div className="card" style={{ marginBottom: 16 }}>
            <div className="card-title" style={{ marginBottom: 10 }}>
              <i className="ti ti-door-enter" style={{ color: 'var(--blue)' }}></i> Today&apos;s Visits
            </div>
            <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 8 }}>Click a visit to bill against it.</div>
            {todaysVisits.map((v) => (
              <div
                key={v.id}
                onClick={() => pickVisit(v)}
                style={{ padding: '8px 4px', cursor: 'pointer', borderBottom: '1px solid var(--g100)', fontSize: 12 }}
              >
                <strong>{v.patients?.first_name} {v.patients?.last_name}</strong>
                <div style={{ color: 'var(--g500)' }}>{v.visit_number} -- {v.visit_type}</div>
              </div>
            ))}
            {todaysVisits.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No visits yet today.</div>}
          </div>
        )}

        {contextPatient && (
          <div className="card">
            <div className="card-title" style={{ marginBottom: 10 }}>
              <i className="ti ti-calculator" style={{ color: 'var(--green)' }}></i> Running Total
            </div>
            <div style={{ fontSize: 13, lineHeight: 1.9 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>Gross</span><span>Rs.{totals.gross.toFixed(2)}</span></div>
              <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>GST</span><span>Rs.{totals.gst.toFixed(2)}</span></div>
              <div style={{ display: 'flex', justifyContent: 'space-between', fontWeight: 700 }}><span>Net Total</span><span>Rs.{totals.net.toFixed(2)}</span></div>
              <div style={{ marginTop: 8, fontSize: 11, color: 'var(--g400)' }}>Not saved until you finalize or save draft.</div>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}



VEDA_EOF_MARKER

mkdir -p "$(dirname "app/(main)/payments/collect/collect-payment-tab.js")"
cat > "app/(main)/payments/collect/collect-payment-tab.js" << 'VEDA_EOF_MARKER'
'use client';

import { useState, useEffect, useRef } from 'react';
import { useSearchParams, useRouter } from 'next/navigation';
import { searchPatientsForPayment, getOutstandingInvoices, collectPayment, getAdvanceBalance, getPatientById, getAllUnpaidInvoices, applyAdjustment } from '../actions';

const MODES = ['Cash', 'Card', 'UPI', 'Cheque', 'Bank Transfer'];
const STATUS_BADGE = { Partial: 'b-amber', Pending: 'b-red' };

export default function CollectPaymentTab() {
  const [searchQuery, setSearchQuery] = useState('');
  const [searchResults, setSearchResults] = useState([]);
  const [selectedPatient, setSelectedPatient] = useState(null);
  const [invoices, setInvoices] = useState([]);
  const [selectedInvoiceIds, setSelectedInvoiceIds] = useState([]);
  const [advanceBalance, setAdvanceBalance] = useState(0);
  const [highlightInvoiceId, setHighlightInvoiceId] = useState(null);
  const [unpaidInvoices, setUnpaidInvoices] = useState([]);

  const [amount, setAmount] = useState('');
  const [modeRows, setModeRows] = useState([{ mode: 'Cash', amount: '' }]);
  const [reference, setReference] = useState('');
  const [remarks, setRemarks] = useState('');

  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);
  const [applyingAdvance, setApplyingAdvance] = useState(false);
  const [receipt, setReceipt] = useState(null);
  const [overpaidAmount, setOverpaidAmount] = useState(0);
  const searchParams = useSearchParams();
  const router = useRouter();
  const urlPatientId = searchParams.get('patientId');
  const urlInvoiceId = searchParams.get('invoiceId');
  const autofillDoneFor = useRef(null);

  useEffect(() => {
    getAllUnpaidInvoices().then(setUnpaidInvoices);
  }, []);

  // Arrived from "Finalize invoice" -- auto-load the patient and their
  // outstanding invoices (including the one just billed) instead of
  // requiring a manual search.
  useEffect(() => {
    if (!urlPatientId) return;
    if (autofillDoneFor.current === urlPatientId) return;
    autofillDoneFor.current = urlPatientId;
    (async () => {
      const result = await getPatientById(urlPatientId);
      if (result.error) { setError(result.error); return; }
      if (urlInvoiceId) setHighlightInvoiceId(urlInvoiceId);
      await pickPatient(result.patient);
    })();
  }, [urlPatientId, urlInvoiceId]);

  // In the common case (single payment mode), the mode's amount should
  // always match the amount collecting -- no need to type the same
  // number twice. Only once a second mode is added (a real split) does
  // each row need its own independently-entered amount.
  useEffect(() => {
    setModeRows((rows) => (rows.length === 1 ? [{ ...rows[0], amount }] : rows));
  }, [amount]);

  const totalSelectedOutstanding = invoices
    .filter((inv) => selectedInvoiceIds.includes(inv.id))
    .reduce((s, inv) => s + (Number(inv.net) - Number(inv.paid)), 0);

  const modesTotal = modeRows.reduce((s, m) => s + (parseFloat(m.amount) || 0), 0);

  async function handleSearch() {
    if (!searchQuery.trim()) return;
    setSearchResults(await searchPatientsForPayment(searchQuery.trim()));
  }

  // Live search as the user types -- no need to press the Search button.
  useEffect(() => {
    const q = searchQuery.trim();
    if (q.length < 2) { setSearchResults([]); return; }
    const t = setTimeout(async () => {
      setSearchResults(await searchPatientsForPayment(q));
    }, 300);
    return () => clearTimeout(t);
  }, [searchQuery]);

  async function pickPatient(p) {
    setError('');
    setSelectedPatient(p);
    setSearchResults([]);
    setSearchQuery('');
    const invs = await getOutstandingInvoices(p.id);
    setInvoices(invs);
    setSelectedInvoiceIds(invs.map((i) => i.id)); // pre-select all, matching "select invoice(s) to pay"
    setAdvanceBalance(await getAdvanceBalance(p.id));
  }

  function toggleInvoice(id) {
    setSelectedInvoiceIds((prev) => (prev.includes(id) ? prev.filter((x) => x !== id) : [...prev, id]));
  }

  function useFullOutstanding() {
    setAmount(totalSelectedOutstanding.toFixed(2));
    setModeRows([{ mode: 'Cash', amount: totalSelectedOutstanding.toFixed(2) }]);
  }

  // The day-of-surgery flow: patient already paid an advance at booking;
  // today the full remaining balance is collected upfront. This applies
  // the advance against the selected invoice(s) first (a real ledger
  // adjustment, not just arithmetic on screen -- the advance balance
  // actually goes down), then auto-fills the correct remaining amount
  // to collect, so nobody has to subtract by hand or remember to visit
  // the separate Adjustments tab.
  async function handleApplyAdvanceAndCollect() {
    setError('');
    if (selectedInvoiceIds.length === 0) { setError('Select at least one invoice.'); return; }
    if (advanceBalance <= 0) { setError('No advance balance available for this patient.'); return; }

    setApplyingAdvance(true);
    let remaining = advanceBalance;
    for (const invId of selectedInvoiceIds) {
      if (remaining <= 0) break;
      const inv = invoices.find((i) => i.id === invId);
      if (!inv) continue;
      const outstanding = Number(inv.net) - Number(inv.paid);
      if (outstanding <= 0.01) continue;
      const toApply = Math.min(remaining, outstanding);
      const result = await applyAdjustment(selectedPatient.id, invId, toApply);
      if (result.error) { setApplyingAdvance(false); setError(result.error); return; }
      remaining -= toApply;
    }

    const [refreshedInvoices, refreshedAdvance] = await Promise.all([
      getOutstandingInvoices(selectedPatient.id),
      getAdvanceBalance(selectedPatient.id),
    ]);
    setInvoices(refreshedInvoices);
    setAdvanceBalance(refreshedAdvance);
    const stillOutstandingIds = refreshedInvoices.filter((i) => selectedInvoiceIds.includes(i.id)).map((i) => i.id);
    setSelectedInvoiceIds(stillOutstandingIds);
    const newTotal = refreshedInvoices
      .filter((i) => stillOutstandingIds.includes(i.id))
      .reduce((s, i) => s + (Number(i.net) - Number(i.paid)), 0);
    setAmount(newTotal.toFixed(2));
    setModeRows([{ mode: 'Cash', amount: newTotal.toFixed(2) }]);
    setApplyingAdvance(false);
  }

  function updateModeRow(idx, field, value) {
    setModeRows((rows) => rows.map((r, i) => (i === idx ? { ...r, [field]: value } : r)));
  }

  function addModeRow() {
    setModeRows((rows) => {
      // Moving from single-mode (auto-filled) to a real split -- clear
      // amounts so staff explicitly enters how much goes to each mode,
      // rather than leaving a stale auto-filled value on the first row.
      const cleared = rows.length === 1 ? [{ ...rows[0], amount: '' }] : rows;
      return [...cleared, { mode: 'Card', amount: '' }];
    });
  }

  function removeModeRow(idx) {
    setModeRows((rows) => {
      const remaining = rows.filter((_, i) => i !== idx);
      // Back to a single mode -- re-sync it to the amount collecting.
      return remaining.length === 1 ? [{ ...remaining[0], amount }] : remaining;
    });
  }

  function reset() {
    setSelectedPatient(null);
    setInvoices([]);
    setSelectedInvoiceIds([]);
    setAmount('');
    setModeRows([{ mode: 'Cash', amount: '' }]);
    setReference('');
    setRemarks('');
    setReceipt(null);
    setOverpaidAmount(0);
    setError('');
  }

  async function handleCollect() {
    setError('');
    if (selectedInvoiceIds.length === 0) { setError('Select at least one invoice to pay.'); return; }
    const amt = parseFloat(amount);
    if (!amt || amt <= 0) { setError('Enter a valid amount collecting.'); return; }
    if (Math.abs(modesTotal - amt) > 0.01) {
      setError(`Payment mode split (Rs.${modesTotal.toFixed(2)}) must add up to the amount collecting (Rs.${amt.toFixed(2)}).`);
      return;
    }

    setLoading(true);
    const modesPayload = modeRows.filter((m) => parseFloat(m.amount) > 0).map((m) => ({ mode: m.mode, amount: parseFloat(m.amount) }));
    const result = await collectPayment(selectedPatient.id, selectedInvoiceIds, amt, modesPayload, reference, remarks);
    setLoading(false);

    if (result.error) { setError(result.error); return; }
    // Anything collected beyond the selected invoices' outstanding
    // total was automatically credited to advance -- surface that so
    // it's not a silent surprise.
    const overpaid = amt - totalSelectedOutstanding;
    setOverpaidAmount(overpaid > 0.01 ? overpaid : 0);
    setReceipt(result.payment);
  }

  // Collecting from a specific invoice means this was reached via a
  // link from the Billing Dashboard (Outstanding Invoices, Today's
  // Visits, or Recent Invoices) -- once paid, the natural next step is
  // back there rather than sitting on this form. A short delay keeps
  // the receipt confirmation visible instead of yanking it away.
  useEffect(() => {
    if (!receipt || !urlInvoiceId) return;
    const timer = setTimeout(() => router.push('/billing'), 2500);
    return () => clearTimeout(timer);
  }, [receipt, urlInvoiceId, router]);

  if (receipt) {
    return (
      <div className="card">
        <div className="msg-success">
          <i className="ti ti-circle-check"></i> Payment collected -- Receipt <strong>{receipt.receipt_number}</strong> -- Rs.{receipt.total_amount}
        </div>
        {overpaidAmount > 0 && (
          <div className="msg-info" style={{ background: 'var(--purple-lt)', color: 'var(--purple)', padding: '8px 12px', borderRadius: 8, fontSize: 12 }}>
            <i className="ti ti-piggy-bank"></i> Rs.{overpaidAmount.toFixed(2)} was more than the selected invoices' balance -- credited to this patient's advance for future use.
          </div>
        )}
        <div style={{ fontSize: 13, lineHeight: 1.9 }}>
          <div><strong>Patient:</strong> {selectedPatient.first_name} {selectedPatient.last_name} -- {selectedPatient.uhid}</div>
          <div><strong>Amount:</strong> Rs.{receipt.total_amount}</div>
          {receipt.reference && <div><strong>Reference:</strong> {receipt.reference}</div>}
        </div>
        <div style={{ display: 'flex', gap: 8, marginTop: 16 }}>
          {urlInvoiceId ? (
            <>
              <button className="btn btn-primary" onClick={() => router.push('/billing')}>
                <i className="ti ti-arrow-left"></i> Back to Billing Dashboard
              </button>
              <span style={{ fontSize: 11, color: 'var(--g400)', alignSelf: 'center' }}>Returning automatically...</span>
            </>
          ) : (
            <button className="btn btn-primary" onClick={reset}>Collect another payment</button>
          )}
        </div>
      </div>
    );
  }

  return (
    <div style={{ display: 'grid', gridTemplateColumns: '2fr 1fr', gap: 20 }}>
      <div className="card">
        <div className="card-title" style={{ marginBottom: 10 }}>
          <i className="ti ti-cash" style={{ color: 'var(--green)' }}></i> Collect Payment
        </div>

        {error && <div className="msg-err">{error}</div>}

        {!selectedPatient ? (
          <div>
            <label className="flbl">Patient (name, UHID, or mobile) *</label>
            <div style={{ display: 'flex', gap: 8 }}>
              <input className="fi" value={searchQuery} onChange={(e) => setSearchQuery(e.target.value)} placeholder="Type to search..." />
              <button className="btn btn-primary" onClick={handleSearch}><i className="ti ti-search"></i></button>
            </div>
            {searchResults.length > 0 && (
              <div style={{ border: '1px solid var(--g200)', borderRadius: 8, marginTop: 8 }}>
                {searchResults.map((p) => (
                  <div key={p.id} onClick={() => pickPatient(p)} style={{ padding: '8px 12px', cursor: 'pointer', borderBottom: '1px solid var(--g100)', fontSize: 13 }}>
                    <strong>{p.first_name} {p.last_name}</strong> -- {p.uhid}
                  </div>
                ))}
              </div>
            )}
          </div>
        ) : (
          <div>
            <div style={{ background: 'var(--green-lt)', padding: '10px 14px', borderRadius: 8, marginBottom: 14 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                <div>
                  <div style={{ fontWeight: 700 }}>{selectedPatient.first_name} {selectedPatient.last_name}</div>
                  <div style={{ fontSize: 11, color: 'var(--g600)' }}>{selectedPatient.uhid}</div>
                </div>
                <button className="btn btn-sm" onClick={reset}>Change</button>
              </div>
              <div style={{ fontSize: 11, marginTop: 5 }}>
                <span style={{ color: 'var(--purple)', fontWeight: 600 }}>Advance balance: </span>
                <span style={{ fontWeight: 700, color: 'var(--purple)' }}>Rs.{advanceBalance}</span>
                {advanceBalance > 0 && <span style={{ color: 'var(--g500)', marginLeft: 4 }}>-- use the purple button below to apply it</span>}
              </div>
            </div>

            <label className="flbl">Select invoice(s) to pay *</label>
            {invoices.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)', marginBottom: 14 }}>No outstanding invoices for this patient.</div>}
            <div style={{ marginBottom: 14 }}>
              {invoices.map((inv) => (
                <label
                  key={inv.id}
                  style={{
                    display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '6px 4px',
                    borderBottom: '1px solid var(--g100)', fontSize: 13, cursor: 'pointer',
                    background: inv.id === highlightInvoiceId ? 'var(--green-lt)' : 'transparent', borderRadius: 4,
                  }}
                >
                  <span>
                    <input type="checkbox" checked={selectedInvoiceIds.includes(inv.id)} onChange={() => toggleInvoice(inv.id)} style={{ marginRight: 8 }} />
                    {inv.invoice_number} -- <span className={`badge ${inv.status === 'Partial' ? 'b-amber' : 'b-red'}`}>{inv.status}</span>
                    {inv.id === highlightInvoiceId && <span className="badge b-green" style={{ marginLeft: 6 }}>Just billed</span>}
                  </span>
                  <span style={{ fontWeight: 600 }}>Rs.{(inv.net - inv.paid).toFixed(2)}</span>
                </label>
              ))}
            </div>

            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10, marginBottom: 10 }}>
              <div>
                <label className="flbl">Amount collecting (Rs.) *</label>
                <input type="number" className="fi" value={amount} onChange={(e) => setAmount(e.target.value)} placeholder="0.00" />
              </div>
              <div>
                <label className="flbl">Total selected outstanding</label>
                <input className="fi" value={`Rs.${totalSelectedOutstanding.toFixed(2)}`} readOnly style={{ background: 'var(--g50)', fontWeight: 700, color: 'var(--red)' }} />
              </div>
            </div>
            <div style={{ display: 'flex', gap: 8, marginBottom: 14, flexWrap: 'wrap' }}>
              <button className="btn btn-sm" onClick={useFullOutstanding}>Use full outstanding amount</button>
              {advanceBalance > 0 && (
                <button className="btn btn-sm" style={{ background: 'var(--purple)', color: '#fff', border: 'none' }} onClick={handleApplyAdvanceAndCollect} disabled={applyingAdvance}>
                  <i className="ti ti-piggy-bank"></i> {applyingAdvance ? 'Applying advance...' : 'Apply Advance & Auto-fill Remaining'}
                </button>
              )}
            </div>

            <label className="flbl">Payment mode(s) * -- split across multiple if needed</label>
            {modeRows.map((row, idx) => (
              <div key={idx} style={{ display: 'flex', gap: 8, marginBottom: 6 }}>
                <select className="fi" value={row.mode} onChange={(e) => updateModeRow(idx, 'mode', e.target.value)} style={{ flex: 1 }}>
                  {MODES.map((m) => <option key={m} value={m}>{m}</option>)}
                </select>
                <input
                  type="number"
                  className="fi"
                  value={row.amount}
                  onChange={(e) => updateModeRow(idx, 'amount', e.target.value)}
                  placeholder={modeRows.length === 1 ? 'Auto-filled from amount above' : 'Amount'}
                  readOnly={modeRows.length === 1}
                  style={{ flex: 1, background: modeRows.length === 1 ? 'var(--g50)' : '#fff' }}
                />
                {modeRows.length > 1 && <button className="btn" onClick={() => removeModeRow(idx)} style={{ padding: '4px 10px' }}>x</button>}
              </div>
            ))}
            <button className="btn btn-sm" onClick={addModeRow} style={{ marginBottom: 6 }}><i className="ti ti-plus"></i> Add mode</button>
            <div style={{ fontSize: 11, color: Math.abs(modesTotal - (parseFloat(amount) || 0)) > 0.01 ? 'var(--red)' : 'var(--green)', marginBottom: 14 }}>
              Split total: Rs.{modesTotal.toFixed(2)}
            </div>

            <div style={{ marginBottom: 10 }}>
              <label className="flbl">Reference / Transaction ID</label>
              <input className="fi" value={reference} onChange={(e) => setReference(e.target.value)} placeholder="UPI ref, card last 4, cheque no..." />
            </div>
            <div style={{ marginBottom: 16 }}>
              <label className="flbl">Remarks</label>
              <input className="fi" value={remarks} onChange={(e) => setRemarks(e.target.value)} placeholder="Optional..." />
            </div>

            <button className="btn btn-green" onClick={handleCollect} disabled={loading}>
              <i className="ti ti-circle-check"></i> {loading ? 'Finalizing...' : 'Finalize Payment'}
            </button>
          </div>
        )}
      </div>

      <div>
        {!urlPatientId && (
          <div className="card" style={{ marginBottom: 16 }}>
            <div className="card-title" style={{ marginBottom: 10 }}>
              <i className="ti ti-receipt" style={{ color: 'var(--red)' }}></i> Unpaid Invoices
            </div>
            <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 8 }}>Click one to start collecting for that patient.</div>
            {unpaidInvoices.map((inv) => (
              <div
                key={inv.id}
                onClick={() => { setHighlightInvoiceId(inv.id); pickPatient(inv.patients); }}
                style={{ padding: '8px 4px', cursor: 'pointer', borderBottom: '1px solid var(--g100)', fontSize: 12 }}
              >
                <div style={{ display: 'flex', justifyContent: 'space-between' }}>
                  <strong>{inv.patients?.first_name} {inv.patients?.last_name}</strong>
                  <span className={`badge ${STATUS_BADGE[inv.status] || 'b-gray'}`}>{inv.status}</span>
                </div>
                <div style={{ color: 'var(--g500)', fontFamily: 'monospace', display: 'flex', justifyContent: 'space-between' }}>
                  <span>{inv.invoice_number}</span>
                  <span>Rs.{(inv.net - inv.paid).toFixed(2)}</span>
                </div>
              </div>
            ))}
            {unpaidInvoices.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>Nothing outstanding right now.</div>}
          </div>
        )}

        <div className="card">
          <div className="card-title" style={{ marginBottom: 10 }}>
            <i className="ti ti-calculator" style={{ color: 'var(--green)' }}></i> Payment Summary
          </div>
          {!selectedPatient ? (
            <div style={{ textAlign: 'center', padding: 20, color: 'var(--g400)', fontSize: 13 }}>Select patient and invoice</div>
          ) : (
            <div style={{ fontSize: 13, lineHeight: 1.9 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>Invoices selected</span><span>{selectedInvoiceIds.length}</span></div>
              <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>Total outstanding</span><span>Rs.{totalSelectedOutstanding.toFixed(2)}</span></div>
              <div style={{ display: 'flex', justifyContent: 'space-between', fontWeight: 700 }}><span>Amount collecting</span><span>Rs.{(parseFloat(amount) || 0).toFixed(2)}</span></div>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}



VEDA_EOF_MARKER

mkdir -p "$(dirname "app/(main)/payments/advance/advance-tab.js")"
cat > "app/(main)/payments/advance/advance-tab.js" << 'VEDA_EOF_MARKER'
'use client';

import { useState, useEffect, useCallback, useRef } from 'react';
import { useSearchParams, useRouter } from 'next/navigation';
import { searchPatientsForPayment, getAdvanceBalance, collectAdvance, getCurrentBalancesByPatient, getLedgerHistory, getTodaysVisits, getPatientById } from '../actions';
import TodaysVisitsWidget from '../todays-visits-widget';

const ADVANCE_TYPES = ['Surgery Advance', 'General Advance', 'Package Advance', 'Other'];
const MODES = ['Cash', 'Card', 'UPI', 'Cheque', 'Bank Transfer'];

const RETURN_LABELS = { 'ot-intraop': 'Operation Theatre' };

export default function AdvanceTab() {
  const searchParams = useSearchParams();
  const router = useRouter();
  const urlPatientId = searchParams.get('patientId');
  const urlAmount = searchParams.get('amount');
  const returnTo = searchParams.get('returnTo');
  const autofillDoneFor = useRef(null);

  const [searchQuery, setSearchQuery] = useState('');
  const [searchResults, setSearchResults] = useState([]);
  const [selectedPatient, setSelectedPatient] = useState(null);
  const [currentBalance, setCurrentBalance] = useState(0);

  const [advanceType, setAdvanceType] = useState('Surgery Advance');
  const [amount, setAmount] = useState('');
  const [modeRows, setModeRows] = useState([{ mode: 'Cash', amount: '' }]);

  // Same simplification as Collect Payment: in the common single-mode
  // case, the mode amount always matches the amount field -- no need to
  // type the same number twice.
  useEffect(() => {
    setModeRows((rows) => (rows.length === 1 ? [{ ...rows[0], amount }] : rows));
  }, [amount]);
  const [reference, setReference] = useState('');
  const [remarks, setRemarks] = useState('');

  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);
  const [success, setSuccess] = useState(null);

  const [balances, setBalances] = useState([]);
  const [history, setHistory] = useState([]);
  const [todaysVisits, setTodaysVisits] = useState([]);

  const refreshSidebar = useCallback(async () => {
    setBalances(await getCurrentBalancesByPatient());
    setHistory(await getLedgerHistory());
  }, []);

  useEffect(() => { refreshSidebar(); }, [refreshSidebar]);
  useEffect(() => { getTodaysVisits().then(setTodaysVisits); }, []);

  // Arrived from OT Dashboard's "Collect Advance" button -- patient and
  // suggested amount (package price minus whatever advance already
  // exists) are already known, so skip the search step entirely.
  useEffect(() => {
    if (!urlPatientId) return;
    if (autofillDoneFor.current === urlPatientId) return;
    autofillDoneFor.current = urlPatientId;
    (async () => {
      const result = await getPatientById(urlPatientId);
      if (result.error) { setError(result.error); return; }
      await pickPatient(result.patient);
      if (urlAmount) setAmount(urlAmount);
    })();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [urlPatientId, urlAmount]);

  const modesTotal = modeRows.reduce((s, m) => s + (parseFloat(m.amount) || 0), 0);

  async function handleSearch() {
    if (!searchQuery.trim()) return;
    setSearchResults(await searchPatientsForPayment(searchQuery.trim()));
  }

  // Live search as the user types -- no need to press the Search button.
  useEffect(() => {
    const q = searchQuery.trim();
    if (q.length < 2) { setSearchResults([]); return; }
    const t = setTimeout(async () => {
      setSearchResults(await searchPatientsForPayment(q));
    }, 300);
    return () => clearTimeout(t);
  }, [searchQuery]);

  async function pickPatient(p) {
    setError('');
    setSelectedPatient(p);
    setSearchResults([]);
    setSearchQuery('');
    setCurrentBalance(await getAdvanceBalance(p.id));
  }

  function updateModeRow(idx, field, value) {
    setModeRows((rows) => rows.map((r, i) => (i === idx ? { ...r, [field]: value } : r)));
  }
  function addModeRow() {
    setModeRows((rows) => {
      const cleared = rows.length === 1 ? [{ ...rows[0], amount: '' }] : rows;
      return [...cleared, { mode: 'Card', amount: '' }];
    });
  }
  function removeModeRow(idx) {
    setModeRows((rows) => {
      const remaining = rows.filter((_, i) => i !== idx);
      return remaining.length === 1 ? [{ ...remaining[0], amount }] : remaining;
    });
  }

  function reset() {
    setSelectedPatient(null);
    setAmount('');
    setModeRows([{ mode: 'Cash', amount: '' }]);
    setReference('');
    setRemarks('');
    setSuccess(null);
    setError('');
  }

  async function handleCollect() {
    setError('');
    const amt = parseFloat(amount);
    if (!amt || amt <= 0) { setError('Enter a valid amount.'); return; }
    if (Math.abs(modesTotal - amt) > 0.01) {
      setError(`Payment mode split (Rs.${modesTotal.toFixed(2)}) must add up to the amount (Rs.${amt.toFixed(2)}).`);
      return;
    }

    setLoading(true);
    const modesPayload = modeRows.filter((m) => parseFloat(m.amount) > 0).map((m) => ({ mode: m.mode, amount: parseFloat(m.amount) }));
    const result = await collectAdvance(selectedPatient.id, advanceType, amt, modesPayload, reference, remarks);
    setLoading(false);

    if (result.error) { setError(result.error); return; }
    setSuccess(result.payment);
    refreshSidebar();
  }

  // Collecting via a returnTo link (e.g. from OT Dashboard) means the
  // natural next step is back there, not sitting on this form.
  useEffect(() => {
    if (!success || !returnTo) return;
    const timer = setTimeout(() => router.push(`/${returnTo}`), 2500);
    return () => clearTimeout(timer);
  }, [success, returnTo, router]);

  return (
    <div style={{ display: 'grid', gridTemplateColumns: '1.3fr 1fr', gap: 20 }}>
      <div className="card">
        <div className="card-title" style={{ marginBottom: 4 }}>
          <i className="ti ti-wallet" style={{ color: 'var(--purple)' }}></i> Advance Collection
        </div>
        <div className="msg-info">
          <i className="ti ti-info-circle"></i> Advance collected without invoice. Balance held in Patient Ledger and adjusted against future invoices.
        </div>

        {error && <div className="msg-err">{error}</div>}

        {success ? (
          <div className="msg-success">
            <i className="ti ti-circle-check"></i> Advance collected -- Receipt <strong>{success.receipt_number}</strong> -- Rs.{success.total_amount}
            <div style={{ marginTop: 10, display: 'flex', gap: 8, alignItems: 'center' }}>
              {returnTo ? (
                <>
                  <button className="btn btn-sm btn-primary" onClick={() => router.push(`/${returnTo}`)}>
                    <i className="ti ti-arrow-left"></i> Back to {RETURN_LABELS[returnTo] || returnTo}
                  </button>
                  <span style={{ fontSize: 11, color: 'var(--g400)' }}>Returning automatically...</span>
                </>
              ) : (
                <button className="btn btn-sm" onClick={reset}>Collect another advance</button>
              )}
            </div>
          </div>
        ) : !selectedPatient ? (
          <div>
            <label className="flbl">Patient *</label>
            <div style={{ display: 'flex', gap: 8 }}>
              <input className="fi" value={searchQuery} onChange={(e) => setSearchQuery(e.target.value)} placeholder="Patient name or UHID..." />
              <button className="btn btn-primary" onClick={handleSearch}><i className="ti ti-search"></i></button>
            </div>
            {searchResults.length > 0 && (
              <div style={{ border: '1px solid var(--g200)', borderRadius: 8, marginTop: 8 }}>
                {searchResults.map((p) => (
                  <div key={p.id} onClick={() => pickPatient(p)} style={{ padding: '8px 12px', cursor: 'pointer', borderBottom: '1px solid var(--g100)', fontSize: 13 }}>
                    <strong>{p.first_name} {p.last_name}</strong> -- {p.uhid}
                  </div>
                ))}
              </div>
            )}
          </div>
        ) : (
          <div>
            <div style={{ background: 'var(--purple-lt)', padding: '10px 14px', borderRadius: 8, marginBottom: 14 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                <div>
                  <div style={{ fontWeight: 700 }}>{selectedPatient.first_name} {selectedPatient.last_name}</div>
                  <div style={{ fontSize: 11, color: 'var(--g600)' }}>{selectedPatient.uhid}</div>
                </div>
                <button className="btn btn-sm" onClick={reset}>Change</button>
              </div>
              <div style={{ fontSize: 12, marginTop: 6 }}>Current advance: <strong style={{ color: 'var(--purple)' }}>Rs.{currentBalance}</strong></div>
            </div>

            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10, marginBottom: 10 }}>
              <div>
                <label className="flbl">Advance type</label>
                <select className="fi" value={advanceType} onChange={(e) => setAdvanceType(e.target.value)}>
                  {ADVANCE_TYPES.map((t) => <option key={t}>{t}</option>)}
                </select>
              </div>
              <div>
                <label className="flbl">Amount (Rs.) *</label>
                <input type="number" className="fi" value={amount} onChange={(e) => setAmount(e.target.value)} placeholder="0.00" />
              </div>
            </div>

            <label className="flbl">Payment mode(s) *</label>
            {modeRows.map((row, idx) => (
              <div key={idx} style={{ display: 'flex', gap: 8, marginBottom: 6 }}>
                <select className="fi" value={row.mode} onChange={(e) => updateModeRow(idx, 'mode', e.target.value)} style={{ flex: 1 }}>
                  {MODES.map((m) => <option key={m} value={m}>{m}</option>)}
                </select>
                <input
                  type="number"
                  className="fi"
                  value={row.amount}
                  onChange={(e) => updateModeRow(idx, 'amount', e.target.value)}
                  placeholder={modeRows.length === 1 ? 'Auto-filled from amount above' : 'Amount'}
                  readOnly={modeRows.length === 1}
                  style={{ flex: 1, background: modeRows.length === 1 ? 'var(--g50)' : '#fff' }}
                />
                {modeRows.length > 1 && <button className="btn" onClick={() => removeModeRow(idx)} style={{ padding: '4px 10px' }}>x</button>}
              </div>
            ))}
            <button className="btn btn-sm" onClick={addModeRow} style={{ marginBottom: 6 }}><i className="ti ti-plus"></i> Add mode</button>
            <div style={{ fontSize: 11, color: Math.abs(modesTotal - (parseFloat(amount) || 0)) > 0.01 ? 'var(--red)' : 'var(--green)', marginBottom: 14 }}>
              Split total: Rs.{modesTotal.toFixed(2)}
            </div>

            <div style={{ marginBottom: 10 }}>
              <label className="flbl">Reference / Transaction ID</label>
              <input className="fi" value={reference} onChange={(e) => setReference(e.target.value)} placeholder="UPI ref, cheque no..." />
            </div>
            <div style={{ marginBottom: 16 }}>
              <label className="flbl">Remarks</label>
              <input className="fi" value={remarks} onChange={(e) => setRemarks(e.target.value)} placeholder="e.g. Surgery scheduled 30 Jun..." />
            </div>

            <button className="btn btn-green" onClick={handleCollect} disabled={loading}>
              <i className="ti ti-circle-check"></i> {loading ? 'Collecting...' : 'Collect advance'}
            </button>
          </div>
        )}
      </div>

      <div>
        <TodaysVisitsWidget visits={todaysVisits} onSelect={pickPatient} />

        <div className="card" style={{ marginBottom: 16 }}>
          <div className="card-title" style={{ marginBottom: 10 }}>
            <i className="ti ti-wallet" style={{ color: 'var(--purple)' }}></i> Current Balance by Patient
          </div>
          <table className="tbl">
            <thead><tr><th>Patient</th><th>Balance</th></tr></thead>
            <tbody>
              {balances.map((b, i) => (
                <tr key={i}><td>{b.patient?.first_name} {b.patient?.last_name}</td><td style={{ fontWeight: 700, color: 'var(--purple)' }}>Rs.{b.balance.toFixed(2)}</td></tr>
              ))}
              {balances.length === 0 && <tr><td colSpan={2} style={{ padding: 12, textAlign: 'center', color: 'var(--g400)' }}>No advances held.</td></tr>}
            </tbody>
          </table>
        </div>

        <div className="card">
          <div className="card-title" style={{ marginBottom: 4 }}>
            <i className="ti ti-history" style={{ color: 'var(--g500)' }}></i> Transaction History
          </div>
          <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 8 }}>
            Immutable record -- entries are never edited, only added to.
          </div>
          <table className="tbl">
            <thead><tr><th>Patient</th><th>Type</th><th>Amount</th></tr></thead>
            <tbody>
              {history.map((h) => (
                <tr key={h.id}>
                  <td>{h.patients?.first_name} {h.patients?.last_name}</td>
                  <td><span className={`badge ${h.entry_type === 'Advance Collected' ? 'b-green' : 'b-amber'}`}>{h.entry_type}</span></td>
                  <td style={{ fontWeight: 600 }}>Rs.{Math.abs(h.amount).toFixed(2)}</td>
                </tr>
              ))}
              {history.length === 0 && <tr><td colSpan={3} style={{ padding: 12, textAlign: 'center', color: 'var(--g400)' }}>No transactions yet.</td></tr>}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  );
}



VEDA_EOF_MARKER

mkdir -p "$(dirname "app/(main)/payments/credit-note/credit-note-tab.js")"
cat > "app/(main)/payments/credit-note/credit-note-tab.js" << 'VEDA_EOF_MARKER'
'use client';

import { useState, useEffect } from 'react';
import { searchPatientsForPayment, getOutstandingInvoices, getApprovers, createCreditNote, getCreditNoteRegister, getTodaysVisits } from '../actions';
import TodaysVisitsWidget from '../todays-visits-widget';

const REASONS = ['Billing correction', 'Service cancellation', 'Approved financial adjustment', 'Goodwill gesture', 'Insurance adjustment', 'Other'];

export default function CreditNoteTab() {
  const [searchQuery, setSearchQuery] = useState('');
  const [searchResults, setSearchResults] = useState([]);
  const [patient, setPatient] = useState(null);
  const [invoices, setInvoices] = useState([]);
  const [approvers, setApprovers] = useState([]);
  const [register, setRegister] = useState([]);

  const [invoiceId, setInvoiceId] = useState('');
  const [amount, setAmount] = useState('');
  const [reason, setReason] = useState('');
  const [approvedBy, setApprovedBy] = useState('');
  const [remarks, setRemarks] = useState('');

  const [error, setError] = useState('');
  const [success, setSuccess] = useState('');
  const [loading, setLoading] = useState(false);
  const [todaysVisits, setTodaysVisits] = useState([]);

  useEffect(() => {
    getApprovers().then(setApprovers);
    refreshRegister();
    getTodaysVisits().then(setTodaysVisits);
  }, []);

  async function refreshRegister() {
    setRegister(await getCreditNoteRegister());
  }

  async function handleSearch() {
    if (!searchQuery.trim()) return;
    setSearchResults(await searchPatientsForPayment(searchQuery.trim()));
  }

  // Live search as the user types -- no need to press the Search button.
  useEffect(() => {
    const q = searchQuery.trim();
    if (q.length < 2) { setSearchResults([]); return; }
    const t = setTimeout(async () => {
      setSearchResults(await searchPatientsForPayment(q));
    }, 300);
    return () => clearTimeout(t);
  }, [searchQuery]);

  async function pickPatient(p) {
    setError(''); setSuccess('');
    setPatient(p);
    setSearchResults([]);
    setSearchQuery('');
    setInvoices(await getOutstandingInvoices(p.id));
    setInvoiceId(''); setAmount(''); setReason(''); setApprovedBy(''); setRemarks('');
  }

  function changePatient() {
    setPatient(null);
    setInvoices([]);
  }

  const selectedInvoice = invoices.find((i) => i.id === invoiceId);
  const outstandingOnSelected = selectedInvoice ? Number(selectedInvoice.net) - Number(selectedInvoice.paid) : 0;

  async function handleSubmit() {
    setError(''); setSuccess('');
    if (!invoiceId) { setError('Select an invoice to credit.'); return; }
    const amt = parseFloat(amount);
    if (!amt || amt <= 0) { setError('Enter a valid credit amount.'); return; }
    if (amt > outstandingOnSelected) { setError(`Credit amount cannot exceed this invoice's outstanding balance (Rs.${outstandingOnSelected.toFixed(2)}).`); return; }
    if (!reason) { setError('Select a reason.'); return; }
    if (!approvedBy) { setError('Select an approver.'); return; }

    setLoading(true);
    const result = await createCreditNote(patient.id, invoiceId, amt, reason, approvedBy, remarks);
    setLoading(false);

    if (result.error) { setError(result.error); return; }
    setSuccess(`Credit note ${result.creditNote.credit_note_number} created for Rs.${amt.toFixed(2)}.`);
    setInvoiceId(''); setAmount(''); setReason(''); setApprovedBy(''); setRemarks('');
    setInvoices(await getOutstandingInvoices(patient.id));
    refreshRegister();
  }

  return (
    <div style={{ display: 'grid', gridTemplateColumns: '1.2fr 1fr', gap: 20 }}>
      <div className="card">
        <div className="card-title" style={{ marginBottom: 4 }}>
          <i className="ti ti-file-minus" style={{ color: 'var(--teal)' }}></i> Credit Note
        </div>
        <div className="msg-info" style={{ background: 'var(--teal-lt)', color: 'var(--teal)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
          <i className="ti ti-info-circle"></i> Reduces what a patient owes on an invoice without reversing any payment -- for billing corrections, service cancellations, goodwill, or insurance adjustments. Different from a refund, which returns money already collected.
        </div>

        {error && <div className="msg-err">{error}</div>}
        {success && <div className="msg-success"><i className="ti ti-circle-check"></i> {success}</div>}

        {!patient ? (
          <div>
            <label className="flbl">Patient</label>
            <div style={{ display: 'flex', gap: 8 }}>
              <input className="fi" value={searchQuery} onChange={(e) => setSearchQuery(e.target.value)} placeholder="Name, UHID, or mobile..." />
              <button className="btn btn-primary" onClick={handleSearch}><i className="ti ti-search"></i></button>
            </div>
            {searchResults.length > 0 && (
              <div style={{ border: '1px solid var(--g200)', borderRadius: 8, marginTop: 8 }}>
                {searchResults.map((p) => (
                  <div key={p.id} onClick={() => pickPatient(p)} style={{ padding: '8px 12px', cursor: 'pointer', borderBottom: '1px solid var(--g100)', fontSize: 13 }}>
                    <strong>{p.first_name} {p.last_name}</strong> -- {p.uhid}
                  </div>
                ))}
              </div>
            )}
            <div style={{ marginTop: 16 }}>
              <TodaysVisitsWidget visits={todaysVisits} onSelect={pickPatient} />
            </div>
          </div>
        ) : (
          <div>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', background: 'var(--teal-lt)', padding: '8px 12px', borderRadius: 8, marginBottom: 14 }}>
              <span><strong>{patient.first_name} {patient.last_name}</strong> -- {patient.uhid}</span>
              <button className="btn btn-sm" onClick={changePatient}>Change</button>
            </div>

            <label className="flbl">Invoice to credit *</label>
            <select className="fi" style={{ marginBottom: 12 }} value={invoiceId} onChange={(e) => setInvoiceId(e.target.value)}>
              <option value="">-- Select invoice --</option>
              {invoices.map((inv) => <option key={inv.id} value={inv.id}>{inv.invoice_number} -- Rs.{(inv.net - inv.paid).toFixed(2)} outstanding</option>)}
            </select>
            {invoices.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)', marginBottom: 12 }}>No outstanding invoices for this patient.</div>}

            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10, marginBottom: 12 }}>
              <div>
                <label className="flbl">Reason *</label>
                <select className="fi" value={reason} onChange={(e) => setReason(e.target.value)}>
                  <option value="">-- Select reason --</option>
                  {REASONS.map((r) => <option key={r} value={r}>{r}</option>)}
                </select>
              </div>
              <div>
                <label className="flbl">Credit amount (Rs.) *</label>
                <input type="number" className="fi" value={amount} onChange={(e) => setAmount(e.target.value)} placeholder={selectedInvoice ? `Up to Rs.${outstandingOnSelected.toFixed(2)}` : '0.00'} />
              </div>
            </div>

            <label className="flbl">Approved by *</label>
            <select className="fi" style={{ marginBottom: 12 }} value={approvedBy} onChange={(e) => setApprovedBy(e.target.value)}>
              <option value="">-- Select approver --</option>
              {approvers.map((a) => <option key={a.id} value={a.id}>{a.full_name}{a.designation ? ` -- ${a.designation}` : ''}</option>)}
            </select>

            <label className="flbl">Remarks</label>
            <textarea className="fi" rows={2} style={{ marginBottom: 14 }} value={remarks} onChange={(e) => setRemarks(e.target.value)} placeholder="Supporting details for this credit note..." />

            <button className="btn" style={{ background: 'var(--teal)', color: '#fff', border: 'none' }} onClick={handleSubmit} disabled={loading || invoices.length === 0}>
              <i className="ti ti-file-minus"></i> {loading ? 'Creating...' : 'Create Credit Note'}
            </button>
          </div>
        )}
      </div>

      <div className="card">
        <div className="card-title" style={{ marginBottom: 10 }}>
          <i className="ti ti-history" style={{ color: 'var(--teal)' }}></i> Credit Note Register
        </div>
        <div style={{ maxHeight: 500, overflowY: 'auto' }}>
          <table className="tbl">
            <thead><tr><th>CN #</th><th>Patient</th><th>Invoice</th><th>Amount</th><th>Reason</th><th>Approved By</th></tr></thead>
            <tbody>
              {register.map((cn) => (
                <tr key={cn.id}>
                  <td style={{ fontFamily: 'monospace', fontSize: 11 }}>{cn.credit_note_number}</td>
                  <td style={{ fontSize: 12 }}>{cn.patients?.first_name} {cn.patients?.last_name}</td>
                  <td style={{ fontFamily: 'monospace', fontSize: 11 }}>{cn.invoices?.invoice_number || '--'}</td>
                  <td style={{ fontSize: 12, fontWeight: 600 }}>Rs.{Number(cn.amount).toFixed(2)}</td>
                  <td style={{ fontSize: 11 }}>{cn.reason}</td>
                  <td style={{ fontSize: 11 }}>{cn.profiles?.full_name || '--'}</td>
                </tr>
              ))}
              {register.length === 0 && (
                <tr><td colSpan={6} style={{ padding: 16, textAlign: 'center', color: 'var(--g400)' }}>No credit notes issued yet.</td></tr>
              )}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  );
}


VEDA_EOF_MARKER

mkdir -p "$(dirname "app/(main)/payments/ledger/ledger-tab.js")"
cat > "app/(main)/payments/ledger/ledger-tab.js" << 'VEDA_EOF_MARKER'
'use client';

import { useState, useEffect } from 'react';
import { searchPatientsForPayment, getPatientUnifiedLedger, getAdvanceBalance, getOutstandingInvoices, getTodaysVisits } from '../actions';
import TodaysVisitsWidget from '../todays-visits-widget';

const TYPE_COLOR = {
  Invoice: 'var(--red)', Payment: 'var(--green)', Advance: 'var(--purple)',
  'Advance Adjustment': 'var(--blue)', Refund: 'var(--amber)', 'Credit Note': 'var(--teal)',
};

function fmt(n) {
  return Number(n).toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

export default function LedgerTab() {
  const [searchQuery, setSearchQuery] = useState('');
  const [searchResults, setSearchResults] = useState([]);
  const [patient, setPatient] = useState(null);
  const [entries, setEntries] = useState([]);
  const [advanceBalance, setAdvanceBalance] = useState(0);
  const [outstandingInvoices, setOutstandingInvoices] = useState([]);
  const [typeFilter, setTypeFilter] = useState('');
  const [visitFilter, setVisitFilter] = useState('');
  const [fromDate, setFromDate] = useState('');
  const [toDate, setToDate] = useState('');
  const [loading, setLoading] = useState(false);
  const [todaysVisits, setTodaysVisits] = useState([]);

  useEffect(() => { getTodaysVisits().then(setTodaysVisits); }, []);

  async function handleSearch() {
    if (!searchQuery.trim()) return;
    setSearchResults(await searchPatientsForPayment(searchQuery.trim()));
  }

  // Live search as the user types -- no need to press the Search button.
  useEffect(() => {
    const q = searchQuery.trim();
    if (q.length < 2) { setSearchResults([]); return; }
    const t = setTimeout(async () => {
      setSearchResults(await searchPatientsForPayment(q));
    }, 300);
    return () => clearTimeout(t);
  }, [searchQuery]);

  async function pickPatient(p) {
    setLoading(true);
    setPatient(p);
    setSearchResults([]);
    setSearchQuery('');
    setTypeFilter(''); setVisitFilter(''); setFromDate(''); setToDate('');
    const [ledgerEntries, balance, outstanding] = await Promise.all([
      getPatientUnifiedLedger(p.id), getAdvanceBalance(p.id), getOutstandingInvoices(p.id),
    ]);
    setEntries(ledgerEntries);
    setAdvanceBalance(balance);
    setOutstandingInvoices(outstanding);
    setLoading(false);
  }

  function changePatient() {
    setPatient(null);
    setEntries([]);
  }

  const visits = [...new Set(entries.map((e) => e.visit).filter((v) => v && v !== '--'))];
  const filtered = entries.filter((e) => {
    if (typeFilter && e.type !== typeFilter) return false;
    if (visitFilter && e.visit !== visitFilter) return false;
    if (fromDate && new Date(e.date) < new Date(fromDate)) return false;
    if (toDate && new Date(e.date) > new Date(`${toDate}T23:59:59`)) return false;
    return true;
  });

  const totalInvoiced = entries.filter((e) => e.type === 'Invoice').reduce((s, e) => s + e.debit, 0);
  const totalCollected = entries.filter((e) => e.type !== 'Invoice').reduce((s, e) => s + e.credit - e.debit, 0);
  const currentBalance = entries.length > 0 ? entries[0].balance : 0;

  return (
    <div>
      <div className="card" style={{ marginBottom: 16 }}>
        <div className="card-title" style={{ marginBottom: 10 }}>
          <i className="ti ti-wallet" style={{ color: 'var(--purple)' }}></i> Patient Ledger
        </div>
        <div className="msg-info" style={{ background: 'var(--blue-lt)', color: 'var(--blue)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
          <i className="ti ti-info-circle"></i> Spans all visits for this patient. Outstanding balance is calculated dynamically from every entry below -- Balance {'>'} 0 means the patient owes the hospital; Balance {'<'} 0 means the hospital owes the patient (unused advance).
        </div>

        {!patient ? (
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 20 }}>
            <div>
              <label className="flbl">Search patient (name, UHID, or mobile)</label>
              <div style={{ display: 'flex', gap: 8 }}>
                <input className="fi" value={searchQuery} onChange={(e) => setSearchQuery(e.target.value)} placeholder="Type to search..." />
                <button className="btn btn-primary" onClick={handleSearch}><i className="ti ti-search"></i> Search</button>
              </div>
              {searchResults.length > 0 && (
                <div style={{ border: '1px solid var(--g200)', borderRadius: 8, marginTop: 8 }}>
                  {searchResults.map((p) => (
                    <div key={p.id} onClick={() => pickPatient(p)} style={{ padding: '8px 12px', cursor: 'pointer', borderBottom: '1px solid var(--g100)', fontSize: 13 }}>
                      <strong>{p.first_name} {p.last_name}</strong> -- {p.uhid}
                    </div>
                  ))}
                </div>
              )}
            </div>
            <TodaysVisitsWidget visits={todaysVisits} onSelect={pickPatient} />
          </div>
        ) : (
          <div>
            <div style={{ background: 'linear-gradient(135deg,#4c1d95,#6d28a8)', borderRadius: 12, padding: '14px 18px', color: '#fff', marginBottom: 16 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start' }}>
                <div>
                  <div style={{ fontSize: 16, fontWeight: 700 }}>{patient.first_name} {patient.last_name}</div>
                  <div style={{ fontSize: 12, opacity: .8, marginTop: 2 }}>{patient.uhid}</div>
                </div>
                <button className="btn btn-sm" onClick={changePatient} style={{ background: 'rgba(255,255,255,.15)', color: '#fff', border: '1px solid rgba(255,255,255,.3)' }}>
                  <i className="ti ti-arrow-left"></i> Change patient
                </button>
              </div>
              <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 10, marginTop: 14 }}>
                <div style={{ background: 'rgba(255,255,255,.12)', borderRadius: 8, padding: '8px 10px', border: '1px solid rgba(255,255,255,.2)' }}>
                  <div style={{ fontSize: 10, opacity: .75, textTransform: 'uppercase' }}>Total Invoiced</div>
                  <div style={{ fontSize: 15, fontWeight: 700, marginTop: 3 }}>Rs.{fmt(totalInvoiced)}</div>
                </div>
                <div style={{ background: 'rgba(255,255,255,.12)', borderRadius: 8, padding: '8px 10px', border: '1px solid rgba(255,255,255,.2)' }}>
                  <div style={{ fontSize: 10, opacity: .75, textTransform: 'uppercase' }}>Total Collected</div>
                  <div style={{ fontSize: 15, fontWeight: 700, marginTop: 3, color: '#86efac' }}>Rs.{fmt(totalCollected)}</div>
                </div>
                <div style={{ background: 'rgba(255,255,255,.12)', borderRadius: 8, padding: '8px 10px', border: '1px solid rgba(255,255,255,.2)' }}>
                  <div style={{ fontSize: 10, opacity: .75, textTransform: 'uppercase' }}>Advance Balance</div>
                  <div style={{ fontSize: 15, fontWeight: 700, marginTop: 3, color: '#c4b5fd' }}>Rs.{fmt(advanceBalance)}</div>
                </div>
                <div style={{ background: 'rgba(255,255,255,.12)', borderRadius: 8, padding: '8px 10px', border: '1px solid rgba(255,255,255,.2)' }}>
                  <div style={{ fontSize: 10, opacity: .75, textTransform: 'uppercase' }}>Current Balance</div>
                  <div style={{ fontSize: 15, fontWeight: 700, marginTop: 3, color: currentBalance > 0 ? '#fca5a5' : '#86efac' }}>Rs.{fmt(currentBalance)}</div>
                </div>
              </div>
            </div>

            {loading ? (
              <div style={{ textAlign: 'center', padding: 30, color: 'var(--g400)' }}>Loading ledger...</div>
            ) : (
              <>
                <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap', marginBottom: 12 }}>
                  <select className="fi" style={{ width: 'auto' }} value={typeFilter} onChange={(e) => setTypeFilter(e.target.value)}>
                    <option value="">All types</option>
                    {Object.keys(TYPE_COLOR).map((t) => <option key={t} value={t}>{t}</option>)}
                  </select>
                  <select className="fi" style={{ width: 'auto' }} value={visitFilter} onChange={(e) => setVisitFilter(e.target.value)}>
                    <option value="">All visits</option>
                    {visits.map((v) => <option key={v} value={v}>{v}</option>)}
                  </select>
                  <input type="date" className="fi" style={{ width: 'auto' }} value={fromDate} onChange={(e) => setFromDate(e.target.value)} />
                  <input type="date" className="fi" style={{ width: 'auto' }} value={toDate} onChange={(e) => setToDate(e.target.value)} />
                  {(typeFilter || visitFilter || fromDate || toDate) && (
                    <button className="btn btn-sm" onClick={() => { setTypeFilter(''); setVisitFilter(''); setFromDate(''); setToDate(''); }}>
                      <i className="ti ti-x"></i> Clear
                    </button>
                  )}
                </div>

                <div className="card" style={{ padding: 0, overflow: 'hidden', marginBottom: 12 }}>
                  <table className="tbl">
                    <thead>
                      <tr><th>Date/Time</th><th>Type</th><th>Reference</th><th>Visit</th><th>Description</th><th style={{ textAlign: 'right' }}>Debit</th><th style={{ textAlign: 'right' }}>Credit</th><th style={{ textAlign: 'right' }}>Balance</th></tr>
                    </thead>
                    <tbody>
                      {filtered.map((e, i) => (
                        <tr key={i} style={{ borderLeft: `3px solid ${TYPE_COLOR[e.type]}` }}>
                          <td style={{ fontSize: 11, whiteSpace: 'nowrap' }}>{new Date(e.date).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })}</td>
                          <td>
                            <span style={{ display: 'inline-flex', alignItems: 'center', gap: 5, fontSize: 12, fontWeight: 600 }}>
                              <span style={{ width: 7, height: 7, borderRadius: '50%', background: TYPE_COLOR[e.type], flexShrink: 0 }}></span>
                              {e.type}
                            </span>
                          </td>
                          <td style={{ fontFamily: 'monospace', fontSize: 11 }}>{e.ref}</td>
                          <td style={{ fontSize: 11 }}>{e.visit}</td>
                          <td style={{ fontSize: 12 }}>{e.desc}</td>
                          <td style={{ textAlign: 'right', fontSize: 12 }}>{e.debit > 0 ? <span style={{ color: 'var(--red)', fontWeight: 600 }}>{fmt(e.debit)}</span> : '--'}</td>
                          <td style={{ textAlign: 'right', fontSize: 12 }}>{e.credit > 0 ? <span style={{ color: 'var(--green)', fontWeight: 600 }}>{fmt(e.credit)}</span> : '--'}</td>
                          <td style={{ textAlign: 'right', fontWeight: 700, color: e.balance > 0 ? 'var(--red)' : e.balance < 0 ? 'var(--purple)' : 'var(--green)' }}>{fmt(e.balance)}</td>
                        </tr>
                      ))}
                      {filtered.length === 0 && (
                        <tr><td colSpan={8} style={{ padding: 20, textAlign: 'center', color: 'var(--g400)' }}>No entries match these filters.</td></tr>
                      )}
                    </tbody>
                  </table>
                </div>

                <div className="card" style={{ padding: '10px 14px' }}>
                  <div style={{ display: 'flex', gap: 16, flexWrap: 'wrap', fontSize: 12, color: 'var(--g600)' }}>
                    {Object.entries(TYPE_COLOR).map(([type, color]) => (
                      <span key={type}><span style={{ display: 'inline-block', width: 8, height: 8, borderRadius: '50%', background: color, marginRight: 4 }}></span>{type}</span>
                    ))}
                  </div>
                </div>
              </>
            )}
          </div>
        )}
      </div>
    </div>
  );
}


VEDA_EOF_MARKER

mkdir -p "$(dirname "app/(main)/payments/refund/refund-tab.js")"
cat > "app/(main)/payments/refund/refund-tab.js" << 'VEDA_EOF_MARKER'
'use client';

import { useState, useEffect } from 'react';
import { searchPatientsForPayment, getPatientPayments, getAdvanceBalance, getApprovers, refundPayment, refundAdvance, getRefundRegister, getTodaysVisits } from '../actions';
import TodaysVisitsWidget from '../todays-visits-widget';

const REASONS = ['Excess payment', 'Cancelled service', 'Duplicate payment', 'Service not rendered', 'Patient request -- approved', 'Other approved reason'];
const MODES = ['Cash', 'Card', 'UPI', 'Cheque', 'Bank Transfer'];

export default function RefundTab() {
  const [searchQuery, setSearchQuery] = useState('');
  const [searchResults, setSearchResults] = useState([]);
  const [patient, setPatient] = useState(null);
  const [payments, setPayments] = useState([]);
  const [advanceBalance, setAdvanceBalance] = useState(0);
  const [approvers, setApprovers] = useState([]);
  const [register, setRegister] = useState([]);

  const [refundFor, setRefundFor] = useState(null);
  const [amount, setAmount] = useState('');
  const [reason, setReason] = useState('');
  const [mode, setMode] = useState('');
  const [approvedBy, setApprovedBy] = useState('');
  const [remarks, setRemarks] = useState('');

  const [error, setError] = useState('');
  const [success, setSuccess] = useState('');
  const [loading, setLoading] = useState(false);
  const [todaysVisits, setTodaysVisits] = useState([]);

  useEffect(() => {
    getApprovers().then(setApprovers);
    refreshRegister();
    getTodaysVisits().then(setTodaysVisits);
  }, []);

  async function refreshRegister() {
    setRegister(await getRefundRegister());
  }

  async function handleSearch() {
    if (!searchQuery.trim()) return;
    setSearchResults(await searchPatientsForPayment(searchQuery.trim()));
  }

  // Live search as the user types -- no need to press the Search button.
  useEffect(() => {
    const q = searchQuery.trim();
    if (q.length < 2) { setSearchResults([]); return; }
    const t = setTimeout(async () => {
      setSearchResults(await searchPatientsForPayment(q));
    }, 300);
    return () => clearTimeout(t);
  }, [searchQuery]);

  async function pickPatient(p) {
    setError(''); setSuccess('');
    setPatient(p);
    setSearchResults([]);
    setSearchQuery('');
    setRefundFor(null);
    const [pmts, balance] = await Promise.all([getPatientPayments(p.id), getAdvanceBalance(p.id)]);
    setPayments(pmts);
    setAdvanceBalance(balance);
  }

  function changePatient() {
    setPatient(null);
    setPayments([]);
    setRefundFor(null);
  }

  function startRefund(payment, allocation) {
    setError(''); setSuccess('');
    setRefundFor({ kind: 'invoice', payment, allocation });
    setAmount(''); setReason(''); setMode(''); setApprovedBy(''); setRemarks('');
  }

  function startRefundAdvance() {
    setError(''); setSuccess('');
    setRefundFor({ kind: 'advance' });
    setAmount(''); setReason(''); setMode(''); setApprovedBy(''); setRemarks('');
  }

  const totalPaid = payments.reduce((s, p) => s + Number(p.total_amount), 0);
  const totalRefundable = payments.reduce((s, p) => s + (p.payment_allocations || []).reduce((s2, a) => s2 + Math.max(0, a.refundable), 0), 0);

  async function confirmRefund() {
    setError('');
    const amt = parseFloat(amount);
    if (!amt || amt <= 0) { setError('Enter a valid refund amount.'); return; }
    if (!reason) { setError('Select a refund reason.'); return; }
    if (!mode) { setError('Select a refund mode.'); return; }
    if (!approvedBy) { setError('Select an approver.'); return; }

    setLoading(true);
    let result;
    if (refundFor.kind === 'advance') {
      if (amt > advanceBalance) { setLoading(false); setError(`Refund amount cannot exceed the available advance balance (Rs.${advanceBalance}).`); return; }
      result = await refundAdvance(patient.id, amt, reason, mode, approvedBy);
    } else {
      if (amt > refundFor.allocation.refundable) { setLoading(false); setError(`Refund amount cannot exceed what remains refundable (Rs.${refundFor.allocation.refundable.toFixed(2)}).`); return; }
      result = await refundPayment(refundFor.payment.id, refundFor.allocation.invoice_id, amt, reason, mode, approvedBy);
    }
    setLoading(false);

    if (result.error) { setError(result.error); return; }
    setSuccess(refundFor.kind === 'advance'
      ? `Refund of Rs.${amt.toFixed(2)} processed from advance balance.`
      : `Refund of Rs.${amt.toFixed(2)} processed against ${refundFor.allocation.invoices?.invoice_number}.`);
    setRefundFor(null);
    const [pmts, balance] = await Promise.all([getPatientPayments(patient.id), getAdvanceBalance(patient.id)]);
    setPayments(pmts);
    setAdvanceBalance(balance);
    refreshRegister();
  }

  return (
    <div style={{ display: 'grid', gridTemplateColumns: '1.3fr 1fr', gap: 20 }}>
      <div>
        <div className="card" style={{ marginBottom: 16 }}>
          <div className="card-title" style={{ marginBottom: 4 }}>
            <i className="ti ti-rotate-clockwise" style={{ color: 'var(--amber)' }}></i> Refund
          </div>
          <div className="msg-info" style={{ background: 'var(--amber-lt)', color: 'var(--amber)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
            <i className="ti ti-info-circle"></i> Reverses money already collected -- the original receipt is never edited or deleted, a new linked refund entry is added alongside it. Requires an approver.
          </div>

          {error && <div className="msg-err">{error}</div>}
          {success && <div className="msg-success"><i className="ti ti-circle-check"></i> {success}</div>}

          {!patient ? (
            <div>
              <label className="flbl">Patient</label>
              <div style={{ display: 'flex', gap: 8 }}>
                <input className="fi" value={searchQuery} onChange={(e) => setSearchQuery(e.target.value)} placeholder="Name, UHID, or mobile..." />
                <button className="btn btn-primary" onClick={handleSearch}><i className="ti ti-search"></i></button>
              </div>
              {searchResults.length > 0 && (
                <div style={{ border: '1px solid var(--g200)', borderRadius: 8, marginTop: 8 }}>
                  {searchResults.map((p) => (
                    <div key={p.id} onClick={() => pickPatient(p)} style={{ padding: '8px 12px', cursor: 'pointer', borderBottom: '1px solid var(--g100)', fontSize: 13 }}>
                      <strong>{p.first_name} {p.last_name}</strong> -- {p.uhid}
                    </div>
                  ))}
                </div>
              )}
              <div style={{ marginTop: 16 }}>
                <TodaysVisitsWidget visits={todaysVisits} onSelect={pickPatient} />
              </div>
            </div>
          ) : (
            <div>
              <div style={{ background: 'var(--amber-lt)', border: '1px solid var(--amber)', borderRadius: 8, padding: '10px 14px', marginBottom: 14 }}>
                <div style={{ display: 'flex', justifyContent: 'space-between' }}>
                  <div style={{ fontWeight: 700, fontSize: 14 }}>{patient.first_name} {patient.last_name}</div>
                  <button className="btn btn-sm" onClick={changePatient}>Change</button>
                </div>
                <div style={{ fontSize: 11, color: 'var(--g600)', marginTop: 2 }}>{patient.uhid}</div>
                <div style={{ display: 'flex', gap: 16, marginTop: 8, fontSize: 12 }}>
                  <span>Total paid: <strong style={{ color: 'var(--green)' }}>Rs.{totalPaid.toFixed(2)}</strong></span>
                  <span>Refundable: <strong style={{ color: 'var(--amber)' }}>Rs.{totalRefundable.toFixed(2)}</strong></span>
                  <span>Advance: <strong style={{ color: 'var(--purple)' }}>Rs.{advanceBalance}</strong></span>
                </div>
              </div>

              {advanceBalance > 0 && (
                <div className="card" style={{ padding: '10px 12px', marginBottom: 8, background: 'var(--purple-lt)', border: '1px solid var(--purple)' }}>
                  <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                    <div style={{ fontSize: 12 }}>
                      <i className="ti ti-wallet" style={{ color: 'var(--purple)' }}></i> Advance balance: <strong style={{ color: 'var(--purple)' }}>Rs.{advanceBalance}</strong>
                      <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 2 }}>Not tied to any invoice -- refund it directly from the pooled balance.</div>
                    </div>
                    <button className="btn btn-sm" style={{ background: 'var(--purple)', color: '#fff', border: 'none' }} onClick={startRefundAdvance}>
                      Refund from Advance
                    </button>
                  </div>
                </div>
              )}

              <label className="flbl" style={{ marginBottom: 8 }}>Receipts -- select what to refund</label>
              {payments.map((p) => (
                <div key={p.id} className="card" style={{ padding: '10px 12px', marginBottom: 8 }}>
                  <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 12, marginBottom: 6 }}>
                    <span style={{ fontFamily: 'monospace', fontWeight: 700 }}>{p.receipt_number}</span>
                    <span style={{ color: 'var(--g500)' }}>{new Date(p.collected_at).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata' })} -- Rs.{p.total_amount}</span>
                  </div>
                  {(p.payment_allocations || []).length === 0 && <div style={{ fontSize: 11, color: 'var(--g400)' }}>Not applied to any invoice (advance).</div>}
                  {(p.payment_allocations || []).map((a) => (
                    <div key={a.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '4px 0', fontSize: 12, borderTop: '1px solid var(--g100)' }}>
                      <span style={{ fontFamily: 'monospace' }}>{a.invoices?.invoice_number}</span>
                      <span>Rs.{Number(a.amount).toFixed(2)} allocated{a.alreadyRefunded > 0 ? ` -- Rs.${a.alreadyRefunded.toFixed(2)} refunded` : ''}</span>
                      {a.refundable > 0 ? (
                        <button className="btn btn-sm" onClick={() => startRefund(p, a)}>Refund up to Rs.{a.refundable.toFixed(2)}</button>
                      ) : <span style={{ color: 'var(--g400)', fontSize: 11 }}>Fully refunded</span>}
                    </div>
                  ))}
                </div>
              ))}
              {payments.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No payments found for this patient.</div>}

              {refundFor && (
                <div style={{ border: '1.5px solid var(--amber)', borderRadius: 8, padding: 14, marginTop: 12 }}>
                  <div style={{ fontSize: 13, fontWeight: 700, marginBottom: 10 }}>
                    {refundFor.kind === 'advance'
                      ? `Refund from advance balance -- up to Rs.${advanceBalance}`
                      : `Refund against ${refundFor.allocation.invoices?.invoice_number} -- up to Rs.${refundFor.allocation.refundable.toFixed(2)}`}
                  </div>
                  <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10, marginBottom: 10 }}>
                    <div>
                      <label className="flbl">Refund reason *</label>
                      <select className="fi" value={reason} onChange={(e) => setReason(e.target.value)}>
                        <option value="">-- Select --</option>
                        {REASONS.map((r) => <option key={r} value={r}>{r}</option>)}
                      </select>
                    </div>
                    <div>
                      <label className="flbl">Refund amount (Rs.) *</label>
                      <input type="number" className="fi" value={amount} onChange={(e) => setAmount(e.target.value)} placeholder="0.00" />
                    </div>
                  </div>
                  <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10, marginBottom: 10 }}>
                    <div>
                      <label className="flbl">Refund mode *</label>
                      <select className="fi" value={mode} onChange={(e) => setMode(e.target.value)}>
                        <option value="">-- Select --</option>
                        {MODES.map((m) => <option key={m} value={m}>{m}</option>)}
                      </select>
                    </div>
                    <div>
                      <label className="flbl">Approved by *</label>
                      <select className="fi" value={approvedBy} onChange={(e) => setApprovedBy(e.target.value)}>
                        <option value="">-- Select --</option>
                        {approvers.map((a) => <option key={a.id} value={a.id}>{a.full_name}</option>)}
                      </select>
                    </div>
                  </div>
                  <label className="flbl">Remarks</label>
                  <input className="fi" style={{ marginBottom: 12 }} value={remarks} onChange={(e) => setRemarks(e.target.value)} placeholder="Optional..." />
                  <div style={{ display: 'flex', gap: 8 }}>
                    <button className="btn" style={{ background: 'var(--amber)', color: '#fff', border: 'none' }} onClick={confirmRefund} disabled={loading}>
                      {loading ? 'Processing...' : 'Process Refund'}
                    </button>
                    <button className="btn" onClick={() => setRefundFor(null)}>Cancel</button>
                  </div>
                </div>
              )}
            </div>
          )}
        </div>
      </div>

      <div className="card">
        <div className="card-title" style={{ marginBottom: 10 }}>
          <i className="ti ti-history" style={{ color: 'var(--amber)' }}></i> Refund Register
        </div>
        <div style={{ maxHeight: 500, overflowY: 'auto' }}>
          <table className="tbl">
            <thead><tr><th>Patient</th><th>Invoice</th><th>Amount</th><th>Mode</th><th>Reason</th><th>Approved By</th></tr></thead>
            <tbody>
              {register.map((r) => (
                <tr key={r.id}>
                  <td style={{ fontSize: 12 }}>{r.patients?.first_name} {r.patients?.last_name}</td>
                  <td style={{ fontFamily: 'monospace', fontSize: 11 }}>{r.invoices?.invoice_number || 'Advance'}</td>
                  <td style={{ fontSize: 12, fontWeight: 600 }}>Rs.{Number(r.amount).toFixed(2)}</td>
                  <td style={{ fontSize: 11 }}>{r.refund_mode || '--'}</td>
                  <td style={{ fontSize: 11 }}>{r.reason}</td>
                  <td style={{ fontSize: 11 }}>{r.profiles?.full_name || '--'}</td>
                </tr>
              ))}
              {register.length === 0 && (
                <tr><td colSpan={6} style={{ padding: 16, textAlign: 'center', color: 'var(--g400)' }}>No refunds processed yet.</td></tr>
              )}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  );
}


VEDA_EOF_MARKER

mkdir -p "$(dirname "app/(main)/investigation/comparison/page.js")"
cat > "app/(main)/investigation/comparison/page.js" << 'VEDA_EOF_MARKER'
'use client';

import { useState, useEffect } from 'react';
import { searchPatientsForInvestigation, getInvestigationComparisonData } from '../actions';
import { matchInvestigationType, parseNumeric } from '../investigation-types';
import InvestigationTabs from '../investigation-tabs';

const COMPARE_TYPES = ['OCT', 'Visual Field'];

export default function InvestigationComparisonPage() {
  const [searchQuery, setSearchQuery] = useState('');
  const [searchResults, setSearchResults] = useState([]);
  const [patient, setPatient] = useState(null);
  const [type, setType] = useState('OCT');
  const [rows, setRows] = useState([]);
  const [loading, setLoading] = useState(false);

  async function handleSearch() {
    if (!searchQuery.trim()) return;
    const results = await searchPatientsForInvestigation(searchQuery.trim());
    setSearchResults(results);
  }

  // Live search as the user types -- no need to press the Search button.
  useEffect(() => {
    const q = searchQuery.trim();
    if (q.length < 2) { setSearchResults([]); return; }
    const t = setTimeout(async () => {
      setSearchResults(await searchPatientsForInvestigation(q));
    }, 300);
    return () => clearTimeout(t);
  }, [searchQuery]);

  async function pickPatient(p) {
    setPatient(p);
    setSearchResults([]);
    setSearchQuery('');
    await loadData(p.id, type);
  }

  async function loadData(patientId, t) {
    setLoading(true);
    const result = await getInvestigationComparisonData(patientId);
    setLoading(false);
    if (result.error) { setRows([]); return; }
    const filtered = (result.rows || []).filter((r) => matchInvestigationType(r.name) === t);
    setRows(filtered);
  }

  async function handleTypeChange(t) {
    setType(t);
    if (patient) await loadData(patient.id, t);
  }

  const first = rows[0];
  const last = rows[rows.length - 1];
  const trend = type === 'OCT' && rows.length > 1 && first && last
    ? {
        cmt: (() => { const a = parseNumeric(first.result_data?.['cmt-re']); const b = parseNumeric(last.result_data?.['cmt-re']); return a !== null && b !== null ? b - a : null; })(),
        rnfl: (() => { const a = parseNumeric(first.result_data?.rnfl); const b = parseNumeric(last.result_data?.rnfl); return a !== null && b !== null ? b - a : null; })(),
      }
    : null;

  return (
    <div>
      <InvestigationTabs />

      <div className="card" style={{ marginBottom: 12 }}>
        <div className="card-head" style={{ marginBottom: 0 }}>
          <div className="card-title"><i className="ti ti-chart-bar-off" style={{ color: 'var(--teal)' }}></i> Longitudinal Comparison</div>
        </div>
        <div style={{ display: 'flex', gap: 8, marginTop: 10, flexWrap: 'wrap', alignItems: 'center' }}>
          {!patient ? (
            <div style={{ position: 'relative', flex: 1, minWidth: 240 }}>
              <div style={{ display: 'flex', gap: 8 }}>
                <input className="fi" value={searchQuery} onChange={(e) => setSearchQuery(e.target.value)} placeholder="Search patient by name or UHID..." />
                <button className="btn btn-primary" onClick={handleSearch}><i className="ti ti-search"></i> Search</button>
              </div>
              {searchResults.length > 0 && (
                <div style={{ border: '1px solid var(--g200)', borderRadius: 8, marginTop: 4, position: 'absolute', background: '#fff', width: '100%', zIndex: 5 }}>
                  {searchResults.map((p) => (
                    <div key={p.id} onClick={() => pickPatient(p)} style={{ padding: '8px 12px', cursor: 'pointer', borderBottom: '1px solid var(--g100)', fontSize: 13 }}>
                      <strong>{p.first_name} {p.last_name}</strong> -- {p.uhid}
                    </div>
                  ))}
                </div>
              )}
            </div>
          ) : (
            <div style={{ display: 'flex', alignItems: 'center', gap: 8, background: 'var(--blue-lt)', padding: '6px 12px', borderRadius: 8 }}>
              <span><strong>{patient.first_name} {patient.last_name}</strong> -- {patient.uhid}</span>
              <button className="btn btn-sm" onClick={() => { setPatient(null); setRows([]); }}>Change</button>
            </div>
          )}
          <select className="fi" style={{ width: 'auto', padding: '7px 10px' }} value={type} onChange={(e) => handleTypeChange(e.target.value)}>
            {COMPARE_TYPES.map((t) => <option key={t} value={t}>{t}</option>)}
          </select>
        </div>
      </div>

      {loading && <div style={{ fontSize: 12, color: 'var(--g400)', padding: 20, textAlign: 'center' }}>Loading...</div>}

      {!loading && patient && rows.length === 0 && (
        <div className="card" style={{ textAlign: 'center', padding: 30, color: 'var(--g400)' }}>No {type} history for this patient.</div>
      )}

      {!loading && rows.length > 0 && (
        <>
          <div style={{ display: 'grid', gridTemplateColumns: `repeat(${rows.length}, 1fr)`, gap: 12, marginBottom: 12 }}>
            {rows.map((r) => (
              <div key={r.id} className="card" style={{ marginBottom: 0 }}>
                <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--g500)', marginBottom: 8 }}>
                  {new Date(r.created_at).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' })}
                </div>
                {type === 'OCT' ? (
                  <>
                    <div style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}><span style={{ color: 'var(--g500)' }}>CMT</span><strong>{r.result_data?.['cmt-re'] || '--'}</strong></div>
                    <div style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0', fontSize: 12 }}><span style={{ color: 'var(--g500)' }}>RNFL</span><strong>{r.result_data?.rnfl || '--'}</strong></div>
                  </>
                ) : (
                  <>
                    <div style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}><span style={{ color: 'var(--g500)' }}>MD RE</span><strong style={{ color: 'var(--red)' }}>{r.result_data?.['md-re'] || '--'}</strong></div>
                    <div style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}><span style={{ color: 'var(--g500)' }}>MD LE</span><strong style={{ color: 'var(--red)' }}>{r.result_data?.['md-le'] || '--'}</strong></div>
                    <div style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0', fontSize: 12 }}><span style={{ color: 'var(--g500)' }}>VFI</span><strong>{r.result_data?.vfi || '--'}</strong></div>
                  </>
                )}
              </div>
            ))}
          </div>

          {trend && (trend.cmt !== null || trend.rnfl !== null) && (
            <div className="card">
              <div className="card-title"><i className="ti ti-trending-up" style={{ color: 'var(--teal)' }}></i> Trend Analysis</div>
              {trend.cmt !== null && (
                <div style={{ display: 'flex', justifyContent: 'space-between', padding: '5px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
                  <span>CMT change</span>
                  <span style={{ fontWeight: 700, color: trend.cmt > 10 ? 'var(--red)' : trend.cmt < -10 ? 'var(--green)' : 'var(--g600)' }}>{trend.cmt >= 0 ? '+' : ''}{trend.cmt} um over {rows.length - 1} visit(s)</span>
                </div>
              )}
              {trend.rnfl !== null && (
                <div style={{ display: 'flex', justifyContent: 'space-between', padding: '5px 0', fontSize: 12 }}>
                  <span>RNFL change</span>
                  <span style={{ fontWeight: 700, color: trend.rnfl < -5 ? 'var(--red)' : 'var(--green)' }}>{trend.rnfl >= 0 ? '+' : ''}{trend.rnfl} um</span>
                </div>
              )}
              <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 8 }}>For clinical decision support. Interpretation by Ophthalmologist only.</div>
            </div>
          )}
        </>
      )}

      {!patient && (
        <div className="card" style={{ textAlign: 'center', padding: 30, color: 'var(--g400)' }}>Search for a patient to compare their investigation results over time.</div>
      )}
    </div>
  );
}


VEDA_EOF_MARKER

mkdir -p "$(dirname "app/(main)/appointments/new/page.js")"
cat > "app/(main)/appointments/new/page.js" << 'VEDA_EOF_MARKER'
'use client';

import { useState, useEffect } from 'react';
import { useRouter } from 'next/navigation';
import { searchPatientsForBooking, getDoctors, createAppointment } from '@/app/(main)/appointments/actions';

export default function NewAppointmentPage() {
  const [searchQuery, setSearchQuery] = useState('');
  const [searchResults, setSearchResults] = useState([]);
  const [selectedPatient, setSelectedPatient] = useState(null);
  const [notRegistered, setNotRegistered] = useState(false);
  const [patientName, setPatientName] = useState('');
  const [mobile, setMobile] = useState('');

  const [doctors, setDoctors] = useState([]);
  const [doctorId, setDoctorId] = useState('');
  const [date, setDate] = useState(() => new Date().toISOString().slice(0, 10));
  const [time, setTime] = useState('');
  const [visitType, setVisitType] = useState('New Consultation');
  const [remarks, setRemarks] = useState('');

  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);
  const router = useRouter();

  useEffect(() => {
    getDoctors().then(setDoctors);
  }, []);

  async function handleSearch() {
    if (!searchQuery.trim()) return;
    const results = await searchPatientsForBooking(searchQuery.trim());
    setSearchResults(results);
  }

  // Live search as the user types -- no need to press the Search button.
  useEffect(() => {
    const q = searchQuery.trim();
    if (q.length < 2) { setSearchResults([]); return; }
    const t = setTimeout(async () => {
      const results = await searchPatientsForBooking(q);
      setSearchResults(results);
    }, 300);
    return () => clearTimeout(t);
  }, [searchQuery]);

  function pickPatient(p) {
    setSelectedPatient(p);
    setSearchResults([]);
    setSearchQuery('');
  }

  async function handleSubmit(e) {
    e.preventDefault();
    setError('');

    if (!selectedPatient && !notRegistered) {
      setError('Search and select a patient, or check "Not registered yet" for a phone booking.');
      return;
    }
    if (notRegistered && (!patientName.trim() || !mobile.trim())) {
      setError('Name and mobile are required for a phone booking.');
      return;
    }
    if (!date || !time) {
      setError('Date and time are required.');
      return;
    }

    setLoading(true);
    const result = await createAppointment({
      patientId: selectedPatient?.id,
      patientName: notRegistered ? patientName : undefined,
      mobile: notRegistered ? mobile : undefined,
      doctorId: doctorId || null,
      date,
      time,
      visitType,
      remarks,
    });
    setLoading(false);

    if (result.error) {
      setError(result.error);
      return;
    }

    router.push('/front-office-dashboard?booked=1');
  }

  return (
    <div style={{ maxWidth: 560, margin: '0 auto' }}>
      <div className="card">
        <div style={{ fontSize: 18, fontWeight: 700, marginBottom: 20 }}>
          <i className="ti ti-calendar-plus" style={{ color: 'var(--blue)', marginRight: 6 }}></i>Book Appointment
        </div>

        {error && <div className="msg-err">{error}</div>}

        <form onSubmit={handleSubmit}>
          {/* Patient selection */}
          {!notRegistered && (
            <div style={{ marginBottom: 12 }}>
              <label className="flbl">Find patient (name, UHID, or mobile) *</label>
              {selectedPatient ? (
                <div
                  style={{
                    display: 'flex',
                    justifyContent: 'space-between',
                    alignItems: 'center',
                    background: 'var(--blue-lt)',
                    padding: '8px 12px',
                    borderRadius: 8,
                  }}
                >
                  <span>
                    <strong>{selectedPatient.first_name} {selectedPatient.last_name}</strong>
                    {' -- '}
                    {selectedPatient.uhid}
                  </span>
                  <button
                    type="button"
                    className="btn"
                    style={{ padding: '4px 10px' }}
                    onClick={() => setSelectedPatient(null)}
                  >
                    Change
                  </button>
                </div>
              ) : (
                <>
                  <div style={{ display: 'flex', gap: 8 }}>
                    <input
                      className="fi"
                      value={searchQuery}
                      onChange={(e) => setSearchQuery(e.target.value)}
                      placeholder="Type to search..."
                    />
                    <button type="button" className="btn" onClick={handleSearch}>
                      Search
                    </button>
                  </div>
                  {searchResults.length > 0 && (
                    <div style={{ border: '1px solid var(--g200)', borderRadius: 8, marginTop: 6 }}>
                      {searchResults.map((p) => (
                        <div
                          key={p.id}
                          onClick={() => pickPatient(p)}
                          style={{
                            padding: '8px 12px',
                            cursor: 'pointer',
                            borderBottom: '1px solid var(--g100)',
                            fontSize: 13,
                          }}
                        >
                          <strong>{p.first_name} {p.last_name}</strong> -- {p.uhid} -- {p.mobile}
                        </div>
                      ))}
                    </div>
                  )}
                </>
              )}
            </div>
          )}

          <div style={{ marginBottom: 16 }}>
            <label style={{ fontSize: 12, display: 'flex', alignItems: 'center', gap: 6 }}>
              <input
                type="checkbox"
                checked={notRegistered}
                onChange={(e) => {
                  setNotRegistered(e.target.checked);
                  setSelectedPatient(null);
                }}
              />
              Not registered yet -- book by phone (name + mobile only)
            </label>
          </div>

          {notRegistered && (
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12, marginBottom: 12 }}>
              <div>
                <label className="flbl">Patient name *</label>
                <input className="fi" value={patientName} onChange={(e) => setPatientName(e.target.value)} />
              </div>
              <div>
                <label className="flbl">Mobile *</label>
                <input className="fi" value={mobile} onChange={(e) => setMobile(e.target.value)} maxLength={10} />
              </div>
            </div>
          )}

          {/* Appointment details */}
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12, marginBottom: 12 }}>
            <div>
              <label className="flbl">Date *</label>
              <input type="date" className="fi" value={date} onChange={(e) => setDate(e.target.value)} required />
            </div>
            <div>
              <label className="flbl">Time *</label>
              <input type="time" className="fi" value={time} onChange={(e) => setTime(e.target.value)} required />
            </div>
          </div>

          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12, marginBottom: 12 }}>
            <div>
              <label className="flbl">Visit type</label>
              <select className="fi" value={visitType} onChange={(e) => setVisitType(e.target.value)}>
                <option>New Consultation</option>
                <option>Follow-up</option>
                <option>Investigation Only</option>
                <option>Post-operative Review</option>
                <option>Emergency</option>
                <option>Procedure</option>
              </select>
            </div>
            <div>
              <label className="flbl">Doctor</label>
              <select className="fi" value={doctorId} onChange={(e) => setDoctorId(e.target.value)}>
                <option value="">-- Any / Not decided --</option>
                {doctors.map((d) => (
                  <option key={d.id} value={d.id}>
                    {d.full_name}
                  </option>
                ))}
              </select>
            </div>
          </div>

          <div style={{ marginBottom: 20 }}>
            <label className="flbl">Remarks</label>
            <input className="fi" value={remarks} onChange={(e) => setRemarks(e.target.value)} />
          </div>

          <div style={{ display: 'flex', gap: 8 }}>
            <button type="submit" className="btn btn-primary" disabled={loading}>
              {loading ? 'Booking...' : 'Book Appointment'}
            </button>
            <button type="button" className="btn" onClick={() => router.push('/front-office-dashboard')}>
              Cancel
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}


VEDA_EOF_MARKER

mkdir -p "$(dirname "app/(main)/patient-timeline/page.js")"
cat > "app/(main)/patient-timeline/page.js" << 'VEDA_EOF_MARKER'
'use client';

import Link from 'next/link';
import { useState, useEffect, useCallback, useRef, Suspense } from 'react';
import { useSearchParams } from 'next/navigation';
import { searchPatients, getPatientTimeline } from './actions';
import { openPopup } from '@/lib/popup';

// Same mapping used in the Consultation workspace's context sidebar --
// kept identical across both so an event type reads as the same color
// everywhere in the app.
const TYPE_COLOR = {
  Visit: 'var(--indigo)',
  Diagnosis: 'var(--blue)',
  Investigation: 'var(--teal)',
  Prescription: 'var(--purple)',
  Surgery: 'var(--red)',
};
const TYPE_ICON = {
  Visit: 'ti-door-enter',
  Diagnosis: 'ti-clipboard-list',
  Investigation: 'ti-flask',
  Prescription: 'ti-pill',
  Surgery: 'ti-scalpel',
};

function PatientTimelineInner() {
  const [query, setQuery] = useState('');
  const [results, setResults] = useState([]);
  const [patient, setPatient] = useState(null);
  const [events, setEvents] = useState([]);
  const [filter, setFilter] = useState('');
  const [selectedEvent, setSelectedEvent] = useState(null);
  const [loading, setLoading] = useState(false);
  const searchParams = useSearchParams();
  const skipNextSearch = useRef(false);

  function handleSearch(val) {
    setQuery(val);
  }

  // Debounced live search -- waits for a short pause in typing before
  // querying, rather than firing a request on every keystroke. Skipped
  // once when the query box is set programmatically (e.g. after picking
  // a patient below), so the dropdown doesn't reopen right after selection.
  useEffect(() => {
    if (skipNextSearch.current) { skipNextSearch.current = false; return; }
    const q = query.trim();
    if (q.length < 2) { setResults([]); return; }
    const t = setTimeout(async () => {
      setResults(await searchPatients(q));
    }, 300);
    return () => clearTimeout(t);
  }, [query]);

  const loadPatientById = useCallback(async (patientId) => {
    setLoading(true);
    setResults([]);
    setSelectedEvent(null);
    const result = await getPatientTimeline(patientId);
    setLoading(false);
    setPatient(result.patient);
    setEvents(result.events || []);
    if (result.patient) {
      skipNextSearch.current = true;
      setQuery(`${result.patient.first_name} ${result.patient.last_name} -- ${result.patient.uhid}`);
    }
  }, []);

  async function handleSelectPatient(p) {
    await loadPatientById(p.id);
  }

  // Deep link from elsewhere in the app (e.g. the Consultation workspace's
  // "Open full timeline" link) -- skip the search step and load directly.
  useEffect(() => {
    const patientId = searchParams.get('patientId');
    if (patientId) loadPatientById(patientId);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [searchParams]);

  const filteredEvents = filter ? events.filter((e) => e.type === filter) : events;
  const counts = {};
  events.forEach((e) => { counts[e.type] = (counts[e.type] || 0) + 1; });

  return (
    <div>
      <div className="card" style={{ marginBottom: 14 }}>
        <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-timeline" style={{ color: 'var(--blue)' }}></i> Clinical Timeline</div>
        <div className="msg-info" style={{ background: 'var(--blue-lt)', color: 'var(--blue)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
          <i className="ti ti-info-circle"></i> Read-only longitudinal history, aggregated across every visit this patient has had.
        </div>
        <div style={{ position: 'relative' }}>
          <input className="fi" placeholder="Search patient by name or UHID..." value={query} onChange={(e) => handleSearch(e.target.value)} />
          {results.length > 0 && (
            <div style={{ position: 'absolute', top: '100%', left: 0, right: 0, background: '#fff', border: '1px solid var(--g200)', borderRadius: 8, marginTop: 4, zIndex: 10, boxShadow: '0 4px 16px rgba(0,0,0,.1)' }}>
              {results.map((p) => (
                <div
                  key={p.id}
                  onClick={() => handleSelectPatient(p)}
                  style={{ padding: '8px 12px', cursor: 'pointer', fontSize: 13, borderBottom: '1px solid var(--g100)' }}
                  onMouseEnter={(e) => (e.currentTarget.style.background = 'var(--g50)')}
                  onMouseLeave={(e) => (e.currentTarget.style.background = '#fff')}
                >
                  <strong>{p.first_name} {p.last_name}</strong> <span style={{ color: 'var(--g400)', fontSize: 11 }}>{p.uhid} -- {p.age} {p.gender}</span>
                </div>
              ))}
            </div>
          )}
        </div>
      </div>

      {loading && <div style={{ textAlign: 'center', padding: 30, color: 'var(--g400)' }}>Loading timeline...</div>}

      {!loading && patient && (
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 280px', gap: 20, alignItems: 'start' }}>
          <div>
            <div className="card" style={{ padding: 0, overflow: 'hidden' }}>
              <div style={{ padding: '12px 14px', background: 'var(--g50)', borderBottom: '1px solid var(--g200)', display: 'flex', gap: 8 }}>
                <select className="fi fi-sm" style={{ width: 'auto' }} value={filter} onChange={(e) => setFilter(e.target.value)}>
                  <option value="">All events</option>
                  <option value="Visit">OPD Visits</option>
                  <option value="Diagnosis">Diagnoses</option>
                  <option value="Investigation">Investigations</option>
                  <option value="Surgery">Surgeries</option>
                  <option value="Prescription">Prescriptions</option>
                </select>
              </div>
              <div style={{ padding: 16 }}>
                {filteredEvents.length === 0 && (
                  <div style={{ textAlign: 'center', padding: 30, color: 'var(--g400)' }}>No events match this filter.</div>
                )}
                {filteredEvents.map((ev, i) => (
                  <div key={i} style={{ display: 'flex', gap: 12 }}>
                    <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', width: 16, flexShrink: 0 }}>
                      <div style={{ width: 12, height: 12, borderRadius: '50%', background: TYPE_COLOR[ev.type], border: '2px solid #fff', boxShadow: '0 0 0 2px var(--g200)', flexShrink: 0 }}></div>
                      {i < filteredEvents.length - 1 && <div style={{ width: 2, background: 'var(--g200)', flex: 1, minHeight: 20, margin: '3px 0' }}></div>}
                    </div>
                    <div style={{ flex: 1, paddingBottom: 16, cursor: 'pointer' }} onClick={() => setSelectedEvent(ev)}>
                      <div style={{ fontSize: 10, fontWeight: 700, color: 'var(--g400)', textTransform: 'uppercase', letterSpacing: '.4px', marginBottom: 3 }}>
                        {new Date(ev.date).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' })}
                      </div>
                      <div style={{ border: ev.type === 'Visit' && ev.queueEntryId ? '1.5px solid var(--blue)' : '1px solid var(--g200)', borderRadius: 8, padding: '8px 10px', display: 'flex', alignItems: 'center', gap: 8 }}>
                        <div style={{ flex: 1 }}>
                          <div style={{ fontSize: 13, fontWeight: 700, color: 'var(--g800)', display: 'flex', alignItems: 'center', gap: 6 }}>
                            <i className={`ti ${TYPE_ICON[ev.type]}`} style={{ color: TYPE_COLOR[ev.type] }}></i> {ev.type} -- {ev.title}
                          </div>
                          <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 2 }}>{ev.detail}</div>
                        </div>
                        {ev.type === 'Visit' && ev.queueEntryId && (
                          <i className="ti ti-chevron-right" style={{ color: 'var(--blue)' }}></i>
                        )}
                      </div>
                    </div>
                  </div>
                ))}
              </div>
            </div>
          </div>

          <div>
            {selectedEvent && (
              <div className="card" style={{ marginBottom: 16 }}>
                <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-file"></i> Event Detail</div>
                <div style={{ fontSize: 12, lineHeight: 1.9 }}>
                  <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>Type</span><span className="badge" style={{ background: `${TYPE_COLOR[selectedEvent.type]}20`, color: TYPE_COLOR[selectedEvent.type] }}>{selectedEvent.type}</span></div>
                  <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>Date</span><span>{new Date(selectedEvent.date).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata' })}</span></div>
                  <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>Visit</span><span style={{ fontFamily: 'monospace' }}>{selectedEvent.visit}</span></div>
                  <div style={{ marginTop: 6 }}><strong>{selectedEvent.title}</strong></div>
                  <div style={{ color: 'var(--g500)', marginTop: 2 }}>{selectedEvent.detail}</div>
                </div>
                <div style={{ fontSize: 10, color: 'var(--g400)', marginTop: 8 }}>Read-only. Editing happens through the corresponding encounter only.</div>
                {selectedEvent.type === 'Visit' && selectedEvent.queueEntryId && (
                  <Link
                    href={`/consultation/${selectedEvent.queueEntryId}`}
                    className="btn btn-primary btn-sm"
                    style={{ marginTop: 10, width: '100%', textAlign: 'center', textDecoration: 'none', display: 'block' }}
                  >
                    <i className="ti ti-file-text"></i> Open Clinical Record
                  </Link>
                )}
                {selectedEvent.type === 'Visit' && !selectedEvent.queueEntryId && (
                  <div style={{ fontSize: 10, color: 'var(--g400)', marginTop: 6 }}>No clinical record was created for this visit.</div>
                )}
                {selectedEvent.type === 'Investigation' && selectedEvent.id && (
                  <button
                    className="btn btn-primary btn-sm"
                    style={{ marginTop: 10, width: '100%', justifyContent: 'center' }}
                    onClick={() => openPopup(`/investigation/${selectedEvent.id}?mode=view`, `inv-${selectedEvent.id}`)}
                  >
                    <i className="ti ti-eye"></i> View Result
                  </button>
                )}
              </div>
            )}

            <div className="card">
              <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-chart-bar" style={{ color: 'var(--blue)' }}></i> Timeline Summary</div>
              <div style={{ fontSize: 12, lineHeight: 1.9 }}>
                <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>Patient</span><span style={{ fontWeight: 600 }}>{patient.first_name} {patient.last_name}</span></div>
                <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>Total events</span><span style={{ fontWeight: 700 }}>{events.length}</span></div>
                {Object.entries(counts).map(([type, count]) => (
                  <div key={type} style={{ display: 'flex', justifyContent: 'space-between' }}>
                    <span>{type}</span><span className="badge" style={{ background: `${TYPE_COLOR[type]}20`, color: TYPE_COLOR[type] }}>{count}</span>
                  </div>
                ))}
              </div>
            </div>
          </div>
        </div>
      )}

      {!loading && !patient && (
        <div className="card" style={{ textAlign: 'center', padding: 40, color: 'var(--g400)' }}>
          <i className="ti ti-search" style={{ fontSize: 32, display: 'block', marginBottom: 10 }}></i>
          Search for a patient above to view their clinical timeline.
        </div>
      )}
    </div>
  );
}

export default function PatientTimelinePage() {
  return (
    <Suspense fallback={<div style={{ textAlign: 'center', padding: 40, color: 'var(--g400)' }}>Loading...</div>}>
      <PatientTimelineInner />
    </Suspense>
  );
}

VEDA_EOF_MARKER

echo "Done. Files updated:"
echo "  app/(main)/visits/new/page.js"
echo "  app/(main)/billing/new/new-invoice-tab.js"
echo "  app/(main)/payments/collect/collect-payment-tab.js"
echo "  app/(main)/payments/advance/advance-tab.js"
echo "  app/(main)/payments/credit-note/credit-note-tab.js"
echo "  app/(main)/payments/ledger/ledger-tab.js"
echo "  app/(main)/payments/refund/refund-tab.js"
echo "  app/(main)/investigation/comparison/page.js"
echo "  app/(main)/appointments/new/page.js"
echo "  app/(main)/patient-timeline/page.js"