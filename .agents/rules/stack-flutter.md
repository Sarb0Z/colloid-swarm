---
applyTo: '**/*.dart,**/pubspec.yaml,**/analysis_options.yaml'
paths:
  - '**/*.dart'
  - '**/pubspec.yaml'
  - '**/analysis_options.yaml'
detect:
  - '**/pubspec.yaml'
---

# Flutter Rules

## Business Invariants
- Lints come from `analysis_options.yaml`, which includes `package:flutter_lints/flutter.yaml`. Fix a finding in the code. Do not add `// ignore:` comments and do not turn a rule off for a file you edit.
- State uses the `provider` package: a `ChangeNotifier` calls `notifyListeners()` after each change a widget reads. `build` reads state with `context.watch` or `Consumer`. A callback such as `onPressed` reads it with `context.read`. A `watch` in a callback does not rebuild and the analyzer does not report it.
- Do not use `BuildContext` after an `await` until `if (!mounted) return;` (or `context.mounted`) has passed. The widget can leave the tree while the call runs, and the stale context throws.
- A `State` releases every `TextEditingController`, `AnimationController`, `FocusNode`, `ScrollController`, and stream subscription it creates in `dispose()`. A `ChangeNotifier` does the same for its own subscriptions.
- A repository uses one navigation API. Where `go_router` is a dependency, route with `context.go` and `context.push`. Do not mix in `Navigator.pushNamed`, because the two keep separate route stacks.
- A token or credential is stored with `flutter_secure_storage`. `shared_preferences` is plain text on disk and holds only non-secret settings.
- A value passed with `--dart-define` is compiled into the binary and readable by any user of the build. Never use it for a credential. Read a secret on a server that the app calls.
- Code that builds for web must not import `dart:io`. It throws on web at run time, and the analyzer reports nothing. Split the platform code with a conditional import.
- Add a dependency with `flutter pub add`, never by editing `pubspec.yaml`, and commit `pubspec.lock` for an app. Do not commit `build/`.
- A test lives in `test/` and ends in `_test.dart`. `flutter test` runs it. A widget test pumps the widget with `tester.pumpWidget` and wraps it in the providers it reads.

## Abnormal Cases and Rationale
- `pubspec.yaml` names a Dart SDK range. A language feature newer than the lower bound compiles on the developer machine and fails in CI. Raise the bound in the same change that uses the feature.
- A generated file, such as `*.g.dart`, `*.freezed.dart`, or a FlutterFlow export, is overwritten on the next run of its generator. Change the source or the generator input, not the output.

## Out of Scope
- Do not restate naming or formatting here. `dart format` and `flutter analyze` own them.
