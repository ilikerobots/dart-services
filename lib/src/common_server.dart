// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library services.common_server;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:logging/logging.dart';
import 'package:rpc/rpc.dart';

import '../version.dart';
import 'analysis_server.dart';
import 'api_classes.dart';
import 'common.dart';
import 'compiler.dart';
import 'pub.dart';
import 'sdk_manager.dart';
import 'summarize.dart';

final Duration _standardExpiration = new Duration(hours: 1);
final Logger log = new Logger('common_server');

/// Toggle to on to enable `package:` support.
final bool enablePackages = false;

abstract class ServerCache {
  Future get(String key);

  Future set(String key, String value, {Duration expiration});

  Future remove(String key);
}

abstract class ServerContainer {
  String get version;
}

class SummaryText {
  String text;

  SummaryText.fromString(String this.text);
}

abstract class PersistentCounter {
  Future increment(String name, {int increment: 1});

  Future<int> getTotal(String name);
}

@ApiClass(name: 'dartservices', version: 'v1')
class CommonServer {
  final ServerContainer container;
  final ServerCache cache;
  final PersistentCounter counter;

  Pub pub;

  Compiler compiler;
  AnalysisServerWrapper analysisServer;

  String sdkPath;

  CommonServer(String this.sdkPath, this.container, this.cache, this.counter) {
    hierarchicalLoggingEnabled = true;
    log.level = Level.ALL;
  }

  Future init() async {
    pub = enablePackages ? new Pub() : new Pub.mock();
    compiler = new Compiler(sdkPath, pub);
    analysisServer = new AnalysisServerWrapper(sdkPath, previewDart2: true);

    await analysisServer.init();
    analysisServer.onExit.then((int code) {
      log.severe('analysisServer exited, code: $code');
      if (code != 0) {
        exit(code);
      }
    });
    await warmup();
  }

  Future warmup({bool useHtml: false}) async {
    await compiler.warmup(useHtml: useHtml);
    await analysisServer.warmup(useHtml: useHtml);
  }

  Future restart() async {
    log.warning('Restarting CommonServer');
    await shutdown();
    log.info('Analysis Servers shutdown');

    await init();

    log.warning('Restart complete');
  }

  Future shutdown() {
    return Future.wait([analysisServer.shutdown()]);
  }

  @ApiMethod(method: 'GET', path: 'counter')
  Future<CounterResponse> counterGet({String name}) {
    return counter.getTotal(name).then((total) {
      return new CounterResponse(total);
    });
  }

  @ApiMethod(
      method: 'POST',
      path: 'analyze',
      description:
          'Analyze the given Dart source code and return any resulting '
          'analysis errors or warnings.')
  Future<AnalysisResults> analyze(SourceRequest request) {
    return _analyze(request.source);
  }

  @ApiMethod(
      method: 'POST',
      path: 'analyzeMulti',
      description:
          'Analyze the given Dart source code and return any resulting '
          'analysis errors or warnings.')
  Future<AnalysisResults> analyzeMulti(SourcesRequest request) {
    return _analyzeMulti(request.sources);
  }

  @ApiMethod(
      method: 'POST',
      path: 'summarize',
      description:
          'Summarize the given Dart source code and return any resulting '
          'analysis errors or warnings.')
  Future<SummaryText> summarize(SourcesRequest request) {
    return _summarize(request.sources['dart'], request.sources['css'],
        request.sources['html']);
  }

  @ApiMethod(method: 'GET', path: 'analyze')
  Future<AnalysisResults> analyzeGet({String source}) {
    return _analyze(source);
  }

  @ApiMethod(
      method: 'POST',
      path: 'compile',
      description: 'Compile the given Dart source code and return the '
          'resulting JavaScript.')
  Future<CompileResponse> compile(CompileRequest request) =>
      _compile(request.source,
          useCheckedMode: true,
          returnSourceMap: request.returnSourceMap ?? false);

