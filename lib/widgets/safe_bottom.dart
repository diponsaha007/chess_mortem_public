import 'package:flutter/material.dart';

/// [base] grown by what the Android navigation bar covers.
/// `viewPadding`, not `padding`, which is zero under an ancestor SafeArea.
EdgeInsets withSafeBottom(BuildContext context, EdgeInsets base) => base
    .copyWith(bottom: base.bottom + MediaQuery.viewPaddingOf(context).bottom);
