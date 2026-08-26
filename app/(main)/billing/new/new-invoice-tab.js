'use client';

import { useState, useEffect, useRef } from 'react';
import { useRouter, useSearchParams } from 'next/navigation';
import {
  searchPatientsForInvoice,
  getVisitsForPatient,
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

const DEPARTMENTS = ['Consultation', 'Investigation', 'Biometry', 'OPD Procedure', 'Surgery', 'Pharmacy'];
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
  const [patientVisits, setPatientVisits] = useState([]);
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
      const visits = await getVisitsForPatient(details.visit.patients.id);
      setPatientVisits(visits);
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

  // Prefill from Front Office's "Prescribed OPD Procedures" widget --
  // same pattern as investigations above, matched against the OPD
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
            serviceCode: i.serviceCode, serviceName: `${i.name} (${i.eye})`, dept: 'OPD Procedure',
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
    if (!urlPkgCaseId) return;
    if (pkgLoadedFor.current === urlPkgCaseId) return;
    pkgLoadedFor.current = urlPkgCaseId;
    (async () => {
      const result = await getPackageForBilling(urlPkgCaseId);
      if (result.error) { setError(result.error); return; }
      if (!result.items || result.items.length === 0) return;
      const [primary, ...rest] = result.items;

      // Establish patient/visit context directly from the package's own
      // case data when nothing has set it yet -- Surgery Billing's "Bill
      // Now" link only ever passes pkgCaseId, not visitId (a surgical
      // case doesn't always have an open visit attached), so this can't
      // rely on the urlVisitId effect above to have already run.
      if (!contextPatient && primary.patient) {
        if (primary.visitId) {
          const details = await getVisitWithPatient(primary.visitId);
          if (!details.error) {
            setContextPatient(details.visit.patients);
            setContextVisit(details.visit);
            const invResult = await getInvoicesForVisit(primary.visitId);
            setExistingInvoices(invResult.invoices || []);
          }
        } else {
          setContextPatient(primary.patient);
        }
        const visits = await getVisitsForPatient(primary.patient.id);
        setPatientVisits(visits);
      }

      // Manual Surgery/Eye/Doctor fields and the package breakup display
      // only show one procedure's details (a print fallback for when
      // the invoice's real case lookup misses) -- the primary
      // procedure's, same as before. A surgery with additional
      // procedures (see surgical_case_procedures) still gets every one
      // of them as its own real line item below.
      setPackageBreakup(primary.breakup && primary.breakup.length > 0 ? primary.breakup : null);
      setSurgeryName(primary.surgeryName || '');
      setSurgeryEyeField(primary.surgeryEye || '');
      setSurgeryDoctorId(primary.surgeonId || '');

      const newLines = result.items.map((i) => {
        // Carry over the discount already recorded at Package Selection
        // (Surgical Journey / Counselling / Register Surgery Directly) --
        // previously always billed at the full package rate regardless of
        // any discount on file for the case.
        const discType = i.discount > 0 ? 'fixed' : 'none';
        const computed = computeLine({ rate: i.rate, gst_pct: i.gstPct }, 1, discType, i.discount || 0);
        return {
          tempId: nextTempId.current++,
          sourcePkgCaseId: i.caseId,
          serviceCode: i.serviceCode, serviceName: i.name, dept: 'Surgery',
          qty: 1, rate: i.rate, gstPct: i.gstPct,
          discType, discValue: i.discount || 0, discReason: i.discount > 0 ? 'Package discount recorded at Package Selection' : '',
          ...computed,
        };
      });
      setDraftLines((prev) => [...prev, ...newLines]);
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
    const visits = await getVisitsForPatient(p.id);
    setPatientVisits(visits);
    const visit = visits[0] || null; // already sorted newest-first
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
    const visits = await getVisitsForPatient(v.patients.id);
    setPatientVisits(visits);
    const invResult = await getInvoicesForVisit(v.id);
    setExistingInvoices(invResult.invoices || []);
  }

  // Fired by the "Visit" dropdown once a patient is already selected --
  // lets the front desk attach the invoice to a different visit than
  // whichever one was auto-picked as most recent.
  async function handleVisitDropdownChange(visitId) {
    setError('');
    if (!visitId) {
      setContextVisit(null);
      setExistingInvoices([]);
      return;
    }
    const v = patientVisits.find((pv) => pv.id === visitId);
    setContextVisit(v || null);
    if (v) {
      const invResult = await getInvoicesForVisit(v.id);
      setExistingInvoices(invResult.invoices || []);
    }
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

    // Every surgery package line gets marked billed -- a surgery with
    // additional procedures (see surgical_case_procedures) adds more
    // than one sourcePkgCaseId line, each needing to flip out of the
    // Pending Package Billing queue, not just the first one.
    const billedPkgCaseIds = [...new Set(draftLines.map((l) => l.sourcePkgCaseId).filter(Boolean))];
    for (const pkgCaseId of billedPkgCaseIds) {
      await markPackageBilled(pkgCaseId, created.invoice.id);
    }

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
    setPatientVisits([]);
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
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', background: 'var(--blue-lt)', padding: '8px 12px', borderRadius: 8, marginBottom: 16, flexWrap: 'wrap', gap: 8 }}>
              <span>
                <strong>{contextPatient.first_name} {contextPatient.last_name}</strong> -- {contextPatient.uhid}
                <span style={{ marginLeft: 8 }} className="badge b-gray">Draft -- not saved yet</span>
              </span>
              <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                <label className="flbl" style={{ margin: 0 }}>Visit</label>
                <select
                  className="fi fi-sm"
                  style={{ minWidth: 220 }}
                  value={contextVisit?.id || ''}
                  onChange={(e) => handleVisitDropdownChange(e.target.value)}
                >
                  <option value="">-- No visit (walk-in charge) --</option>
                  {patientVisits.map((v) => (
                    <option key={v.id} value={v.id}>
                      {v.visit_number || v.id.slice(0, 8)} -- {v.visit_type} -- {new Date(v.created_at).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short' })}
                      {v.status !== 'Open' ? ` (${v.status})` : ''}
                    </option>
                  ))}
                </select>
                <button className="btn btn-sm" onClick={startOver}>Change / New</button>
              </div>
            </div>

            {!contextVisit && (
              <div className="msg-info" style={{ fontSize: 12, marginBottom: 12 }}>
                <i className="ti ti-alert-triangle"></i> No visit selected -- this invoice won&apos;t be linked to a visit. Pick one above if this bill is for a specific visit.
              </div>
            )}

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



