import 'dart:async';
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

abstract class Threadlike {
  int? instanceId;
  bool done = false;

  /// override to add extra behavior for cleanup
  Future<void> finishWork() async {
    done = true;
  }
  void exitNow() async => {};

  void finishAndExit() async {
    await finishWork();
    exitNow();
  }
}

class FgSubscriptionProxy<R,C> {
  // T is the type returned from the background thread's subscribe() stream to a `bgthread.generatorMethod<T> async*`
  // Instantiating this class (FgSubscriptionProxy) sets up the plumbing for dealing with that.
  FgSubscriptionProxy._(this.initialValue) {
    currentValue = this.initialValue;
  }

  static Future<FgSubscriptionProxy<R,C>> init<R,C>(
      R initialValue,
      BgThread<C> bgchild, // already created, so we're just wiring up streams to an existing background thread.
      Stream<R> Function(C) func,
    ) async {
    FgSubscriptionProxy<R,C> thisObj = FgSubscriptionProxy._(initialValue);
    await thisObj.setupSubscriptionStream(bgchild, func);
    return thisObj;
  }

  StreamController<R> fgSubscriptionController = StreamController<R>.broadcast();
  late R initialValue; // passed to bgthread's constructor
  late R currentValue = initialValue;  // used as a cache for this FG thread

  Future<void> setupSubscriptionStream(
    BgThread<C> bgchild,
    Stream<R> Function(C) func
  ) async {
    Stream<R> fgStream = bgchild.subscribe(func); //
    fgSubscriptionController.stream.listen((val) => currentValue = val); // updates cache
    fgSubscriptionController.addStream(fgStream);
  }

  //  need to pass in a closure to create a widget, receiving args too.  AnimatedEmojiData face, double size
  StreamBuilder<R> fgStreamBuilder(Widget Function<R> (BuildContext context, AsyncSnapshot<R> snapshot) builderFunc) =>
    StreamBuilder<R>(
        stream: fgSubscriptionController.stream,
        initialData: currentValue,
        builder: builderFunc);
}


class Command {
  final CommandMethods method;
  final SendPort? sendPort;
  final Object? callable;
  final Object? token;

  Command(this.method, {this.sendPort, this.callable, this.token});
}

enum CommandMethods {
  create,
  invoke,
  subscribe,
  exit,
}

class ErrorHolder {
  final dynamic errorObject;
  final StackTrace stackTrace;
  ErrorHolder(this.errorObject, this.stackTrace);
}
class StreamFinished {}

/// Supports starting a single instance of <T> in a background Isolate
/// with automatic setup of the Send/ReceivePort(s) and all that jazz
/// Inspired by https://github.com/gaaclarke/agents
class BgThread<T> {
  Isolate? _isolate;
  final SendPort _commandPort;
  static int instanceID = 0;

  BgThread._(this._isolate, this._commandPort);

  static void _dispatcherInChild<T extends Threadlike>(SendPort parentPort) async {
    ReceivePort receivePort = ReceivePort();
    parentPort.send(receivePort.sendPort); // now have a "pipe" between parent and child
    late T state;
    receivePort.listen((_command) async {
      Command command = _command; // cast
      switch (command.method) {
        // CREATE
        case (CommandMethods.create):
          try {
            if (command.token is RootIsolateToken) {
              RootIsolateToken rootIsolateToken = command.token as RootIsolateToken;
              BackgroundIsolateBinaryMessenger.ensureInitialized(rootIsolateToken);
            }
            state = (command.callable! as T Function())();
            command.sendPort!.send(null);
          } catch (e, stackTrace) {
            var error = ErrorHolder(e, stackTrace);
            command.sendPort!.send(error);
            print("---> exitting isolate now...");
            Isolate.exit(command.sendPort, error);
          }
          // parentPort.send(null); // why?
          break;
        // INVOKE
        case (CommandMethods.invoke):
          Object? result;
          try {
            Object? Function(T) func = command.callable as Object? Function(T);
            result = func(state);
            if (result is Future) {
              result = await result;
            }
            command.sendPort!.send(result);
          } catch (e, stackTrace) {
            command.sendPort!.send(ErrorHolder(e, stackTrace));
          }
          break;
        // SUBSCRIBE
        case (CommandMethods.subscribe):
          final func = command.callable as Stream<dynamic> Function(T);
          Stream<dynamic> stream = func(state);
          try {
            await for (final result in stream) {
              command.sendPort!.send(result);
            }
          } catch (e, stackTrace) {
            command.sendPort!.send(ErrorHolder(e, stackTrace));
          }
          command.sendPort!.send(StreamFinished());
          break;
        // EXIT
        case (CommandMethods.exit):
          state.finishAndExit();
          receivePort.close();
          Isolate.exit(command.sendPort!, CommandMethods.exit);
          // ignore: dead_code
          break;
      };
    });
  }

