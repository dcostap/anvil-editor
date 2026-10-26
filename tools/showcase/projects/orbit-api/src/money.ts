export type Money = number;

export function roundToCent(amount: Money): Money {
  return Math.round(amount * 100) / 100;
}
