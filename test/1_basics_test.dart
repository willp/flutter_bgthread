import 'dart:async';

import '../lib/bgthread.dart';

import 'package:test/test.dart';

class TestClass extends Threadlike {
  late final String name;
  // int? instanceId;

  TestClass.init();
  static TestClass start() {
    var instance = TestClass.init();
    instance.runForever();
    return instance;
  }

  TestClass.badInit() {
    throw 'bad stuff';
  }

  Stream<int> subIntegers(int max, {int delayMS=50}) async* {
    int i = 0;
    while (i < max) {
      yield i++;
      await Future.delayed(Duration(milliseconds: delayMS));
    }
  }

  int getInteger() => 31;

  Future<int> getFutureInteger(int val) {
    return Future.value(val);
  }

  Never brokenGetSomething() {
    throw 'custom error string';
  }

  @override
  void exitNow() async {
    super.exitNow();
    print("exitNow cleanup handler invoked...  in child class TestClass");
    await Future.delayed(Duration(seconds: 2));
  }

  void runForever() async {
    print("\n");
    print("TestClass started, now running forever... in async event loop.");
    while (! this.done) {
      print("... bg isolate TestClass still running.");
      await Future.delayed(Duration(milliseconds: 100));
    }
    print(">>>>>>>>>>>>>> CLEANLY GRACEFULLY EXITING!");
  }
}

void main() async {
 test('my first test', () async {
    BgThread<TestClass> bg = await BgThread.create(TestClass.init);
    expect(bg, isNotNull);
 }); 

 test('get single integer 31', () async {
  BgThread<TestClass> bg = await BgThread.create(TestClass.init);
  int ret = await bg.invoke((_this) => _this.getInteger());
  expect(ret, 31);
 });

 test('bgthread throws exception during create', () async {
  expect(() async {
    await BgThread.create(TestClass.badInit);
  }, throwsA('bad stuff'));
 });

 test('bgthread throws exception during invoke', () async {
  BgThread<TestClass> bg = await BgThread.create(TestClass.init);
  expect(() async {
    await bg.invoke((_this) => _this.brokenGetSomething());
  }, throwsA('custom error string'));
 });

 test('iterate on integer list as a Stream', () async {
  BgThread<TestClass> bg = await BgThread.create(TestClass.init);
  Stream<int> ret = bg.subscribe((_this) => _this.subIntegers(10));
  var vals = <int>[0, 1, 2, 3, 4, 5, 6, 7, 8, 9];
  expect(await ret.toList(), vals);
 });

 test('invoke async method, then call .exit()', () async {
  BgThread<TestClass> bg = await BgThread.create(TestClass.start);
  expect(await bg.invokeAsync((_this) async => _this.getFutureInteger(32)), 32);
  bg.exit();
  await Future.delayed(Duration(seconds: 1));
 });

}