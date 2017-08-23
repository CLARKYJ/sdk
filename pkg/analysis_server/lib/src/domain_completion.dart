// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';

import 'package:analysis_server/protocol/protocol.dart';
import 'package:analysis_server/protocol/protocol_constants.dart';
import 'package:analysis_server/protocol/protocol_generated.dart';
import 'package:analysis_server/src/analysis_server.dart';
import 'package:analysis_server/src/collections.dart';
import 'package:analysis_server/src/domain_abstract.dart';
import 'package:analysis_server/src/plugin/plugin_manager.dart';
import 'package:analysis_server/src/provisional/completion/completion_core.dart';
import 'package:analysis_server/src/services/completion/completion_core.dart';
import 'package:analysis_server/src/services/completion/completion_performance.dart';
import 'package:analysis_server/src/services/completion/dart/completion_manager.dart';
import 'package:analyzer/src/dart/analysis/driver.dart';
import 'package:analyzer/src/generated/source.dart';
import 'package:analyzer_plugin/protocol/protocol.dart' as plugin;
import 'package:analyzer_plugin/protocol/protocol_common.dart';
import 'package:analyzer_plugin/protocol/protocol_constants.dart' as plugin;
import 'package:analyzer_plugin/protocol/protocol_generated.dart' as plugin;

/**
 * Instances of the class [CompletionDomainHandler] implement a [RequestHandler]
 * that handles requests in the completion domain.
 */
class CompletionDomainHandler extends AbstractRequestHandler {
  /**
   * The maximum number of performance measurements to keep.
   */
  static const int performanceListMaxLength = 50;

  /**
   * The next completion response id.
   */
  int _nextCompletionId = 0;

  /**
   * Code completion performance for the last completion operation.
   */
  CompletionPerformance performance;

  /**
   * A list of code completion performance measurements for the latest
   * completion operation up to [performanceListMaxLength] measurements.
   */
  final RecentBuffer<CompletionPerformance> performanceList =
      new RecentBuffer<CompletionPerformance>(performanceListMaxLength);

  /**
   * Performance for the last priority change event.
   */
  CompletionPerformance computeCachePerformance;

  /**
   * The current request being processed or `null` if none.
   */
  CompletionRequestImpl _currentRequest;

  /**
   * Initialize a new request handler for the given [server].
   */
  CompletionDomainHandler(AnalysisServer server) : super(server);

  /**
   * Compute completion results for the given request and append them to the stream.
   * Clients should not call this method directly as it is automatically called
   * when a client listens to the stream returned by [results].
   * Subclasses should override this method, append at least one result
   * to the [controller], and close the controller stream once complete.
   */
  Future<CompletionResult> computeSuggestions(CompletionRequestImpl request,
      CompletionGetSuggestionsParams params) async {
    //
    // Allow plugins to start computing fixes.
    //
    Map<PluginInfo, Future<plugin.Response>> pluginFutures;
    plugin.CompletionGetSuggestionsParams requestParams;
    String file = params.file;
    int offset = params.offset;
    AnalysisDriver driver = server.getAnalysisDriver(file);
    if (driver != null) {
      requestParams = new plugin.CompletionGetSuggestionsParams(file, offset);
      pluginFutures = server.pluginManager
          .broadcastRequest(requestParams, contextRoot: driver.contextRoot);
    }
    //
    // Compute completions generated by server.
    //
    List<CompletionSuggestion> suggestions = <CompletionSuggestion>[];
    if (request.result != null) {
      const COMPUTE_SUGGESTIONS_TAG = 'computeSuggestions';
      performance.logStartTime(COMPUTE_SUGGESTIONS_TAG);

      CompletionContributor contributor = new DartCompletionManager();
      String contributorTag = 'computeSuggestions - ${contributor
          .runtimeType}';
      performance.logStartTime(contributorTag);
      try {
        suggestions.addAll(await contributor.computeSuggestions(request));
      } on AbortCompletion {
        suggestions.clear();
      }
      performance.logElapseTime(contributorTag);
      performance.logElapseTime(COMPUTE_SUGGESTIONS_TAG);
    }
    // TODO (danrubel) if request is obsolete (processAnalysisRequest returns
    // false) then send empty results

