# Zkittle

A basic templating language for Zig programs.

The name is pronounced like "skittle," not "zee kittle".

## Syntax

    A template always starts with "literal" text.
    i.e. text that will just be included in the final document verbatim.

    You can add data to your templates by surrounding a \\command block// with double slashes.
    
    Whitespace inside command blocks is ignored, and it's legal to have an empty \\// command block.

    \\ $ If a command block contains a $, then everything else in that command block is considered a comment //
    
    \\$ If there is no // to close a command block before the end of the line it is opened on, it ends with the line.
    \\$ The final newline character is not included in the output document in this case.
    \\$ Since comments end at the end of their containing command block, they are also at most one line.

    Templates are evaluated using a "data context", which is usually a struct value.
    The \\identifiers// in the command block reference fields of the data struct.
    You can reference nested data structures the same way you would in Zig: \\ parent_field.child_field //

    Individual elements of "collections" (arrays and slices) are accessed with '.': \\ some_array.0 //
    Optionals are treated as a collection of size 0 or 1.
    Values of type void, null, and undefined are considered collections of size 0.
    The length of a collection can be printed with: \\ some_array.# //
    Accessing an out-of-bounds element is allowed; it becomes a void value (printing it is a no-op).

    Tagged union fields can be accessed the same way as structs, but only the active field will resolve to actual data;
    inactive fields will resolve to void.

    The special \\*// item represents the whole data context.
    It's mostly useful when the data context is not a struct union, or collection.

    You can "push" a new data context with the ':' operator (a.k.a "within").
    This can be useful if you want to access multiple fields of a deeply nested struct.  For example, instead of:
        First Name: \\phonebook.z.ziggleman.0.first//
        Last Name: \\phonebook.z.ziggleman.0.last//
        Phone Number: \\phonebook.z.ziggleman.0.phone//
    we could instead write:
    \\ phonebook.z.ziggleman.0:
        First Name: \\first//
        Last Name: \\last//
        Phone Number: \\phone//
    \\ ~
    Note that the sequence does not end at the end of the command block, so that it can include literal text easily.
    Instead, the ~ character ends the region.

    When the data selected by a "within" expression is a collection, the sequence will be evaluated once for each item in the collection.
    You can access the current index with the \\@index// syntax.  When not inside a "within" region, this will always resolve to 0.
    You can access the entire collection instead of an individual item with \\ ^*
    You can access the "outer" data context with \\ ^^* // (note this also works when the within expression isn't a collection)
    If you have nested "within" expressions, the '^' prefixes can be chained as needed.

    The conditional '?' operator only evaluates its subsequent region when its data value is "truthy," but it does not push a new data context:
    \\ should_render_section? // whatever \\ ~
    Boolean false, the number zero, and empty collections (including void-like values) are considered falsey; all other values are truthy.

    Both "within" and "conditional" regions may contain a ';' before the '~' to create an "otherwise" region.
    This region will only be evaluated if the first region is not evaluated. e.g.
    \\ has_full_name ? full_name ; first_name last_name ~ //

    By default all strings will be printed with an HTML escape function.
    This can be overridden or disabled in code when generating other types of documents.
    You can also disable it for a specific expression with \\ @raw some_value //.
    It's assumed that "true", "false", and numbers (as formatted with std.fmt.format's `{d}` rules) will never need to be escaped.

    The \\ @include "path/to/template" // syntax can be used to pull the entire content of another template into the current one.
    Note that this happens at compile time, not at runtime (the template source is provided to the template parser by a callback).

    The \\ @resource "whatever" // syntax works similarly to @include, but instead of interpreting the data returned by the callback as template source,
    it treats it as a raw literal to be printed.
