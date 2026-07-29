# Vendored diff components

## hdiff histogram algorithm

- Upstream: https://github.com/raygard/hdiff
- Revision: `f8454ca1ef0de16846aba5c9db864048fb4cee82`
- License: 0BSD (`hdiff/LICENSE`)
- Anvil adapts the in-memory histogram matching core; CLI/file/output code is not included.

## Diff Template Library (DTL)

- Upstream: https://github.com/cubicdaiya/dtl
- Revision: `32567bb9ec704f09040fb1ed7431a3d967e3df03`
- License: BSD-3-Clause (`dtl/LICENSE`)
- Used as the shortest-edit-script fallback for histogram regions without a useful low-occurrence anchor.
