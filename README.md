# lwk
*(Lua Website Kit)*

An HTML/CSS templating engine/static site generator scriptable in Lua.

# Features
- A clean DSL for HTML/CSS
  - Basic HTML elements, along with templating helpers like conditionals and loops
  - Nested selectors, unit helpers, and unquoted keywords (e.g. `rem(1)`, `flex`)
- Allows reusable components that integrate into the DSL, with custom render logic
  - CSS can be written right next to the definition of a component and the engine
    collects styles into a global stylesheet if you use the `GlobalStyles` helper
- Very extensible with Lua
  - Write arbitrary Lua functions to group and sort pages based on their existing
    metadata, or rewrite or emit entirely new metadata
  - Component and page renders can depend on that metadata
  - Make custom handlers for new input source formats in Lua

<details>
  <summary>(Click to expand) Minimal example</summary>

  This snippet:

  ```lua
  return Document {
      lang = 'en',
      head {
          meta { charset = 'UTF-8' },
          title 'Hello world!',
      },
      body(p 'Hello from Lua!'),
  }
  ```

  renders as (prettified):

  ```html
  <!DOCTYPE html>
  <html lang="en">
      <head>
          <meta charset="UTF-8">
          <title>Hello world!</title>
      </head>
      <body>
          <p>Hello from Lua!</p>
      </body>
  </html>
  ```
</details>

# Quickstart

