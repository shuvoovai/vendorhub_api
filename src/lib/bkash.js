// bKash payments: placeholder until the bKash Tokenized Checkout gateway is connected.
// Today a BKASH order is placed with paymentStatus PENDING and a Payment row
// (provider "bkash", PENDING); an admin marks it PAID or REFUNDED through
// PATCH /api/v1/admin/orders/:orderId. Vendors may confirm BKASH orders without waiting.
//
// When the gateway arrives, implement these and call them from checkout / a callback route:
//   createPayment(order)     -> { paymentId, bkashURL }   (grant token, create payment)
//   executePayment(paymentId) -> { trxID, status }        (after the customer returns)
//   refundPayment(payment, amount)                        (on cancellation)
// Store trxID in Payment.providerRef and the raw response in Payment.rawPayload.

const notConnected = () => {
  throw new Error('The bKash gateway is not connected yet');
};

export const BKASH_PROVIDER = 'bkash';
export const isGatewayConnected = () => false;
export const createPayment = notConnected;
export const executePayment = notConnected;
export const refundPayment = notConnected;
