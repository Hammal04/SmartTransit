/**
 * controllers/PaymentController.js
 * Cash-only payment controller.
 * No gateway — booking confirmation = cash payment pending.
 * Driver marks cash as received (future feature hook).
 *
 * GET  /api/payments             Admin — all transactions
 * GET  /api/payments/summary     Admin — KPI stats
 * GET  /api/payments/my          Passenger — own history
 * GET  /api/payments/:bookingId  Admin | Passenger — by booking
 */

import { PaymentModel } from '../models/PaymentModel.js';

function num(v) {
  if (v === null || v === undefined) return 0;
  return typeof v === 'string' ? parseFloat(v) : Number(v);
}

function coercePayment(p) {
  return { ...p, amount: num(p.amount) };
}

export class PaymentController {

  // GET /api/payments/:bookingId
  static async getByBookingId(req, res) {
    const bookingId = parseInt(req.params.bookingId);
    const pool = req.app.locals.pool;
    const conn = await pool.getConnection();
    try {
      const payment = await PaymentModel.findByBookingId(conn, bookingId);
      if (!payment)
        return res.status(404).json({ status: 'error', message: 'No payment for this booking.' });
      if (req.user.role === 'Passenger' && payment.user_id !== req.user.userId)
        return res.status(403).json({ status: 'error', message: 'Access denied.' });
      return res.json(coercePayment(payment));
    } catch (err) {
      console.error(`[Payment][getByBookingId] ${err.message}`);
      return res.status(500).json({ status: 'error', message: err.message });
    } finally { conn.release(); }
  }

  // GET /api/payments  (Admin)
  static async getAll(req, res) {
    const pool = req.app.locals.pool;
    const conn = await pool.getConnection();
    try {
      const rows = await PaymentModel.findAll(conn);
      return res.json(rows.map(coercePayment));
    } catch (err) {
      console.error(`[Payment][getAll] ${err.message}`);
      return res.status(500).json({ status: 'error', message: err.message });
    } finally { conn.release(); }
  }

  // GET /api/payments/summary  (Admin)
  static async getSummary(req, res) {
    const pool = req.app.locals.pool;
    const conn = await pool.getConnection();
    try {
      return res.json(await PaymentModel.summary(conn));
    } catch (err) {
      return res.status(500).json({ status: 'error', message: err.message });
    } finally { conn.release(); }
  }

  // GET /api/payments/my  (Passenger)
  static async getMy(req, res) {
    const pool = req.app.locals.pool;
    const conn = await pool.getConnection();
    try {
      const rows = await PaymentModel.findByUserId(conn, req.user.userId);
      return res.json(rows.map(coercePayment));
    } catch (err) {
      return res.status(500).json({ status: 'error', message: err.message });
    } finally { conn.release(); }
  }
}
