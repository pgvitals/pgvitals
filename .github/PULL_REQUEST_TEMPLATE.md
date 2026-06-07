## Summary

<!-- What does this PR add or fix? One paragraph. -->

## Checklist

- [ ] New section file follows the `sql/NN_description.sql` naming convention
- [ ] Section header includes `What`, `Look for`, and `Action` lines
- [ ] Query tested against PostgreSQL (version: ___)
- [ ] `master.sql` updated with the new section
- [ ] `docs/SECTIONS.md` updated with a new row
- [ ] No `INSERT`, `UPDATE`, `DELETE`, or DDL in `sql/` files
- [ ] `LIMIT` clause included on potentially large result sets
- [ ] `nullif(x, 0)` used in division to avoid divide-by-zero

## PostgreSQL versions tested

<!-- e.g. 14.9, 15.4, 16.1 -->

## Notes for reviewers

<!-- Anything the reviewer should know: edge cases, assumptions, known limitations -->
