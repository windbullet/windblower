# Third-party notices

PureTone original application code: GPL-3.0-only. Full license: LICENSE and App/Resources/Licenses/GPL-3.0.txt.

| Component | Source | License/use |
|---|---|---|
| libFLAC 1.5.0 | https://github.com/xiph/flac | Library: BSD-style Xiph license; only the library is linked |
| libmpg123 | https://github.com/madebr/mpg123 | LGPL-2.1; pinned source commit in build script; rebuild/relink sources included by reference |
| libsoxr 0.1.3 | https://github.com/chirlu/soxr | LGPL-2.1; source-built, no proprietary binary dependency |
| FlyingFox 0.27.1 | https://github.com/swhitty/FlyingFox | MIT |
| AMSMB2 4.0.3 / libsmb2 | https://github.com/amosavian/AMSMB2 | LGPL-2.1 package (individual wrapper files retain MIT notices); dynamically linked Swift package |
| Yams 5.1.3 / libyaml | https://github.com/jpsim/Yams | MIT |
| LDDC format/API reference | https://github.com/chenmozhijin/LDDC | GPL-3.0-only; Copyright (C) 2024–2025 沉默の金 <cmzj@cmzj.org>; QRC cipher tables/nonstandard key setup and format handling adapted with attribution |

mpg123 notice: This software uses code of mpg123, copyright by the mpg123 project and its contributors, free software under the GNU Lesser General Public License version 2.1.

The build script copies native dependency license files into Vendor/<platform>/licenses. The app build copies them into its bundled Licenses folder. Swift package license texts remain in the upstream repositories and are included in the bundled notice collection by the build script. No user music or online lyrics are bundled with this project.

DSP formulas are independently implemented from the RBJ Audio EQ Cookbook (https://www.w3.org/TR/audio-eq-cookbook/) and the trapezoidal state-variable filter derivations by Andrew Simper / Julius O. Smith III. No proprietary plugin code is included.
