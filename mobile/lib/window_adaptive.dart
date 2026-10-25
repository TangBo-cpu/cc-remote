import 'package:flutter/widgets.dart';

/// Material 3 window width classes. Phones sit in compact for portrait and
/// medium for landscape; tablets reach expanded where the chat ships a
/// persistent session rail instead of the modal sidebar.
enum WindowWidthClass { compact, medium, expanded }

const double kWindowMediumBreakpoint = 600;
const double kWindowExpandedBreakpoint = 840;

WindowWidthClass windowWidthClassOf(BuildContext context) {
  final width = MediaQuery.sizeOf(context).width;
  if (width >= kWindowExpandedBreakpoint) return WindowWidthClass.expanded;
  if (width >= kWindowMediumBreakpoint) return WindowWidthClass.medium;
  return WindowWidthClass.compact;
}

bool isExpandedWindow(BuildContext context) =>
    windowWidthClassOf(context) == WindowWidthClass.expanded;

bool isMediumWindowOrWider(BuildContext context) =>
    windowWidthClassOf(context) != WindowWidthClass.compact;

/// Caps a modal/sheet width on medium+ windows so dialogs stop stretching
/// edge to edge on tablets. Compact phones keep [compactWidth] (typically
/// the full-width behavior of the original layout).
double adaptiveSheetMaxWidth(
  BuildContext context, {
  double compactWidth = double.infinity,
  double wideWidth = 560,
}) {
  return isMediumWindowOrWider(context)
      ? wideWidth
      : compactWidth;
}
