'use client';

import { useState, useEffect, useCallback, useRef, Fragment } from 'react';
import { formatPatientName } from '@/lib/patientName';
import {
  getTodayCollectionSummary,
  getReconciliationData,
  saveReconciliation,
  getCloseDayReadiness,
  closeDay,
  getDayClosingHistory,
  getDailyReport,
  reopenDay,
  getDayOpening,
  openDay,
  getRevenueByDepartmentToday,
  getUnclosedPastDays,
  getExpenseCategoriesActive,
  getExpensesForDate,
  getPettyCashTotal,
  getCashCounterForDate,
  recordClosingCash,
  confirmCashCounter,
  unlockCashCounter,
  getCashCounterHistory,
  getReconciliationLockStatus,
  lockReconciliation,
  unlockReconciliation,
  addExpense,
  deleteExpense,
} from './actions';
import { addExpenseCategory } from '@/app/(main)/master-data/actions';
import { getApprovers } from '@/app/(main)/payments/actions';
import { getOpenQueueEntriesToday, bulkForceCloseQueueEntries } from '@/app/(main)/queue/actions';
import AttachmentUploader from '@/app/components/AttachmentUploader';
import { uploadAttachment } from '@/lib/attachments';
import { openPrintPopup } from '@/lib/printPopup';

// Fixed column order for Payment Mode Summary's Type x Mode grid --
// same order the printed report uses, so modes appear consistently
// regardless of which ones a given day actually has amounts in.
// Table 1's display columns -- Card/Cheque/Bank Transfer dropped per
// explicit request; this hospital's payments are always Cash or UPI.
// The KPI strip's "Total Other" card above stays dynamic (not tied to
// this list), so it would still surface real money on any other mode.
const MODES = ['Cash', 'UPI'];

const TABS = [
  { key: 'summary', label: "Today's Collection", icon: 'ti-chart-bar' },
  { key: 'pettycash', label: 'Cash Expenses', icon: 'ti-cash-banknote' },
  { key: 'reconciliation', label: 'Reconciliation & Close Day', icon: 'ti-calculator' },
  { key: 'report', label: 'Daily Report', icon: 'ti-file-text' },
  { key: 'history', label: 'History', icon: 'ti-history' },
];

const VARIANCE_REASONS = ['Change given error', 'Denomination counting error', 'Uncounted change', 'Recording error', 'Other'];