    //
    // Add the fixes produced by plugins to the server-generated fixes.
    //
    if (pluginFutures != null) {
      List<plugin.Response> responses = await waitForResponses(pluginFutures,
          requestParameters: requestParams);
      for (plugin.Response response in responses) {
        plugin.CompletionGetSuggestionsResult result =
            new plugin.CompletionGetSuggestionsResult.fromResponse(response);
        if (result.results != null && result.results.isNotEmpty) {
          if (suggestions.isEmpty) {
            request.replacementOffset = result.replacementOffset;
            request.replacementLength = result.replacementLength;
          } else if (request.replacementOffset != result.replacementOffset &&
              request.replacementLength != result.replacementLength) {
            server.instrumentationService
                .logError('Plugin completion-results dropped due to conflicting'
                    ' replacement offset/length: ${result.toJson()}');
            continue;
          }
          suggestions.addAll(result.results);
        }
      }
    }
    //
    // Return the result.
    //
    return new CompletionResult(
        request.replacementOffset, request.replacementLength, suggestions);
  }

  @override
  Response handleRequest(Request request) {
    return runZoned(() {
      String requestName = request.method;
      if (requestName == COMPLETION_REQUEST_GET_SUGGESTIONS) {
        processRequest(request);
        return Response.DELAYED_RESPONSE;
      }
      return null;
    }, onError: (exception, stackTrace) {
      server.sendServerErrorNotification(
          'Failed to handle completion domain request: ${request.toJson()}',
          exception,
          stackTrace);
    });
  }

  void ifMatchesRequestClear(CompletionRequest completionRequest) {
    if (_currentRequest == completionRequest) {
      _currentRequest = null;
    }
  }

  /**
   * Process a `completion.getSuggestions` request.
   */
  Future<Null> processRequest(Request request) async {
    performance = new CompletionPerformance();

    // extract and validate params
    CompletionGetSuggestionsParams params =
        new CompletionGetSuggestionsParams.fromRequest(request);
    String filePath = params.file;
    int offset = params.offset;

    AnalysisResult result = await server.getAnalysisResult(filePath);
    Source source;

    if (result == null || !result.exists) {
      if (server.onNoAnalysisCompletion != null) {
        String completionId = (_nextCompletionId++).toString();
        await server.onNoAnalysisCompletion(
            request, this, params, performance, completionId);
        return;
      }
      source = server.resourceProvider.getFile(filePath).createSource();
    } else {
      if (offset < 0 || offset > result.content.length) {
        server.sendResponse(new Response.invalidParameter(
            request,
            'params.offset',
            'Expected offset between 0 and source length inclusive,'
            ' but found $offset'));
        return;
      }
      source =
          server.resourceProvider.getFile(result.path).createSource(result.uri);

      recordRequest(performance, source, result.content, offset);
    }
    CompletionRequestImpl completionRequest = new CompletionRequestImpl(
        result, server.resourceProvider, source, offset, performance);

    String completionId = (_nextCompletionId++).toString();

    setNewRequest(completionRequest);

    // initial response without results
    server.sendResponse(new CompletionGetSuggestionsResult(completionId)
        .toResponse(request.id));

    // Compute suggestions in the background
    computeSuggestions(completionRequest, params)
        .then((CompletionResult result) {
      const SEND_NOTIFICATION_TAG = 'send notification';
      performance.logStartTime(SEND_NOTIFICATION_TAG);
      sendCompletionNotification(completionId, result.replacementOffset,
          result.replacementLength, result.suggestions);
      performance.logElapseTime(SEND_NOTIFICATION_TAG);
      performance.notificationCount = 1;
      performance.logFirstNotificationComplete('notification 1 complete');
      performance.suggestionCountFirst = result.suggestions.length;
      performance.suggestionCountLast = result.suggestions.length;
      performance.complete();
    }).whenComplete(() {
      ifMatchesRequestClear(completionRequest);
    });
  }

  /**
   * If tracking code completion performance over time, then
   * record addition information about the request in the performance record.
   */
  void recordRequest(CompletionPerformance performance, Source source,
      String content, int offset) {
    performance.source = source;
    if (performanceListMaxLength == 0 || source == null) {
      return;
    }
    performance.setContentsAndOffset(content, offset);
    performanceList.add(performance);
  }

  /**
   * Send completion notification results.
   */
  void sendCompletionNotification(String completionId, int replacementOffset,
      int replacementLength, Iterable<CompletionSuggestion> results) {
    server.sendNotification(new CompletionResultsParams(
            completionId, replacementOffset, replacementLength, results, true)
        .toNotification());
  }

  void setNewRequest(CompletionRequest completionRequest) {
    _abortCurrentRequest();
    _currentRequest = completionRequest;
  }

  /**
   * Abort the current completion request, if any.
   */
  void _abortCurrentRequest() {
    if (_currentRequest != null) {
      _currentRequest.abort();
      _currentRequest = null;
    }
  }
}

/**
 * The result of computing suggestions for code completion.
 */
class CompletionResult {
  /**
   * The length of the text to be replaced if the remainder of the identifier
   * containing the cursor is to be replaced when the suggestion is applied
   * (that is, the number of characters in the existing identifier).
   */
  final int replacementLength;

  /**
   * The offset of the start of the text to be replaced. This will be different
   * than the offset used to request the completion suggestions if there was a
   * portion of an identifier before the original offset. In particular, the
   * replacementOffset will be the offset of the beginning of said identifier.
   */
  final int replacementOffset;

  /**
   * The suggested completions.
   */
  final List<CompletionSuggestion> suggestions;

  CompletionResult(
      this.replacementOffset, this.replacementLength, this.suggestions);
}
