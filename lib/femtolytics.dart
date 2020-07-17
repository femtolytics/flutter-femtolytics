import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:math';

import 'package:device_info/device_info.dart';
import 'package:flutter/material.dart';
import 'package:flutter_user_agent/flutter_user_agent.dart';
import 'package:logging/logging.dart';
import 'package:package_info/package_info.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import 'package:http/http.dart' as http;

abstract class TraceableStatelessWidget extends StatelessWidget {
  final String name;

  TraceableStatelessWidget({this.name = '', Key key}) : super(key: key);

  @override
  StatelessElement createElement() {
    Femtolytics()._event('VIEW', properties: {
      'view': this.name.isEmpty ? this.runtimeType.toString() : this.name
    });
    return StatelessElement(this);
  }
}

abstract class TraceableStatefulWidget extends StatefulWidget {
  final String name;

  TraceableStatefulWidget({this.name = '', Key key}) : super(key: key);

  @override
  StatefulElement createElement() {
    Femtolytics()._event('VIEW', properties: {
      'view': this.name.isEmpty ? this.runtimeType.toString() : this.name
    });
    return StatefulElement(this);
  }
}

abstract class TraceableInheritedWidget extends InheritedWidget {
  final String name;

  TraceableInheritedWidget({this.name = '', Key key, Widget child})
      : super(key: key, child: child);

  @override
  InheritedElement createElement() {
    Femtolytics()._event('VIEW', properties: {
      'view': this.name.isEmpty ? this.runtimeType.toString() : this.name
    });
    return InheritedElement(this);
  }
}

class Femtolytics {
  // Singleton
  static Femtolytics _instance = new Femtolytics.internal();
  Femtolytics.internal() {
    _tracker = _Tracker();
    _tracker.initialize();
  }

  factory Femtolytics() => _instance;

  static void setEndpoint(String url) {
    Femtolytics()._tracker.setEndpoint(url);
  }

  static void action(String action, {Map<String, dynamic> properties}) {
    Femtolytics()._tracker.action(action, properties: properties);
  }

  static void crash(Object error, StackTrace stackTrace) {
    Femtolytics()._tracker.event('CRASH', properties: {
      'exception': error.toString(),
      'stack_trace': stackTrace.toString()
    });
  }

  static void goal(String goal, {Map<String, dynamic> properties}) {
    if (properties == null) {
      properties = {};
    }
    properties['goal'] = goal;
    Femtolytics()._tracker.event('GOAL', properties: properties);
  }

  void _event(String event, {Map<String, dynamic> properties}) {
    _tracker.event(event, properties: properties);
  }

  _Tracker _tracker;
}

// uuid: 2.0.4
// package_info: ^0.4.0+13
// device_info: ^0.4.2+4
// logging

class _Action {
  final String action;
  final Map<String, dynamic> properties;
  final DateTime time;

  _Action(this.action, this.properties, this.time);
}

class _Event {
  final String event;
  final Map<String, dynamic> properties;
  final DateTime time;

  _Event(this.event, this.properties, this.time);
}

class _Tracker with WidgetsBindingObserver {
  final Logger log = new Logger('Femtolytics');

  String userAgent;

  static final int _kCurrentVersion = 1;
  static final String _kDatabaseFilename = 'femtolytics.db';
  static final String _kVisitorTable = 'visitor';
  static final String _kActionsTable = 'actions';
  static final String _kEventsTable = 'events';

  final JsonEncoder _encoder = JsonEncoder();
  final JsonDecoder _decoder = JsonDecoder();

  String _baseURL;
  Database _database;
  PackageInfo _packageInfo;
  String _visitorId;
  String _device;
  String _os;
  Timer _timer;
  bool _initialized = false;
  Queue<dynamic> _queue = Queue();

