# Title
ACBP: A SQL-Native Categorical-Boolean Paradigm for Deterministic, Sub-Second Clinical Dashboards

## Authors
Muteb Hail S. Al Anazi (DotK), Riyadh, Saudi Arabia

## Background
Operational dashboards in hospitals need determinism, auditability, and fast refresh under governance constraints. Ad-hoc logic scattered across BI tools and services makes results hard to verify and keep consistent at scale.

## Objective
Introduce ACBP (Al Anazi Categorical-Boolean Paradigm): a SQL-native method to encode decision rules as a categorical-boolean equation, compile them to database artifacts (views/materialized views), and verify soundness/coverage as part of CI.

## Methods
ACBP defines flags \(F∈{0,1}^B\), categories \(c∈C\), and rules \(R\); validity is \(ACBP(F,c)=\bigwedge_{r∈R}r(F,c)\). The compiler emits:
- `*_decision_space(_mat)` enumerating \(D\),
- `*_valid_masks(_mat)=π_F(D)` enforcing **strict** \(M=π_F(D)\),
- a verifier (SQL) for soundness/coverage/duplicates.
A lightweight Streamlit app tracks P50/P95 latency and daily SLO via Wilson lower bounds.

## Results
On synthetic but structured clinic and inpatient models:
Clinic P50 818 ms, P95 937 ms (n=1,680). Inpatient P50 614 ms, P95 750 ms (n=1,680). Daily SLO: clinic ≥95% of loads under 920 ms across days; inpatient ~83–91% under 700 ms (lower 95% CL). Theorems verified in-DB (0 violations).

## Discussion
ACBP centralizes rules, proves equivalence \(D_{sql}=D\) (soundness/completeness), and makes valid-mask enumeration a projection \(M=π_F(D)\). Deterministic SQL artifacts simplify governance and incident forensics compared to opaque BI stacks.

## Conclusion
ACBP yields fast, deterministic dashboards with verifiable logic. We release the equation, verifier SQL, seeds, and a demo app to support replication and operational adoption.

**Keywords:** clinical operations, dashboards, SQL, determinism, latency SLO, governance
