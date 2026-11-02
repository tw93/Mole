# Third-Party Notices

Mole CLI (Linux) includes material from the projects below. Each keeps its
own license; the text of each license follows its entry.

## xdg-ninja

- Source: https://github.com/b3nj5m1n/xdg-ninja (catalog at commit
  `ebf481aee21326cacb87bcb628b19be53b00db82`, 2026-10-04)
- What was taken: home folder and file names from `programs/*.json`, reviewed
  by hand and paired with Arch package names, in `mole_app_xdg_ninja_paths`
  (`lib/uninstall/inventory.sh`). No xdg-ninja code is included;
  `scripts/xdg-ninja-aliases.py` reads the catalog offline to propose rows.

```
MIT License

Copyright (c) 2022 b3nj5m1n

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
