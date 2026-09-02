# Bundled dprint formatter

Anvil includes these pinned formatter components:

- dprint 0.57.0: https://github.com/dprint/dprint
- dprint-plugin-json 0.23.0: https://github.com/dprint/dprint-plugin-json
- dprint-plugin-toml 0.8.0: https://github.com/dprint/dprint-plugin-toml
- pretty_yaml 0.6.0: https://github.com/g-plane/pretty_yaml
- markup_fmt 0.27.3: https://github.com/g-plane/markup_fmt

The files came from the official dprint release and plugin services. Their
SHA-256 values are:

```text
a06ee95b5f5af756d8c403975d1392cf70bcdf460f95afac57b792646d93d809  dprint.exe
3e1f1b7c1427df6bd8981a11aaa2c466fde8d1115e9dde4c652130458539443c  plugins/json-0.23.0.wasm
69cb40cba5e8a53560ccea7fdced073a55d04eb05492f0d9b877f916b976945d  plugins/toml-0.8.0.wasm
40a2fdda7040317eb1b23520f3a00769a5571eedb049c4ca9175c1b9eeba01ae  plugins/pretty_yaml-0.6.0.wasm
07cebe7cebf3660d15a92ad94888f2b04903ee0c1aabbb6a5b8a018720d04568  plugins/markup_fmt-0.27.3.wasm
```

## License

Each component uses the MIT License.

- dprint: Copyright (c) 2019 David Sherret
- dprint-plugin-json: Copyright (c) 2020 David Sherret
- dprint-plugin-toml: Copyright (c) 2021-2023 David Sherret
- pretty_yaml: Copyright (c) 2024-present Pig Fang
- markup_fmt: Copyright (c) 2023-present Pig Fang

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
