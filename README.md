# flutter-femtolytics
A Flutter client for [femtolytics](https://femtolytics.com).

## Background
Femtolytics is a small open-source mobile application analytics solution.

You can either use the hosted solution at [femtolytics](https://femtolytics.com) or host your own instance of femtolytics by using [django-femtolytics](https://github.com/femtolytics/django-femtolytics)

This plugin is a pure Dart plugin and has minimal dependencies.

## Getting Started

You should ensure that you add the dependency to your flutter project.

```
dependencies:
 femtolytics: "^0.0.1"
```

You can also reference the git repo directly if you want:

```
dependencies:
 femtolyics:
   git: git://github.com/femtolytics/flutter-femtolyics.git
```

## Setting up

As early as possible in your application you should provide the URL of the endpoint for your femtolytics instance, a good place is either in your main or the constructor of your application as follows:

```dart
class MyApp extends StatelessWidget {
    MyApp() {
        Femtolytics.setEndpoint('https://example.com/analytics');
    }
}
```

The plugin queues in the event in a local database no matter, and will not lose events even if one were to happen before the endpoint is defined.

## Tracking views

flutter-femtolytics comes with mixins to help you track how your user are navigating through your application.

Simply replace `StatelessWidget` by `TraceableStatelessWidget`, `StatefulWidget` by `TraceableStatefulWidget` and finally `InheritedWidget` by `TraceableInheritedWidget`.

The constructor of those mixins take a `name` argument so you can customize the name of the view. If not specified, then the class name (`this.runtimeType.toString()`) will be used.

Here is an example of how you can pass the name to the mixins:
```dart
class HomePage extends TraceableStatefulWidget {
  HomePage({Key key}) : super(key: key, name: "Home");

  @override
  State<StatefulWidget> createState() => HomeState();
}
```

## Tracking actions and goals

Other than tracking basic flows within the application, you can record custom actions and goals.

To record an action simply call `Femtolytics.action("my action")` and similarly to track goals call `Femtolytics.goal("purchase")`.

Both of those calls also take a dictionary of arbitrary values so that you can track custom properties with both goals and actions.

For example
```dart
Femtolytics.action('SelectColorClicked', properties: {
    'color': 'blue',
});
```

```dart
Femtolytics.goal('in_app', properties: {
    'product': 'loot10',
    'price': 10,
});
```

## Recording crashes and exceptions

Femtolytics can track crashes for you as long as you call the `Femtolytics.crash` at the right moment. The following sample code shows how to modify your main.dart to catch Dart exceptions as well as Flutter exceptions.

```dart
import 'dart:async';

import 'package:flutter/femtolytics.dart';
import 'package:flutter/foundation.dart' as Foundation;
import 'package:flutter/material.dart';

void main() {
  FlutterError.onError = (FlutterErrorDetails details) async {
    if (Foundation.kReleaseMode) {
      Zone.current.handleUncaughtError(details.exception, details.stack);
    } else {
      FlutterError.dumpErrorToConsole(details);
    }
  };

  runZonedGuarded<Future<Null>>(() async {
    runApp(App());
  }, (Object error, StackTrace stackTrace) {
    Femtolytics.crash(error, stackTrace);
  });
}
```