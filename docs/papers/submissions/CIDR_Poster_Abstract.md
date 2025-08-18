# Title
From Equation to MatView: ACBP Compiles Categorical-Boolean Policies into Verifiable Decision Spaces with Sub-Second Joins

## Authors
Muteb Hail S. Al Anazi (DotK)

## Abstract (≈250 words)
We present ACBP, a minimal categorical-boolean equation and compiler that turns policy predicates into native database artifacts with formal guarantees. Let flags \(F∈{0,1}^B\), categories \(c∈C\), and rule set \(R\). Validity is computed as \(ACBP(F,c)=\bigwedge_{r∈R} r(F,c)\). The compiler emits validators plus two canonical relations: the decision space \(D\) and its projection \(M=π_F(D)\). We prove \(D_{sql}=D\) (soundness/completeness) and enforce \(M\) as a projection rather than a bit-only heuristic. Theorems compile down to SQL checks (soundness, coverage, duplicate keys), making correctness verifiable using only the database.

On structured clinic and inpatient models, a small Streamlit front-end drives joins against materialized decision spaces. Under synthetic but repeatable load, we observe clinic P50 818 ms and P95 937 ms (n=1,680), and inpatient P50 614 ms and P95 750 ms (n=1,680). Daily SLO tracking (Wilson 95% lower bounds) shows the clinic model ≥95% of loads under 920 ms, and inpatient ~83–91% under 700 ms. These latencies reflect the advantages of pushing logic to SQL with stable indices and projecting valid masks from \(D\).

Contributions: (1) a compact policy calculus with a SQL compilation path; (2) strict \(M=π_F(D)\) to avoid category-impossible masks; (3) theorem verification implemented in SQL; (4) an SLO harness for latency distributions; and (5) an artifact set (code + Zenodo) enabling replication. We argue that making policy logic relational—and provable—simplifies governance and yields “logic at the speed of thought” for operational analytics.

**Keywords:** data systems, relational compilation, materialized views, verification, performance SLO
