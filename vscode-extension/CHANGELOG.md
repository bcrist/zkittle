# Change Log

## [v0.0.8]
- Renamed `#` pseudo-field to `@count`
- Added [Fragment](https://htmx.org/essays/template-fragments/) support - allows referencing a subsection of a template as a separately invokable template

## [v0.0.7]
- Intern long literal strings by line to reduce the size of literal data

## [v0.0.6]
- Reference expressions can now be parenthesized to change order of operations of `/`, `|`, and `.` operators

## [v0.0.5]
- Added `/` ("alternative") operator

## [v0.0.4]
- Added `@url` directive to enable escaping some variables using an alternative algorithm
- Fixes for zig 0.13.0

## [v0.0.3]
- Added `@exists` pseudo-field
- Added `|` ("fallback") operator

## [v0.0.2]
- Allow sharing template literal data between mutliple templates
- Misc Fixes

## [v0.0.1]
- Initial Release
