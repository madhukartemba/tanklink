import 'package:flutter/widgets.dart';

/// Closes the route [context] belongs to, but only while it is the top one.
///
/// Use it for every close that does not come straight from a tap: after an
/// `await`, in a post-frame callback, or anywhere a second close could race
/// the first. A plain `Navigator.pop` pops whatever is on top, so a late or
/// repeated one closes the screen underneath, and popping the home route
/// leaves a blank screen. A route that is already closing is not current, so
/// a second call here does nothing.
bool popSelf<T extends Object?>(BuildContext context, [T? result]) {
  if (!context.mounted) return false;
  final route = ModalRoute.of(context);
  if (route == null || !route.isCurrent) return false;
  Navigator.of(context).pop<T>(result);
  return true;
}
