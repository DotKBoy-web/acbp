# SPDX-License-Identifier: LicenseRef-DotK-Proprietary-NC-1.0
# Copyright (c) 2025 DotK (Muteb Hail S Al Anazi)
#!/usr/bin/env python3
import argparse, csv, random, math, os
from typing import Dict, List, Tuple

# ---------- Flags & categories (must stay consistent with your JSONs) ----------
CLINIC_FLAGS = ["booked", "checked_in", "seen_by_doctor", "canceled", "rescheduled"]
CLINIC_CATS = {
    "appt_type":   ["NewPatient", "FollowUp", "Urgent", "Procedure", "Teleconsult"],
    "site":        ["Main", "Annex", "Downtown"],
    "age_group":   ["Peds", "Adult", "Geriatric"],
    "department":  ["General", "Cardiology", "Orthopedics", "Imaging", "Pediatrics"],
    "provider_role": ["Attending", "Resident", "NP/PA"],
    "modality":    ["InPerson", "Virtual"],
    "visit_hour":  ["08:00", "09:00", "10:00", "11:00", "14:00"],
    "weekday":     ["Mon", "Tue", "Wed", "Thu", "Fri"],
    "insurance":   ["SelfPay", "Private", "Government"]
}

INPATIENT_FLAGS = ["booked", "checked_in", "in_icu", "discharged", "expired", "transferred"]
INPATIENT_CATS = {
    "admission_type": ["Elective", "Emergency", "Transfer", "Maternity"],
    "site":           ["Main", "Annex", "Downtown"],
    "age_group":      ["Peds", "Adult", "Geriatric"],
    "ward":           ["Med", "Surg", "ICU", "PICU", "Onc"],
    "payer":          ["SelfPay", "Private", "Government"],
    "arrival_source": ["ER", "Clinic", "OtherHospital"],
    "admit_hour":     ["06:00", "09:00", "12:00", "18:00"],
    "weekday":        ["Mon", "Tue", "Wed", "Thu", "Fri"]
}

# ---------- Demographics catalogs ----------
DEM_SEX      = (["M", "F", "Other"], [0.49, 0.49, 0.02])
DEM_LANGUAGE = (["EN", "AR"], [0.7, 0.3])
DEM_CITY     = (["Riyadh", "Jeddah", "Dammam", "Mecca", "Medina"], [0.32, 0.28, 0.18, 0.12, 0.10])

# ---------- helpers ----------
def pack_mask(bits: Dict[str, int], flags: List[str]) -> int:
    m = 0
    for i, f in enumerate(flags):
        if bits.get(f, 0):
            m |= (1 << i)
    return m

def wpick(rng: random.Random, options: List[str], weights: List[float]) -> str:
    return rng.choices(options, weights=weights, k=1)[0]

