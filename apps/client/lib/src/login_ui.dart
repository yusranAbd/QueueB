import 'package:flutter/material.dart';

import 'patient_design.dart';

// Scoped to the centered login form; authentication lives in LoginPage.
abstract final class LoginStyle {
  static const paper = PatientDesign.background;
  static const rule = PatientDesign.border;
  static const white = PatientDesign.paper;
  static const shadow = Color(0x140f2a43);
  static const cardWidth = 420.0;
  static const cardRadius = 12.0;
  static const fieldRadius = 6.0;
  static const displayButtonClearance = 80.0;
  static const inputText = TextStyle(fontSize: 14, color: PatientDesign.ink);

  static bool compact(BuildContext context) =>
      MediaQuery.sizeOf(context).height -
          MediaQuery.viewInsetsOf(context).bottom -
          MediaQuery.paddingOf(context).vertical <
      740;
}

/// Natural-height, centered form. Short views, keyboard and larger text retain
/// scrolling instead of clipping fields or shrinking the user's text scale.
class LoginLayout extends StatelessWidget {
  const LoginLayout({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xfff1f5ff), Color(0xffe2ebfc)],
      ),
    ),
    child: LayoutBuilder(
      builder: (context, bounds) {
        final horizontal = bounds.maxWidth < 360 ? 12.0 : 20.0;
        final vertical = LoginStyle.compact(context) ? 12.0 : 24.0;
        final buttonBelowCard =
            bounds.maxWidth <
            LoginStyle.cardWidth + 2 * LoginStyle.displayButtonClearance;
        return SingleChildScrollView(
          key: const ValueKey('login-scroll'),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: bounds.maxHeight),
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                horizontal,
                vertical,
                horizontal,
                buttonBelowCard ? LoginStyle.displayButtonClearance : vertical,
              ),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: LoginStyle.cardWidth,
                  ),
                  child: child,
                ),
              ),
            ),
          ),
        );
      },
    ),
  );
}

class LoginFormCard extends StatelessWidget {
  const LoginFormCard({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final compact = LoginStyle.compact(context);
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(LoginStyle.fieldRadius),
    );
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(LoginStyle.fieldRadius),
      borderSide: const BorderSide(color: LoginStyle.rule),
    );
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 20 : 24,
        vertical: 20,
      ),
      decoration: BoxDecoration(
        color: LoginStyle.white,
        borderRadius: BorderRadius.circular(LoginStyle.cardRadius),
        border: Border.all(color: LoginStyle.rule),
        boxShadow: const [
          BoxShadow(
            color: LoginStyle.shadow,
            blurRadius: 32,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: Theme(
        data: theme.copyWith(
          inputDecorationTheme: theme.inputDecorationTheme.copyWith(
            isDense: true,
            fillColor: const Color(0xfffcfdff),
            labelStyle: LoginStyle.inputText.copyWith(
              color: PatientDesign.muted,
            ),
            hintStyle: LoginStyle.inputText.copyWith(
              color: PatientDesign.muted,
            ),
            prefixIconColor: PatientDesign.muted,
            suffixIconColor: PatientDesign.muted,
            prefixIconConstraints: const BoxConstraints(
              minWidth: 44,
              minHeight: 48,
            ),
            suffixIconConstraints: const BoxConstraints(
              minWidth: 44,
              minHeight: 48,
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 14,
            ),
            border: border,
            enabledBorder: border,
            focusedBorder: border.copyWith(
              borderSide: const BorderSide(
                color: PatientDesign.primary,
                width: 1.5,
              ),
            ),
            errorBorder: border.copyWith(
              borderSide: BorderSide(color: theme.colorScheme.error),
            ),
            focusedErrorBorder: border.copyWith(
              borderSide: BorderSide(
                color: theme.colorScheme.error,
                width: 1.5,
              ),
            ),
            disabledBorder: border,
          ),
          filledButtonTheme: FilledButtonThemeData(
            style: FilledButton.styleFrom(
              minimumSize: const Size(48, 48),
              shape: shape,
              textStyle: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          textButtonTheme: TextButtonThemeData(
            style: TextButton.styleFrom(
              minimumSize: const Size(44, 44),
              shape: shape,
              textStyle: const TextStyle(fontSize: 13),
            ),
          ),
        ),
        child: child,
      ),
    );
  }
}
