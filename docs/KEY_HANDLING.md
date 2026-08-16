# Why RustyJson keeps decoded keys as strings

Most applications do not need to configure JSON key handling. `RustyJson.decode/1`
returns object keys as strings, which works for requests, webhooks, third-party
APIs, and any payload that may gain new fields.

RustyJson makes one deliberate departure from Jason: it leaves out
`keys: :atoms` and the lowercase `a` sigil modifier. Both create new atoms from
JSON keys. RustyJson still supports `keys: :atoms!` and uppercase `A`, which only
use atoms already loaded in the VM.

## Why RustyJson made this choice

Atoms are global to the BEAM and are not garbage collected. The atom table also
has a fixed limit. When a decoder calls `String.to_atom/1` on each object key,
whoever supplies the JSON gets to add permanent atoms to your VM.

This is unsafe for HTTP requests and other external data. An API may add fields
without warning. An attacker can also send a stream of unique keys. Those atoms
remain after each request finishes, and exhausting the atom table terminates the
VM.

RustyJson has no named mode or global setting that turns arbitrary JSON keys into
atoms. A custom decoding function can still make that choice, but the call site
has to say so.

## What this means for your code

If you already call `RustyJson.decode(json)` without a `:keys` option, nothing
changes. Match the fields you need as strings:

```elixir
with {:ok, %{"id" => id, "name" => name}} <- RustyJson.decode(json) do
  %{id: id, name: name}
end
```

Map patterns ignore fields that you do not name. If the provider adds another
field, this code continues to work.

Use `keys: :atoms!` only when your application controls the schema, every key
atom already exists, and an unexpected field should fail the decode. It converts
every key recursively. If a service adds `"plan"` and `:plan` has not been loaded,
the whole decode raises even if your code never reads that field.

`keys: :atoms!` prevents atom creation, but it is not a key allowlist. It accepts
any matching atom already loaded elsewhere in the VM. If you need an exact set of
keys, pass a decoding function:

```elixir
known_keys = %{"id" => :id, "name" => :name}
RustyJson.decode!(json, keys: &Map.fetch!(known_keys, &1))
```

The function runs on every object key recursively. `Map.fetch!/2` raises as soon
as the payload contains a key outside the mapping.

## Moving from dynamic atom keys

If you used `keys: :atoms` with Jason or RustyJson 0.3, the usual fix is to remove
the option and update map access or patterns to use strings. Convert the validated
fields into a struct or atom-key map after decoding if the rest of your code
expects atoms.

For a closed, application-owned schema, change `keys: :atoms` to `keys: :atoms!`
and make sure every expected atom is declared in application code. For sigils,
remove lowercase `a` to keep string keys or use uppercase `A` for existing atoms.

A custom decoding function can still call `String.to_atom/1`. That restores
dynamic atom creation, so keep the choice local to trusted, bounded input.
