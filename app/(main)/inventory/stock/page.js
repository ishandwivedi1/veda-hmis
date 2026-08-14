'use client';

import { useState, useEffect, useCallback } from 'react';
import InventoryTabs from '../inventory-tabs';
import {
  getInventoryDashboard, getUntrackedDrugs, createInventoryItem, updateInventoryItem,
  getItemMovements, writeOffLot,
} from '../actions';

const STATUS_BADGE = { OK: 'b-green', Low: 'b-amber', Out: 'b-red' };

function Modal({ onClose, width = 420, children }) {
  return (
    <div style={{ position: 'fixed', inset: 0, background: 'rgba(0,0,0,.4)', display: 'flex', alignItems: 'center', justifyContent: 'center', zIndex: 200 }} onClick={onClose}>
      <div className="card" style={{ width, marginBottom: 0, maxHeight: '85vh', overflowY: 'auto' }} onClick={(e) => e.stopPropagation()}>
        {children}
      </div>
    </div>
  );
}

export default function InventoryStockPage() {
  const [rows, setRows] = useState([]);
  const [loading, setLoading] = useState(true);

  const [showAddItem, setShowAddItem] = useState(false);
  const [untrackedDrugs, setUntrackedDrugs] = useState([]);
  const [addDrugId, setAddDrugId] = useState('');
  const [addUnit, setAddUnit] = useState('Strip');
  const [addReorder, setAddReorder] = useState('10');

  const [editItem, setEditItem] = useState(null);
  const [editUnit, setEditUnit] = useState('');
  const [editReorder, setEditReorder] = useState('');

  const [historyItem, setHistoryItem] = useState(null);
  const [movements, setMovements] = useState([]);

  const [error, setError] = useState('');
  const [saving, setSaving] = useState(false);

  const refresh = useCallback(async () => {
    const data = await getInventoryDashboard();
    setRows(data.rows);
    setLoading(false);
  }, []);

  useEffect(() => { refresh(); }, [refresh]);

  async function openAddItem() {
    setError('');
    const drugs = await getUntrackedDrugs();
    setUntrackedDrugs(drugs);
    setAddDrugId(drugs[0]?.id || '');
    setShowAddItem(true);
  }

  async function handleAddItem() {
    if (!addDrugId) return;
    setSaving(true);
    const res = await createInventoryItem(addDrugId, addUnit, addReorder);
    setSaving(false);
    if (res.error) { setError(res.error); return; }
    setShowAddItem(false);
    refresh();
  }

  function openEditItem(row) {
    setError('');
    setEditItem(row);
    setEditUnit(row.unit);
    setEditReorder(String(row.reorderLevel));
  }

  async function handleEditItem() {
    setSaving(true);
    const res = await updateInventoryItem(editItem.itemId, editUnit, editReorder);
    setSaving(false);
    if (res.error) { setError(res.error); return; }
    setEditItem(null);
    refresh();
  }

  async function openHistory(row) {
    setHistoryItem(row);
    const m = await getItemMovements(row.itemId);
    setMovements(m);
  }

  async function handleWriteOff(lotId, type) {
    const notes = window.prompt(`Reason for ${type.toLowerCase()}?`) || '';
    const res = await writeOffLot(lotId, type, notes);
    if (res.error) { alert(res.error); return; }
    refresh();
    if (historyItem) openHistory(historyItem);
  }

  return (
    <div>
      <InventoryTabs />

      <div className="card">
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 10 }}>
          <div className="card-title"><i className="ti ti-boxes" style={{ color: 'var(--blue)' }}></i> Pharmacy Stock</div>
          <button className="btn btn-primary" onClick={openAddItem}><i className="ti ti-plus"></i> Track New Drug</button>
        </div>

        {loading ? (
          <div style={{ padding: 20, textAlign: 'center', color: 'var(--g400)' }}>Loading...</div>
        ) : (
          <table className="tbl">
            <thead><tr><th>Drug</th><th>Form</th><th>Unit</th><th>On Hand</th><th>Reorder At</th><th>Nearest Expiry</th><th>Status</th><th></th></tr></thead>
            <tbody>
              {rows.map((r) => (
                <tr key={r.itemId}>
                  <td>
                    <div style={{ fontWeight: 600 }}>{r.name}</div>
                    <div style={{ fontSize: 10, color: 'var(--g500)' }}>{r.generic}</div>
                  </td>
                  <td>{r.form || '--'}</td>
                  <td>{r.unit}</td>
                  <td style={{ fontWeight: 700, color: r.stockStatus === 'Out' ? 'var(--red)' : r.stockStatus === 'Low' ? 'var(--amber)' : 'inherit' }}>{r.onHand}</td>
                  <td>{r.reorderLevel}</td>
                  <td style={{ color: r.expiringSoon ? 'var(--red)' : 'inherit', fontSize: 11 }}>
                    {r.nearestExpiry ? new Date(r.nearestExpiry).toLocaleDateString('en-IN') : '--'}
                    {r.expiringSoon && <span style={{ marginLeft: 4 }}>⚠</span>}
                  </td>
                  <td><span className={`badge ${STATUS_BADGE[r.stockStatus]}`}>{r.stockStatus}</span></td>
                  <td style={{ display: 'flex', gap: 6 }}>
                    <button className="btn btn-sm" onClick={() => openEditItem(r)}>Edit</button>
                    <button className="btn btn-sm" onClick={() => openHistory(r)}>History</button>
                  </td>
                </tr>
              ))}
              {rows.length === 0 && (
                <tr><td colSpan={8} style={{ padding: 20, textAlign: 'center', color: 'var(--g400)' }}>
                  No drugs are being stock-tracked yet. Click &quot;Track New Drug&quot; to start.
                </td></tr>
              )}
            </tbody>
          </table>
        )}
      </div>

      {showAddItem && (
        <Modal onClose={() => setShowAddItem(false)} width={400}>
          <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-plus"></i> Track New Drug</div>
          {error && <div className="msg-err" style={{ fontSize: 12 }}>{error}</div>}
          <div style={{ marginBottom: 8 }}>
            <label className="flbl">Drug</label>
            <select className="fi" value={addDrugId} onChange={(e) => setAddDrugId(e.target.value)}>
              {untrackedDrugs.length === 0 && <option value="">-- All drugs already tracked --</option>}
              {untrackedDrugs.map((d) => (
                <option key={d.id} value={d.id}>{d.brand || d.generic} {d.strength} ({d.generic})</option>
              ))}
            </select>
          </div>
          <div style={{ display: 'flex', gap: 8, marginBottom: 12 }}>
            <div style={{ flex: 1 }}>
              <label className="flbl">Stocking unit</label>
              <select className="fi" value={addUnit} onChange={(e) => setAddUnit(e.target.value)}>
                <option>Strip</option><option>Bottle</option><option>Vial</option><option>Box</option><option>Tube</option><option>Unit</option>
              </select>
            </div>
            <div style={{ flex: 1 }}>
              <label className="flbl">Reorder level</label>
              <input className="fi" type="number" min="0" value={addReorder} onChange={(e) => setAddReorder(e.target.value)} />
            </div>
          </div>
          <div style={{ display: 'flex', gap: 8, justifyContent: 'flex-end' }}>
            <button className="btn" onClick={() => setShowAddItem(false)}>Cancel</button>
            <button className="btn btn-primary" onClick={handleAddItem} disabled={saving || !addDrugId}>{saving ? 'Saving...' : 'Start Tracking'}</button>
          </div>
        </Modal>
      )}

      {editItem && (
        <Modal onClose={() => setEditItem(null)} width={380}>
          <div className="card-title" style={{ marginBottom: 4 }}><i className="ti ti-edit"></i> Edit Item</div>
          <div style={{ fontSize: 12, color: 'var(--g500)', marginBottom: 10 }}>{editItem.name}</div>
          {error && <div className="msg-err" style={{ fontSize: 12 }}>{error}</div>}
          <div style={{ display: 'flex', gap: 8, marginBottom: 14 }}>
            <div style={{ flex: 1 }}>
              <label className="flbl">Stocking unit</label>
              <select className="fi" value={editUnit} onChange={(e) => setEditUnit(e.target.value)}>
                <option>Strip</option><option>Bottle</option><option>Vial</option><option>Box</option><option>Tube</option><option>Unit</option>
              </select>
            </div>
            <div style={{ flex: 1 }}>
              <label className="flbl">Reorder level</label>
              <input className="fi" type="number" min="0" value={editReorder} onChange={(e) => setEditReorder(e.target.value)} />
            </div>
          </div>
          <div style={{ display: 'flex', gap: 8, justifyContent: 'flex-end' }}>
            <button className="btn" onClick={() => setEditItem(null)}>Cancel</button>
            <button className="btn btn-primary" onClick={handleEditItem} disabled={saving}>{saving ? 'Saving...' : 'Save Changes'}</button>
          </div>
        </Modal>
      )}

      {historyItem && (
        <Modal onClose={() => setHistoryItem(null)} width={520}>
          <div className="card-title" style={{ marginBottom: 4 }}><i className="ti ti-history"></i> Movement History</div>
          <div style={{ fontSize: 12, color: 'var(--g500)', marginBottom: 10 }}>{historyItem.name}</div>
          <table className="tbl" style={{ fontSize: 11 }}>
            <thead><tr><th>Date</th><th>Type</th><th>Qty</th><th>Batch</th><th>By</th></tr></thead>
            <tbody>
              {movements.map((m) => (
                <tr key={m.id}>
                  <td>{new Date(m.created_at).toLocaleDateString('en-IN')}</td>
                  <td>{m.movement_type}{m.notes && <div style={{ fontSize: 9, color: 'var(--red)' }}>{m.notes}</div>}</td>
                  <td style={{ color: Number(m.qty_change) < 0 ? 'var(--red)' : 'var(--green)', fontWeight: 600 }}>{Number(m.qty_change) > 0 ? '+' : ''}{m.qty_change}</td>
                  <td>{m.inventory_lots?.batch_number || '--'}</td>
                  <td>{m.profiles?.full_name || '--'}</td>
                </tr>
              ))}
              {movements.length === 0 && (
                <tr><td colSpan={5} style={{ padding: 16, textAlign: 'center', color: 'var(--g400)' }}>No movements yet.</td></tr>
              )}
            </tbody>
          </table>
          <div style={{ marginTop: 12, textAlign: 'right' }}>
            <button className="btn" onClick={() => setHistoryItem(null)}>Close</button>
          </div>
        </Modal>
      )}
    </div>
  );
}
