import { Money } from "../money";

/** The share of a monthly price that a part of the cycle pays. */
export function prorate(monthlyPrice: Money, days: number, cycleDays: number): Money {
  return monthlyPrice * (days / 30);
}