function fmt(n) {
  return `Rs.${Number(n || 0).toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}

function CashCounterTab({ onStatusChange }) {
  const [today, setToday] = useState(null);
  const [history, setHistory] = useState([]);
  const [loading, setLoading] = useState(true);

  const [closingInput, setClosingInput] = useState('');
  const [error, setError] = useState('');
  const [saving, setSaving] = useState(false);

  const [lookupDate, setLookupDate] = useState('');
  const [lookupResult, setLookupResult] = useState(null);
  const [lookupLoading, setLookupLoading] = useState(false);

  const refresh = useCallback(async () => {
    const [t, h] = await Promise.all([getCashCounterForDate(), getCashCounterHistory(2)]);
    setToday(t);
    setHistory(h);
    setLoading(false);
    onStatusChange?.(t.amountHandedOver != null);
  }, [onStatusChange]);

  useEffect(() => { refresh(); }, [refresh]);

  async function handleRecordClosing() {
    setError('');
    setSaving(true);
    const result = await recordClosingCash(closingInput);
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setClosingInput('');
    refresh();
  }

  async function handleConfirm() {
    setError('');
    setSaving(true);
    const result = await confirmCashCounter();
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    refresh();
  }

  async function handleUnlockCounter() {
    setError('');
    setSaving(true);
    const result = await unlockCashCounter();
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setClosingInput('');
    refresh();
  }

  async function handleLookup() {
    if (!lookupDate) return;
    setLookupLoading(true);
    setLookupResult(await getCashCounterForDate(lookupDate));
    setLookupLoading(false);
  }

  // Live preview while staff are still typing the Closing Cash count,
  // before it's Recorded -- lets them see Cash Handed Over update as
  // they adjust the figure, instead of only finding out after saving.
  // Purely client-side math mirroring the server formula in
  // getCashCounterForDate; nothing is persisted until Record is clicked.
  const liveClosingCash = closingInput !== '' && !isNaN(Number(closingInput)) ? Number(closingInput) : null;
  const livePreview = (today && today.closingCash == null && liveClosingCash != null)
    ? Number(today.openingCash || 0) + Number(today.reconciledCashActual || 0) - liveClosingCash
    : null;

  if (loading || !today) {
    return <div className="card"><div style={{ padding: 20, color: 'var(--g400)', fontSize: 13 }}>Loading...</div></div>;
  }

  return (
    <div>
      <div className="card" style={{ marginBottom: 16 }}>
        <div className="card-title" style={{ marginBottom: 14 }}><span className="badge b-gray" style={{ marginRight: 8 }}>Step 2</span><i className="ti ti-wallet" style={{ color: 'var(--blue)' }}></i> Cash Counter -- Today</div>

        {!today.reconciliationLocked ? (
          <div style={{ fontSize: 12.5, color: 'var(--g500)', padding: '4px 0' }}>
            <i className="ti ti-lock" style={{ color: 'var(--g400)' }}></i> Close Reconciliation (Step 1) above first -- Cash Counter unlocks once that's done.
          </div>
        ) : (
          <>
            {error && <div className="msg-err" style={{ marginBottom: 14 }}>{error}</div>}

            <div style={{ display: 'flex', gap: 24, padding: '16px 20px', background: 'var(--g50)', borderRadius: 'var(--r)', marginBottom: 20 }}>
              <div style={{ flex: 1 }}>
                <div style={{ fontSize: 10.5, fontWeight: 700, textTransform: 'uppercase', letterSpacing: '.4px', color: 'var(--g500)', marginBottom: 4 }}>Opening Cash</div>
                <div style={{ fontFamily: 'var(--font-display-stack)', fontSize: 22, fontWeight: 700 }}>{today.openingCash != null ? fmt(today.openingCash) : '--'}</div>
                {today.openedBy && <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 2 }}>Opened by {today.openedBy}</div>}
              </div>
              <div style={{ flex: 1 }}>
                <div style={{ fontSize: 10.5, fontWeight: 700, textTransform: 'uppercase', letterSpacing: '.4px', color: 'var(--g500)', marginBottom: 4 }}>Closing Cash (Retained)</div>
                <div style={{ fontFamily: 'var(--font-display-stack)', fontSize: 22, fontWeight: 700, color: 'var(--green)' }}>{today.closingCash != null ? fmt(today.closingCash) : (liveClosingCash != null ? fmt(liveClosingCash) : '--')}</div>
                {today.closingRecordedBy && <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 2 }}>Counted by {today.closingRecordedBy}</div>}
                {today.closingCash == null && liveClosingCash != null && <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 2 }}>Not recorded yet</div>}
              </div>
              <div style={{ flex: 1 }}>
                <div style={{ fontSize: 10.5, fontWeight: 700, textTransform: 'uppercase', letterSpacing: '.4px', color: 'var(--g500)', marginBottom: 4 }}>Cash Handed Over</div>
                <div style={{ fontFamily: 'var(--font-display-stack)', fontSize: 22, fontWeight: 700, color: 'var(--purple)' }}>{today.amountHandedOver != null ? fmt(today.amountHandedOver) : (today.computedHandover != null ? fmt(today.computedHandover) : (livePreview != null ? fmt(livePreview) : '--'))}</div>
                <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 2 }}>
                  {today.handedOverBy
                    ? `Handed over by ${today.handedOverBy}`
                    : today.closingCash != null
                      ? `Opening ${fmt(today.openingCash || 0)} + Cash (Step 1, net of expenses) ${fmt(today.reconciledCashActual)} - Retained ${fmt(today.closingCash)}`
                      : livePreview != null
                        ? `Live estimate as you type -- Record to lock in the count`
                        : 'Record closing cash count below to compute'}
                </div>
              </div>
            </div>

            {today.closingCash == null && (
              <div style={{ marginBottom: 4 }}>
                <label className="flbl">Record Closing Cash Count</label>
                <div style={{ display: 'flex', gap: 8 }}>
                  <input className="fi" type="number" min="0" value={closingInput} onChange={(e) => setClosingInput(e.target.value)} placeholder="Amount physically counted in the drawer" style={{ flex: 1 }} />
                  <button className="btn btn-primary" disabled={saving || !closingInput} onClick={handleRecordClosing}>{saving ? 'Saving...' : 'Record'}</button>
                </div>
              </div>
            )}

            {today.closingCash != null && today.amountHandedOver == null && (
              <button className="btn btn-primary" disabled={saving} onClick={handleConfirm}>
                <i className="ti ti-lock"></i> {saving ? 'Confirming...' : 'Confirm & Close Cash Counter'}
              </button>
            )}

            {today.amountHandedOver != null && (
              <div style={{ background: 'var(--green-lt)', color: 'var(--green)', padding: '10px 14px', borderRadius: 'var(--r-sm)', fontSize: 13, fontWeight: 600, display: 'flex', justifyContent: 'space-between', alignItems: 'center', flexWrap: 'wrap', gap: 8 }}>
                <span><i className="ti ti-check"></i> Cash Counter closed -- {fmt(today.amountHandedOver)} handed over by {today.handedOverBy}. Close Day (Step 3) is now unlocked below.</span>
                <button className="btn btn-sm" style={{ background: '#fff' }} onClick={handleUnlockCounter}><i className="ti ti-lock-open"></i> Unlock</button>
              </div>
            )}
          </>
        )}
      </div>

      <div className="card">
        <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-history"></i> Cash Counter History -- Last 2 Days</div>
        <table className="tbl">
          <thead><tr><th>Date</th><th style={{ textAlign: 'right' }}>Opening</th><th style={{ textAlign: 'right' }}>Closing (Retained)</th><th style={{ textAlign: 'right' }}>Handed Over</th><th>By</th></tr></thead>
          <tbody>
            {history.map((h) => (
              <tr key={h.date}>
                <td>{new Date(h.date).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: '2-digit', month: 'short', year: 'numeric' })}</td>
                <td style={{ textAlign: 'right' }}>{fmt(h.openingCash)}</td>
                <td style={{ textAlign: 'right' }}>{h.closingCash != null ? fmt(h.closingCash) : '--'}</td>
                <td style={{ textAlign: 'right' }}>{h.amountHandedOver != null ? fmt(h.amountHandedOver) : '--'}</td>
                <td style={{ fontSize: 12 }}>{h.handedOverBy || '--'}</td>
              </tr>
            ))}
            {history.length === 0 && (
              <tr><td colSpan={5} style={{ padding: 20, textAlign: 'center', color: 'var(--g400)' }}>No history yet.</td></tr>
            )}
          </tbody>
        </table>

        <div style={{ marginTop: 16, paddingTop: 14, borderTop: '1px solid var(--g100)' }}>
          <label className="flbl">View another day</label>
          <div style={{ display: 'flex', gap: 8, marginBottom: lookupResult ? 10 : 0 }}>
            <input className="fi" type="date" value={lookupDate} onChange={(e) => setLookupDate(e.target.value)} style={{ flex: 1 }} />
            <button className="btn btn-sm" disabled={!lookupDate || lookupLoading} onClick={handleLookup}>{lookupLoading ? 'Loading...' : 'View'}</button>
          </div>
          {lookupResult && (
            <div style={{ display: 'flex', gap: 20, fontSize: 13, padding: '8px 0' }}>
              <span>Opening: <strong>{lookupResult.openingCash != null ? fmt(lookupResult.openingCash) : '--'}</strong></span>
              <span>Closing: <strong>{lookupResult.closingCash != null ? fmt(lookupResult.closingCash) : '--'}</strong></span>
              <span>Handed Over: <strong>{lookupResult.amountHandedOver != null ? fmt(lookupResult.amountHandedOver) : '--'}</strong></span>
              {lookupResult.handedOverBy && <span style={{ color: 'var(--g500)' }}>by {lookupResult.handedOverBy}</span>}
            </div>
          )}
        </div>
      </div>
    </div>
  );
}

export default function CashManagementPage() {
  const [activeTab, setActiveTab] = useState('summary');
  const [summary, setSummary] = useState({ transactions: [], byMode: {}, total: 0, count: 0 });
  const [revenueByDept, setRevenueByDept] = useState({});
  const [reconRows, setReconRows] = useState([]);
  const [readiness, setReadiness] = useState(null);
  const [history, setHistory] = useState([]);
  const [approvers, setApprovers] = useState([]);
  const [closedToday, setClosedToday] = useState(false);
  const [reconLock, setReconLock] = useState({ locked: false });
  const [cashCounterConfirmed, setCashCounterConfirmed] = useState(false);
  // Stable identity across every re-render of this (large, frequently
  // re-rendering) component -- CashCounterTab's own refresh effect
  // depends on this prop's reference, so an inline arrow here would
  // give it a new identity on every keystroke anywhere on this page
  // (report notes, past-day recon fields, etc.), re-triggering its
  // Cash Counter fetch each time instead of only when status changes.
  const handleCashCounterStatusChange = useCallback((confirmed) => setCashCounterConfirmed(confirmed), []);
  const [opening, setOpening] = useState(null);
  const [openingBalance, setOpeningBalance] = useState('');
  const [openingRemarks, setOpeningRemarks] = useState('');
  const [todayClosingInfo, setTodayClosingInfo] = useState(null);
  const [openQueueEntries, setOpenQueueEntries] = useState([]);
  const [bulkCloseReason, setBulkCloseReason] = useState('');
  const [bulkClosing, setBulkClosing] = useState(false);
  const [unclosedPastDays, setUnclosedPastDays] = useState([]);
  const [closingPastDate, setClosingPastDate] = useState(null);
  const [pastSummary, setPastSummary] = useState(null);
  const [pastReconRows, setPastReconRows] = useState([]);
  const [pastReconEdits, setPastReconEdits] = useState({});
  const [pastReconApprover, setPastReconApprover] = useState('');
  const [pastCloseNotes, setPastCloseNotes] = useState('');
  const [pastLoading, setPastLoading] = useState(false);
  const [pastCounter, setPastCounter] = useState(null);
  const [pastClosingInput, setPastClosingInput] = useState('');

  const [reconEdits, setReconEdits] = useState({});
  const [reconApprover, setReconApprover] = useState('');
  const [closeNotes, setCloseNotes] = useState('');
  const [reportDate, setReportDate] = useState(new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' }));
  const [report, setReport] = useState(null);
  const [reopenTarget, setReopenTarget] = useState(null);
  const [reopenReason, setReopenReason] = useState('');

  const [error, setError] = useState('');
  const [success, setSuccess] = useState('');
  const [loading, setLoading] = useState(false);

  const [expenseCategories, setExpenseCategories] = useState([]);
  const [todayExpenses, setTodayExpenses] = useState([]);
  const [pettyCashTotal, setPettyCashTotal] = useState(0);
  const [newExpenseCategory, setNewExpenseCategory] = useState('');
  const [newExpenseAmount, setNewExpenseAmount] = useState('');
  const [newExpenseRemarks, setNewExpenseRemarks] = useState('');
  const [newExpenseBill, setNewExpenseBill] = useState(null);
  const [expenseSaving, setExpenseSaving] = useState(false);
  const [showAddCategory, setShowAddCategory] = useState(false);
  const [newCategoryName, setNewCategoryName] = useState('');
  const [expandedExpenseId, setExpandedExpenseId] = useState(null);
  const billInputRef = useRef(null);

  const refreshPettyCash = useCallback(async () => {
    const today = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
    const [cats, expenses, total] = await Promise.all([
      getExpenseCategoriesActive(),
      getExpensesForDate(today),
      getPettyCashTotal(today),
    ]);
    setExpenseCategories(cats);
    setTodayExpenses(expenses);
    setPettyCashTotal(total);
  }, []);

  useEffect(() => { refreshPettyCash(); }, [refreshPettyCash]);

  async function handleAddExpense() {
    setError(''); setSuccess('');
    if (!newExpenseCategory) { setError('Select an expense category.'); return; }
    if (!newExpenseAmount || parseFloat(newExpenseAmount) <= 0) { setError('Enter a valid amount.'); return; }
    setExpenseSaving(true);
    const result = await addExpense(newExpenseCategory, parseFloat(newExpenseAmount), newExpenseRemarks, '');
    if (result.error) { setExpenseSaving(false); setError(result.error); return; }

    if (newExpenseBill && result.expense) {
      const formData = new FormData();
      formData.append('file', newExpenseBill);
      formData.append('entityType', 'petty_cash_expense');
      formData.append('entityId', result.expense.id);
      const uploadResult = await uploadAttachment(formData);
      if (uploadResult.error) setError(`Expense saved, but the bill upload failed: ${uploadResult.error}`);
    }

    setExpenseSaving(false);
    setNewExpenseCategory(''); setNewExpenseAmount(''); setNewExpenseRemarks(''); setNewExpenseBill(null);
    if (billInputRef.current) billInputRef.current.value = '';
    setSuccess('Expense recorded.');
    refreshPettyCash();
    refreshReconciliation();
  }

  async function handleDeleteExpense(exp) {
    if (!window.confirm(`Delete this ${fmt(exp.amount)} expense?`)) return;
    setError(''); setSuccess('');
    const result = await deleteExpense(exp.id, exp.expense_date);
    if (result.error) { setError(result.error); return; }
    refreshPettyCash();
    refreshReconciliation();
  }

  async function handleAddCategory() {
    setError('');
    if (!newCategoryName.trim()) return;
    const result = await addExpenseCategory({ name: newCategoryName });
    if (result.error) { setError(result.error); return; }
    setNewCategoryName('');
    setShowAddCategory(false);
    refreshPettyCash();
  }

  const refresh = useCallback(async () => {
    // Was previously a sequential await-then-Promise.all -- the other
    // 5 fetches don't depend on the summary at all, only readiness
    // does, so there's no reason to make them wait behind it.
    const [
      summaryData, revenueByDeptData, historyData,
      openingData, openQueueData, unclosedPastDaysData,
    ] = await Promise.all([
      getTodayCollectionSummary(),
      getRevenueByDepartmentToday(),
      getDayClosingHistory(),
      getDayOpening(),
      getOpenQueueEntriesToday(),
      getUnclosedPastDays(),
    ]);
    const readinessData = await getCloseDayReadiness(undefined, summaryData);
    // readiness.alreadyClosed is the same day_closings check
    // isTodayClosed() used to make as a separate RPC round trip.
    const isClosed = readinessData.alreadyClosed;
    const [lockStatus, counterStatus] = await Promise.all([getReconciliationLockStatus(), getCashCounterForDate()]);
    setReconLock(lockStatus);
    setCashCounterConfirmed(counterStatus.amountHandedOver != null);
    setSummary(summaryData);
    setRevenueByDept(revenueByDeptData);
    setReadiness(readinessData);
    setReconRows(readinessData.reconciliation); // already computed inside getCloseDayReadiness -- no need to fetch again
    setHistory(historyData);
    setClosedToday(isClosed);
    setOpening(openingData);
    setOpenQueueEntries(openQueueData);
    setUnclosedPastDays(unclosedPastDaysData);
    if (isClosed) {
      const todayStr = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
      setTodayClosingInfo(await getDailyReport(todayStr));
    } else {
      setTodayClosingInfo(null);
    }
  }, []);

  // Scoped refresh for the actual closing ritual -- saving one payment
  // mode's reconciliation (or adding/removing a petty cash expense,
  // which changes Cash's expected figure) doesn't change the
  // underlying transactions for the day at all, so there's no reason
  // to re-run the heavy payments+joins query, revenue-by-department,
  // 30-row closing history, day opening, open queue, and unclosed-past-
  // days checks every single time. Closing a day with 5 payment modes
  // used to mean 5 full-page-equivalent reloads back to back -- this
  // is the fix for that. Reuses the summary already in state (petty
  // cash total is always fetched fresh inside getReconciliationData
  // regardless, so Cash's expected figure still updates correctly).
  const refreshReconciliation = useCallback(async () => {
    if (!summary) { await refresh(); return; }
    const readinessData = await getCloseDayReadiness(undefined, summary);
    setReadiness(readinessData);
    setReconRows(readinessData.reconciliation);
    setClosedToday(readinessData.alreadyClosed);
    setReconLock(await getReconciliationLockStatus());
  }, [summary, refresh]);

  useEffect(() => { refresh(); }, [refresh]);
  useEffect(() => { getApprovers().then(setApprovers); }, []);

  function updateReconField(mode, field, value) {
    setReconEdits((prev) => ({ ...prev, [mode]: { ...prev[mode], [field]: value } }));
  }

  async function handleSaveRecon(row) {
    setError(''); setSuccess('');
    const edit = reconEdits[row.mode] || {};
    const actual = edit.actual !== undefined ? parseFloat(edit.actual) : row.actual;
    const reason = edit.reason !== undefined ? edit.reason : row.reason;
    const variance = actual - row.expected;

    if (Math.abs(variance) > 0.01 && !reason) {
      setError(`A variance reason is required for ${row.mode} (variance: ${fmt(variance)}).`);
      return;
    }
    if (Math.abs(variance) > 0.01 && !reconApprover) {
      setError('Select a supervisor to approve this variance.');
      return;
    }

    const result = await saveReconciliation(row.mode, row.expected, actual, reason, Math.abs(variance) > 0.01 ? reconApprover : null);
    if (result.error) { setError(result.error); return; }
    setSuccess(`${row.mode} reconciled.`);
    refreshReconciliation();
  }

  async function handleLockReconciliation() {
    setError(''); setSuccess('');
    const result = await lockReconciliation();
    if (result.error) { setError(result.error); return; }
    setSuccess('Reconciliation closed for the day.');
    refreshReconciliation();
  }

  async function handleUnlockReconciliation() {
    setError(''); setSuccess('');
    const result = await unlockReconciliation();
    if (result.error) { setError(result.error); return; }
    setSuccess('Reconciliation unlocked -- you can edit it again.');
    refreshReconciliation();
  }

  async function handleOpenDay() {
    setError(''); setSuccess('');
    const result = await openDay(parseFloat(openingBalance) || 0, openingRemarks);
    if (result.error) { setError(result.error); return; }
    setSuccess('Day opened.');
    setOpeningBalance(''); setOpeningRemarks('');
    refresh();
  }

  // Soft warning, not a hard block -- Close Day can still proceed with
  // patients left open in Doctor/Optometry queues. This just makes it a
  // deliberate choice with a reason on record, instead of those visits
  // silently rolling into tomorrow's queue view.
  async function handleBulkForceClose() {
    setError(''); setSuccess('');
    if (!bulkCloseReason.trim()) { setError('A reason is required to close these visits.'); return; }
    setBulkClosing(true);
    const ids = openQueueEntries.map((e) => e.id);
    const result = await bulkForceCloseQueueEntries(ids, bulkCloseReason);
    setBulkClosing(false);
    if (result.error) { setError(result.error); return; }
    setSuccess(`Closed ${result.count} visit(s).`);
    setBulkCloseReason('');
    refresh();
  }

  // ── CLOSE A PAST DAY -- self-contained, mirrors the main
  // Reconciliation/Close Day flow but scoped to a specific backdated
  // date instead of today, with its own state so it can't collide with
  // whatever's happening on today's tabs at the same time. ──
  async function openPastDayClosing(date) {
    setError(''); setSuccess('');
    setClosingPastDate(date);
    setPastReconEdits({});
    setPastCloseNotes('');
    setPastClosingInput('');
    // Fetched once per session and reused on every mode save below --
    // the underlying transactions for a past, already-finished day
    // never change mid-session, so there's no reason to re-run the
    // heavy payments+joins query after every single save (same fix as
    // the main today's-reconciliation flow above).
    const summaryData = await getTodayCollectionSummary(date);
    setPastSummary(summaryData);
    setPastReconRows(await getReconciliationData(date, summaryData));
    setPastCounter(await getCashCounterForDate(date));
  }

  async function refreshPastCounter() {
    setPastCounter(await getCashCounterForDate(closingPastDate));
  }

  async function handleRecordPastClosing() {
    setError('');
    setPastLoading(true);
    const result = await recordClosingCash(pastClosingInput, closingPastDate);
    setPastLoading(false);
    if (result.error) { setError(result.error); return; }
    setPastClosingInput('');
    refreshPastCounter();
  }

  async function handleConfirmPastCounter() {
    setError('');
    setPastLoading(true);
    const result = await confirmCashCounter(closingPastDate);
    setPastLoading(false);
    if (result.error) { setError(result.error); return; }
    refreshPastCounter();
  }

  async function handleUnlockPastCounter() {
    setError('');
    setPastLoading(true);
    const result = await unlockCashCounter(closingPastDate);
    setPastLoading(false);
    if (result.error) { setError(result.error); return; }
    setPastClosingInput('');
    refreshPastCounter();
  }

  function updatePastReconField(mode, field, value) {
    setPastReconEdits((prev) => ({ ...prev, [mode]: { ...prev[mode], [field]: value } }));
  }

  async function handleSavePastRecon(row) {
    setError(''); setSuccess('');
    const edit = pastReconEdits[row.mode] || {};
    const actual = edit.actual !== undefined ? parseFloat(edit.actual) : row.actual;
    const reason = edit.reason !== undefined ? edit.reason : row.reason;
    const variance = actual - row.expected;

    if (Math.abs(variance) > 0.01 && !reason) {
      setError(`A variance reason is required for ${row.mode} (variance: ${fmt(variance)}).`);
      return;
    }
    if (Math.abs(variance) > 0.01 && !pastReconApprover) {
      setError('Select a supervisor to approve this variance.');
      return;
    }

    const result = await saveReconciliation(row.mode, row.expected, actual, reason, Math.abs(variance) > 0.01 ? pastReconApprover : null, closingPastDate);
    if (result.error) { setError(result.error); return; }
    setSuccess(`${row.mode} reconciled for ${closingPastDate}.`);
    setPastReconRows(await getReconciliationData(closingPastDate, pastSummary));
  }

  async function handleClosePastDay() {
    setError(''); setSuccess('');
    const allSaved = pastReconRows.every((r) => r.saved);
    if (!allSaved) { setError('Complete reconciliation for every payment mode before closing this day.'); return; }
    if (pastCounter && pastCounter.amountHandedOver == null) { setError('Confirm Cash Counter (Step 2) for this date before closing it.'); return; }
    setPastLoading(true);
    const result = await closeDay(pastCloseNotes, closingPastDate);
    setPastLoading(false);
    if (result.error) { setError(result.error); return; }
    setSuccess(`${closingPastDate} closed successfully.`);
    setClosingPastDate(null);
    refresh();
  }

  async function handleCloseDay() {
    setError(''); setSuccess('');
    if (!readiness?.reconciliationComplete) { setError('Complete reconciliation for every payment mode before closing.'); return; }
    setLoading(true);
    const result = await closeDay(closeNotes);
    setLoading(false);
    if (result.error) { setError(result.error); return; }
    setSuccess('Day closed successfully. Daily report generated.');
    refresh();
    setActiveTab('report');
    loadReport(new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' }));
  }

  async function loadReport(date) {
    setReport(await getDailyReport(date));
  }

  useEffect(() => { if (activeTab === 'report') loadReport(reportDate); }, [activeTab, reportDate]);

  async function handleReopen() {
    if (!reopenReason.trim()) { setError('A reason is required to reopen.'); return; }
    setError('');
    const result = await reopenDay(reopenTarget, reopenReason);
    if (result.error) { setError(result.error); return; }
    setSuccess(`${reopenTarget} reopened.`);
    setReopenTarget(null);
    setReopenReason('');
    refresh();
  }

  return (
    <div>
      <div style={{ borderRadius: 12, padding: '14px 18px', marginBottom: 16, color: '#fff', background: closedToday ? 'linear-gradient(135deg,#303a42,#1c242b)' : opening ? 'linear-gradient(135deg,#166534,#157a4f)' : (unclosedPastDays.length > 0 ? 'linear-gradient(135deg,#991b1b,#7f1d1d)' : 'linear-gradient(135deg,#92400e,#a15c00)') }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
          <div style={{ width: 10, height: 10, borderRadius: '50%', background: closedToday ? '#97a0aa' : opening ? '#4ade80' : (unclosedPastDays.length > 0 ? '#f87171' : '#fbbf24'), boxShadow: closedToday ? 'none' : `0 0 8px ${opening ? '#4ade80' : (unclosedPastDays.length > 0 ? '#f87171' : '#fbbf24')}` }}></div>
          <div>
            <div style={{ fontWeight: 700 }}>
              {closedToday
                ? `Closed at ${new Date(todayClosingInfo?.closing?.closed_at).toLocaleTimeString('en-IN', { timeZone: 'Asia/Kolkata', hour: '2-digit', minute: '2-digit' })}`
                : opening
                  ? `Opened at ${new Date(opening.opened_at).toLocaleTimeString('en-IN', { timeZone: 'Asia/Kolkata', hour: '2-digit', minute: '2-digit' })} by ${opening.profiles?.full_name || '--'}`
                  : unclosedPastDays.length > 0
                    ? `Can't open today -- ${unclosedPastDays[0]} was never closed`
                    : 'Day not opened yet'}
            </div>
            <div style={{ fontSize: 12, opacity: .85 }}>{new Date().toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', weekday: 'long', day: 'numeric', month: 'long', year: 'numeric' })}</div>
          </div>
          <div style={{ marginLeft: 'auto', fontSize: 13 }}>{fmt(summary.total)} collected today ({summary.count} transactions)</div>
        </div>
        {!opening && !closedToday && unclosedPastDays.length > 0 && (
          <div style={{ marginTop: 12, paddingTop: 12, borderTop: '1px solid rgba(255,255,255,.25)', display: 'flex', gap: 10, alignItems: 'center', flexWrap: 'wrap' }}>
            <span style={{ fontSize: 12.5 }}><i className="ti ti-alert-triangle"></i> {unclosedPastDays.length} earlier day(s) were opened but never closed -- close {unclosedPastDays.length > 1 ? 'them' : 'it'} before today can be opened.</span>
            <button className="btn" style={{ background: '#fff', color: '#991b1b', fontWeight: 700 }} onClick={() => setActiveTab('reconciliation')}>
              <i className="ti ti-calendar-exclamation"></i> Go to Reconciliation & Close Day
            </button>
          </div>
        )}
        {!opening && !closedToday && unclosedPastDays.length === 0 && (
          <div style={{ marginTop: 12, paddingTop: 12, borderTop: '1px solid rgba(255,255,255,.25)', display: 'flex', gap: 8, alignItems: 'flex-end', flexWrap: 'wrap' }}>
            <div>
              <label style={{ fontSize: 10, opacity: .85, display: 'block', marginBottom: 3 }}>Opening cash balance (Rs.)</label>
              <input type="number" value={openingBalance} onChange={(e) => setOpeningBalance(e.target.value)} placeholder="0.00" style={{ padding: '6px 10px', borderRadius: 6, border: 'none', width: 140 }} />
            </div>
            <div style={{ flex: 1, minWidth: 160 }}>
              <label style={{ fontSize: 10, opacity: .85, display: 'block', marginBottom: 3 }}>Remarks</label>
              <input value={openingRemarks} onChange={(e) => setOpeningRemarks(e.target.value)} placeholder="Optional..." style={{ padding: '6px 10px', borderRadius: 6, border: 'none', width: '100%' }} />
            </div>
            <button className="btn" style={{ background: '#fff', color: 'var(--amber)', fontWeight: 700 }} onClick={handleOpenDay}>
              <i className="ti ti-unlock"></i> Open Day
            </button>
          </div>
        )}
      </div>

      <div style={{ display: 'flex', gap: 6, marginBottom: 16, flexWrap: 'wrap' }}>
        {TABS.map((t) => (
          <button key={t.key} className={activeTab === t.key ? 'btn btn-primary' : 'btn'} onClick={() => { setActiveTab(t.key); setError(''); setSuccess(''); }}>
            <i className={`ti ${t.icon}`}></i> {t.label}
          </button>
        ))}
      </div>

      {error && <div className="msg-err">{error}</div>}
      {success && <div className="msg-success"><i className="ti ti-circle-check"></i> {success}</div>}

      {activeTab === 'summary' && (
        <div>
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 16, marginBottom: 16 }}>
            <div className="card" style={{ borderTop: '3px solid var(--amber)' }}>
              <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>Total Collected</div>
              <div style={{ fontSize: 22, fontWeight: 800, marginTop: 6 }}>{fmt(summary.total)}</div>
              <div style={{ fontSize: 11, color: 'var(--g400)' }}>{summary.count} transactions</div>
            </div>
            {['Cash', 'UPI', 'Card'].map((m) => (
              <div key={m} className="card" style={{ borderTop: '3px solid var(--blue)' }}>
                <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>{m}</div>
                <div style={{ fontSize: 22, fontWeight: 800, marginTop: 6 }}>{fmt(summary.byMode[m] || 0)}</div>
              </div>
            ))}
          </div>

          <div className="card" style={{ marginBottom: 16 }}>
            <div className="card-title" style={{ marginBottom: 10 }}>
              <i className="ti ti-chart-bar" style={{ color: 'var(--amber)' }}></i> Collections by Department -- Today
            </div>
            {Object.keys(revenueByDept).length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No collections yet today.</div>}
            {Object.entries(revenueByDept).sort((a, b) => b[1] - a[1]).map(([dept, amount]) => {
              const max = Math.max(...Object.values(revenueByDept));
              return (
                <div key={dept} style={{ marginBottom: 10 }}>
                  <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 12, marginBottom: 3 }}>
                    <span>{dept}</span><span style={{ fontWeight: 600 }}>{fmt(amount)}</span>
                  </div>
                  <div style={{ height: 8, background: 'var(--g100)', borderRadius: 4 }}>
                    <div style={{ width: `${max ? (amount / max) * 100 : 0}%`, height: '100%', background: 'var(--amber)', borderRadius: 4 }}></div>
                  </div>
                </div>
              );
            })}
          </div>

          <div className="card">
            <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-receipt" style={{ color: 'var(--green)' }}></i> Transactions Today</div>
            <table className="tbl">
              <thead><tr><th>Receipt #</th><th>Time</th><th>Patient</th><th>Mode(s)</th><th style={{ textAlign: 'right' }}>Amount</th></tr></thead>
              <tbody>
                {summary.transactions.map((p) => {
                  const isNonCash = p.payment_type === 'advance_adjustment' || p.payment_type === 'credit_note';
                  const displayName = p.patients ? formatPatientName(p.patients) : (p.opticalCustomerName || '--');
                  return (
                    <tr key={p.id} style={isNonCash ? { opacity: 0.65 } : undefined}>
                      <td style={{ fontFamily: 'monospace' }}>
                        {p.receipt_number}
                        {p.source === 'optical' && <span className="badge b-blue" style={{ fontSize: 9, marginLeft: 4 }}>Optical</span>}
                      </td>
                      <td>{new Date(p.collected_at).toLocaleTimeString('en-IN', { timeZone: 'Asia/Kolkata', hour: '2-digit', minute: '2-digit' })}</td>
                      <td>{displayName}</td>
                      <td>
                        {(p.payment_modes || []).map((m) => m.mode).join('+')}
                        {isNonCash && <span className="badge b-gray" style={{ fontSize: 9, marginLeft: 4 }}>{p.payment_type === 'credit_note' ? 'Credit note -- no cash' : 'Adjustment -- no new cash'}</span>}
                      </td>
                      <td style={{ textAlign: 'right', fontWeight: 600, color: p.payment_type === 'refund' ? 'var(--red)' : 'var(--g800)' }}>
                        {p.payment_type === 'refund' ? '-' : ''}{fmt(p.total_amount)}
                      </td>
                    </tr>
                  );
                })}
                {summary.transactions.length === 0 && (
                  <tr><td colSpan={5} style={{ padding: 20, textAlign: 'center', color: 'var(--g400)' }}>No transactions yet today.</td></tr>
                )}
              </tbody>
            </table>
          </div>
        </div>
      )}

      {activeTab === 'pettycash' && (
        <div>
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(2, 1fr)', gap: 16, marginBottom: 16 }}>
            <div className="card" style={{ borderTop: '3px solid var(--red)' }}>
              <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>Today's Cash Expenses</div>
              <div style={{ fontSize: 22, fontWeight: 800, marginTop: 6 }}>{fmt(pettyCashTotal)}</div>
              <div style={{ fontSize: 11, color: 'var(--g400)' }}>{todayExpenses.length} entries</div>
            </div>
            <div className="card" style={{ borderTop: '3px solid var(--blue)' }}>
              <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>Net Cash Expected</div>
              <div style={{ fontSize: 22, fontWeight: 800, marginTop: 6 }}>{fmt((summary.byMode['Cash'] || 0) - pettyCashTotal)}</div>
              <div style={{ fontSize: 11, color: 'var(--g400)' }}>Cash collected minus cash expenses</div>
            </div>
          </div>

          {!opening && (
            <div className="msg-err" style={{ marginBottom: 14 }}><i className="ti ti-alert-triangle"></i> Today's cash day hasn't been opened yet. Open it from the "Today's Collection" tab before recording expenses.</div>
          )}
          {closedToday && (
            <div className="msg-err" style={{ marginBottom: 14 }}><i className="ti ti-lock"></i> Today is already closed -- cash expense entries are locked. See the Daily Report tab.</div>
          )}

          {!closedToday && opening && (
            <div className="card" style={{ marginBottom: 16 }}>
              <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-plus" style={{ color: 'var(--green)' }}></i> Record an Expense</div>
              <div style={{ display: 'grid', gridTemplateColumns: '1.6fr 0.8fr 1.6fr', gap: 10, marginBottom: 10 }}>
                <select className="fi" value={newExpenseCategory} onChange={(e) => setNewExpenseCategory(e.target.value)}>
                  <option value="">-- Category --</option>
                  {expenseCategories.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
                </select>
                <input type="number" className="fi" placeholder="Amount" value={newExpenseAmount} onChange={(e) => setNewExpenseAmount(e.target.value)} />
                <input type="text" className="fi" placeholder="Remarks (optional)" value={newExpenseRemarks} onChange={(e) => setNewExpenseRemarks(e.target.value)} />
              </div>
              <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
                <label className="btn" style={{ cursor: 'pointer', marginBottom: 0 }}>
                  <i className="ti ti-paperclip"></i> {newExpenseBill ? newExpenseBill.name : 'Attach bill (optional)'}
                  <input ref={billInputRef} type="file" accept="application/pdf,image/jpeg,image/png,image/jpg" onChange={(e) => setNewExpenseBill(e.target.files?.[0] || null)} style={{ display: 'none' }} />
                </label>
                {newExpenseBill && (
                  <button className="btn" style={{ padding: '3px 9px', fontSize: 11 }} onClick={() => { setNewExpenseBill(null); if (billInputRef.current) billInputRef.current.value = ''; }}>
                    <i className="ti ti-x"></i>
                  </button>
                )}
                <span style={{ flex: 1 }}></span>
                <button className="btn btn-primary" disabled={expenseSaving} onClick={handleAddExpense}>{expenseSaving ? 'Saving...' : 'Add Expense'}</button>
              </div>

              {!showAddCategory && (
                <div style={{ marginTop: 10 }}>
                  <button className="btn btn-sm" onClick={() => setShowAddCategory(true)}><i className="ti ti-plus"></i> New category</button>
                </div>
              )}
              {showAddCategory && (
                <div style={{ display: 'flex', gap: 8, marginTop: 10 }}>
                  <input type="text" className="fi fi-sm" style={{ maxWidth: 220 }} placeholder="Category name" value={newCategoryName} onChange={(e) => setNewCategoryName(e.target.value)} />
                  <button className="btn btn-sm btn-primary" onClick={handleAddCategory}>Save</button>
                  <button className="btn btn-sm" onClick={() => { setShowAddCategory(false); setNewCategoryName(''); }}>Cancel</button>
                </div>
              )}
            </div>
          )}

          <div className="card">
            <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-receipt" style={{ color: 'var(--red)' }}></i> Today's Expenses</div>
            <table className="tbl">
              <thead><tr><th>Time</th><th>Category</th><th>Remarks</th><th>Entered By</th><th style={{ textAlign: 'right' }}>Amount</th><th></th></tr></thead>
              <tbody>
                {todayExpenses.map((exp) => (
                  <Fragment key={exp.id}>
                    <tr>
                      <td>{new Date(exp.created_at).toLocaleTimeString('en-IN', { timeZone: 'Asia/Kolkata', hour: '2-digit', minute: '2-digit' })}</td>
                      <td>{exp.master_expense_categories?.name}</td>
                      <td>{exp.paid_to || '--'}</td>
                      <td>{exp.profiles?.full_name || 'Staff'}</td>
                      <td style={{ textAlign: 'right', fontWeight: 600 }}>{fmt(exp.amount)}</td>
                      <td style={{ textAlign: 'right', whiteSpace: 'nowrap' }}>
                        <button className="btn" style={{ padding: '3px 9px', fontSize: 11 }} onClick={() => setExpandedExpenseId(expandedExpenseId === exp.id ? null : exp.id)}>
                          <i className="ti ti-paperclip"></i>
                        </button>
                        {!closedToday && (
                          <button className="btn" style={{ padding: '3px 9px', fontSize: 11, marginLeft: 4 }} onClick={() => handleDeleteExpense(exp)}>
                            <i className="ti ti-trash" style={{ color: 'var(--red)' }}></i>
                          </button>
                        )}
                      </td>
                    </tr>
                    {expandedExpenseId === exp.id && (
                      <tr>
                        <td colSpan={6} style={{ background: 'var(--g50)' }}>
                          <AttachmentUploader entityType="petty_cash_expense" entityId={exp.id} title="Bill / Receipt" />
                        </td>
                      </tr>
                    )}
                  </Fragment>
                ))}
                {todayExpenses.length === 0 && (
                  <tr><td colSpan={6} style={{ padding: 20, textAlign: 'center', color: 'var(--g400)' }}>No cash expenses recorded today.</td></tr>
                )}
              </tbody>
            </table>
          </div>
        </div>
      )}

      {activeTab === 'reconciliation' && (
        <>
        {/* Always reachable regardless of today's Step 1/2/3 status --
            an unclosed past day blocks Open Day for today (see the DB's
            open_day() guard), so if this were gated behind today's own
            steps (as it used to be) there'd be no way to ever reach it:
            today can't open until the past day closes, and today's
            steps can't run until it opens. */}
        {unclosedPastDays.length > 0 && (
          <div className="card" style={{ marginBottom: 16, border: '1.5px solid var(--red)' }}>
            <div className="card-title" style={{ marginBottom: 10 }}>
              <i className="ti ti-alert-triangle" style={{ color: 'var(--red)' }}></i> {unclosedPastDays.length} day(s) were opened but never closed
            </div>
            <div className="msg-err" style={{ marginBottom: 12 }}>
              <i className="ti ti-lock"></i> A new day can&apos;t be opened until these are resolved. Close them here, oldest first.
            </div>

            {!closingPastDate ? (
              <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
                {unclosedPastDays.map((d) => (
                  <button key={d} className="btn" style={{ borderColor: 'var(--red)', color: 'var(--red)' }} onClick={() => openPastDayClosing(d)}>
                    <i className="ti ti-calendar-exclamation"></i> Close {d}
                  </button>
                ))}
              </div>
            ) : (
              <div>
                <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 10 }}>
                  <strong style={{ fontSize: 14 }}>Closing {closingPastDate}</strong>
                  <button className="btn btn-sm" onClick={() => setClosingPastDate(null)}>Back to list</button>
                </div>

                <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase', marginBottom: 6 }}><span className="badge b-gray" style={{ marginRight: 6 }}>Step 1</span>Cash Reconciliation</div>
                <div style={{ display: 'flex', padding: '8px 12px', background: 'var(--g50)', borderRadius: 8, marginBottom: 6, fontSize: 11, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase' }}>
                  <span style={{ minWidth: 140 }}>Mode</span>
                  <span style={{ minWidth: 130, textAlign: 'right' }}>Expected</span>
                  <span style={{ flex: 1, textAlign: 'center' }}>Actual</span>
                  <span style={{ minWidth: 130, textAlign: 'right' }}>Variance</span>
                  <span style={{ minWidth: 90 }}></span>
                </div>
                {pastReconRows.map((row) => {
                  const editedActual = pastReconEdits[row.mode]?.actual !== undefined ? pastReconEdits[row.mode].actual : row.actual;
                  const variance = parseFloat(editedActual || 0) - row.expected;
                  const hasVariance = Math.abs(variance) > 0.01;
                  return (
                    <div key={row.mode} style={{ padding: '10px 12px', borderBottom: '1px solid var(--g100)', background: hasVariance ? 'var(--amber-lt)' : 'transparent', borderRadius: 8, marginBottom: 6 }}>
                      <div style={{ display: 'flex', alignItems: 'center' }}>
                        <span style={{ minWidth: 140, fontWeight: 600, fontSize: 13 }}>{row.mode}</span>
                        <span style={{ minWidth: 130, textAlign: 'right', fontWeight: 700, color: 'var(--green)' }}>{fmt(row.expected)}</span>
                        <span style={{ flex: 1, textAlign: 'center' }}>
                          <input type="number" className="fi fi-sm" style={{ maxWidth: 140, textAlign: 'right', display: 'inline-block' }} value={editedActual}
                            onChange={(e) => updatePastReconField(row.mode, 'actual', e.target.value)} />
                        </span>
                        <span style={{ minWidth: 130, textAlign: 'right', fontWeight: 700, color: hasVariance ? 'var(--red)' : 'var(--g400)' }}>
                          {hasVariance ? (variance > 0 ? '+' : '') + fmt(variance) : fmt(0)}
                        </span>
                        <span style={{ minWidth: 90, textAlign: 'right' }}>
                          <button className="btn btn-sm btn-primary" onClick={() => handleSavePastRecon(row)}>Save</button>
                          {row.saved && <span className="badge b-green" style={{ marginLeft: 6 }}>Saved</span>}
                        </span>
                      </div>
                      {hasVariance && (
                        <div style={{ display: 'flex', gap: 8, marginTop: 8 }}>
                          <input className="fi fi-sm" placeholder="Variance reason" value={pastReconEdits[row.mode]?.reason !== undefined ? pastReconEdits[row.mode].reason : row.reason}
                            onChange={(e) => updatePastReconField(row.mode, 'reason', e.target.value)} />
                          <select className="fi fi-sm" value={pastReconApprover} onChange={(e) => setPastReconApprover(e.target.value)}>
                            <option value="">-- Approving supervisor --</option>
                            {approvers.map((a) => <option key={a.id} value={a.id}>{a.full_name}</option>)}
                          </select>
                        </div>
                      )}
                    </div>
                  );
                })}
                {pastReconRows.length === 0 && <div style={{ padding: 20, textAlign: 'center', color: 'var(--g400)' }}>No collections recorded for this date -- nothing to reconcile.</div>}

                {pastCounter && (
                  <div style={{ marginTop: 20, padding: 14, background: 'var(--g50)', borderRadius: 8 }}>
                    <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase', marginBottom: 10 }}><span className="badge b-gray" style={{ marginRight: 6 }}>Step 2</span>Cash Counter</div>

                    {!pastReconRows.every((r) => r.saved) ? (
                      <div style={{ fontSize: 12.5, color: 'var(--g500)' }}><i className="ti ti-lock" style={{ color: 'var(--g400)' }}></i> Save reconciliation for every mode above first.</div>
                    ) : (
                      <>
                        <div style={{ display: 'flex', gap: 24, marginBottom: 14, flexWrap: 'wrap' }}>
                          <div>
                            <div style={{ fontSize: 10.5, fontWeight: 700, textTransform: 'uppercase', color: 'var(--g500)' }}>Opening</div>
                            <div style={{ fontSize: 18, fontWeight: 700 }}>{pastCounter.openingCash != null ? fmt(pastCounter.openingCash) : '--'}</div>
                          </div>
                          <div>
                            <div style={{ fontSize: 10.5, fontWeight: 700, textTransform: 'uppercase', color: 'var(--g500)' }}>Closing (Retained)</div>
                            <div style={{ fontSize: 18, fontWeight: 700, color: 'var(--green)' }}>{pastCounter.closingCash != null ? fmt(pastCounter.closingCash) : '--'}</div>
                          </div>
                          <div>
                            <div style={{ fontSize: 10.5, fontWeight: 700, textTransform: 'uppercase', color: 'var(--g500)' }}>Handed Over</div>
                            <div style={{ fontSize: 18, fontWeight: 700, color: 'var(--purple)' }}>{pastCounter.amountHandedOver != null ? fmt(pastCounter.amountHandedOver) : (pastCounter.computedHandover != null ? fmt(pastCounter.computedHandover) : '--')}</div>
                          </div>
                        </div>

                        {pastCounter.closingCash == null && (
                          <div style={{ display: 'flex', gap: 8, marginBottom: 4 }}>
                            <input className="fi" type="number" min="0" value={pastClosingInput} onChange={(e) => setPastClosingInput(e.target.value)} placeholder="Amount physically counted / retained" style={{ flex: 1 }} />
                            <button className="btn btn-primary" disabled={pastLoading || !pastClosingInput} onClick={handleRecordPastClosing}>{pastLoading ? 'Saving...' : 'Record'}</button>
                          </div>
                        )}

                        {pastCounter.closingCash != null && pastCounter.amountHandedOver == null && (
                          <button className="btn btn-primary" disabled={pastLoading} onClick={handleConfirmPastCounter}>
                            <i className="ti ti-lock"></i> {pastLoading ? 'Confirming...' : 'Confirm Cash Counter'}
                          </button>
                        )}

                        {pastCounter.amountHandedOver != null && (
                          <div style={{ background: 'var(--green-lt)', color: 'var(--green)', padding: '8px 12px', borderRadius: 'var(--r-sm)', fontSize: 12.5, fontWeight: 600, display: 'flex', justifyContent: 'space-between', alignItems: 'center', flexWrap: 'wrap', gap: 8 }}>
                            <span><i className="ti ti-check"></i> Confirmed -- {fmt(pastCounter.amountHandedOver)} handed over.</span>
                            <button className="btn btn-sm" style={{ background: '#fff' }} onClick={handleUnlockPastCounter}><i className="ti ti-lock-open"></i> Unlock</button>
                          </div>
                        )}
                      </>
                    )}
                  </div>
                )}

                <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase', marginTop: 20, marginBottom: 6 }}><span className="badge b-gray" style={{ marginRight: 6 }}>Step 3</span>Close Day</div>
                <label className="flbl">Closing notes</label>
                <textarea className="fi" rows={2} style={{ marginBottom: 10 }} value={pastCloseNotes} onChange={(e) => setPastCloseNotes(e.target.value)} placeholder="e.g. Closed late -- internet outage on this date" />
                <button className="btn btn-danger" onClick={handleClosePastDay} disabled={pastLoading || (pastReconRows.length > 0 && !pastReconRows.every((r) => r.saved)) || (pastCounter && pastCounter.amountHandedOver == null)}>
                  <i className="ti ti-lock"></i> {pastLoading ? 'Closing...' : `Close ${closingPastDate}`}
                </button>
              </div>
            )}
          </div>
        )}

        <div className="card">
          <div className="card-title" style={{ marginBottom: 4, display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
            <span><span className="badge b-gray" style={{ marginRight: 8 }}>Step 1</span><i className="ti ti-calculator" style={{ color: 'var(--amber)' }}></i> Cash Reconciliation</span>
            {!closedToday && reconLock.locked && (
              <button className="btn btn-sm" onClick={handleUnlockReconciliation}><i className="ti ti-lock-open"></i> Unlock</button>
            )}
          </div>
          <div className="msg-info" style={{ background: 'var(--blue-lt)', color: 'var(--blue)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 14 }}>
            <i className="ti ti-info-circle"></i> Enter the actual counted amount for each mode. The system computes variance automatically -- a reason and supervisor approval are required whenever actual differs from expected.
          </div>
          {closedToday && (
            <div className="msg-err" style={{ marginBottom: 14 }}><i className="ti ti-lock"></i> Today is already closed -- reconciliation is read-only.</div>
          )}
          {!closedToday && reconLock.locked && (
            <div className="msg-info" style={{ background: 'var(--green-lt)', color: 'var(--green)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 14 }}>
              <i className="ti ti-circle-check"></i> Reconciliation closed{reconLock.lockedBy ? ` by ${reconLock.lockedBy}` : ''} -- Cash Counter (Step 2) is now unlocked below. Use Unlock above if you need to change anything here.
            </div>
          )}

          {(() => { const reconciliationDisabled = closedToday || reconLock.locked; return (
          <>
          <div style={{ display: 'flex', padding: '8px 12px', background: 'var(--g50)', borderRadius: 8, marginBottom: 6, fontSize: 11, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase' }}>
            <span style={{ minWidth: 140 }}>Mode</span>
            <span style={{ minWidth: 130, textAlign: 'right' }}>Expected</span>
            <span style={{ flex: 1, textAlign: 'center' }}>Actual</span>
            <span style={{ minWidth: 130, textAlign: 'right' }}>Variance</span>
            <span style={{ minWidth: 90 }}></span>
          </div>

          {reconRows.map((row) => {
            const editedActual = reconEdits[row.mode]?.actual !== undefined ? reconEdits[row.mode].actual : row.actual;
            const variance = parseFloat(editedActual || 0) - row.expected;
            const hasVariance = Math.abs(variance) > 0.01;
            return (
              <div key={row.mode} style={{ padding: '10px 12px', borderBottom: '1px solid var(--g100)', background: hasVariance ? 'var(--amber-lt)' : 'transparent', borderRadius: 8, marginBottom: 6 }}>
                <div style={{ display: 'flex', alignItems: 'center' }}>
                  <span style={{ minWidth: 140, fontWeight: 600, fontSize: 13 }}>{row.mode}</span>
                  <span style={{ minWidth: 130, textAlign: 'right', fontWeight: 700, color: 'var(--green)' }}>{fmt(row.expected)}</span>
                  <span style={{ flex: 1, textAlign: 'center' }}>
                    <input type="number" className="fi fi-sm" style={{ maxWidth: 140, textAlign: 'right', display: 'inline-block' }} value={editedActual} disabled={reconciliationDisabled}
                      onChange={(e) => updateReconField(row.mode, 'actual', e.target.value)} />
                  </span>
                  <span style={{ minWidth: 130, textAlign: 'right', fontWeight: 700, color: hasVariance ? 'var(--red)' : 'var(--g400)' }}>
                    {hasVariance ? (variance > 0 ? '+' : '') + fmt(variance) : fmt(0)}
                  </span>
                  <span style={{ minWidth: 90, textAlign: 'right' }}>
                    {!reconciliationDisabled && <button className="btn btn-sm btn-primary" onClick={() => handleSaveRecon(row)}>Save</button>}
                    {row.saved && <span className="badge b-green" style={{ marginLeft: 6 }}>Saved</span>}
                  </span>
                </div>
                {hasVariance && !reconciliationDisabled && (
                  <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginTop: 8 }}>
                    <select className="fi fi-sm" value={reconEdits[row.mode]?.reason !== undefined ? reconEdits[row.mode].reason : row.reason} onChange={(e) => updateReconField(row.mode, 'reason', e.target.value)}>
                      <option value="">-- Variance reason --</option>
                      {VARIANCE_REASONS.map((r) => <option key={r} value={r}>{r}</option>)}
                    </select>
                    <select className="fi fi-sm" value={reconApprover} onChange={(e) => setReconApprover(e.target.value)}>
                      <option value="">-- Approved by --</option>
                      {approvers.map((a) => <option key={a.id} value={a.id}>{a.full_name}</option>)}
                    </select>
                  </div>
                )}
              </div>
            );
          })}
          {reconRows.length === 0 && <div style={{ padding: 20, textAlign: 'center', color: 'var(--g400)' }}>No collections yet today -- nothing to reconcile.</div>}
          {!closedToday && !reconLock.locked && (
            <button className="btn btn-primary" style={{ marginTop: 14 }} onClick={handleLockReconciliation}><i className="ti ti-lock"></i> Close Reconciliation</button>
          )}
          </>
          ); })()}
        </div>

        <div style={{ marginTop: 16 }}>
          <CashCounterTab onStatusChange={handleCashCounterStatusChange} />
        </div>

        {!cashCounterConfirmed ? (
          <div className="card" style={{ marginTop: 16 }}>
            <div className="card-title" style={{ marginBottom: 4 }}><span className="badge b-gray" style={{ marginRight: 8 }}>Step 3</span><i className="ti ti-lock" style={{ color: 'var(--g400)' }}></i> Close Day</div>
            <div style={{ fontSize: 12.5, color: 'var(--g500)' }}>Confirm Cash Counter (Step 2) above first.</div>
          </div>
        ) : (
        <div style={{ marginTop: 16 }}>
        <div style={{ display: 'grid', gridTemplateColumns: '1.2fr 1fr', gap: 20 }}>
          <div className="card">
            <div className="card-title" style={{ marginBottom: 10 }}><span className="badge b-gray" style={{ marginRight: 8 }}>Step 3</span><i className="ti ti-lock" style={{ color: 'var(--red)' }}></i> Close Day</div>
            {closedToday ? (
              <div className="msg-success"><i className="ti ti-circle-check"></i> Today is already closed. See the Daily Report tab.</div>
            ) : (
              <>
                <div className="msg-err" style={{ background: 'var(--amber-lt)', color: 'var(--amber)', border: 'none' }}>
                  <i className="ti ti-alert-triangle"></i> Once closed, no new visits, invoices, or payments can be created for today until it's reopened.
                </div>
                <label className="flbl">Closing notes</label>
                <textarea className="fi" rows={2} style={{ marginBottom: 14 }} value={closeNotes} onChange={(e) => setCloseNotes(e.target.value)} placeholder="Optional..." />
                <button className="btn btn-danger" onClick={handleCloseDay} disabled={loading || !readiness?.reconciliationComplete}>
                  <i className="ti ti-lock"></i> {loading ? 'Closing...' : 'Close Day and Generate Report'}
                </button>
              </>
            )}
          </div>
          <div className="card">
            <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-checklist" style={{ color: 'var(--green)' }}></i> Pre-close Checklist</div>
            <div style={{ fontSize: 13, lineHeight: 2.2 }}>
              <div><i className={`ti ${opening ? 'ti-circle-check' : 'ti-circle-x'}`} style={{ color: opening ? 'var(--green)' : 'var(--amber)', marginRight: 6 }}></i>
                Day opened{opening ? ` at ${new Date(opening.opened_at).toLocaleTimeString('en-IN', { timeZone: 'Asia/Kolkata', hour: '2-digit', minute: '2-digit' })}` : ' -- required before any payment can be collected today'}
              </div>
              <div><i className={`ti ${readiness?.reconciliationComplete ? 'ti-circle-check' : 'ti-circle-x'}`} style={{ color: readiness?.reconciliationComplete ? 'var(--green)' : 'var(--red)', marginRight: 6 }}></i>
                Reconciliation complete for all payment modes
              </div>
              <div><i className={`ti ${!closedToday ? 'ti-circle-check' : 'ti-circle-x'}`} style={{ color: !closedToday ? 'var(--green)' : 'var(--red)', marginRight: 6 }}></i>
                Day not already closed
              </div>
            </div>
          </div>

          {openQueueEntries.length > 0 && (
            <div className="card" style={{ gridColumn: '1 / -1' }}>
              <div className="card-title" style={{ marginBottom: 10 }}>
                <i className="ti ti-alert-triangle" style={{ color: 'var(--amber)' }}></i> {openQueueEntries.length} visit(s) still open in Doctor/Optometry queues
              </div>
              <div className="msg-info" style={{ marginBottom: 10 }}>
                <i className="ti ti-info-circle"></i> These won&apos;t block closing the day, but if left as-is they&apos;ll keep showing as pending tomorrow. Close them now with a shared reason, or leave them and resolve individually later from the Queue.
              </div>
              <table className="tbl" style={{ marginBottom: 12 }}>
                <thead><tr><th>Patient</th><th>Dept</th><th>Token</th><th>Status</th><th>Since</th></tr></thead>
                <tbody>
                  {openQueueEntries.map((e) => (
                    <tr key={e.id}>
                      <td>{formatPatientName(e.visits?.patients)} <span style={{ color: 'var(--g400)', fontSize: 11 }}>({e.visits?.patients?.uhid})</span></td>
                      <td>{e.department}</td>
                      <td>{e.token}</td>
                      <td>{e.status}</td>
                      <td>{new Date(e.issued_at).toLocaleTimeString('en-IN', { timeZone: 'Asia/Kolkata', hour: '2-digit', minute: '2-digit' })}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
              <label className="flbl">Reason (applied to all {openQueueEntries.length} visits above) *</label>
              <div style={{ display: 'flex', gap: 8 }}>
                <input className="fi" value={bulkCloseReason} onChange={(e) => setBulkCloseReason(e.target.value)} placeholder="e.g. End of day -- unresolved at closing time" />
                <button className="btn" style={{ background: 'var(--amber)', color: '#fff', borderColor: 'transparent' }} onClick={handleBulkForceClose} disabled={bulkClosing}>
                  {bulkClosing ? 'Closing...' : `Close All ${openQueueEntries.length}`}
                </button>
              </div>
            </div>
          )}
        </div>
        </div>
        )}
        </>
      )}

      {activeTab === 'report' && (
        <div>
          <div className="card" style={{ marginBottom: 16, display: 'flex', justifyContent: 'space-between', alignItems: 'flex-end', flexWrap: 'wrap', gap: 12 }}>
            <div>
              <label className="flbl">Report date</label>
              <input type="date" className="fi" style={{ maxWidth: 200 }} value={reportDate} onChange={(e) => setReportDate(e.target.value)} />
            </div>
            {report?.closing && (
              <button className="btn btn-primary" onClick={() => openPrintPopup(`/cash-daily-report-print?date=${reportDate}`)}>
                <i className="ti ti-printer"></i> Print Daily Report
              </button>
            )}
          </div>
          {!report?.closing ? (
            <div className="card" style={{ textAlign: 'center', padding: 30, color: 'var(--g400)' }}>No closed day on record for this date.</div>
          ) : (
            <>
              {/* KPI STRIP -- same visual style as the Billing Dashboard's
                  tabs (colored top border, big number). Not click-to-filter
                  here since the report below is one continuous printable
                  document, not swappable panels -- these are a quick-glance
                  summary sitting above the detail. */}
              <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 16, marginBottom: 16 }}>
                <div className="card" style={{ borderTop: '3px solid var(--blue)' }}>
                  <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>Total Collection</div>
                  <div style={{ fontSize: 22, fontWeight: 800, marginTop: 6 }}>{fmt(report.modeSummary.total)}</div>
                  <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 2 }}>Cash + UPI + Other, collected today</div>
                </div>
                <div className="card" style={{ borderTop: '3px solid var(--green)' }}>
                  <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>Total Cash</div>
                  <div style={{ fontSize: 22, fontWeight: 800, marginTop: 6 }}>{fmt(report.modeSummary.byMode['Cash'] || 0)}</div>
                  <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 2 }}>Collected today</div>
                </div>
                <div className="card" style={{ borderTop: '3px solid var(--indigo)' }}>
                  <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>Total UPI</div>
                  <div style={{ fontSize: 22, fontWeight: 800, marginTop: 6 }}>{fmt(report.modeSummary.byMode['UPI'] || 0)}</div>
                  <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 2 }}>Collected today</div>
                </div>
                <div className="card" style={{ borderTop: '3px solid var(--purple)' }}>
                  <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>Total Other</div>
                  <div style={{ fontSize: 22, fontWeight: 800, marginTop: 6 }}>
                    {fmt(Object.entries(report.modeSummary.byMode).filter(([m]) => m !== 'Cash' && m !== 'UPI').reduce((s, [, amt]) => s + amt, 0))}
                  </div>
                  <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 2 }}>Card, Cheque, Bank Transfer</div>
                </div>
              </div>

              <div style={{ background: 'linear-gradient(135deg,#1e1b4b,#1e4e8c)', color: '#fff', borderRadius: 12, padding: '20px 24px', marginBottom: 16 }}>
                <div style={{ fontSize: 18, fontWeight: 700 }}>VEDA EYE HOSPITAL</div>
                <div style={{ fontSize: 12, opacity: .8 }}>Haridwar, Uttarakhand</div>
                <div style={{ fontSize: 13, fontWeight: 700, marginTop: 10, borderTop: '1px solid rgba(255,255,255,.2)', paddingTop: 10 }}>
                  DAILY CASH CLOSING REPORT<br />
                  Date: {report.closing.closing_date}<br />
                  Closed by: {report.closing.profiles?.full_name || '--'} at {new Date(report.closing.closed_at).toLocaleTimeString('en-IN', { timeZone: 'Asia/Kolkata' })}
                </div>
              </div>

              {/* PAYMENT MODE SUMMARY -- straight from Payments, six
                  gross rows (hospital/optical x billed/advance/refund),
                  no netting or attribution logic anywhere in this
                  table. Grand Total is the only derived figure (sum of
                  all six, refund rows subtracted) -- the actual cash
                  movement for the day, and what Day Totals reconciles
                  Income by Category against further down. */}
              <div className="card" style={{ marginBottom: 16, overflowX: 'auto' }}>
                <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-cash-banknote" style={{ color: 'var(--green)' }}></i> Payment Mode Summary</div>
                <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 8 }}>
                  Straight from Payments -- what actually moved today, by mode, before any billing attribution.
                </div>
                {report.modeSummary.total === 0 && Object.keys(report.modeSummary.byMode).length === 0 ? (
                  <div style={{ fontSize: 12, color: 'var(--g400)' }}>No payments recorded today.</div>
                ) : (() => {
                  const modesPresent = MODES.filter((m) => report.modeSummary.byMode[m]);
                  const rows = [
                    { label: 'Payments against Hospital Billed Items', cat: report.hospitalBilledItems },
                    { label: 'Payments Against Billed Optical Items', cat: report.opticalBilledItems },
                    { label: 'Hospital Advances', cat: report.hospitalAdvances },
                    { label: 'Optical Advances', cat: report.opticalAdvances },
                    { label: 'Hospital Refunds', cat: report.hospitalRefunds, negative: true },
                    { label: 'Optical Refunds', cat: report.opticalRefunds, negative: true },
                  ];
                  return (
                    <table className="tbl" style={{ fontSize: 12.5 }}>
                      <thead>
                        <tr>
                          <th style={{ textAlign: 'left' }}>Type</th>
                          {modesPresent.map((m) => <th key={m} style={{ textAlign: 'right' }}>{m}</th>)}
                          <th style={{ textAlign: 'right' }}>Total</th>
                        </tr>
                      </thead>
                      <tbody>
                        {rows.map((r) => (
                          <tr key={r.label}>
                            <td>{r.label}</td>
                            {modesPresent.map((m) => (
                              <td key={m} style={{ textAlign: 'right', color: r.negative && r.cat.byMode[m] ? 'var(--red)' : undefined }}>
                                {r.cat.byMode[m] ? fmt(r.cat.byMode[m]) : '--'}
                              </td>
                            ))}
                            <td style={{ textAlign: 'right', fontWeight: 600, color: r.negative && r.cat.total ? 'var(--red)' : undefined }}>{fmt(r.cat.total)}</td>
                          </tr>
                        ))}
                        <tr>
                          <td style={{ fontWeight: 700 }}>Grand Total</td>
                          {modesPresent.map((m) => <td key={m} style={{ textAlign: 'right', fontWeight: 700 }}>{fmt(report.modeSummary.byMode[m] || 0)}</td>)}
                          <td style={{ textAlign: 'right', fontWeight: 800, color: 'var(--green)' }}>{fmt(report.modeSummary.total)}</td>
                        </tr>
                      </tbody>
                    </table>
                  );
                })()}
              </div>

              {/* TABLE 2: BILLED INCOME BY CATEGORY -- for account-book
                  entry: billed value plus exactly how it was settled,
                  split by Cash/UPI. Net Cash/UPI are each net of
                  today's refunds against TODAY's own invoices only --
                  a refund against an earlier invoice is out of scope
                  here entirely, since that invoice was never part of
                  this table's Billed figure. Each row self-checks:
                  Billed == Net Cash + Net UPI + Settled via Advance +
                  Credit Notes + Outstanding. Advances are category-
                  agnostic (deposited before being tied to any bill),
                  so they're the summary row at the bottom instead of a
                  column on every category. */}
              <div className="card" style={{ marginBottom: 16, overflowX: 'auto' }}>
                <div className="card-title" style={{ marginBottom: 4 }}>Billed Income by Category</div>
                <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 10 }}>
                  Full invoiced/sale value, by category, and exactly how it was settled -- for account-book entry.
                </div>
                {(() => {
                  const c = report.billedCategories;
                  const rows = [
                    { label: 'OPD Consultation charges', row: c['OPD Consultation charges'] },
                    { label: 'Procedure charges', row: c['Procedure charges'] },
                    { label: 'Investigation charges', row: c['Investigation charges'] },
                    { label: 'Pharmacy', row: c.Pharmacy },
                    { label: 'Surgery Income', row: c['Surgery Income'] },
                    { label: 'Optical Shop Sales', row: c['Optical Shop Sales'] },
                  ];
                  if (c.Unclassified.billed !== 0) rows.push({ label: 'Unclassified -- needs review', row: c.Unclassified, flag: true });
                  const total = rows.reduce((acc, r) => ({
                    billed: acc.billed + r.row.billed, netCash: acc.netCash + r.row.netCash, netUPI: acc.netUPI + r.row.netUPI,
                    advanceSettled: acc.advanceSettled + r.row.advanceSettled, creditNoteSettled: acc.creditNoteSettled + r.row.creditNoteSettled, outstanding: acc.outstanding + r.row.outstanding,
                  }), { billed: 0, netCash: 0, netUPI: 0, advanceSettled: 0, creditNoteSettled: 0, outstanding: 0 });
                  return (
                    <table className="tbl" style={{ fontSize: 12.5 }}>
                      <thead>
                        <tr>
                          <th style={{ textAlign: 'left' }}>Category</th>
                          <th style={{ textAlign: 'right' }}>Billed</th>
                          <th style={{ textAlign: 'right' }}>Net Cash Collected</th>
                          <th style={{ textAlign: 'right' }}>Net UPI Collected</th>
                          <th style={{ textAlign: 'right' }}>Settled via Advance</th>
                          <th style={{ textAlign: 'right' }}>Credit Notes</th>
                          <th style={{ textAlign: 'right' }}>Outstanding</th>
                        </tr>
                      </thead>
                      <tbody>
                        {rows.map((r) => (
                          <tr key={r.label}>
                            <td style={r.flag ? { color: 'var(--red)' } : undefined}>{r.flag && <i className="ti ti-alert-triangle"></i>} {r.label}</td>
                            <td style={{ textAlign: 'right', fontWeight: 600 }}>{fmt(r.row.billed)}</td>
                            <td style={{ textAlign: 'right' }}>{fmt(r.row.netCash)}</td>
                            <td style={{ textAlign: 'right' }}>{fmt(r.row.netUPI)}</td>
                            <td style={{ textAlign: 'right', color: r.row.advanceSettled ? 'var(--purple)' : undefined }}>{fmt(r.row.advanceSettled)}</td>
                            <td style={{ textAlign: 'right', color: r.row.creditNoteSettled ? 'var(--red)' : undefined }}>{fmt(r.row.creditNoteSettled)}</td>
                            <td style={{ textAlign: 'right', color: r.row.outstanding ? 'var(--amber)' : undefined }}>{fmt(r.row.outstanding)}</td>
                          </tr>
                        ))}
                        <tr style={{ background: 'var(--blue-lt, #eff6ff)' }}>
                          <td style={{ fontWeight: 800 }}>Total Billed</td>
                          <td style={{ textAlign: 'right', fontWeight: 800, color: 'var(--blue)' }}>{fmt(total.billed)}</td>
                          <td style={{ textAlign: 'right', fontWeight: 800 }}>{fmt(total.netCash)}</td>
                          <td style={{ textAlign: 'right', fontWeight: 800 }}>{fmt(total.netUPI)}</td>
                          <td style={{ textAlign: 'right', fontWeight: 800 }}>{fmt(total.advanceSettled)}</td>
                          <td style={{ textAlign: 'right', fontWeight: 800 }}>{fmt(total.creditNoteSettled)}</td>
                          <td style={{ textAlign: 'right', fontWeight: 800 }}>{fmt(total.outstanding)}</td>
                        </tr>
                        {(() => {
                          // Advances have no category/dept of their own, so
                          // they're not part of billedCategories above --
                          // these four rows only ever populate Net Cash/Net
                          // UPI. Grand Total's Net Cash/Net UPI reproduces
                          // Payment Mode Summary's Grand Total exactly (see
                          // getDailyReport) -- a live cross-check between
                          // Table 1 and Table 2.
                          const advanceRows = [
                            { label: 'Net Hospital Advance Collected', row: report.netHospitalAdvanceCollected, color: 'var(--purple)' },
                            { label: 'Net Optical Advance Collected', row: report.netOpticalAdvanceCollected, color: 'var(--purple)' },
                            { label: 'Previous Hospital Advance Refund', row: report.previousHospitalAdvanceRefund, color: 'var(--red)' },
                            { label: 'Previous Optical Advance Returned', row: report.previousOpticalAdvanceReturned, color: 'var(--red)' },
                          ];
                          const grandTotal = {
                            billed: total.billed,
                            netCash: total.netCash + advanceRows.reduce((s, r) => s + r.row.netCash, 0),
                            netUPI: total.netUPI + advanceRows.reduce((s, r) => s + r.row.netUPI, 0),
                            advanceSettled: total.advanceSettled, creditNoteSettled: total.creditNoteSettled, outstanding: total.outstanding,
                          };
                          return (
                            <>
                              {advanceRows.map((r, i) => (
                                <tr key={r.label}>
                                  <td style={{ fontWeight: 600, ...(i === 0 ? { paddingTop: 10, borderTop: '1.5px solid var(--g200)' } : {}) }}>{r.label}</td>
                                  <td style={i === 0 ? { borderTop: '1.5px solid var(--g200)' } : undefined}></td>
                                  <td style={{ textAlign: 'right', color: r.color, ...(i === 0 ? { borderTop: '1.5px solid var(--g200)' } : {}) }}>{fmt(r.row.netCash)}</td>
                                  <td style={{ textAlign: 'right', color: r.color, ...(i === 0 ? { borderTop: '1.5px solid var(--g200)' } : {}) }}>{fmt(r.row.netUPI)}</td>
                                  <td style={i === 0 ? { borderTop: '1.5px solid var(--g200)' } : undefined}></td>
                                  <td style={i === 0 ? { borderTop: '1.5px solid var(--g200)' } : undefined}></td>
                                  <td style={i === 0 ? { borderTop: '1.5px solid var(--g200)' } : undefined}></td>
                                </tr>
                              ))}
                              <tr>
                                <td style={{ fontWeight: 700, paddingTop: 10, borderTop: '1.5px solid var(--g200)' }}>Grand Total</td>
                                <td style={{ borderTop: '1.5px solid var(--g200)' }}></td>
                                <td style={{ textAlign: 'right', fontWeight: 800, color: 'var(--green)', paddingTop: 10, borderTop: '1.5px solid var(--g200)' }}>{fmt(grandTotal.netCash)}</td>
                                <td style={{ textAlign: 'right', fontWeight: 800, color: 'var(--green)', paddingTop: 10, borderTop: '1.5px solid var(--g200)' }}>{fmt(grandTotal.netUPI)}</td>
                                <td style={{ borderTop: '1.5px solid var(--g200)' }}></td>
                                <td style={{ borderTop: '1.5px solid var(--g200)' }}></td>
                                <td style={{ borderTop: '1.5px solid var(--g200)' }}></td>
                              </tr>
                            </>
                          );
                        })()}
                      </tbody>
                    </table>
                  );
                })()}
                {report.billedCategories.Unclassified.billed !== 0 && report.unclassifiedDepts.length > 0 && (
                  <div style={{ fontSize: 11, color: 'var(--red)', marginTop: 8 }}>
                    <i className="ti ti-alert-triangle"></i> Service dept{report.unclassifiedDepts.length > 1 ? 's' : ''} not mapped to a category: <strong>{report.unclassifiedDepts.join(', ')}</strong>. Check Financial Masters for a missing/unexpected department, or an invoice with no line items on file.
                  </div>
                )}
              </div>

              {report.expenses.length > 0 && (
                <div className="card" style={{ marginTop: 16 }}>
                  <div className="card-title" style={{ marginBottom: 10 }}>Cash Expenses</div>
                  <table className="tbl">
                    <thead><tr><th>Category</th><th>Remarks</th><th>Entered By</th><th style={{ textAlign: 'right' }}>Amount</th></tr></thead>
                    <tbody>
                      {report.expenses.map((exp) => (
                        <tr key={exp.id}>
                          <td>{exp.master_expense_categories?.name}</td>
                          <td>{exp.paid_to || '--'}</td>
                          <td>{exp.profiles?.full_name || 'Staff'}</td>
                          <td style={{ textAlign: 'right', fontWeight: 600 }}>{fmt(exp.amount)}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}

              {/* CASH COUNTER -- same source as the live Step 2 tab, so
                  a closed day's figures here match exactly what was
                  confirmed that day. Cash Collected is gross (Table
                  1's Cash column, before expenses); Cash Retained is
                  the closing/retained count from Step 2 (cash_counter.
                  closing_cash); Cash Handed Over is the confirmed
                  figure once Step 2 is done for this date, or
                  "Pending" if it hasn't been confirmed yet. */}
              <div className="card" style={{ marginTop: 16 }}>
                <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-wallet" style={{ color: 'var(--blue)' }}></i> Cash Counter</div>
                <table className="tbl" style={{ fontSize: 13 }}>
                  <tbody>
                    <tr>
                      <td>Opening Cash</td>
                      <td style={{ textAlign: 'right', fontWeight: 600 }}>{fmt(report.cashCounter.openingCash)}</td>
                    </tr>
                    <tr>
                      <td>Cash Collected</td>
                      <td style={{ textAlign: 'right', fontWeight: 600, color: 'var(--green)' }}>{fmt(report.cashCounter.cashCollected)}</td>
                    </tr>
                    <tr>
                      <td>Cash Expenses</td>
                      <td style={{ textAlign: 'right', fontWeight: 600, color: 'var(--red)' }}>{fmt(report.cashCounter.cashExpenses)}</td>
                    </tr>
                    <tr>
                      <td>Cash Retained</td>
                      <td style={{ textAlign: 'right', fontWeight: 600, color: 'var(--purple)' }}>
                        {report.cashCounter.closingCash != null ? fmt(report.cashCounter.closingCash) : <span style={{ color: 'var(--g400)', fontWeight: 600 }}>Pending</span>}
                      </td>
                    </tr>
                    <tr style={{ background: 'var(--blue-lt, #eff6ff)' }}>
                      <td style={{ fontWeight: 800 }}>Cash Handed Over</td>
                      <td style={{ textAlign: 'right', fontWeight: 800, color: 'var(--blue)' }}>
                        {report.cashCounter.amountHandedOver != null ? fmt(report.cashCounter.amountHandedOver) : <span style={{ color: 'var(--g400)', fontWeight: 600 }}>Pending</span>}
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </>
          )}
        </div>
      )}

      {activeTab === 'history' && (
        <div className="card">
          <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-history" style={{ color: 'var(--g400)' }}></i> Closing History</div>
          <table className="tbl">
            <thead><tr><th>Date</th><th>Closed By</th><th>Revenue</th><th>Collected</th><th>Outstanding</th><th></th></tr></thead>
            <tbody>
              {history.map((h) => (
                <tr key={h.id}>
                  <td style={{ fontFamily: 'monospace' }}>{h.closing_date}</td>
                  <td>{h.profiles?.full_name || '--'}</td>
                  <td>{fmt(h.total_revenue)}</td>
                  <td>{fmt(h.total_collected)}</td>
                  <td>{fmt(h.total_outstanding)}</td>
                  <td>
                    {reopenTarget === h.closing_date ? (
                      <div style={{ display: 'flex', gap: 4 }}>
                        <input className="fi fi-sm" placeholder="Reason" value={reopenReason} onChange={(e) => setReopenReason(e.target.value)} style={{ width: 140 }} />
                        <button className="btn btn-sm btn-danger" onClick={handleReopen}>Confirm</button>
                        <button className="btn btn-sm" onClick={() => setReopenTarget(null)}>Cancel</button>
                      </div>
                    ) : (
                      <button className="btn btn-sm" onClick={() => { setReopenTarget(h.closing_date); setReopenReason(''); }}>
                        <i className="ti ti-lock-open"></i> Reopen
                      </button>
                    )}
                  </td>
                </tr>
              ))}
              {history.length === 0 && (
                <tr><td colSpan={6} style={{ padding: 20, textAlign: 'center', color: 'var(--g400)' }}>No closed days yet.</td></tr>
              )}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
