import { Money, roundToCent } from "../money";
import { Plan, PlanChange } from "../plans";
import { daysBetween, startOfCycle } from "./calendar";

export interface InvoiceLine {
  description: string;
  amount: Money;
}

export interface InvoicePreview {
  customerId: string;
  periodStart: Date;
  periodEnd: Date;
  lines: InvoiceLine[];
  total: Money;
}

/**
 * Builds the next invoice for a customer. A plan change in the
 * middle of the cycle splits the period, and each part pays its
 * own plan's daily rate.
 */
export function previewInvoice(
  customerId: string,
  plan: Plan,
  changes: PlanChange[],
  today: Date,
): InvoicePreview {
  const periodStart = startOfCycle(plan, today);
  const periodEnd = new Date(periodStart);
  periodEnd.setMonth(periodEnd.getMonth() + 1);

  const cycleDays = daysBetween(periodStart, periodEnd);
  const lines: InvoiceLine[] = [];
  let current = plan;
  let from = periodStart;

  const inCycle = changes.filter(
    (c) => c.at > periodStart && c.at < periodEnd,
  );
  for (const change of inCycle) {
    lines.push(prorated(current, from, change.at, cycleDays));
    current = change.plan;
    from = change.at;
  }
  lines.push(prorated(current, from, periodEnd, cycleDays));

  const sum = lines.reduce((total, line) => total + line.amount, 0);
  const total = roundToCent(sum);
  return { customerId, periodStart, periodEnd, lines, total };
}

function prorated(plan: Plan, from: Date, to: Date, cycleDays: number): InvoiceLine {
  const days = daysBetween(from, to);
  return {
    description: `${plan.name} (${days} of ${cycleDays} days)`,
    amount: (plan.monthlyPrice * days) / cycleDays,
  };
}
