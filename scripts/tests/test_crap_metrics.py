import importlib.util
import json
import math
import shutil
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "crap_metrics.py"
SPEC = importlib.util.spec_from_file_location("crap_metrics", SCRIPT)
metrics = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(metrics)


class CrapMetricsTests(unittest.TestCase):
    def test_formula_and_known_boundary_values(self):
        self.assertEqual(metrics.crap_score(10, 0), 110)
        self.assertEqual(metrics.crap_score(10, 1), 10)
        self.assertEqual(metrics.crap_score(10, .5), 22.5)
        self.assertEqual(metrics.crap_score(1, 0), 2)

    def test_unknown_is_not_zero(self):
        self.assertIsNone(metrics.crap_score(29, None))
        self.assertEqual(metrics.method_coverage(None, {"line": 3}),
                         {"coverage": None, "granularity": "unknown", "approximation": False,
                          "reason": "覆盖率报告没有此文件"})

    def test_invalid_percent_nonfinite_and_complexity_rejected(self):
        for coverage in (50, 100, -1, math.nan, math.inf, True, "0.5"):
            with self.subTest(coverage=coverage), self.assertRaises(ValueError):
                metrics.crap_score(10, coverage)
        for complexity in (0, -2, 1.5, True):
            with self.subTest(complexity=complexity), self.assertRaises(ValueError):
                metrics.crap_score(complexity, .5)

    def test_file_coverage_only_requires_opt_in(self):
        file = {"lineCoverage": .95, "functions": []}
        declaration = {"line": 4, "modifier_line": 4}
        self.assertIsNone(metrics.method_coverage(file, declaration)["coverage"])
        approximate = metrics.method_coverage(file, declaration, True)
        self.assertTrue(approximate["approximation"])
        self.assertEqual(approximate["granularity"], "file_line")

    def test_method_mapping_excludes_default_arguments_and_closures(self):
        file = {"functions": [
            {"name": "A.f(_:)", "lineNumber": 5, "coveredLines": 2, "executableLines": 4, "lineCoverage": .5},
            {"name": "closure #1 in A.f(_:)", "lineNumber": 5, "coveredLines": 0, "executableLines": 1, "lineCoverage": 0},
            {"name": "default argument 0 of A.f(_:)", "lineNumber": 5, "coveredLines": 1, "executableLines": 1, "lineCoverage": 1},
        ]}
        result = metrics.method_coverage(file, {"line": 5, "modifier_line": 5})
        self.assertEqual(result["coverage"], .5)
        self.assertFalse(result["approximation"])

    def test_ambiguous_and_zero_executable_lines_unknown(self):
        function = {"name": "A.f()", "lineNumber": 5, "coveredLines": 0, "executableLines": 0, "lineCoverage": 0}
        self.assertIsNone(metrics.method_coverage({"functions": [function]}, {"line": 5, "modifier_line": 5})["coverage"])
        function = dict(function, coveredLines=2, executableLines=2, lineCoverage=1)
        self.assertIsNone(metrics.method_coverage({"functions": [function, function]}, {"line": 5, "modifier_line": 5}, True)["coverage"])

    def test_inconsistent_coverage_rejected(self):
        file = {"functions": [{"name": "A.f()", "lineNumber": 5, "coveredLines": 1, "executableLines": 4, "lineCoverage": .99}]}
        with self.assertRaises(ValueError):
            metrics.method_coverage(file, {"line": 5, "modifier_line": 5})

    def test_multiline_function_coverage_starts_on_body(self):
        function = {"name": "A.f(_:)", "lineNumber": 8, "coveredLines": 2, "executableLines": 4, "lineCoverage": .5}
        result = metrics.method_coverage({"functions": [function]}, {"line": 5, "modifier_line": 5, "body_line": 8})
        self.assertEqual(result["coverage"], .5)

    def test_missing_method_ratio_stays_unknown(self):
        function = {"name": "A.f()", "lineNumber": 5, "coveredLines": 2, "executableLines": 4}
        self.assertIsNone(metrics.method_coverage({"functions": [function]}, {"line": 5, "modifier_line": 5})["coverage"])

    def test_nested_types_multiline_raw_strings_comments_and_overloads(self):
        source = '''struct Outer {
    let text = #"a } func invented() {"#
    /* nested /* class Fake { */ comment } */
    struct Inner {
        static
        func f(_ x: Int, label y: (Int, Int)) { if x > 0 {} }
        func f(value: String) { let x = """\n} func fake() {}\n""" }
        init(value: String = "}") {}
    }
}
extension Outer { func other() {} }
'''
        result = metrics.declarations(source)
        self.assertEqual([item["name"] for item in result],
                         ["Outer.Inner.f(_:label:)", "Outer.Inner.f(value:)", "Outer.Inner.init(value:)", "Outer.other()"])
        self.assertEqual(result[0]["modifier_line"], 5)
        self.assertEqual(result[0]["line"], 6)

    def test_static_modifier_on_same_line_and_column(self):
        result = metrics.declarations("struct A {\n    static func f() {}\n    static func g() {}\n}\n")
        self.assertEqual(result[0]["modifier_line"], 2)
        self.assertEqual(result[1]["modifier_line"], 3)
        self.assertEqual(result[1]["lint_column"], 5)

    def test_protocol_declaration_does_not_absorb_next_body(self):
        result = metrics.declarations("protocol P { func f()\n func g() }\n struct A { func f() {} }")
        self.assertEqual([item["name"] for item in result], ["A.f()"])

    def test_exclusions_and_generated_file_detection(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for name, text in (("codexBar/A.swift", "func f() {}"), ("codexBar/ThirdParty/B.swift", "func g() {}"),
                               ("DerivedData/C.swift", "func h() {}"), ("codexBar/D.swift", "// Generated by a tool\nfunc f() {}")):
                file = root / name
                file.parent.mkdir(parents=True, exist_ok=True)
                file.write_text(text)
            self.assertEqual([file.name for file in metrics.sources(root, [root], metrics.DEFAULT_EXCLUDES)], ["A.swift"])

    def test_coverage_target_must_be_unambiguous_and_present(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            file = root / "coverage.json"
            data = {"targets": [{"name": "app", "files": [{"path": str(root / "A.swift")}]},
                                {"name": "tests", "files": [{"path": str(root / "A.swift")}] }]}
            file.write_text(json.dumps(data))
            with self.assertRaises(ValueError):
                metrics.load_coverage(file, None, root)
            with self.assertRaises(ValueError):
                metrics.load_coverage(file, "missing", root)
            index, metadata = metrics.load_coverage(file, "tests", root)
            self.assertIn(str((root / "A.swift").resolve()), index)
            self.assertEqual(metadata["target"], "tests")

    def test_summary_filter_keeps_unknown_explicit(self):
        args = metrics.parse_args(["--output", "/tmp/metrics.json", "--top", "1", "--min-complexity", "10"])
        report = {"method_count": 1, "source_file_count": 1, "coverage_counts": {"unknown": 1},
                  "methods": [{"method": "A.f()", "file": "A.swift", "line": 4, "complexity": 20,
                               "coverage": None, "approximation": False, "crap": None}]}
        self.assertIn("unknown", metrics.summary(report, args))
        args.include_unknown = False
        self.assertNotIn("A.f()", metrics.summary(report, args))

    def test_protected_auth_and_configuration_paths_rejected_without_reading(self):
        for option, path in (("--coverage-report", "/test-home/.codex/auth.json"),
                             ("--output", "/test-home/.codexbar/config.json")):
            arguments = ["--output", "/tmp/metrics.json", option, path]
            with self.subTest(option=option), self.assertRaises(ValueError):
                metrics.validate_report_paths(metrics.parse_args(arguments), Path("/test-home"))

    def test_output_must_not_overwrite_measurement_input(self):
        args = metrics.parse_args(["--output", "/tmp/coverage.json", "--coverage-report", "/tmp/coverage.json"])
        with self.assertRaises(ValueError):
            metrics.validate_report_paths(args)

    @unittest.skipUnless(shutil.which("swiftlint"), "需要已有的 SwiftLint，不自动安装")
    def test_real_swiftlint_base_path_and_nested_function_behavior(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "A.swift"
            source.write_text("struct A {\nfunc straight() {}\nfunc branch(_ x: Bool) { if x {} }\nfunc nested() { func inner() { if true {} } }\n}\n")
            result = metrics.lint_metrics([source], root, "swiftlint")
            increments = {item["line"]: int(item["reason"].split("currently complexity is ")[1]) for item in result}
            self.assertEqual(increments[2], 0)
            self.assertEqual(increments[3], 1)
            # 两个同一行声明仍能看出父函数不包含 inner 的分支；评估器拒绝关联歧义。
            self.assertEqual(sorted(int(item["reason"].split("currently complexity is ")[1]) for item in result if item["line"] == 4), [0, 1])


if __name__ == "__main__":
    unittest.main()
