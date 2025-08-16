---
layout: default
title: ACBP — Schemas & Examples
---

# ACBP — Schemas & Examples

## Schemas
- **v0:** [schema/v0/acbp.schema.json]({{ site.baseurl }}/schema/v0/acbp.schema.json)
- **v1:** [schema/v1/acbp.schema.json]({{ site.baseurl }}/schema/v1/acbp.schema.json)

## Example Models
- Clinic (v0): [models/clinic_visit.v0.json]({{ site.baseurl }}/models/clinic_visit.v0.json)
- Inpatient (v0): [models/inpatient_admission.v0.json]({{ site.baseurl }}/models/inpatient_admission.v0.json)

## Docs
- DSL spec: [ACBP-DSL]({{ site.baseurl }}/ACBP-DSL)

## VS Code JSON schema hint
Add to `.vscode/settings.json`:
```json
{
  "json.schemas": [
    {
      "fileMatch": ["*.v0.json","clinic_visit.json","inpatient_admission.json"],
      "url": "https://dotkboy-web.github.io/acbp/schema/v0/acbp.schema.json"
    },
    {
      "fileMatch": ["*.v1.json"],
      "url": "https://dotkboy-web.github.io/acbp/schema/v1/acbp.schema.json"
    }
  ]
}
```