# ---------- CLINIC sampling ----------
def sample_clinic_row(rng: random.Random) -> Dict[str, str]:
    w_age = {"Peds": 0.2, "Adult": 0.6, "Geriatric": 0.2}
    w_site = {"Main": 0.55, "Annex": 0.25, "Downtown": 0.20}
    w_dept = {"General": 0.35, "Cardiology": 0.13, "Orthopedics": 0.14, "Imaging": 0.18, "Pediatrics": 0.20}
    w_role = {"Attending": 0.5, "Resident": 0.25, "NP/PA": 0.25}
    w_mod  = {"InPerson": 0.8, "Virtual": 0.2}
    w_type = {"NewPatient": 0.24, "FollowUp": 0.35, "Urgent": 0.18, "Procedure": 0.13, "Teleconsult": 0.10}
    w_hour = {"08:00": 0.18, "09:00": 0.22, "10:00": 0.22, "11:00": 0.20, "14:00": 0.18}
    w_day  = {"Mon": 0.2, "Tue": 0.2, "Wed": 0.2, "Thu": 0.2, "Fri": 0.2}
    w_ins  = {"SelfPay": 0.12, "Private": 0.63, "Government": 0.25}

    def w(d): return rng.choices(list(d.keys()), weights=list(d.values()), k=1)[0]

    row = {
        "appt_type": w(w_type), "site": w(w_site), "age_group": w(w_age),
        "department": w(w_dept), "provider_role": w(w_role), "modality": w(w_mod),
        "visit_hour": w(w_hour), "weekday": w(w_day), "insurance": w(w_ins),
    }


    if row["appt_type"] == "Teleconsult":
        row["modality"] = "Virtual"
    if row["modality"] == "Virtual" and row["appt_type"] not in ("FollowUp", "Teleconsult"):
        row["appt_type"] = rng.choice(["FollowUp", "Teleconsult"])
    if row["modality"] == "Virtual" and row["department"] in ("Imaging", "Orthopedics"):
        row["modality"] = "InPerson"
    if row["department"] == "Pediatrics":
        row["age_group"] = "Peds"
    if row["site"] == "Annex" and row["department"] == "Cardiology":
        row["department"] = rng.choice(["General", "Orthopedics", "Imaging", "Pediatrics"])


    stage = rng.choices(["canceled", "rescheduled", "booked_only", "checked_in", "seen"],
                        weights=[0.10, 0.12, 0.18, 0.25, 0.35], k=1)[0]
    bits = {f: 0 for f in CLINIC_FLAGS}
    if stage == "canceled":
        bits["canceled"] = 1; bits["booked"] = 1
    elif stage == "rescheduled":
        bits["rescheduled"] = 1; bits["booked"] = 1
    elif stage == "booked_only":
        bits["booked"] = 1
    elif stage == "checked_in":
        bits["checked_in"] = 1; bits["booked"] = 1
    else:
        bits["seen_by_doctor"] = 1; bits["checked_in"] = 1; bits["booked"] = 1
        if rng.random() < 0.6:
            row["visit_hour"] = rng.choice(["09:00", "10:00"])


    if rng.random() < 0.06:
        if rng.random() < 0.5:
            bits["checked_in"] = 1; bits["booked"] = 0
        else:
            bits["seen_by_doctor"] = 1; bits["checked_in"] = 0; bits["booked"] = rng.choice([0,1])

    row["mask"] = str(pack_mask(bits, CLINIC_FLAGS))
    return row

# ---------- INPATIENT sampling ----------
def sample_inpatient_row(rng: random.Random) -> Dict[str, str]:
    # catalogs aligned with the JSON model
    w_adm = {"Elective": 0.45, "Emergency": 0.25, "Transfer": 0.30}
    w_site = {"Main": 0.65, "Annex": 0.35}
    w_age  = {"Adult": 0.75, "Peds": 0.25}
    w_ward = {"Medical": 0.40, "Surgical": 0.28, "ICU": 0.20, "StepDown": 0.12}
    w_pay  = {"SelfPay": 0.10, "Private": 0.55, "Public": 0.35}
    w_src  = {"ED": 0.55, "Clinic": 0.25, "Transfer": 0.10, "Direct": 0.10}
    w_hr   = {"00:00": 0.12, "04:00": 0.10, "08:00": 0.24, "12:00": 0.24, "16:00": 0.18, "20:00": 0.12}
    w_day  = {"Mon": 1/7, "Tue": 1/7, "Wed": 1/7, "Thu": 1/7, "Fri": 1/7, "Sat": 1/7, "Sun": 1/7}

    def w(d): return rng.choices(list(d.keys()), weights=list(d.values()), k=1)[0]

    row = {
        "admission_type": w(w_adm),
        "site":           w(w_site),
        "age_group":      w(w_age),
        "ward":           w(w_ward),
        "payer":          w(w_pay),
        "arrival_source": w(w_src),
        "admit_hour":     w(w_hr),
        "weekday":        w(w_day),
    }

    # stages; include an "unbooked" case so Emergency can be valid without booked/checked_in
    stage = rng.choices(
        ["unbooked", "booked_only", "checked_in", "icu", "discharged", "expired", "transferred"],
        weights=[0.08,        0.14,          0.32,   0.12,      0.22,     0.04,        0.08],
        k=1
    )[0]

    bits = {f: 0 for f in INPATIENT_FLAGS}

    if stage == "unbooked":
        pass  # mask stays 0 (valid)
    elif stage == "booked_only":
        bits["booked"] = 1
    elif stage == "checked_in":
        bits["booked"] = 1; bits["checked_in"] = 1
    elif stage == "icu":
        bits["booked"] = 1; bits["checked_in"] = 1; bits["in_icu"] = 1
        row["ward"] = "ICU"  # keep ICU ward with ICU flag
    elif stage == "discharged":
        bits["booked"] = 1; bits["checked_in"] = 1; bits["discharged"] = 1
    elif stage == "expired":
        bits["booked"] = 1; bits["checked_in"] = 1; bits["expired"] = 1
    else:  # transferred
        bits["booked"] = 1; bits["checked_in"] = 1; bits["transferred"] = 1
        row["arrival_source"] = "Transfer"

    # Enforce the model rule: FORBID_WHEN(booked when admission_type='Emergency').
    # If we accidentally set booked/checked_in for Emergency, mostly flip the category to keep rows valid.
    if row["admission_type"] == "Emergency" and (bits["booked"] or bits["checked_in"]):
        if rng.random() < 0.85:
            row["admission_type"] = rng.choice(["Elective", "Transfer"])
        else:
            # keep Emergency but make it valid by clearing flags (unbooked)
            bits = {f: 0 for f in INPATIENT_FLAGS}

    # small fraction of deliberately inconsistent cases to exercise validators
    if rng.random() < 0.05:
        bad = rng.choice(["icu_wrong_ward", "discharged_without_checked_in", "discharged_with_transfer_source"])
        if bad == "icu_wrong_ward":
            bits["booked"] = 1; bits["checked_in"] = 1; bits["in_icu"] = 1
            row["ward"] = rng.choice(["Medical", "Surgical", "StepDown"])  # violates FORBID_WHEN(in_icu,...)
        elif bad == "discharged_without_checked_in":
            bits["discharged"] = 1; bits["checked_in"] = 0; bits["booked"] = rng.choice([0, 1])  # violates IMPLIES
        else:  # discharged_with_transfer_source
            bits["booked"] = 1; bits["checked_in"] = 1; bits["discharged"] = 1
            row["arrival_source"] = "Transfer"  # violates FORBID_WHEN(discharged when arrival_source='Transfer')

    row["mask"] = str(pack_mask(bits, INPATIENT_FLAGS))
    return row

