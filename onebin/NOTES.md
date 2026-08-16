# onebin — Implementation Notes & Decision Log

## Decisions

- **util/buf (`ob_rdstr`)**: If `dstsz` is too small to hold the full string plus its NUL terminator, `ob_rdstr` fails with `-1` (instead of truncating) and sets `dst[0] = '\0'`.
