import 'package:flutter/material.dart';

/// Pops a route from inside `TextField.onSubmitted` (pressing Enter).
///
/// Popping synchronously here can trip a Flutter framework assertion
/// (`_dependents.isEmpty`, see `docs/DECISIONS.md`) while `EditableText` is
/// still mid-way through its own submit handling. Deferring by a frame
/// reduces how often that race is hit, though it turned out **not** to be
/// a full fix on its own — the assertion is a known-flaky framework-level
/// race that app-level scheduling can't fully win, so it's also silenced
/// at the source in `main.dart` (`_silenceDialogSubmitAssertion`). That
/// silencing is what actually makes this safe to use; the deferral here is
/// just a courtesy that avoids the assertion in the common case.
void safePopOnSubmit<T>(BuildContext context, T value) {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (context.mounted) Navigator.of(context).pop(value);
  });
}