  Future<void> initialize() async {
    io.Directory documentsDirectory = await getApplicationDocumentsDirectory();
    String path = join(documentsDirectory.path, _kDatabaseFilename);
    log.fine('Initializing analytics database $path');
    _database = await openDatabase(
      path,
      version: _kCurrentVersion,
      onCreate: _onCreate,
    );

    // Device and Operating System
    DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();
    if (io.Platform.isIOS) {
      IosDeviceInfo info = await deviceInfo.iosInfo;
      _device = info.isPhysicalDevice ? info.model : '${info.model} Simulator';
      _os = '${info.systemName} ${info.systemVersion}';
    } else if (io.Platform.isAndroid) {
      AndroidDeviceInfo info = await deviceInfo.androidInfo;
      _device = info.isPhysicalDevice
          ? '${info.brand} ${info.device}'
          : '${info.brand} ${info.device} Simulator';
      _os = info.version.toString();
    }
    log.fine('Device: $_device; OS: $_os');

    // Application Information
    _packageInfo = await PackageInfo.fromPlatform();
    log.fine(
        'Package: ${_packageInfo.packageName} ${_packageInfo.version} ${_packageInfo.buildNumber}');

    // User agent
    await FlutterUserAgent.init();
    userAgent = FlutterUserAgent.webViewUserAgent;

    // User
    _visitorId = await _getVisitorId();
    if (_visitorId == null) {
      _visitorId = Uuid().v4().toString();
      log.fine('New User $_visitorId');
      await _setVisitorId(_visitorId);
      // Log Special Event
      event('NEW_USER', properties: {'visitor_id': _visitorId});
    }
    // Monitor Lifecycle
    WidgetsBinding.instance.addObserver(this);

    // Reset queue handles just in case.
    await _database.update(_kActionsTable, {'handle': null});

    // At this point we are ready to store messages into the database.
    _initialized = true;

    // dequeue now, and schedule periodic timer.
    this._dequeue();
    _timer = Timer.periodic(Duration(seconds: 60), (timer) {
      this._dequeue();
    });
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer.cancel();
  }

  void setEndpoint(String url) {
    this._baseURL = url;
    log.info('Using femtolytics endpoint $url');
    _dequeue();
  }

  void event(String event, {Map<String, dynamic> properties}) {
    if (_initialized) {
      _storeEvent(event, properties: properties);
    } else {
      _queue.add(_Event(event, properties, DateTime.now()));
    }
  }

