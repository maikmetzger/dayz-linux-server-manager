#!/usr/bin/env python3
"""Row output for bash consumers.

bash's `read` treats consecutive whitespace delimiters as one, so a
tab-separated row with an empty field (a lobby player without GUID, a file
without linked name) shifts every following field into the wrong variable.
Rows meant for bash therefore use the ASCII unit separator (0x1F), which is
not whitespace, and bash reads them with IFS=$'\\x1f'.
"""
FIELD_SEP = '\x1f'


def field(value) -> str:
    """One field: separators and line breaks inside a value must not break the row."""
    return (str(value).replace(FIELD_SEP, ' ').replace('\t', ' ')
            .replace('\r', ' ').replace('\n', ' '))


def join_row(values) -> str:
    """One output line for a sequence of values."""
    return FIELD_SEP.join(field(v) for v in values)
