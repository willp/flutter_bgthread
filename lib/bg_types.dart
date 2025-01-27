import 'package:flutter/widgets.dart';

typedef ProxiedStreamBuilder<R> = StreamBuilder<R> Function(Widget Function(BuildContext, AsyncSnapshot<R>) builderFunc);