  void action(String action, {Map<String, dynamic> properties}) {
    if (_initialized) {
      _storeAction(action, properties: properties);
    } else {
      _queue.add(_Action(action, properties, DateTime.now()));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // inactive -> paused ... inactive -> resumed
    if (state == AppLifecycleState.inactive) {
      log.fine('Lifecycle: inactive');
      _dequeue();
    }

    switch (state) {
      case AppLifecycleState.detached:
        event('DETACHED');
        break;
      case AppLifecycleState.inactive:
        event('INACTIVE');
        break;
      case AppLifecycleState.paused:
        event('PAUSED');
        break;
      case AppLifecycleState.resumed:
        event('RESUMED');
        break;
    }
  }

  void _onCreate(Database database, int version) async {
    if (version == 1) {
      await database.execute('DROP TABLE IF EXISTS visitor');
      await database.execute('DROP TABLE IF EXISTS events');
      await database.execute('DROP TABLE IF EXISTS actions');

      await database.execute("""
      CREATE TABLE visitor (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        visitor_id TEXT NOT NULL,
        created INT NOT NULL
      )
      """);
      await database.execute("""
      CREATE UNIQUE INDEX idx_visitor_visitor_id ON visitor(visitor_id)
      """);

      await database.execute("""
      CREATE TABLE actions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        action TEXT NOT NULL,
        properties TEXT NOT NULL,
        visitor_id TEXT NOT NULL,
        handle INT,
        created INT NOT NULL
      )
      """);
      await database.execute("""
      CREATE TABLE events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        event TEXT NOT NULL,
        properties TEXT NOT NULL,
        visitor_id TEXT NOT NULL,
        handle INT,
        created INT NOT NULL
      )
      """);
    }
  }

  Future<void> _storeAction(String action,
      {Map<String, dynamic> properties, DateTime time}) async {
    Map<String, dynamic> row = {};
    row['action'] = action;
    row['properties'] = _encoder.convert(properties);
    row['visitor_id'] = _visitorId;
    row['created'] = time == null
        ? DateTime.now().millisecondsSinceEpoch
        : time.millisecondsSinceEpoch;
    int id = await _database.insert(_kActionsTable, row);
    log.fine('Inserted action $id into database $action');
  }

  Future<void> _storeEvent(String event,
      {Map<String, dynamic> properties, DateTime time}) async {
    Map<String, dynamic> row = {};
    row['event'] = event;
    row['properties'] = _encoder.convert(properties);
    row['visitor_id'] = _visitorId;
    row['created'] = time == null
        ? DateTime.now().millisecondsSinceEpoch
        : time.millisecondsSinceEpoch;
    int id = await _database.insert(_kEventsTable, row);
    log.fine('Inserted event $id into database $event');
  }

  Future<String> _getVisitorId() async {
    var rows = await _database
        .query(_kVisitorTable, columns: ['id', 'visitor_id', 'created']);
    if (rows.length > 0) {
      return rows.first['visitor_id'];
    }
    return null;
  }

  Future<int> _setVisitorId(String visitorId) async {
    return _database.insert(_kVisitorTable, {
      'visitor_id': visitorId,
      'created': DateTime.now().millisecondsSinceEpoch
    });
  }

  Future<void> _dequeue() async {
    if (this._baseURL == null || !_initialized) {
      return;
    }

    // Check internal queue first.
    while (_queue.length > 0) {
      var event = _queue.removeFirst();
      if (event is _Action) {
        await _storeAction(event.action,
            properties: event.properties, time: event.time);
      } else if (event is _Event) {
        await _storeEvent(event.event,
            properties: event.properties, time: event.time);
      }
    }

    var handle = Random().nextInt(1000000000);
    log.finest('handle = $handle');

    // ACTIONS
    await _database.update(_kActionsTable, {'handle': handle},
        where: 'handle IS NULL');
    var rows = await _database
        .query(_kActionsTable, where: 'handle = ?', whereArgs: [handle]);
    if (rows.length > 0) {
      log.fine('found ${rows.length} action(s) pending in queue');
    }

    for (var row in rows) {
      String action = row['action'];
      Map<String, dynamic> properties = _decoder.convert(row['properties']);
      DateTime time = DateTime.fromMillisecondsSinceEpoch(row['created']);

      Map<String, dynamic> message =
          _actionToMap(action, time, properties: properties);
      log.fine('Message: $message');
      var body = {
        'actions': [message]
      };
      bool sent = await _post('action', body);
      if (sent) {
        log.fine('Action sent successfully');
        await _database
            .delete(_kActionsTable, where: 'id = ?', whereArgs: [row['id']]);
      } else {
        log.fine('Failed to send action');
        await _database.update(_kActionsTable, {'handle': null},
            where: 'id = ?', whereArgs: [row['id']]);
      }
    }

    // EVENTS
    await _database.update(_kEventsTable, {'handle': handle},
        where: 'handle IS NULL');
    rows = await _database
        .query(_kEventsTable, where: 'handle = ?', whereArgs: [handle]);
    if (rows.length > 0) {
      log.fine('found ${rows.length} event(s) pending in queue');
    }

    for (var row in rows) {
      String event = row['event'];
      Map<String, dynamic> properties = _decoder.convert(row['properties']);
      DateTime time = DateTime.fromMillisecondsSinceEpoch(row['created']);

      Map<String, dynamic> message =
          _eventToMap(event, time, properties: properties);
      log.fine('Message: $message');
      var body = {
        'events': [message]
      };
      bool sent = await _post('event', body);
      if (sent) {
        log.fine('Event sent successfully');
        await _database
            .delete(_kEventsTable, where: 'id = ?', whereArgs: [row['id']]);
      } else {
        log.fine('Failed to send event');
        await _database.update(_kEventsTable, {'handle': null},
            where: 'id = ?', whereArgs: [row['id']]);
      }
    }
  }

  Future<bool> _post(String type, Map<String, dynamic> message) {
    var url = '$_baseURL/$type';
    var headers = {
      'User-Agent': userAgent,
    };
    return http
        .post(url, body: _encoder.convert(message), headers: headers)
        .then((http.Response response) {
      final int status = response.statusCode;
      return status >= 200 && status < 400;
    });
  }

  Map<String, dynamic> _commonMap() {
    Map<String, dynamic> message = {};
    // Package
    message['package'] = {};
    message['package']['name'] = _packageInfo.packageName;
    message['package']['version'] = _packageInfo.version;
    message['package']['build'] = _packageInfo.buildNumber;
    // Device
    message['device'] = {};
    message['device']['name'] = _device;
    message['device']['os'] = _os;
    // User
    message['visitor_id'] = _visitorId;
    return message;
  }

  Map<String, dynamic> _actionToMap(String action, DateTime actionTime,
      {Map<String, dynamic> properties}) {
    Map<String, dynamic> message = _commonMap();
    // Action
    message['action'] = {};
    message['action']['type'] = action;
    message['action']['time'] = actionTime.toIso8601String();
    if (properties != null) {
      message['action']['properties'] = properties;
    }

    return message;
  }

  Map<String, dynamic> _eventToMap(String event, DateTime time,
      {Map<String, dynamic> properties}) {
    Map<String, dynamic> message = _commonMap();
    // Event
    message['event'] = {};
    message['event']['type'] = event;
    message['event']['time'] = time.toIso8601String();
    if (properties != null) {
      message['event']['properties'] = properties;
    }
    return message;
  }
}