  @ApiMethod(method: 'GET', path: 'compile')
  Future<CompileResponse> compileGet({String source}) => _compile(source);

  @ApiMethod(
      method: 'POST',
      path: 'complete',
      description:
          'Get the valid code completion results for the given offset.')
  Future<CompleteResponse> complete(SourceRequest request) {
    if (request.offset == null) {
      throw new BadRequestError('Missing parameter: \'offset\'');
    }

    return _complete(request.source, request.offset);
  }

  @ApiMethod(
      method: 'POST',
      path: 'completeMulti',
      description:
          'Get the valid code completion results for the given offset.')
  Future<CompleteResponse> completeMulti(SourcesRequest request) {
    if (request.location == null) {
      throw new BadRequestError('Missing parameter: \'location\'');
    }

    return _completeMulti(
        request.sources, request.location.sourceName, request.location.offset);
  }

  @ApiMethod(method: 'GET', path: 'complete')
  Future<CompleteResponse> completeGet({String source, int offset}) {
    if (source == null) {
      throw new BadRequestError('Missing parameter: \'source\'');
    }
    if (offset == null) {
      throw new BadRequestError('Missing parameter: \'offset\'');
    }

    return _complete(source, offset);
  }

  @ApiMethod(
      method: 'POST',
      path: 'fixes',
      description: 'Get any quick fixes for the given source code location.')
  Future<FixesResponse> fixes(SourceRequest request) {
    if (request.offset == null) {
      throw new BadRequestError('Missing parameter: \'offset\'');
    }

    return _fixes(request.source, request.offset);
  }

  @ApiMethod(
      method: 'POST',
      path: 'fixesMulti',
      description: 'Get any quick fixes for the given source code location.')
  Future<FixesResponse> fixesMulti(SourcesRequest request) {
    if (request.location.sourceName == null) {
      throw new BadRequestError('Missing parameter: \'fullName\'');
    }
    if (request.location.offset == null) {
      throw new BadRequestError('Missing parameter: \'offset\'');
    }

    return _fixesMulti(
        request.sources, request.location.sourceName, request.location.offset);
  }

  @ApiMethod(method: 'GET', path: 'fixes')
  Future<FixesResponse> fixesGet({String source, int offset}) {
    if (source == null) {
      throw new BadRequestError('Missing parameter: \'source\'');
    }
    if (offset == null) {
      throw new BadRequestError('Missing parameter: \'offset\'');
    }

    return _fixes(source, offset);
  }

  @ApiMethod(
      method: 'POST',
      path: 'format',
      description: 'Format the given Dart source code and return the results. '
          'If an offset is supplied in the request, the new position for that '
          'offset in the formatted code will be returned.')
  Future<FormatResponse> format(SourceRequest request) {
    return _format(request.source, offset: request.offset);
  }

  @ApiMethod(method: 'GET', path: 'format')
  Future<FormatResponse> formatGet({String source, int offset}) {
    if (source == null) {
      throw new BadRequestError('Missing parameter: \'source\'');
    }

    return _format(source, offset: offset);
  }

  @ApiMethod(
      method: 'POST',
      path: 'document',
      description: 'Return the relevant dartdoc information for the element at '
          'the given offset.')
  Future<DocumentResponse> document(SourceRequest request) {
    return _document(request.source, request.offset);
  }

  @ApiMethod(method: 'GET', path: 'document')
  Future<DocumentResponse> documentGet({String source, int offset}) {
    return _document(source, offset);
  }

  @ApiMethod(
      method: 'GET',
      path: 'version',
      description: 'Return the current SDK version for DartServices.')
  Future<VersionResponse> version() => new Future.value(_version());

  Future<AnalysisResults> _analyze(String source) async {
    if (source == null) {
      throw new BadRequestError('Missing parameter: \'source\'');
    }
    return _analyzeMulti({kMainDart: source});
  }

