# Third-Party Notices

sidereon is licensed under the MIT License (see LICENSE). It contains, ports,
or reimplements algorithms from the following third-party sources. All are
permissive licenses; their required attributions are reproduced below. No
copyleft (GPL/LGPL/AGPL/MPL/EUPL/CDDL) code or dependencies are included.

--------------------------------------------------------------------------------
## RTKLIB (BSD 2-Clause)

The integer least-squares (MLAMBDA/LAMBDA) routine is a Rust port of RTKLIB's
`lambda.c`.

  Copyright (c) 2007-2020, T. Takasu, All rights reserved.

  Redistribution and use in source and binary forms, with or without
  modification, are permitted provided that the following conditions are met:

  1. Redistributions of source code must retain the above copyright notice,
     this list of conditions and the following disclaimer.
  2. Redistributions in binary form must reproduce the above copyright notice,
     this list of conditions and the following disclaimer in the documentation
     and/or other materials provided with the distribution.

  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
  AND ANY EXPRESS OR IMPLIED WARRANTIES ARE DISCLAIMED. IN NO EVENT SHALL THE
  COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
  INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES ARISING IN ANY WAY
  OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH
  DAMAGE.

--------------------------------------------------------------------------------
## ERFA (BSD 3-Clause)

Nutation/precession coefficient tables and conventions are derived from ERFA
(Essential Routines for Fundamental Astronomy), itself derived from IAU SOFA.
The complete BSD 3-Clause license, including ERFA's SOFA-heritage terms, is
distributed as `LICENSES/ERFA-BSD-3-Clause.txt`, copied byte-for-byte from the
official [ERFA 2.0.1 license](https://raw.githubusercontent.com/liberfa/erfa/v2.0.1/LICENSE)
(accessed 2026-07-20).

--------------------------------------------------------------------------------
## SciPy (BSD 3-Clause)

The trust-region least-squares solver (`trust-region-least-squares`)
reimplements algorithms equivalent to SciPy's least-squares routines. The
complete BSD 3-Clause license is distributed as
`LICENSES/SciPy-BSD-3-Clause.txt`, copied byte-for-byte from the official
[SciPy 1.18.0 license](https://raw.githubusercontent.com/scipy/scipy/v1.18.0/LICENSE.txt)
(accessed 2026-07-20).

--------------------------------------------------------------------------------
## newtua-lzw-z (MIT OR Apache-2.0)

The bounded historical Unix `compress` (`.Z`) decoder is derived from the
`newtua-lzw-z` 0.1.0 decoder core, modified to stop before an output-byte limit
would be exceeded.

This derived code is used under the MIT license option:

  MIT License

  Copyright (c) 2026 Aleksei Trankov

  Permission is hereby granted, free of charge, to any person obtaining a copy
  of this software and associated documentation files (the "Software"), to deal
  in the Software without restriction, including without limitation the rights
  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
  copies of the Software, and to permit persons to whom the Software is
  furnished to do so, subject to the following conditions:

  The above copyright notice and this permission notice shall be included in all
  copies or substantial portions of the Software.

  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
  SOFTWARE.

--------------------------------------------------------------------------------
## Compiled Rust dependencies (Apache-2.0 and ISC)

The source-build and precompiled NIF distributions include the following
locked Rust dependencies:

- approx 0.5.1 — Apache-2.0; Copyright 2015 Brendan Zabarauskas.
- nalgebra 0.33.3 — Apache-2.0; Copyright 2020 Sébastien Crozet.
- nalgebra-macros 0.2.2 — Apache-2.0; authors Andreas Longva and Sébastien
  Crozet.
- simba 0.9.1 — Apache-2.0; author Sébastien Crozet.
- libloading 0.8.9 and 0.9.0 — ISC; Copyright © 2015 Simonas Kazlauskas.

The full Apache License 2.0 is distributed as `LICENSES/Apache-2.0.txt`. The
complete libloading ISC copyright and permission notice is distributed as
`LICENSES/ISC-libloading.txt`.

--------------------------------------------------------------------------------
## IERS Conventions Software

The solid-earth / ocean / pole tide displacement follows the IERS Conventions
reference routines (e.g. DEHANTTIDEINEL), used under the IERS Conventions
Software License. This is Sidereon-derived Rust code, not software distributed
or endorsed by the IERS Conventions Center. The routines were renamed, and the
source describes how the derived implementation differs from the original.

The full official notice is reproduced in
`LICENSES/IERS-Conventions-Software-License.txt` from the official
[`DEHANTTIDEINEL.F`](https://iers-conventions.obspm.fr/content/chapter7/software/dehanttideinel/DEHANTTIDEINEL.F)
source (accessed 2026-07-20). The exact public non-test tide sources from
[sidereon-core 0.33.1](https://github.com/neilberkman/sidereon/tree/v0.33.1/crates/sidereon-core/src/tides)
are distributed under `third_party_source/sidereon-core-0.33.1/tides/`.
Published results obtained with these routines should acknowledge use of the
IERS Conventions software.

--------------------------------------------------------------------------------
## Reference algorithms (no code copied)

The following informed reimplementations from public specifications/literature;
no source code was copied:

- SGP4 / SDP4: D. Vallado et al., "Revisiting Spacetrack Report #3" (AIAA), and
  the CelesTrak reference vectors (validation only).
- Frame/time-scale conventions cross-checked against Skyfield (MIT) and the IAU
  conventions.
- Galileo NeQuick-G: reimplemented from the Galileo OS SIS ICD "Ionospheric
  Correction Algorithm for Galileo Single Frequency Users"; MODIP and CCIR data
  tables transcribed as ITU-R / EU-JRC reference data (facts).
- NRLMSISE-00: U.S. Naval Research Laboratory (public domain).
