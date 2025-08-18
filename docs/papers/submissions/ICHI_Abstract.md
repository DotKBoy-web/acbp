# Title
The ACBP Equation: Compiling Categorical-Boolean Clinical Policies to Verifiable SQL with Sub-Second Dashboards

## Authors
Muteb Hail S. Al Anazi (DotK)

## Motivation and Significance
Healthcare analytics frequently mixes business rules across disparate tools, hindering provenance and reproducibility. We propose ACBP, a compact formalism and compiler that makes rule logic first-class in the database.

## Methods
Define \(F,c,R\) and \(ACBP(F,c)\) as conjunction of deterministic predicates. Emit SQL validators and decision-space enumerations; enforce \(M=π_F(D)\). Provide theorem checks as SQL, and a small UI that tracks P50/P95 and SLO using Wilson intervals. No ML is on the critical path (policy first); ML can feed flags non-critically.

## Results
Clinic model: P50 ~818 ms, P95 ~937 ms (n=1,680). Inpatient: P50 ~614 ms, P95 ~750 ms (n=1,680). Daily clinic SLO ≥95% under 920 ms. Inpatient 83–91% under 700 ms (95% lower bounds). Verifier reports 0 violations for soundness/coverage/duplicates.

## Impact
ACBP offers (i) deterministic dashboards with formal guarantees; (ii) SQL artifacts amenable to governance; (iii) an evaluation harness with reproducible seeds. For health systems, this reduces time-to-trust for operational analytics.

## Availability
Repository, site, and Zenodo snapshots included. Demo requires PostgreSQL 16+, Python, and Streamlit.

**Keywords:** healthcare informatics, DSL, SQL compilation, decision rules, performance SLO, reproducibility
