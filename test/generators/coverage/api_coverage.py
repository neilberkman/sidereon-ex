#!/usr/bin/env python3
"""Write COVERAGE.md: every public module-level item of sidereon-core and the
sidereon facade, and where this binding's native code uses it.

Usage (from the repository root, with a checkout of the core at the pinned
revision):

    python3 test/generators/coverage/api_coverage.py <core crates dir> <core revision>

An item is public when every module on its path is declared `pub mod`, or when
a public module re-exports it with `pub use`. Module-level items are `pub fn`,
`struct`, `enum`, `trait`, `type`, `const` and `static` declarations at column
0; methods, fields and variants are counted with the item that declares them.
An item is bound when an identifier of that name appears in
native/sidereon_nif/src; the files it appears in are listed. An item that
appears nowhere is MISSING. A name shared by two items counts both as bound,
so the MISSING count is a lower bound.
"""
import collections
import os
import re
import sys

ITEM = re.compile(r'^pub (?:const |async |unsafe )*(fn|struct|enum|trait|type|const|static)\s+([A-Za-z_][A-Za-z0-9_]*)')
MOD = re.compile(r'^\s*(pub(?:\([^)]*\))?\s+)?mod\s+([a-z_0-9]+)\s*([;{])', re.M)


def mod_file(dirpath, name):
    for cand in (os.path.join(dirpath, name + '.rs'), os.path.join(dirpath, name, 'mod.rs')):
        if os.path.exists(cand):
            return cand
    return None


def inventory(crates):
    items = {}
    reexports = []

    def walk(path_file, modpath, public):
        text = open(path_file).read()
        base = os.path.dirname(path_file)
        stem = os.path.splitext(os.path.basename(path_file))[0]
        sub_dir = base if stem in ('mod', 'lib') else os.path.join(base, stem)
        for line in text.splitlines():
            m = ITEM.match(line)
            if m:
                items['::'.join(modpath + [m.group(2)])] = (m.group(1), public)
        for m in MOD.finditer(text):
            vis, name, term = m.group(1), m.group(2), m.group(3)
            line_start = text.rfind('\n', 0, m.start()) + 1
            if name in ('tests', 'test') or '#[cfg(test)]' in text[max(0, line_start - 40):line_start]:
                continue
            if term == ';':
                f = mod_file(sub_dir, name)
                if f:
                    walk(f, modpath + [name], public and bool(vis) and vis.strip() == 'pub')
        if public:
            for m in re.finditer(r'(?m)^pub use\s+([^;]+);', text):
                reexports.append(' '.join(m.group(1).split()))

    for crate in ('sidereon-core', 'sidereon'):
        walk(os.path.join(crates, crate, 'src', 'lib.rs'), [crate.replace('-', '_')], True)

    names = set()
    for use in reexports:
        for leaf in re.split(r'[{},]', use):
            leaf = leaf.strip()
            if not leaf or leaf.endswith('::'):
                continue
            names.add(leaf.split(' as ')[0].strip().split('::')[-1])
    return {p: k for p, (k, public) in items.items() if public or p.split('::')[-1] in names}


def main():
    crates, revision = sys.argv[1], sys.argv[2]
    nif_dir = os.path.join('native', 'sidereon_nif', 'src')
    uses = collections.defaultdict(set)
    for f in sorted(os.listdir(nif_dir)):
        if f.endswith('.rs'):
            for ident in set(re.findall(r'[A-Za-z_][A-Za-z0-9_]*', open(os.path.join(nif_dir, f)).read())):
                uses[ident].add(f)
    items = inventory(crates)
    by_mod = collections.OrderedDict()
    for path in sorted(items):
        by_mod.setdefault('::'.join(path.split('::')[:-1]), []).append(path.split('::')[-1])
    total = len(items)
    missing = sum(1 for p in items if p.split('::')[-1] not in uses)
    out = [
        '# Core API coverage',
        '',
        f'Public module-level items of `sidereon-core` and `sidereon` at core revision `{revision}`,',
        'and the native source files of this binding that use each. Written by',
        '`test/generators/coverage/api_coverage.py`; its docstring states how an item is',
        'found and when it counts as bound.',
        '',
        f'- Items: {total}',
        f'- Bound (used by the native code): {total - missing}',
        f'- MISSING: {missing}',
        '',
    ]
    for mod, names in by_mod.items():
        out.append(f'## `{mod}`')
        out.append('')
        out.append('| Item | Kind | Binding |')
        out.append('|---|---|---|')
        for name in names:
            files = uses.get(name)
            where = ', '.join(f'`{f}`' for f in sorted(files)) if files else 'MISSING'
            out.append(f'| `{name}` | {items[mod + "::" + name]} | {where} |')
        out.append('')
    open('COVERAGE.md', 'w').write('\n'.join(out))
    print(f'{total} items, {missing} missing')


if __name__ == '__main__':
    main()
