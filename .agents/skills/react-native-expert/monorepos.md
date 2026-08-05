# Expo monorepos and native dependencies

## Declare dependencies at the point of use

Each workspace must declare every package that its source imports. An app
workspace must declare the native packages that its app source imports. A
shared workspace must declare the packages that its shared source imports.
Do not duplicate every native dependency in the app package without checking
which workspace imports it and how Expo resolves it.

## Keep one compatible native runtime

Follow [Expo autolinking](https://docs.expo.dev/modules/autolinking/) for the
installed Expo SDK. Deduplicate native modules so the native runtime does not
receive multiple copies of the same module. Align versions that must share one
native runtime, but do not force one exact version for unrelated
JavaScript-only packages.

Use the current [Expo monorepo documentation](https://docs.expo.dev/guides/monorepos/)
for Metro and workspace configuration. Do not add manual resolver overrides
until the installed Expo toolchain requires them.
