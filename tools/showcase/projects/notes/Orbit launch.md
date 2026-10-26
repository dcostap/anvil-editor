# Orbit 2.4 launch

Ship the proration preview to every paid plan before the **March billing run**. Pricing rules live in [[Pricing]], and the maths is in [[Proration#Daily rate]].

> [!warning] Freeze on Friday
> No schema changes after the freeze. Hotfixes need two reviews.

## Checklist

- [x] Split previews at plan changes
- [x] Round once, on the total
- [ ] Load test with 50k invoices
- [ ] Update the help centre

## Rollout

| Stage   | Customers | Date   | Owner |
| ------- | --------: | ------ | ----- |
| Canary  |        2% | Mar 3  | Ana   |
| Beta    |       25% | Mar 10 | Kenji |
| General |      100% | Mar 17 | Ana   |

## Daily rate

```ts
const share = (plan.monthlyPrice * days) / cycleDays;
```

An upgrade on day 12 of a 30-day cycle pays 19 days of the new plan.[^1]

[^1]: The change day belongs to the new plan.