  Future<SummaryText> _summarize(String dart, String html, String css) async {
    if (dart == null || html == null || css == null) {
      throw new BadRequestError('Missing core source parameter.');
    }
    String sourcesJson =
        new JsonEncoder().convert({"dart": dart, "html": html, "css": css});
    log.info("About to summarize: ${_hashSource(sourcesJson)}");

    SummaryText summaryString =
        await _analyzeMulti({kMainDart: dart}).then((result) {
      Summarizer summarizer =
          new Summarizer(dart: dart, html: html, css: css, analysis: result);
      return new SummaryText.fromString(summarizer.returnAsSimpleSummary());
    });
    return new Future.value(summaryString);
  }

  Future<AnalysisResults> _analyzeMulti(Map<String, String> sources) async {
    if (sources == null) {
      throw new BadRequestError('Missing parameter: \'sources\'');
    }

    Stopwatch watch = new Stopwatch()..start();
    try {
      AnalysisServerWrapper server = analysisServer;
      AnalysisResults results = await server.analyzeMulti(sources);
      int lineCount = sources.values
          .map((s) => s.split('\n').length)
          .fold(0, (a, b) => a + b);
      int ms = watch.elapsedMilliseconds;
      log.info('PERF: Analyzed ${lineCount} lines of Dart in ${ms}ms.');
      counter.increment("Analyses");
      counter.increment("Analyzed-Lines", increment: lineCount);
      return results;
    } catch (e, st) {
      log.severe('Error during analyze', e, st);
      await restart();
      throw e;
    }
  }

  Future<CompileResponse> _compile(String source,
      {bool useCheckedMode: true, bool returnSourceMap: false}) async {
    if (source == null) {
      throw new BadRequestError('Missing parameter: \'source\'');
    }
    String sourceHash = _hashSource(source);

    // TODO(lukechurch): Remove this hack after
    // https://github.com/dart-lang/rpc/issues/15 lands
    var trimSrc = source.trim();
    bool suppressCache = trimSrc.endsWith("/** Supress-Memcache **/") ||
        trimSrc.endsWith("/** Suppress-Memcache **/");

    String memCacheKey = "%%COMPILE:v0:useCheckedMode:$useCheckedMode"
        "returnSourceMap:$returnSourceMap:"
        "source:$sourceHash";

    return checkCache(memCacheKey).then((dynamic result) {
      if (!suppressCache && result != null) {
        log.info("CACHE: Cache hit for compile");
        var resultObj = new JsonDecoder().convert(result);
        return new CompileResponse(resultObj["output"],
            returnSourceMap ? resultObj["sourceMap"] : null);
      } else {
        log.info("CACHE: MISS, forced: $suppressCache");
        Stopwatch watch = new Stopwatch()..start();

        return compiler
            .compile(source,
                useCheckedMode: useCheckedMode,
                returnSourceMap: returnSourceMap)
            .then((CompilationResults results) async {
          if (results.hasOutput) {
            int lineCount = source.split('\n').length;
            int outputSize = (results.getOutput().length + 512) ~/ 1024;
            int ms = watch.elapsedMilliseconds;
            log.info('PERF: Compiled ${lineCount} lines of Dart into '
                '${outputSize}kb of JavaScript in ${ms}ms.');
            counter.increment("Compilations");
            counter.increment("Compiled-Lines", increment: lineCount);
            String out = results.getOutput();
            String sourceMap = returnSourceMap ? results.getSourceMap() : null;

            String cachedResult = new JsonEncoder()
                .convert({"output": out, "sourceMap": sourceMap});
            await setCache(memCacheKey, cachedResult);
            return new CompileResponse(out, sourceMap);
          } else {
            List<CompilationProblem> problems = results.problems;
            String errors = problems.map(_printCompileProblem).join('\n');
            throw new BadRequestError(errors);
          }
        }).catchError((e, st) {
          log.severe('Error during compile: ${e}\n${st}');
          throw e;
        });
      }
    });
  }

