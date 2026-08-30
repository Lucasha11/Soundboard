# Rule Exceptions

Time-boxed deviations from a MUST in `DATA_GOVERNANCE.md`. See DG-EX-01 through DG-EX-04.

Claude may draft an entry. Claude must never fill the approval line (`DG-EX-02`).
An expired exception fails the build (`DG-EX-03`).

## Active

_None._

## Template

```
### EX-001
Rule:                  DG-XXX-NN
Scope:                 <exact files, services, or surfaces>
Justification:         <business reason>
Compensating control:  <what reduces the risk meanwhile>
Expires:               YYYY-MM-DD   (max 90 days from approval)
Approved by:           <governance owner - leave empty until signed>
Approved on:           <YYYY-MM-DD>
```
