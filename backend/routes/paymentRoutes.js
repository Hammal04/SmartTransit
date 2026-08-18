/**
 * routes/paymentRoutes.js  (cash-only)
 *
 * GET /api/payments/summary   → Admin KPI
 * GET /api/payments/my        → Passenger history
 * GET /api/payments           → Admin all transactions
 * GET /api/payments/:bookingId → Admin | Passenger (row-filtered)
 */

import { Router }            from 'express';
import { PaymentController } from '../controllers/PaymentController.js';

export function makePaymentRouter(authenticateToken, requireRole) {
  const router = Router();

  router.get('/summary',      authenticateToken, requireRole('Admin'),     PaymentController.getSummary);
  router.get('/my',           authenticateToken, requireRole('Passenger'), PaymentController.getMy);
  router.get('/',             authenticateToken, requireRole('Admin'),     PaymentController.getAll);
  router.get('/:bookingId',   authenticateToken,                           PaymentController.getByBookingId);

  return router;
}
