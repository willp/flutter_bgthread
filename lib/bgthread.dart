import 'dart:async';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

abstract class Threadlike {
  int? instanceId;
  bool done = false;

  /// override to add extra behavior for cleanup
  /// be sure to call super() so that it can set done=true
  Future<void> finishWork() async {
    done = true;
  }

  /// override to perform final cleanup
  /// or don't override: the default implementation is a noop
  void exitNow() async => {};

  /// call this to set the done flag, and invoke any cleanup handler code
  /// in an overriden exitNow() method
  void finishAndExit() async {
    await finishWork();
    exitNow();
  }
}

class FgSubscriptionProxy<T, R> {
  // R is the type Returned from the background thread's subscribe() stream to a `bgthread.generatorMethod<R> async*`
  // Instantiating this class (FgSubscriptionProxy) sets up the plumbing for dealing with that.
  // T is the BgThread<T> class.
  FgSubscriptionProxy._(this.initialValue) {
    currentValue = this.initialValue;
  }

  static FgSubscriptionProxy<T, R> init<T, R>(
    BgThread<T> bgchild, // already created, so we're just wiring up streams to an existing background thread.
    R initialValue,
    Stream<R> Function(T) func,
  ) {
    FgSubscriptionProxy<T, R> thisObj = FgSubscriptionProxy._(initialValue);
    thisObj.setupSubscriptionStream(bgchild, func);
    return thisObj;
  }

  StreamController<R> fgSubscriptionController = StreamController<R>.broadcast();
  late R initialValue; // passed to bgthread's constructor
  late R currentValue = initialValue; // used as a cache for this FG thread

  void setupSubscriptionStream(BgThread<T> bgchild, Stream<R> Function(T) func) {
    Stream<R> fgStream = bgchild.subscribe(func);
    fgSubscriptionController.stream.listen((val) => currentValue = val); // updates cache
    fgSubscriptionController.addStream(fgStream);
  }

  //  need to pass in a closure to create a widget, receiving args too.
  StreamBuilder<R> fgProxyStreamBuilder(Widget Function(BuildContext context, AsyncSnapshot<R> snapshot) builderFunc) =>
      StreamBuilder<R>(stream: fgSubscriptionController.stream, initialData: currentValue, builder: builderFunc);
}


class Command {
  final CommandMethods method;
  final SendPort? sendPort;
  final Object? callable;
  final RootIsolateToken? token;

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

  static RootIsolateToken? rootToken;

  BgThread._(this._isolate, this._commandPort);

  static void _dispatcherInChild<T extends Threadlike>(SendPort parentPort) async {
    ReceivePort receivePort = ReceivePort();
    parentPort.send(receivePort.sendPort); // now have a "pipe" between parent and child
    late T state;
    receivePort.listen((_command) async {
      Command command = _command; // cast
      switch (command.method) {
        // 
        // CREATE
        case (CommandMethods.create):
          try {
            if (command.token != null) {  // always non-null
              // print('child setting new static TOKEN from command parameter.  static is currently: ${BgThread.rootToken}');
              BgThread.rootToken = command.token;
              RootIsolateToken rootIsolateToken = command.token!;  // always non-null
              BackgroundIsolateBinaryMessenger.ensureInitialized(rootIsolateToken);
            }
            state = (command.callable! as T Function())();
            command.sendPort!.send(null);
          } catch (e, stackTrace) {
            var error = ErrorHolder(e, stackTrace);
            command.sendPort!.send(error);
            Isolate.exit(command.sendPort, error);
          }
          // parentPort.send(null); // why?
          break;
        // 
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
        //
        // SUBSCRIBE
        case (CommandMethods.subscribe):
          final func = command.callable as Stream<dynamic> Function(T);
          Stream<dynamic> stream = func(state);
          // TODO: maybe re-enable this after updating tests
          // assert (stream.isBroadcast);  // remember to always pass the StreamController.stream, not the raw source stream
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
          try {
            state.finishAndExit();
            receivePort.close();
          } finally {
            Isolate.exit(command.sendPort!, CommandMethods.exit);
          }
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
    //
    // BEFORE creating Isolate, store a static copy of the rootIsolateToken in BgThread's static
    RootIsolateToken? rootIsolateToken = RootIsolateToken.instance;
    if (rootIsolateToken != null) {
      // set in static before spawn() so child gets a copy for any create() calls making grand-child Isolates
      BgThread.rootToken = rootIsolateToken;
    } else {
      // this happens only in a child BgThread of a child BgThread, since RootIsolateToken.instance is null in that case
      rootIsolateToken = BgThread.rootToken;
    }
    //
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

    sendPort.send(Command(
      CommandMethods.create,
      sendPort: creationFailed.sendPort,
      callable: func,
      token: rootIsolateToken,  // is null when create child threads of child threads
      )
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

  /// Request background isolate to exit
  Future<void> exit() async {
    // print("Calling EXIT");
    _ensureIsolateIsActive();
    ReceivePort receivePort = ReceivePort();
    _commandPort.send(
        Command(CommandMethods.exit, sendPort: receivePort.sendPort));
    var lastitem = await receivePort.first;
    // print ("Got last response of: $lastitem");
    assert (lastitem == CommandMethods.exit);
  }

}