  Future<DocumentResponse> _document(String source, int offset) async {
    if (source == null) {
      throw new BadRequestError('Missing parameter: \'source\'');
    }
    if (offset == null) {
      throw new BadRequestError('Missing parameter: \'offset\'');
    }
    Stopwatch watch = new Stopwatch()..start();
    try {
      Map<String, String> docInfo =
          await analysisServer.dartdoc(source, offset);
      docInfo ??= {};
      log.info('PERF: Computed dartdoc in ${watch.elapsedMilliseconds}ms.');
      counter.increment("DartDocs");
      return new DocumentResponse(docInfo);
    } catch (e, st) {
      log.severe('Error during dartdoc', e, st);
      await restart();
      rethrow;
    }
  }

  VersionResponse _version() => new VersionResponse(
      sdkVersion: SdkManager.sdk.version,
      sdkVersionFull: SdkManager.sdk.versionFull,
      runtimeVersion: vmVersion,
      servicesVersion: servicesVersion,
      appEngineVersion: container.version);

  Future<CompleteResponse> _complete(String source, int offset) async {
    if (source == null) {
      throw new BadRequestError('Missing parameter: \'source\'');
    }
    if (offset == null) {
      throw new BadRequestError('Missing parameter: \'offset\'');
    }

    return _completeMulti({kMainDart: source}, kMainDart, offset);
  }

  Future<CompleteResponse> _completeMulti(
      Map<String, String> sources, String sourceName, int offset) async {
    if (sources == null) {
      throw new BadRequestError('Missing parameter: \'source\'');
    }
    if (sourceName == null) {
      throw new BadRequestError('Missing parameter: \'name\'');
    }
    if (offset == null) {
      throw new BadRequestError('Missing parameter: \'offset\'');
    }

    Stopwatch watch = new Stopwatch()..start();
    counter.increment("Completions");
    try {
      var response = await analysisServer.completeMulti(
          sources,
          new Location()
            ..sourceName = sourceName
            ..offset = offset);
      log.info('PERF: Computed completions in ${watch.elapsedMilliseconds}ms.');
      return response;
    } catch (e, st) {
      log.severe('Error during _complete', e, st);
      await restart();
      rethrow;
    }
  }

  Future<FixesResponse> _fixes(String source, int offset) async {
    if (source == null) {
      throw new BadRequestError('Missing parameter: \'source\'');
    }
    if (offset == null) {
      throw new BadRequestError('Missing parameter: \'offset\'');
    }

    return _fixesMulti({kMainDart: source}, kMainDart, offset);
  }

  Future<FixesResponse> _fixesMulti(
      Map<String, String> sources, String sourceName, int offset) async {
    if (sources == null) {
      throw new BadRequestError('Missing parameter: \'sources\'');
    }
    if (offset == null) {
      throw new BadRequestError('Missing parameter: \'offset\'');
    }

    Stopwatch watch = new Stopwatch()..start();
    counter.increment("Fixes");
    var response = await analysisServer.getFixesMulti(
        sources,
        new Location()
          ..sourceName = sourceName
          ..offset = offset);
    log.info('PERF: Computed fixes in ${watch.elapsedMilliseconds}ms.');
    return response;
  }

  Future<FormatResponse> _format(String source, {int offset}) async {
    if (source == null) {
      throw new BadRequestError('Missing parameter: \'source\'');
    }
    offset ??= 0;

    Stopwatch watch = new Stopwatch()..start();
    counter.increment("Formats");

    var response = await analysisServer.format(source, offset);
    log.info('PERF: Computed format in ${watch.elapsedMilliseconds}ms.');
    return response;
  }

  Future<T> checkCache<T>(String query) => cache.get(query);

  Future<T> setCache<T>(String query, String result) =>
      cache.set(query, result, expiration: _standardExpiration);
}

String _printCompileProblem(CompilationProblem problem) => problem.message;

String _hashSource(String str) {
  return sha1.convert(str.codeUnits).toString();
}
