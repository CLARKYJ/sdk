// Copyright (c) 2019, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/src/error/codes.dart';
import 'package:analyzer/src/generated/engine.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

import '../dart/resolution/driver_resolution.dart';

main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(ExtensionOverrideAccessToStaticMemberTest);
  });
}

@reflectiveTest
class ExtensionOverrideAccessToStaticMemberTest extends DriverResolutionTest {
  @override
  AnalysisOptionsImpl get analysisOptions => AnalysisOptionsImpl()
    ..contextFeatures = FeatureSet.forTesting(
        sdkVersion: '2.3.0', additionalFeatures: [Feature.extension_methods]);

  test_getter() async {
    await assertErrorsInCode('''
extension E on String {
  static String get empty => '';
}
void f() {
  E('a').empty;
}
''', [
      error(CompileTimeErrorCode.EXTENSION_OVERRIDE_ACCESS_TO_STATIC_MEMBER, 79,
          5),
    ]);
  }

  test_getterAndSetter() async {
    await assertErrorsInCode('''
extension E on String {
  static String get empty => '';
  static void set empty(String s) {}
}
void f() {
  E('a').empty += 'b';
}
''', [
      error(CompileTimeErrorCode.EXTENSION_OVERRIDE_ACCESS_TO_STATIC_MEMBER,
          116, 5),
    ]);
  }

  test_method() async {
    await assertErrorsInCode('''
extension E on String {
  static String empty() => '';
}
void f() {
  E('a').empty();
}
''', [
      error(CompileTimeErrorCode.EXTENSION_OVERRIDE_ACCESS_TO_STATIC_MEMBER, 77,
          5),
    ]);
    var invocation = findNode.methodInvocation('empty();');
    assertMethodInvocation(
      invocation,
      findElement.method('empty'),
      'String Function()',
    );
  }

  test_setter() async {
    await assertErrorsInCode('''
extension E on String {
  static void set empty(String s) {}
}
void f() {
  E('a').empty = 'b';
}
''', [
      error(CompileTimeErrorCode.EXTENSION_OVERRIDE_ACCESS_TO_STATIC_MEMBER, 83,
          5),
    ]);
  }
}