If you prefer reading code instead of docs,
[my website's code](https://github.com/Apeiros-46B/website)
contains plenty of direct usage examples.

You need Lua (I tested on LuaJIT and Lua 5.4), GNU coreutils, and GNU find.

Include lwk as a submodule in your repo, then make an `init.lua`, which is the
script you will run to build the site. Note that paths are resolved from your
working dir when you run it, not the position of `init.lua` itself.

At the top, require the path module so that subsequent imports work properly.
For example if you put your submodule at `./lib/lwk` relative to the dir in which
you will run init:

```lua
require('lib.lwk.path')('lib/lwk')
```

After that, require the `router` library and call `.process` to set up the build.
Only two args are mandatory, `in_dir` and `out_dir`. For example, to read pages
from `./src/site` and output the built site to `./dist`:

```lua
local router = require('router')

router.process {
    in_dir = './src/site',
    out_dir = './dist',
}
```

Add a page under your `in_dir` (in this case `src/site`), and name the file
`index.html.lua`. You can copy the example here:

<details>
  <summary>(Click to expand) Example page</summary>

  ```lua
  return Document {
      lang = 'en',
      head {
          meta { charset = 'UTF-8' },
          title 'Hello world!',
      },
      body(p 'Hello from Lua!'),
  }
  ```
</details>

How the code in this page is rendered will be explained in the next section.

To build, simply run your `init.lua` with your Lua interpreter of choice. This
will produce `dist/index.html`.

Files ending in `.html.lua` and `.css.lua` are evaluated as Lua and rendered
as plain compact `.html` and `.css` respectively. Other files (except
[`_ctx.lua`](#declaring-metadata)) pass through to the exact same relative path
in `out_dir`.

# Writing HTML

*(Note for this section: Lua lets you omit the parentheses in a function call if
it only has one arg and that arg is a string or table literal, so `p 'Hi'`
is equivalent to `p('Hi')`.)*

A page is just a Lua module that returns a renderable, or a tuple of
(metadata, renderable) (see [the section on metadata](#metadata)). A renderable is
any value that lwk can resolve into output.

Strings and numbers are renderables, rendering as escaped text. Additional types
are explained in the following sections.

> [!NOTE]
> Falsy values (`nil` and `false`) render nothing, but a `nil` hole in an array
> of children will stop traversal due to Lua limitations.

## Renderables: Elements

Pages are evaluated inside a Lua env that injects HTML elements as global variables.
The values of these variables are renderables, which can be called to add attributes
or children. You can use them without any `require` or namespace prefix.

### Attributes and children

Children passed to elements must be renderables.

If an element has no children, you can write it directly as a value (e.g. `br`),
which acts as a renderable.

If an element has one child and no attributes, call it with the child as an arg,
returning a renderable:

```lua
div(p 'Hello world!')
```

If an element has multiple children and/or attributes, call it with a table.
This also returns a renderable:

```lua
ul {
    class = 'my-list',
    aria_label = 'List of things',
    li 'Some list item',
    li 'Foo bar baz quux',
}
```

String-keyed items in the table are treated as attrs and integer-keyed items are
treated as children. Underscores in attr names are translated to hyphens in the
generated HTML.

Attribute values are either primitives or arrays. Arrays are joined into strings
with a different joiner depending on the attribute (`class` uses spaces, `style`
uses semicolons, etc.).

### Utilities

Since `table` is both the name of an HTML element and a Lua stdlib namespace,
the HTML element shadows the library. You can access the library like so:

```lua
-- this brings in Lua's original `table` library
local TABLE = require('table')
local foo = TABLE.concat(...)
```

At the toplevel of your pages, you should use `Document`. It behaves identically to
`html` except also adding a `<!DOCTYPE html>` before the rest of the rendered
content.

Since strings are rendered as escaped HTML, if you need an unescaped raw string
anywhere, use the `Raw` builtin (also helpful with Lua multiline strings):

```lua
Raw [[
    <p>This is some raw HTML that will make it directly to the generated page.</p>
    <p>None of this will be escaped.</p>
]]
```

### Extending via currying

Elements support being called again and again, merging attributes and children,
which lets you make resuable templates like so:

```lua
local my_template = ul { class = 'my-list', li 'ABC' }

-- these two are equivalent:
my_template {
    class = 'other-class',
    li 'foobar',
    li 'XYZ',
}
ul {
    class = 'my-list other-class',
    li 'ABC',
    li 'foobar',
    li 'XYZ',
}
```

`class`, `style`, `accept`, and `srcset` are merged, but other attributes
overwrite instead of merging.

## Renderables: Tables

If you use a nested table as a renderable, it represents multiple items (a fragment),
and its elements act as if they were passed to the parent scope. For example, these
two are equivalent:

```lua
local my_t = { li 'ABC', li 'XYZ' }
ul { class = 'my-list', my_t }
-----
ul { class = 'my-list', li 'ABC', li 'XYZ' }
```

This lets you build lists using arbitrary Lua code.

## Renderables: Render callbacks

A render callback is just a function that takes a single argument `ctx`
(the context, explained in the [metadata section](#metadata)) and returns any
renderable value, including literals, HTML elements, components, or
other render callbacks.

Render callbacks always run after
[component registration](#component-load-order)
and
[metadata transformations](#metadata-transforms).

```lua
div {
    function(ctx)
        -- returned value depends on ctx
        return ul { ... }
    end,
}
```

## Renderables: Control flow

The DSL also provides builtin renderables for control flow templating.
The syntax may look unintuitive, but it's just based on repeated function calls.

### If

```lua
If (condition) (p 'Value if truthy') (p 'Value if falsy')

-- You can also omit the last else branch
If (condition) (p 'Value if truthy')

-- The expression is a call chain, so you can omit parens with table args:
If (condition) {
    p 'Something',
    p 'Condition is truthy',
} {
    p 'Something else',
    p 'Condition is falsy',
}
```

> [!CAUTION]
> `If` branch expressions are evaluated immediately, unlike regular if statements.

If you do some nil check in the condition for example, and then depend on that
value being non-nil in one of the branches, it may fail if you try to index
that value. In this case, either:

- Make the branches lazy
  ```lua
  If (x)
      (function() return p(x.value) end)
      (function() return p 'x is nil' end)
  ```
- Use a regular Lua function
  ```lua
  function()
      if condition then ... else ... end
  end
  ```

Unfortunately both are quite ugly but there's no way to work around this in Lua
without introducing a function wrapper somewhere in the expression.

### For

> [!NOTE]
> `For` is based on `ipairs` and intentionally does not work for string keys due
> to string keys having no defined `pairs` order in Lua.

```lua
For (items) (function(v, k, ctx)
    return ...
end)

-- You can omit the k and ctx args if you don't need them, since Lua is fine
-- with ignoring additional function args. This is also why v comes first instead
-- of k, so you can write a cleaner version like this:
For (items) (function(v) return ... end)
```

## Renderables: Modifiers

A modifier is a renderable that modifies some property of its parent element
instead of producing its own content. Multiple modifiers as children run in
child order. They cannot be used at the document root, because they must
modify their parent.

The parent element is not necessarily the closest parent in the code, because
some types of parents do not create real elements (e.g. `If`). Modifiers instead
target the closest real element. See [this section](#modifier-targeting) for more
details.

### Basic modifiers

There are two basic builtin modifiers:

- `Set(name, value)` replaces an attribute on the parent
- `Append(name, ...)` adds values to an attribute while preserving existing ones

An example of both, used in conjunction with `If`, as part of a navbar link:

```lua
a {
    href = '/about',
    class = 'nav-link',

    If (active_page == 'about') {
        Set('aria-current', 'page'),
        Append('class', 'active'),
    },

    'About',
}
```

In a real implementation, you wouldn't manually type out every `a` like this,
you would use `For` on a list of pages (maybe one generated by a
[metadata transform](#metadata-transforms)) to generate the navbar links.

### Toggling multiple classes

If you find yourself having to toggle a bunch of classes on some element based
on several different conditions, use the builtin `Classes`. It takes a table,
where each pair is a mapping from a literal class name to a boolean or a
function that takes a context and returns a boolean.

```lua
div {
    class = 'my-div',
    Classes {
        active = foo == bar,
        something = function(ctx) return ctx.something end,
    }
}
```

## Components

Add the `components_dir` arg to `router.process` in your `init.lua`. This
essentially just sets up auto-imports for the files based on their name, so
for example if you added a `MyComponent.lua` file inside your components dir,
then in pages you can reference `MyComponent` without any explicit imports.

If you want a component to reference another component, it should work in most
cases, but see [this section](#component-load-order) for more details.

Components can technically return any value (it doesn't even have to be a
renderable), but it's most useful to have them return something that
constructs renderables, for which there are a few major useful patterns:

### Function with custom args

Just return a regular Lua function given any args you want that returns a
renderable. Call the function using your args and use its result as a renderable
in your document tree.

Examples from my website:
- [`Section`](https://github.com/Apeiros-46B/website/blob/8ac54f6d784cb41b6b7266827d1d2ae97b22d6f9/src/components/util/Section.lua)
- [`Date`](https://github.com/Apeiros-46B/website/blob/8ac54f6d784cb41b6b7266827d1d2ae97b22d6f9/src/components/common/Date.lua)

### Realized element

You can return an element that has already been called. These can be directly
inserted into the document tree, or they can continue to be
[extended](#extending-via-currying) at the call site to add more attributes or
children.

Examples from my website:
- [`FlexFill`](https://github.com/Apeiros-46B/website/blob/8ac54f6d784cb41b6b7266827d1d2ae97b22d6f9/src/components/util/FlexFill.lua)
- [`SideNote`](https://github.com/Apeiros-46B/website/blob/8ac54f6d784cb41b6b7266827d1d2ae97b22d6f9/src/components/blog/SideNote.lua)
- [`HorizList`](https://github.com/Apeiros-46B/website/blob/8ac54f6d784cb41b6b7266827d1d2ae97b22d6f9/src/components/util/HorizList.lua)

### Render callback

You can return an aforementioned render callback which takes a `ctx` arg and
returns a renderable. The callback should be directly used as a renderable in
your document tree without calling it explicitly. This is most useful in
conjunction with [metadata transforms](#metadata-transforms).

Examples from my website:
- [`Navbar`](https://github.com/Apeiros-46B/website/blob/8ac54f6d784cb41b6b7266827d1d2ae97b22d6f9/src/components/common/Navbar.lua)
- [`TagPage`](https://github.com/Apeiros-46B/website/blob/8ac54f6d784cb41b6b7266827d1d2ae97b22d6f9/src/components/blog/TagPage.lua)

### Custom component object

When a component needs both caller-supplied props and render-time context, use
`Component.new`, which returns a constructor like the builtin HTML elements.
Calling the constructor creates a renderable.

```lua
return Component.new(name, function(self, parent, args, ctx)
    return renderable
end, lang)
```

- `name` is just a node identifier, make it the same as your file's basename
- `self` is the component instance itself
- `parent` is the node that has this invocation as a child, which may be absent
- `args` is the arguments supplied by the caller, which may be any value. Most
  commonly, you would pass a table which potentially contains string or numeric
  keys
- `ctx` is the [context](#context), the same as a render callback's `ctx` arg
- `lang` is an optional language restriction, usually either `'html'` or `'css'`.
  If you omit it, the component inherits the surrounding language.

This is distinct from just a function that returns a render callback,
since it has other bells and whistles; e.g. repeated calls can be used to
extend props and children, just like [with HTML elements](#extending-via-currying).

> [!WARNING]
> Currently components currying extending children is broken, but props should
> work fine

Examples:
- [`Classes`](https://github.com/Apeiros-46B/lwk/blob/043c3a2cf7329d50d1f041e392b7187cb6cd5fe1/dsl/builtins.lua#L210-L239)
  (lwk builtin, returns a *modifier* renderable so it acts like one too)
- [`ArticleTagList`](https://github.com/Apeiros-46B/website/blob/8ac54f6d784cb41b6b7266827d1d2ae97b22d6f9/src/components/blog/ArticleTagList.lua)
  (from my website)

### Custom modifier

*(Not recommended, prefer composing `Set`, `Append`, and `Classes` instead)*

For completely new modifier logic that can't be expressed in terms of custom
`Component`s that return a builtin modifier object, use `Modifier.new`:

```lua
Modifier.new(name, function(self, parent, ctx, ...)
    -- modify `parent` here
end, lang)
```

The parameters are the same as in `Component.new`, except for `...`, which
can be any set of arguments your modifier accepts, not necessarily a vararg
(only the first three args in the callback (`self, parent, ctx`) are fixed).

The `parent` is the [modifier target](#modifier-targeting).

For HTML element `parent`s, attributes are stored in `parent.props`, so
the following modifications can be made:
- Assign a value to set or replace an attribute
- Assign `nil` to remove an attribute

Use `parent.format_key(your_str)` to apply the element's attr naming convention,
which is replacing underscores with hyphens in both HTML and CSS.

Simple example:

```lua
return Modifier.new('RemoveAttr', function(_, parent, _, name)
    parent.props[parent.format_key(name)] = nil
end, 'html')
```

Examples from lwk:
- [builtin `Set`](https://github.com/Apeiros-46B/lwk/blob/043c3a2cf7329d50d1f041e392b7187cb6cd5fe1/dsl/builtins.lua#L157-L162)
- [builtin `Append`](https://github.com/Apeiros-46B/lwk/blob/043c3a2cf7329d50d1f041e392b7187cb6cd5fe1/dsl/builtins.lua#L165-L200)

# Writing CSS

## Syntax and helpers

The CSS DSL is relatively more abstracted from regular CSS compared to the HTML
DSL. There are a few major toplevel CSS renderables:
- `Vars(selector) { k = v }` defines CSS variables (`--k: v;`)
- `Rule(selector) { ... }` creates CSS rules with props and potentially nesting
- `Query` is a nicer sugar for queries, taking either a table of conditions as shown
  below (which are joined with `and`), or a raw string (e.g.
  `Query '@media' 'screen and (min-width: 40rem)' { ... }`)
- `Import 'url'` produces an `@import` rule

The renderables are available in the same DSL env as HTML, but must be rendered
inside a CSS context. A CSS context can be created in one of three ways:

|Method|Output|
|------|------|
| `GlobalStyles { ... }` in a page or component file | To `/bundle.css` |
| `style { ... }` in HTML | To embedded stylesheet element |
| Array of CSS renderables returned from `name.css.lua` | To separate CSS file |

To link `GlobalStyles`'s bundle, there is a `LinkGlobalStyles` convenience helper
(that creates a `link`), which should be placed in your document's `head`.

```lua
-- could also be a style block, but in most cases this is more useful
GlobalStyles {
    Vars ':root' { accent = '#06c' },

    Rule '.card' {
        background_color = var 'accent',
        padding = { rem(1), rem(2) },
        display = flex,

        -- .card:hover
        Rule '&:hover' { opacity = 0.8 },

        -- .card p
        Rule 'p' { margin = 0 },
    },

    Query '@media' { min_width = rem(40) } {
        Rule '.card' { padding = rem(3) },
    },
}
```

As in the HTML DSL, property and variable names translate underscore into hyphens.

### Rules

You can nest rules as children of another rule. In this case, the selector becomes
a descendant selector. If you use a `&`, you can reference the parent selector
explicitly (for example to add pseudoclasses), similar to SCSS.

> [!WARNING]
> Unlike SCSS, comma-separated parent selectors aren't handled properly. I will
> probably fix this in the future.

### Values

You can pass arrays as property values, which are joined with spaces or commas
depending on the property (e.g. `font_family` and `box_shadow` use commas).

Numbers can be given units with helpers like `rem(1)` and `px(2)`. There is one
the every CSS unit, which are named the same as the real units, except for `%` and
`in` which are `pct` and `inch` instead.

You can also write keywords like `flex` without quotes, even if they share a name
with an HTML element, as long as they don't conflict with other globals. In
the latter case, just use a quoted string.

Other misc value helpers:
- `var 'name'` returns `var(--name)`, translating underscores to hyphens
- `url 'path'` returns a CSS `url(...)` value
- `Quoted 'text'` adds quotes to a value, e.g. for the `content` property
- `InlineSvg 'path'` reads an SVG file into a CSS data URL. Paths are relative to
  the calling file unless they start with a `/`, in which case they're relative to
  `in_dir`

### CSS bundling details

You can use `GlobalStyles(priority, { ... })` to control the order in the bundle.
Lower priorities come first (default `50`) and styles with the same priority stay
in registration order. The priority is global and not just scoped to that specific
component.

Calling `GlobalStyles` at the toplevel of a component file adds its styles once,
even if you never use that component. It's also ok for a component to return
nothing, so you can make a component file that just calls `GlobalStyles` to
register styles and does nothing else.

# Metadata

## Declaring metadata

To attach metadata to a page, return a table before its renderable. Metadata keys
have no special meaning, it's entirely up to your pages, components, and transforms
to determine what they mean.

```lua
return { title = 'Hello', date = '2026-11-07' }, function(ctx)
    return Document {
        head { title(ctx.page.meta.title) },
        body { h1(ctx.page.meta.title) },
    }
end
```

You can put defaults for a directory's pages in a `_ctx.lua` file:

```lua
-- src/site/blog/_ctx.lua
return { blog = true }
```

Page metadata overrides the defaults for the directory. Nested tables are
deep merged for string keys and appended for integer keys.

## Metadata transforms

After discovering pages, lwk calls each function in the `middlewares` list (passed
to `router.process`) in declared order, then renders the pages.

Each function takes (and can modify) the manifest, which contains `pages` and an
initially empty `groups` table. The return values of these functions are ignored,
just modify `manifest` directly.

For example, in `init.lua` you could collect blog posts and sort them newest first:

```lua
local function collect_posts(manifest)
    local posts = {}
    for _, page in ipairs(manifest.pages) do
        if page.meta.blog then
            posts[#posts+1] = page
        end
    end

    -- assumes every post has date in lexicographically comparable format
    table.sort(posts, function(a, b)
        return a.meta.date > b.meta.date
    end)

    manifest.groups.posts = posts
end

router.process {
    in_dir = './src/site',
    out_dir = './dist',
    middlewares = { collect_posts },
}
```

You can then use the list in a page or component's render callback:

```lua
function(ctx)
    return ul {
        For (ctx.manifest.groups.posts) (function(page)
            return li {
                a { href = '/' .. page.dst_rel_path, page.meta.title },
            }
        end),
    }
end
```

By default, output paths just remove the final `.lua` extension, so
`blog/post.html.lua` becomes `blog/post.html`.

You can also change `page.meta`, rewrite `page.dst_rel_path` (to put the
destination HTML at a different place in the `out_dir`), add arbitrary fields
for later transforms to read (e.g. `page.url`), or filter `manifest.pages`
(keep it a contiguous array without nil holes before you return from any
transform).

See my website's code for an example of nav/blog groups, blog tags, next/prev
article links, and a `skip` metadata key removing a page from rendering:
- [The transforms](https://github.com/Apeiros-46B/website/blob/8ac54f6d784cb41b6b7266827d1d2ae97b22d6f9/init.lua)
- [`Article`](https://github.com/Apeiros-46B/website/blob/8ac54f6d784cb41b6b7266827d1d2ae97b22d6f9/src/components/blog/Article.lua)
- [`ArticleTagList`](https://github.com/Apeiros-46B/website/blob/8ac54f6d784cb41b6b7266827d1d2ae97b22d6f9/src/components/blog/ArticleTagList.lua)
- [`Navbar`](https://github.com/Apeiros-46B/website/blob/8ac54f6d784cb41b6b7266827d1d2ae97b22d6f9/src/components/common/Navbar.lua)

## Context

The `ctx` arg passed to render callbacks contains the following, after metadata
transforms have finished:

| Name | What |
| --- | --- |
| `ctx.page.meta` | Current page's merged metadata |
| `ctx.page.filename` | Input filename, e.g. `post.html.lua` |
| `ctx.page.rel_path` | Input path relative to `in_dir` |
| `ctx.page.dst_rel_path` | Output path relative to `out_dir` |
| `ctx.manifest.pages` | Array of discovered pages, potentially filtered by transforms |
| `ctx.manifest.groups` | Collections created by transforms |
| Custom `ctx` keys | Values supplied through `router.process { ctx = ... }` |
| `ctx.state` | Page-local state initialized to an empty table for each new page |

`ctx.page` is inaccessible from any render callbacks inside `GlobalStyles`.

You can pass additional context using the `ctx` arg to `router.process`, e.g.
`ctx = { site_name = 'My site' }` makes `ctx.site_name` available anywhere
you can get a `ctx`.

`ctx.state` and the corresponding `Provide` helper can be used to avoid prop
drilling. Any attrs passed to `Provide` are merged into `ctx.state` for its
children, without changing the outer context:

```lua
Provide {
    section = 'blog',
    -- This render callback can be as deeply nested as you like, inside a component,
    -- inside another render callback, etc. It can go across files too
    function(ctx)
        return p(ctx.state.section)
    end,
}
```

# Gory details

Some potentially non-obvious behaviors are documented here.

## Component load order

All components are registered before pages are evaluated, so pages can use
any components without any dependency concerns.

In component files, component references *inside* render callbacks (including the
callback passed to `Component.new`) are looked up during rendering, after all
components have been registered.

However, references in a component file but outside callbacks (i.e. those that
load immediately when the component file is loaded) resolve if the referenced
component is already registered. Otherwise, a component-like name (uppercase start)
produces a placeholder which **only supports one single-argument deferred call**:

```lua
return div {
    OtherComponent { title = 'Hello' },
}
```

The resulting renderable only calls the "real" component during rendering, so it
lacks some features like multiple arguments and chained calls.

It is recommended to use render callbacks instead of depending on the component
load order.

## Modifier targeting

The parent element is the enclosing element whose children are being resolved,
even through fragments, callbacks, conditionals, and components if they do not
create any elements. Only introducing an element closer in ancestry changes
the target.

In this example:

```lua
div {
    {
        If (active) {
            Append('class', 'active'),
        },
    },
}
```

the `Append` targets the `div`, since the table fragment and the `If` do not
create a real element.

This also applies across component boundaries:

```lua
-- in Useless.lua
return Component.new('Useless', function(_, _, args, _)
    return { p 'Foo', args, p 'Bar' }
end)

div {
    Useless {
        -- modifies the `div`
        Append('class', 'highlight'),
        p 'Hello world!'
    }
}
```

If the component places its children inside another element, then the modifier
will target that element instead:

```lua
-- in SlightlyLessUseless.lua
return Component.new('SlightlyLessUseless', function(_, _, args, _)
    return span { 'Foo', args, 'Bar' }
end)

div {
    SlightlyLessUseless {
        -- modifies the inner `span`
        Append('class', 'highlight'),
        'Hello world!',
    }
}
```

# TODO

Unresolved issues that I haven't gotten around to yet:
- Component currying doesn't extend children
- Fix ctx inheritance requiring a contiguous chain and document it
- Improve custom handlers mechanism and document it