# ---------- emitters ----------
def write_csv(path: str, rows: List[Dict[str, str]], header: List[str]) -> None:
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=header)
        w.writeheader()
        w.writerows([{k: r.get(k, "") for k in header} for r in rows])

def generate(model: str, n_rows: int, seed: int, out_prefix: str) -> Tuple[str, str]:
    rng = random.Random(seed)

    if model == "clinic_visit":
        cat_header = list(CLINIC_CATS.keys())
        sampler = lambda: sample_clinic_row(rng)
        flags = CLINIC_FLAGS
    elif model == "inpatient_admission":
        cat_header = list(INPATIENT_CATS.keys())
        sampler = lambda: sample_inpatient_row(rng)
        flags = INPATIENT_FLAGS
    else:
        raise SystemExit(f"Unknown model: {model}")

    header = ["mask", "patient_mrn", "sex", "language", "city"] + cat_header
    rows: List[Dict[str, str]] = []
    for i in range(n_rows):
        r = sampler()

        r["patient_mrn"] = f"MRN{seed:03d}{i:09d}"
        r["sex"]         = wpick(rng, *DEM_SEX)
        r["language"]    = wpick(rng, *DEM_LANGUAGE)
        r["city"]        = wpick(rng, *DEM_CITY)
        rows.append(r)

    p1 = out_prefix + "_part1.csv"
    p2 = out_prefix + "_part2.csv"
    mid = n_rows // 2
    write_csv(p1, rows[:mid], header)
    write_csv(p2, rows[mid:], header)
    return p1, p2

# ---------- CLI ----------
def main():
    ap = argparse.ArgumentParser(description="ACBP synthetic dataset generator (+demographics)")
    ap.add_argument("model", choices=["clinic_visit", "inpatient_admission"])
    ap.add_argument("--rows", type=int, default=40000)
    ap.add_argument("--seed", type=int, default=42)
    args = ap.parse_args()

    prefix = "clinic_visit_data" if args.model == "clinic_visit" else "inpatient_admission_data"
    p1, p2 = generate(args.model, args.rows, args.seed, prefix)
    print(f"Created: {p1}\n         {p2}")

if __name__ == "__main__":
    main()
