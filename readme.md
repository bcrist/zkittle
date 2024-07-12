# Zkittle

A basic templating language for Zig programs.

The name is pronounced like "skittle," not "zee kittle".

## Syntax

    A template always starts with "literal" text.
    i.e. text that will just be included in the final document verbatim.

    You can add data to your templates by surrounding a \\command block// with double slashes.
    
    Whitespace inside command blocks is ignored, and it's legal to have an empty \\// command block.

    \\ $ If a command block contains a $, then //
    everything else in that command block is considered a comment.
    
    \\$ If there is no // to close a block on the same line, it ends at the end of the line.
    \\$ The final newline character is not included in the output document in this case.
    \\$ Since comments end at the end of their containing command block, they are also at most one line.

    Templates are evaluated using a "data context", which is usually a struct value.
    The \\identifiers// in the command block reference fields of the data struct.
    You can reference nested data structures the same way you would in Zig: \\ parent_field.child_field //

    Individual elements of "collections" (arrays and slices) are accessed with '.': \\ some_array.0 //
    Optionals are treated as a collection of size 0 or 1.
    The length of a collection can be printed with: \\ some_array.# //
    Accessing an out-of-bounds element is allowed; it becomes a void value (printing it is a no-op).

    Tagged union fields can be accessed the same way as structs, but only the active field will resolve
    to actual data; inactive fields will resolve to void.

    Values of type void are considered a special 'nil' value.  This includes accessing a struct field
    that doesn't exist, an enum or union tag that isn't active (or doesn't exist), or a collection index
    that's out of bounds, as well as data explicitly declared to have a type of `void` or
    `@TypeOf(undefined)`.  All values have a \\value.@exists// pseudo-field which converts the value to
    a bool, where nil becomes false, and anything else becomes true.

    The special \\*// syntax represents the whole data context (similar to the "this" or "self" pointer in
    some programming languages).  It can be useful when the current data context is not a struct, union,
    or collection.

    Identifiers that aren't qualified by '^' can reference a field in the current context, or the first
    parent context that has a non-nil value for the field.  This is useful because sometimes a template
    is designed to be imported, but you don't know if it will be inside a "within" expression.  You can
    explicitly search only the current context by using \\*.field// instead of \\field//.

    You can "push" a new data context with the ':' operator (a.k.a "within").
    This can be useful if you want to access multiple fields of a deeply nested struct.
    For example, instead of:
        First Name: \\phonebook.z.ziggleman.0.first//
        Last Name: \\phonebook.z.ziggleman.0.last//
        Phone Number: \\phonebook.z.ziggleman.0.phone//
    we could instead write:
    \\ phonebook.z.ziggleman.0:
        First Name: \\first//
        Last Name: \\last//
        Phone Number: \\phone//
    \\ ~
    Note that the sequence does not end at the end of the command block, so that it can include
    literal text easily.  Instead, the ~ character ends the region.

    When the data selected by a "within" expression is a collection, the sequence will be evaluated once
    for each item in the collection.  You can print the current index with the \\@index// syntax.  When
    not inside a "within" region, nothing will be output.  You can access the entire collection
    instead of an individual item with \\ ^* //.  You can access the "outer" data context with \\ ^^* //.
    (note this also works when the within expression isn't a collection)
    If you have nested "within" expressions, the '^' prefixes can be chained as needed.

    The conditional '?' operator only evaluates its subsequent region when its data value is "truthy,"
    but it does not push a new data context:
    \\ should_render_section? // whatever \\ ~
    Boolean false, the number zero, and empty collections (including void-like values) are considered
    falsey; all other values are truthy.

    Both ':' and '?' regions may contain a ';' before the '~' to create an "otherwise" region.
    This region will only be evaluated if the first region is not evaluated. e.g.
    \\ has_full_name ? full_name ; first_name last_name ~ //

    \\x / y// is mostly equivalent to \\x? x ; y ~// except that the former can be used as an
    expression, while the latter always just prints x or y.  Similarly \\x | y// is corresponds to
    \\x.@exists? x ; y ~// in the same way.

    By default all strings will be printed with an HTML escape function.
    This can be overridden or disabled in code when generating other types of documents.
    You can also disable it for a specific expression with \\ @raw some_value //.
    An alternative escaping function can be used for specific expressions with \\ @url some_value //.
    By default, this will escape using percent encoding; suitable for embedding arbitrary data in URLs.

    The \\ @include "path/to/template" // syntax can be used to pull the entire content of another
    template into the current one.
    Note that this happens at compile time, not at runtime (the template source is provided to the
    template parser by a callback).

    The \\ @resource "whatever" // syntax works similarly to @include, but instead of interpreting
    the data returned by the callback as template source,
    it treats it as a raw literal to be printed.

    Sometimes you may want to render only a part of a template in some cases.  To facilitate this,
    you can define a \\ #fragment_name // to refer to part of the template, ending with the \\~//
    operator.  This doesn't affect how the overall template is rendered, but allows you to access
    the sub-template by name from code.  See https://htmx.org/essays/template-fragments/ for more
    information about how this technique might be useful.
