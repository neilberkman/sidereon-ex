See `AGENTS.md` in the project root for architecture and conventions.

## Key Rules

1. **No FMA except in mat3_vec3_mul** — normal Rust arithmetic does not fuse. Only the final matrix-vector multiply uses `f64::mul_add()`. This is required for 0 ULP Skyfield parity.

2. **Test with `mix test --include skyfield_parity`** after any change to the coordinate pipeline.

3. **Elixir formatting**: uses Quokka plugin. Run `mix format`.
