// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/**
 * This tool drives the services API with a large number of files and fuzz
 * test variations. This should be run over all of the co19 tests in the SDK
 * prior to each deployment of the server.
 */
library services.fuzz_driver;

import 'dart:async';
import 'dart:io' as io;
import 'dart:math';

bool _VERBOSE = false;
bool _DUMP_SRC = false;
bool _DUMP_PERF = false;
bool _DUMP_DELTA = false;

var random = new Random(0);
var maxMutations = 2;
var iterations = 5;
String resultsPath;

String SDK_BASE_PATH = io.Platform.environment["HOME"] + "/GitRepos/dart-sdk/sdk";

int lastOffset;

Future main(List<String> args) async {
  if (args.length == 0) {
    print('''
Usage: fasta_test 
    path_to_test_collection
    path_to_results
    [seed = 0]
    [mutations per iteration = 2]
    [iterations = 5]''');

    io.exit(1);
  }

  int seed = 0;
  String testCollectionRoot = args[0];
  resultsPath = args[1];
  if (args.length >= 3) seed = int.parse(args[2]);
  if (args.length >= 4) maxMutations = int.parse(args[3]);
  if (args.length >= 5) iterations = int.parse(args[4]);

  // Load the list of files.
  var fileEntities = [];
  if (io.FileSystemEntity.isDirectorySync(testCollectionRoot)) {
    io.Directory dir = new io.Directory(testCollectionRoot);
    fileEntities = dir.listSync(recursive: true);
  } else {
    fileEntities = [new io.File(testCollectionRoot)];
  }

  int counter = 0;
  Stopwatch sw = new Stopwatch()..start();

  // Main testing loop.
  for (var fse in fileEntities) {
    counter++;
    if (!fse.path.endsWith('.dart')) continue;

    try {
      print("Seed: $seed, "
          "${((counter/fileEntities.length)*100).toStringAsFixed(2)}%, "
          "Elapsed: ${sw.elapsed}");

      random = new Random(seed);
      seed++;
      await testPath(fse.path);
    } catch (e) {
      print(e);
      print("FAILED: ${fse.path}");
    }
  }

  print ("Shutting down");
}


Future testPath(
    String path) async {
  var f = new io.File(path);
  String src = f.readAsStringSync();
  print('Path, iteration, Compilation/ms');

  for (int i = 0; i < iterations; i++) {
    // Run once for each file without mutation.

    Stopwatch sw = new Stopwatch()..start();

    var result = io.Process.runSync("$SDK_BASE_PATH/pkg/front_end/tool/fasta", 
      ["compile", "--platform=$SDK_BASE_PATH/out/ReleaseX64/patched_sdk/platform.dill", path]);
    
    print ("$path, $i, ${sw.elapsedMilliseconds}");
    String id = path.split("/").last.split(".").first.split("-").first;
    sw.reset();

    if (result.stderr != null && result.stderr != "") {
      print ("==== FAIL: $path");
      new io.File("$resultsPath/$id.dart").writeAsStringSync(src);
      new io.File("$resultsPath/$id.md").writeAsStringSync(
        """
@peter-ahe-google
ID: $id
```
${result.stderr}
```
        """
      );
      break; 
   
    }

    if (maxMutations == 0) break;

    // And then for the remainder with an increasing mutated file.
    int noChanges = random.nextInt(maxMutations);

    for (int j = 0; j < noChanges; j++) {
      src = mutate(src);
    }
  }
}

Future withTimeOut(Future f) {
  return f.timeout(new Duration(seconds: 30));
}

String mutate(String src) {
  var chars = [
    "{",
    "}",
    "[",
    "]",
    "'",
    ",",
    "!",
    "@",
    "#",
    "\$",
    "%",
    "^",
    "&",
    " ",
    "(",
    ")",
    "null ",
    "class ",
    "for ",
    "void ",
    "var ",
    "dynamic ",
    ";",
    "as ",
    "is ",
    ".",
    "import "
  ];
  String s = chars[random.nextInt(chars.length)];
  int i = random.nextInt(src.length);
  if (i == 0) i = 1;

  if (_DUMP_DELTA) {
    log("Delta: $s");
  }
  String newStr = src.substring(0, i - 1) + s + src.substring(i);
  return newStr;
}

final int termWidth = io.stdout.hasTerminal ? io.stdout.terminalColumns : 200;

void log(dynamic obj) {
  if (_VERBOSE) {
    print("${new DateTime.now()} $obj");
  }
}
