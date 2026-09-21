# Third-party notices

## LeftOpen

MacPilot's **Local Ports** core adapts the listener scanning, process/project
inference, safe SIGTERM close workflow, and icon discovery ideas from
[LeftOpen](https://github.com/SonghaiFan/leftopen), based on commit
`2fde101440583f95c86c7408c63b77d73aaa5ea0`.

The adapted code lives under `Sources/MacPilotLocalPortsCore/` and keeps the
scanner and safety boundary independent of SwiftUI. MacPilot does not include
LeftOpen's application shell, menu-bar UI, branding, configuration, build
scripts, or privileged operations.

LeftOpen is distributed under the MIT License:

```text
MIT License

Copyright (c) 2026 Songhai Fan

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
```

## Snapzy

MacPilot's screenshot implementation directly migrates the capture source from
[Snapzy](https://github.com/duongductrong/Snapzy) (commit `417c8e0`,
`v1.31.0-beta.18`). The migrated files live under
`Sources/MacPilot/SnapzyCapture/` and retain the upstream type and pipeline
structure; MacPilot-specific changes are limited to localization, permission,
and storage seams.
Snapzy is distributed under the BSD 3-Clause License, copyright (c) 2026,
Trong Duong Duc. The applicable license text follows.

This notice does not change MacPilot's license. It identifies the upstream
source used for the single-frame ScreenCaptureKit session, frozen display
snapshots, multi-display crop/composition, and area-selection overlay.

```text
BSD 3-Clause License

Copyright (c) 2026, Trong Duong Duc

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its
   contributors may be used to endorse or promote products derived from
   this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```
