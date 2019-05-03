// Copyright (c) 2018, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';

import 'package:analysis_server/src/protocol_server.dart'
    show
        CompletionSuggestion,
        RuntimeCompletionExpression,
        RuntimeCompletionVariable,
        SourceEdit;
import 'package:analysis_server/src/provisional/completion/completion_core.dart';
import 'package:analysis_server/src/services/completion/completion_core.dart';
import 'package:analysis_server/src/services/completion/completion_performance.dart';
import 'package:analysis_server/src/services/completion/dart/completion_manager.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/file_system/overlay_file_system.dart';
import 'package:analyzer/src/dart/analysis/driver.dart';
import 'package:analyzer_plugin/protocol/protocol_common.dart';
import 'package:analyzer_plugin/utilities/change_builder/change_builder_dart.dart';

class RuntimeCompletionComputer {
  final OverlayResourceProvider resourceProvider;
  final AnalysisDriver analysisDriver;

  final String code;
  final int offset;

  final String contextPath;
  final int contextOffset;

  final List<RuntimeCompletionVariable> variables;
  final List<RuntimeCompletionExpression> expressions;

  RuntimeCompletionComputer(
      this.resourceProvider,
      this.analysisDriver,
      this.code,
      this.offset,
      this.contextPath,
      this.contextOffset,
      this.variables,
      this.expressions);

  Future<RuntimeCompletionResult> compute() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    var contextResult = await analysisDriver.getResult(contextPath);
    var session = contextResult.session;

    const codeMarker = '__code_\_';

    // Insert the code being completed at the context offset.
    var changeBuilder = new DartChangeBuilder(session);
    int nextImportPrefixIndex = 0;
    await changeBuilder.addFileEdit(contextPath, (builder) {
      builder.addInsertion(contextOffset, (builder) {
        builder.writeln('{');

        // TODO(scheglov) Use variables.

        builder.write(codeMarker);
        builder.writeln(';');

        builder.writeln('}');
      });
    }, importPrefixGenerator: (uri) => '__prefix${nextImportPrefixIndex++}');

    // Compute the patched context file content.
    String targetCode = SourceEdit.applySequence(
      contextResult.content,
      changeBuilder.sourceChange.edits[0].edits,
    );

    // Insert the code being completed.
    int targetOffset = targetCode.indexOf(codeMarker) + offset;
    targetCode = targetCode.replaceAll(codeMarker, code);

    // Update the context file content to include the code being completed.
    // Then resolve it, and restore the file to its initial state.
    ResolvedUnitResult targetResult;
    await _withContextFileContent(targetCode, () async {
      targetResult = await analysisDriver.getResult(contextPath);
    });

    CompletionContributor contributor = new DartCompletionManager();
    CompletionRequestImpl request = new CompletionRequestImpl(
      targetResult,
      targetOffset,
      new CompletionPerformance(),
    );
    var suggestions = await contributor.computeSuggestions(request);

    // Remove completions with synthetic import prefixes.
    suggestions.removeWhere((s) => s.completion.startsWith('__prefix'));

    // TODO(scheglov) Add support for expressions.
    var expressions = <RuntimeCompletionExpression>[];
    return new RuntimeCompletionResult(expressions, suggestions);
  }

  Future<void> _withContextFileContent(
      String newContent, Future<void> Function() f) async {
    if (resourceProvider.hasOverlay(contextPath)) {
      var contextFile = resourceProvider.getFile(contextPath);
      var prevOverlayContent = contextFile.readAsStringSync();
      var prevOverlayStamp = contextFile.modificationStamp;
      try {
        resourceProvider.setOverlay(
          contextPath,
          content: newContent,
          modificationStamp: 0,
        );
        analysisDriver.changeFile(contextPath);
        await f();
      } finally {
        resourceProvider.setOverlay(
          contextPath,
          content: prevOverlayContent,
          modificationStamp: prevOverlayStamp,
        );
        analysisDriver.changeFile(contextPath);
      }
    } else {
      try {
        resourceProvider.setOverlay(
          contextPath,
          content: newContent,
          modificationStamp: 0,
        );
        analysisDriver.changeFile(contextPath);
        await f();
      } finally {
        resourceProvider.removeOverlay(contextPath);
        analysisDriver.changeFile(contextPath);
      }
    }
  }
}

/// The result of performing runtime completion.
class RuntimeCompletionResult {
  final List<RuntimeCompletionExpression> expressions;
  final List<CompletionSuggestion> suggestions;

  RuntimeCompletionResult(this.expressions, this.suggestions);
}