  static Future<BgThread<T>> create<T extends Threadlike>(
    T Function() func, {
    String? name,
  }) async {
    ReceivePort commandPort = ReceivePort();
    ReceivePort errorPort = ReceivePort();
    ReceivePort exitPort = ReceivePort();
    Isolate isolate = await Isolate.spawn(
      _dispatcherInChild<T>,
      commandPort.sendPort,
      errorsAreFatal: false,
      onError: errorPort.sendPort,
      onExit: exitPort.sendPort,
      debugName: name ?? 'Isolate-${instanceID++}',
    );
    exitPort.listen((message) {print("(1) onExit: $message");},
      onError: (message) {print("(1) onExit exitport onError: $message");},
      onDone: () {print("(1) onExit exitport onDone!!!");},
      );
    errorPort.listen((message) {print("(2) onError: $message");},
      onError: (message) {print("(2) onError errorPort onError: $message");},
      onDone: () {print("(2) onDone errorPort onDone!!!");},
    );
    final sendPort = await commandPort.first;
    ReceivePort creationFailed = ReceivePort();
    RootIsolateToken rootIsolateToken = RootIsolateToken.instance!;
    sendPort.send(Command(
      CommandMethods.create,
      sendPort: creationFailed.sendPort,
      callable: func,
      token: rootIsolateToken)
    );
    commandPort.close(); // not sure why we do this... ?
    final error = await creationFailed.first;  // null on success
    if (error is ErrorHolder) {
      // print("ERROR: ${error.errorObject}");
      // print("STACK TRACE: ${error.stackTrace}");
      Error.throwWithStackTrace(error.errorObject, error.stackTrace);
    }
    return BgThread<T>._(isolate, sendPort);
  }

  void _ensureIsolateIsActive() {
    if (_isolate == null) {
      throw StateError('BG Isolate has been killed.');
    }
  }

  void _checkInvokeFailure(dynamic result) {
    if (result is ErrorHolder) {
      dynamic exc = result.errorObject;
      StackTrace stk = result.stackTrace;
      Error.throwWithStackTrace(exc, stk);
    }
  }

  Future<R> _getInvokeResult<R>(ReceivePort receivePort, Command cmd) async {
    _commandPort.send(cmd);
    dynamic result = await receivePort.first;
    _checkInvokeFailure(result);
    return result as R;
  }

  Future<R> invoke<R>(R Function(T) func) async {
    _ensureIsolateIsActive();
    ReceivePort receivePort = ReceivePort();
    // print("Sending command for $func");
    return _getInvokeResult<R>(receivePort,
        Command(CommandMethods.invoke,
           sendPort: receivePort.sendPort,
           callable: func));
  }

  /// Request background isolate to execute R func(S)
  Future<R> invokeAsync<R>(Future<R> Function(T) func) async {
    _ensureIsolateIsActive();
    ReceivePort receivePort = ReceivePort();
    // print("Sending command for ASYNC $func");
    return _getInvokeResult<R>(receivePort,
        Command(CommandMethods.invoke,
           sendPort: receivePort.sendPort,
           callable: func));
  }

  Stream<R> subscribe<R>(Stream<R> Function(T) func) async* {
    _ensureIsolateIsActive();
    ReceivePort receivePort = ReceivePort();
    _commandPort.send(Command(CommandMethods.subscribe, sendPort: receivePort.sendPort, callable: func));
    await for (final result in receivePort) {
      if (result is StreamFinished) {
        receivePort.close();
        return;
      }
      if (result is ErrorHolder) {
        Error.throwWithStackTrace(result.errorObject, result.stackTrace);
      }
      yield result as R;
    }
  }

  /// Request background isolate to execute R func(S)
  Future<void> exit() async {
    print("Calling EXIT");
    _ensureIsolateIsActive();
    ReceivePort receivePort = ReceivePort();
    _commandPort.send(
        Command(CommandMethods.exit, sendPort: receivePort.sendPort));
    var lastitem = await receivePort.first;
    print ("Got last response of: $lastitem");
    assert (lastitem == CommandMethods.exit);
  }

}
