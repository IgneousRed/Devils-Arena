# Historical persistence fixtures

`reload-v1.json` and `reload-v2.json` are literal examples of the historical JSON
formats. Keep their field names, enum values and dimensions frozen. They are
decoded directly in the migration tests, rather than generated from current Odin
type definitions, so a historical-shape change cannot silently change test input.
