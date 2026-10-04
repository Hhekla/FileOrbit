#!/usr/bin/env python3
"""Discover Swift tests using Swift's parser, then run their unchanged bodies.

This intentionally supports only the repository's zero-argument XCTestCase methods
and assertion APIs implemented by StandaloneTestSupport.swift. An unsupported test,
unknown XCTest API, compilation error, failed assertion, or skip cannot produce a
successful exit. Test fixture cleanup is rejected instead of silently rewritten.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys


def fail(message):
    raise RuntimeError(message)


def core_snapshot(root):
    files = sorted((root / "Sources/KumquatCore").rglob("*.swift")) + [root / "Package.swift"]
    return {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest() for path in files}


def discover(source, swiftc):
    parsed = subprocess.run([swiftc, "-frontend", "-dump-parse", str(source)],
                            capture_output=True, text=True)
    if parsed.returncode:
        fail(f"Swift parser rejected {source}:\n{parsed.stderr}")
    # Swift versions differ on which stream they use for the AST.
    ast = parsed.stdout + parsed.stderr
    current = None
    cases = []
    for line in ast.splitlines():
        class_match = re.match(r'^(\s*)\(class_decl range=\[.*?\] "([^"]+)"', line)
        if class_match:
            current = (class_match[2], len(class_match[1]))
        method = re.match(r'^(\s*)\(func_decl range=\[.*?\] "(test[^"(]*)(\([^"]*\))"', line)
        if not method:
            continue
        if current is None or current[1] != 2 or len(method[1]) != 4 or method[3] != "()":
            fail(f"Unsupported test structure in {source}: {line.strip()}. Nothing is silently skipped.")
        cases.append((current[0], method[2]))
    if not cases and re.search(r"\bXCTestCase\b", source.read_text()):
        fail(f"No test methods discovered in XCTestCase file {source}; inspect parser compatibility.")
    return cases


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bin-dir", type=Path)
    parser.add_argument("--run-dir", type=Path)
    parser.add_argument("--core-manifest", type=Path)
    parser.add_argument("--snapshot-core", type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    if args.snapshot_core:
        args.snapshot_core.write_text(json.dumps(core_snapshot(root), indent=2) + "\n")
        return 0
    if not args.bin_dir or not args.run_dir:
        parser.error("--bin-dir and --run-dir are required when running tests")
    expected_core = json.loads(args.core_manifest.read_text()) if args.core_manifest else core_snapshot(root)
    if core_snapshot(root) != expected_core:
        fail("Core source changed while building. Rerun against a stable source snapshot.")
    run_dir = args.run_dir.resolve()
    run_dir.mkdir(parents=True, exist_ok=True)
    swiftc = os.environ.get("SWIFTC", "swiftc")
    test_files = sorted((root / "Tests").rglob("*.swift"))
    if not test_files:
        fail("No test source files found.")
    support = root / "scripts/StandaloneTestSupport.swift"
    supported = set(re.findall(r"\b(?:func|class|struct)\s+(XCT\w+)", support.read_text())) | {"XCTest"}
    generated = []
    all_cases = []
    manifest = {"adapter": str(support.relative_to(root)), "files": [], "tests": [], "core_sha256": expected_core}
    source_hashes = {}
    for index, source in enumerate(test_files):
        text = source.read_text()
        digest = hashlib.sha256(source.read_bytes()).hexdigest()
        source_hashes[source] = digest
        unknown = sorted(set(re.findall(r"\bXCT\w+\b", text)) - supported)
        if unknown:
            fail(f"Unsupported XCTest APIs in {source}: {', '.join(unknown)}")
        if re.search(r"\b(?:removeItem|unlink|rmdir)\s*\(", text):
            fail(f"{source} deletes fixtures. Remove its cleanup explicitly before using this retained-fixture runner.")
        cases = discover(source, swiftc)
        # Keep every test body and line number. Only XCTest import is replaced by the
        # assertion adapter. Separate Swift files preserve private helper scoping.
        # XCTest re-exports Foundation. Keep that import visible per source file so
        # tests that use Data/URL without an explicit Foundation import still compile.
        transformed = re.sub(r"(?m)^[ \t]*import XCTest[ \t]*$",
                             "import Foundation // Assertions: StandaloneTestSupport.swift", text)
        target = run_dir / f"Tests{index:03d}-{source.name}"
        target.write_text(f"#sourceLocation(file: {json.dumps(str(source))}, line: 1)\n" + transformed)
        generated.append(target)
        manifest["files"].append({"path": str(source.relative_to(root)), "sha256": digest,
                                  "discovered_tests": len(cases)})
        all_cases.extend(cases)
    names = [f"{suite}.{method}" for suite, method in all_cases]
    if not names or len(set(names)) != len(names):
        fail("No tests or duplicate test names found; refusing an ambiguous run.")
    manifest["tests"] = names
    (run_dir / "discovery.json").write_text(json.dumps(manifest, indent=2) + "\n")
    runner = ["import Foundation", "@main struct StandaloneTestRunner {",
              "  @MainActor static func main() async {", "    let results = StandaloneResults.shared"]
    for suite, method in all_cases:
        name = f"{suite}.{method}"
        runner += [f"    await results.run({json.dumps(name)}, create: {{ {suite}() }}) {{ instance in",
                   f"      try await (instance as! {suite}).{method}()", "    }"]
    runner += [f"    exit(results.finish(expected: {len(names)}))", "  }", "}"]
    main_file = run_dir / "StandaloneTestRunner.swift"
    main_file.write_text("\n".join(runner) + "\n")
    objects = sorted((args.bin_dir / "KumquatCore.build").glob("*.o"))
    if not objects or not (args.bin_dir / "Modules/KumquatCore.swiftmodule").exists():
        fail(f"No compiled, testable KumquatCore objects/module in {args.bin_dir}")
    executable = run_dir / "StandaloneCoreTests"
    command = [swiftc, "-parse-as-library", "-I", str(args.bin_dir / "Modules"), str(support)]
    command += [str(path) for path in generated] + [str(main_file)]
    command += [str(path) for path in objects] + ["-o", str(executable)]
    (run_dir / "compile-command.json").write_text(json.dumps(command, indent=2) + "\n")
    print(f"Discovered {len(names)} tests from {len(test_files)} source files. No test filtering.", flush=True)
    print(f"Discovery manifest: {run_dir / 'discovery.json'}", flush=True)
    with (run_dir / "compile.log").open("w") as log:
        result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
    if result.returncode:
        print((run_dir / "compile.log").read_text(), file=sys.stderr)
        return result.returncode
    for source, expected in source_hashes.items():
        if hashlib.sha256(source.read_bytes()).hexdigest() != expected:
            fail(f"Test source changed while compiling: {source}. Rerun to verify a consistent snapshot.")
    if core_snapshot(root) != expected_core:
        fail("Core source changed while compiling tests. Rerun against a stable snapshot.")
    if sorted((root / "Tests").rglob("*.swift")) != test_files:
        fail("Test source inventory changed while compiling. Rerun so all tests are discovered.")
    with (run_dir / "results.log").open("w") as log:
        process = subprocess.Popen([str(executable)], stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, text=True)
        for line in process.stdout:
            sys.stdout.write(line)
            log.write(line)
            log.flush()
        status = process.wait()
    if core_snapshot(root) != expected_core or sorted((root / "Tests").rglob("*.swift")) != test_files or any(
        hashlib.sha256(source.read_bytes()).hexdigest() != digest for source, digest in source_hashes.items()
    ):
        fail("Source changed during test execution. Artifacts remain available, but this is not verification of the current source.")
    print(f"Exit status: {status}. All artifacts retained at {run_dir}", flush=True)
    return status if status >= 0 else 128 - status


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuntimeError, OSError, subprocess.SubprocessError) as error:
        print(f"VERIFICATION ERROR: {error}", file=sys.stderr)
        sys.exit(1)
