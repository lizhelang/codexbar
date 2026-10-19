#!/usr/bin/env python3
"""只读评估 Swift 方法的 CRAP；仅写指定报告，不运行 App 或读取用户认证。"""

import argparse
import bisect
import fnmatch
import hashlib
import json
import math
import re
import subprocess
import tempfile
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path


DEFAULT_EXCLUDES = (
    "build", "DerivedData", "dist", "release", ".build", "ThirdParty", "Pods",
    "Carthage", "vendor", "node_modules", ".git", ".codex", ".omx", ".ufoo",
    "probes", "experiments", "generated", "codexBarTests", "Tests", "fixtures",
)
FORMULA = "complexity ** 2 * (1 - coverage) ** 3 + complexity"


def crap_score(complexity, coverage):
    if not isinstance(complexity, int) or isinstance(complexity, bool) or complexity < 1:
        raise ValueError("复杂度必须是正整数")
    if coverage is None:
        return None
    if isinstance(coverage, bool) or not isinstance(coverage, (float, int)):
        raise ValueError("覆盖率必须是 0..1 的数值")
    if not math.isfinite(coverage) or not 0 <= coverage <= 1:
        raise ValueError("覆盖率必须是 0..1 的数值，不能使用百分数 50/100")
    return complexity ** 2 * (1 - coverage) ** 3 + complexity


def run(args, cwd=None):
    result = subprocess.run(args, cwd=cwd, text=True, capture_output=True)
    if result.returncode:
        # 不回显子进程日志，避免意外输出认证资料或源码中的字符串。
        raise ValueError("命令失败（退出码 %d）：%s" % (result.returncode, args[0]))
    return result.stdout


def excluded(path, patterns):
    return any(pattern in path.parts or fnmatch.fnmatch(path.as_posix(), pattern)
               for pattern in patterns)


def sources(project, roots, patterns):
    result = []
    for root in roots:
        for path in root.rglob("*.swift"):
            if path.is_symlink() or not path.is_file():
                continue
            relative = path.relative_to(project)
            if excluded(relative, patterns) or path.name.endswith(".generated.swift"):
                continue
            text = path.read_text(encoding="utf-8")
            if re.search(r"(?im)^\s*//.*(?:auto[- ]generated|generated (?:by|file)|do not edit)", text[:1000]):
                continue
            result.append(path)
    return sorted(set(result))


def mask_swift(text):
    """遮蔽注释和普通/raw/多行字符串，保持字符位置与行号；不计字符串插值。"""
    chars = list(text)
    i = 0
    while i < len(text):
        start = i
        if text.startswith("//", i):
            end = text.find("\n", i)
            i = len(text) if end < 0 else end
        elif text.startswith("/*", i):
            i += 2
            depth = 1
            while i < len(text) and depth:
                if text.startswith("/*", i):
                    depth += 1
                    i += 2
                elif text.startswith("*/", i):
                    depth -= 1
                    i += 2
                else:
                    i += 1
        else:
            opening = re.match(r'(#*)("""|")', text[i:]) if text[i] in '#"' else None
            if not opening:
                i += 1
                continue
            hashes, quote = opening.groups()
            delimiter = quote + hashes
            i += len(opening.group())
            while i < len(text):
                if text.startswith("\\" + hashes, i):
                    i += 2 + len(hashes)
                elif text.startswith(delimiter, i):
                    i += len(delimiter)
                    break
                else:
                    i += 1
        for position in range(start, min(i, len(text))):
            if chars[position] != "\n":
                chars[position] = " "
    return "".join(chars)


def brace_pairs(masked):
    stack, pairs = [], {}
    for match in re.finditer(r"[{}]", masked):
        if match.group() == "{":
            stack.append(match.start())
        elif stack:
            pairs[stack.pop()] = match.start()
    return pairs


def declarations(text):
    """声明名称辅助解析；复杂度完全来自 SwiftLint，不由这里估算。"""
    masked = mask_swift(text)
    pairs = brace_pairs(masked)
    line_starts = [0] + [match.end() for match in re.finditer("\n", masked)]
    types = []
    for match in re.finditer(r"\b(?:struct|enum|class|actor|extension)\s+(?!func\b)([\w.]+)", masked):
        opening = masked.find("{", match.end())
        if opening in pairs:
            types.append((opening, pairs[opening], match.group(1)))
    result = []
    for match in re.finditer(r"\b(func\s+([\w`]+|[+*/!=<>?&|^-]+)|init[?!]?)\s*(?:<[^{}]*?>)?\s*\(", masked):
        opening = match.end() - 1
        depth, end = 1, opening + 1
        while end < len(masked) and depth:
            if masked[end] == "(":
                depth += 1
            elif masked[end] == ")":
                depth -= 1
            end += 1
        if depth:
            continue
        body = masked.find("{", end)
        # 无函数体的 protocol 声明不能吸收后面声明的函数体。
        following = re.search(r"\b(?:func|init|var|let|struct|class|enum)\b|[;}]", masked[end:body])
        if body not in pairs or following:
            continue
        parameters = masked[opening + 1:end - 1]
        labels, nesting, start = [], 0, 0
        for pos, char in enumerate(parameters + ","):
            if char in "([{<":
                nesting += 1
            elif char in ")]}>":
                nesting = max(0, nesting - 1)
            elif char == "," and nesting == 0:
                label = re.match(r"\s*(?:@\w+\s+)*([\w`]+)\s*(?:[\w`]+\s*)?:", parameters[start:pos])
                if label:
                    labels.append(label.group(1).strip("`") + ":")
                start = pos + 1
        owner = ".".join(t[2] for t in sorted(types) if t[0] < match.start() < t[1])
        name = match.group(2) or "init"
        line = bisect.bisect_right(line_starts, match.start())
        # SwiftLint 的 static/class modifier 可能在 func 前一行。
        prefix = masked[line_starts[max(0, line - 2)]:match.start()]
        modifier = re.search(r"\b(?:static|class)\s*$", prefix)
        lint_offset = line_starts[max(0, line - 2)] + modifier.start() if modifier else match.start()
        static_line = bisect.bisect_right(line_starts, lint_offset)
        result.append({"name": (owner + "." if owner else "") + name.strip("`") + "(" + "".join(labels) + ")",
                       "line": line, "modifier_line": static_line,
                       "lint_column": lint_offset - line_starts[static_line - 1] + 1,
                       "body_line": bisect.bisect_right(line_starts, body),
                       "end_line": bisect.bisect_right(line_starts, pairs[body])})
    return result


def lint_metrics(paths, project, swiftlint):
    with tempfile.TemporaryDirectory(prefix="codexbar-crap-lint-") as tmp:
        config = Path(tmp) / "metrics.yml"
        config.write_text("only_rules: [cyclomatic_complexity]\ncyclomatic_complexity:\n  warning: -1\n  error: 100000\n  ignores_case_statements: false\n", encoding="utf-8")
        output = run([swiftlint, "lint", "--config", str(config), "--reporter", "json",
                      "--quiet", "--no-cache", *map(str, paths)], cwd=project)
    metrics = json.loads(output)
    if not isinstance(metrics, list):
        raise ValueError("SwiftLint JSON 格式错误")
    return metrics


def load_coverage(path, target, project):
    if path is None:
        return {}, {"status": "unknown", "reason": "未提供覆盖率报告"}
    if path.suffix in (".xcresult", ".xccovreport"):
        arguments = ["xcrun", "xccov", "view", "--json"]
        if path.suffix == ".xcresult":
            arguments.append("--report")
        data = json.loads(run(arguments + [str(path)]))
    else:
        data = json.loads(path.read_text(encoding="utf-8"))
    targets = data.get("targets", [])
    selected = [item for item in targets if target is None or item.get("name") == target]
    if not selected:
        raise ValueError("覆盖率报告中找不到指定 target；不能把缺失覆盖率当作 0")
    index = {}
    for item in selected:
        for file in item.get("files", []):
            raw_path = Path(file["path"])
            file_path = raw_path if raw_path.is_absolute() else project / raw_path
            key = str(file_path.resolve())
            if key in index:
                raise ValueError("多个 target 含同一个源码文件；请明确 --coverage-target")
            index[key] = file
    return index, {"status": "provided", "source": str(path), "target": target,
                   "format": "xccov", "granularity": "function line coverage",
                   "branch_coverage": False,
                   "limits": "不代表条件/失败路径、独立 closure、真实 OAuth 或 macOS 系统验收"}


def method_coverage(file, declaration, allow_approximation=False):
    if file is None:
        return {"coverage": None, "granularity": "unknown", "approximation": False,
                "reason": "覆盖率报告没有此文件"}
    candidates = []
    for function in file.get("functions", []):
        if function.get("lineNumber") not in range(declaration["modifier_line"], declaration.get("body_line", declaration["line"]) + 1):
            continue
        name = function.get("name", "")
        if re.search(r"(?i)closure|default argument|implicit|getter|setter", name):
            continue
        candidates.append(function)
    if len(candidates) == 1:
        candidate = candidates[0]
        covered, executable = candidate.get("coveredLines"), candidate.get("executableLines")
        if not isinstance(executable, int) or executable <= 0:
            return {"coverage": None, "granularity": "unknown", "approximation": False,
                    "reason": "方法没有可执行行覆盖数据"}
        ratio = candidate.get("lineCoverage")
        if ratio is None:
            return {"coverage": None, "granularity": "unknown", "approximation": False,
                    "reason": "方法行覆盖率字段缺失"}
        crap_score(1, ratio)
        if not isinstance(covered, int) or not 0 <= covered <= executable or not math.isclose(ratio, covered / executable, abs_tol=1e-7):
            raise ValueError("方法覆盖率与 coveredLines/executableLines 不一致")
        return {"coverage": ratio, "granularity": "method_line", "approximation": False,
                "covered_lines": covered, "executable_lines": executable,
                "coverage_function": candidate.get("name"), "reason": None}
    if not candidates and allow_approximation and file.get("lineCoverage") is not None:
        crap_score(1, file["lineCoverage"])
        return {"coverage": file["lineCoverage"], "granularity": "file_line",
                "approximation": True, "reason": "没有方法数据，显式允许文件级近似"}
    return {"coverage": None, "granularity": "unknown", "approximation": False,
            "reason": "多个同一行方法/closure，无法无歧义关联" if candidates else "找不到此声明的方法级覆盖率；未使用文件级猜测"}


def module_for(path):
    name = path.stem
    if path.parts[0] in ("scripts", "codexBarTests"):
        return "tests_and_scripts"
    if "Views" in path.parts or name.startswith(("MenuBar", "Settings", "UsageDashboard")):
        return "menu_ui"
    if "Callback" in name:
        return "localhost_callback"
    if any(part in name for part in ("OAuth", "Login", "ProfileService")):
        return "oauth_import_refresh"
    if any(part in name for part in ("Config", "TokenStore", "CodexSync", "SessionLog", "LocalCost", "IndexStore", "CodexPaths")):
        return "config_persistence_migration"
    if any(part in name for part in ("Gateway", "Wham", "Quota", "Usage", "Translator", "Account", "Collector")):
        return "api_quota_account_status"
    return "macos_and_support"


def test_inventory(project):
    result = []
    directory = project / "codexBarTests"
    if not directory.is_dir():
        return result
    for file in directory.glob("*.swift"):
        text = file.read_text(encoding="utf-8")
        masked = mask_swift(text)
        result.append((file, masked, {"file": str(file.relative_to(project)),
                                      "declared_tests": len(re.findall(r"\bfunc\s+test\w*\s*\(", masked)),
                                      "has_error_or_regression_named_tests": bool(re.search(r"func\s+test\w*(?:Fail|Error|Reject|Invalid|Rollback|Regress|Migrat|Cancel)", masked))}))
    return result


def related_tests(source, inventory):
    pattern = re.compile(r"\b" + re.escape(source.stem) + r"\b")
    return [metadata for file, text, metadata in inventory if source.stem in file.stem or pattern.search(text)]


def file_changes(project, source, days):
    result = subprocess.run(["git", "log", "--since=%d.days.ago" % days, "--format=%H", "--", str(source.relative_to(project))], cwd=project, text=True, capture_output=True)
    return len(result.stdout.splitlines()) if result.returncode == 0 else None


def risk(complexity, coverage, sensitive, module, thresholds):
    score = crap_score(complexity, coverage["coverage"])
    if score is None:
        band, explanation = "unknown", "覆盖率未知，无法计算 CRAP；优先核查高复杂度候选"
    else:
        band = ("lower", "attention", "review", "high_priority")[sum(score >= value for value in thresholds)]
        if complexity >= 10:
            explanation = "高复杂度 + 低行覆盖率" if coverage["coverage"] < .5 else "高复杂度 + 较高行覆盖率，仍需失败/条件路径证据"
        else:
            explanation = "低复杂度，行覆盖率不足" if coverage["coverage"] < .5 else "较低复杂度且已有行覆盖证据"
    notes = [explanation, "行覆盖不证明所有条件、happy path 之外的行为或 mock 的真实性"]
    if sensitive:
        notes.append("认证/配置/凭据边界需要独立审查，风险不能仅由 CRAP 决定")
    if module in ("oauth_import_refresh", "localhost_callback", "api_quota_account_status", "menu_ui", "macos_and_support"):
        notes.append("网络、localhost 或 macOS 适配需要相应集成证据，普通单元测试不足以验收")
    if coverage["approximation"]:
        notes.append("文件级 approximation 可能掩盖未测试方法，不与方法级结果混排")
    return score, band, notes


def evaluate(args):
    project = args.project.resolve()
    roots = [(project / directory).resolve() for directory in args.source_dir] if args.source_dir else [project / "codexBar" if (project / "codexBar").is_dir() else project]
    if not project.is_dir() or any(not root.is_dir() or not root.is_relative_to(project) for root in roots):
        raise ValueError("项目/源码目录不存在或不属于指定项目")
    paths = sources(project, roots, DEFAULT_EXCLUDES + tuple(args.exclude))
    if not paths:
        raise ValueError("没有可评估的非生成 Swift 源码")
    coverage, coverage_meta = load_coverage(args.coverage_report, args.coverage_target, project)
    raw = lint_metrics(paths, project, args.swiftlint)
    inventory = test_inventory(project)
    path_set = {str(path): path for path in paths}
    cache, metrics = {}, []
    for item in raw:
        if item.get("rule_id") != "cyclomatic_complexity":
            continue
        path = path_set.get(str(Path(item["file"]).resolve()))
        if path is None:
            continue
        if path not in cache:
            text = path.read_text(encoding="utf-8")
            sensitive = any(part in path.stem for part in ("OAuth", "Login", "Callback", "TokenStore", "CodexSync", "CodexPaths", "ConfigStore", "AccountCSV", "Gateway", "ProfileService", "DeviceUsage")) or bool(re.search(r"\b(?:accessToken|refreshToken|idToken|apiKey|pairingSecret)\b", mask_swift(text)))
            cache[path] = (declarations(text), related_tests(path, inventory), file_changes(project, path, args.churn_days), text, sensitive)
        decls, tests, changes, text, sensitive = cache[path]
        line = item["line"]
        matches = [decl for decl in decls if decl["modifier_line"] == line and decl["lint_column"] == item["character"]]
        if len(matches) != 1:
            raise ValueError("无法唯一解析方法声明：%s:%s" % (path.relative_to(project), line))
        decl = matches[0]
        branch_match = re.search(r"currently complexity is (\d+)", item["reason"])
        if not branch_match:
            raise ValueError("无法解析 SwiftLint 复杂度；请检查工具版本")
        branches = int(branch_match.group(1))
        complexity = branches + 1
        relative = path.relative_to(project)
        module = module_for(relative)
        method_cov = method_coverage(coverage.get(str(path)), decl, args.include_approximation)
        score, band, notes = risk(complexity, method_cov, sensitive, module, args.thresholds)
        dependencies = []
        for name, pattern in (("macOS", r"import (?:AppKit|SwiftUI|Darwin|Security)|NSWorkspace|NSRunningApplication"), ("network", r"URLSession|URLRequest|NWConnection|WebSocket"), ("localhost", r"Listener|AF_INET|sockaddr|Localhost"), ("filesystem", r"FileManager|Data\(contentsOf|SQLite|sqlite3_")):
            if re.search(pattern, text):
                dependencies.append(name)
        metrics.append({"method": method_cov.get("coverage_function", decl["name"]), "declared_method": decl["name"], "file": str(relative), "line": decl["line"], "end_line": decl["end_line"],
                        "module": module, "complexity": complexity, "swiftlint_branch_increment": branches,
                        **method_cov, "crap": score, "risk_band": band,
                        "method_test_count": None, "related_declared_test_count": sum(test["declared_tests"] for test in tests),
                        "test_attribution": "file reference heuristic; unknown at method level", "related_tests": tests,
                        "core_oauth_path": module in ("oauth_import_refresh", "localhost_callback"),
                        "core_account_status_path": module == "api_quota_account_status" or path.stem == "TokenStore",
                        "core_menu_interaction_path": module == "menu_ui", "sensitive_boundary": sensitive,
                        "boundary_classification": "file-name heuristic; requires manual confirmation",
                        "file_commits_in_window": changes, "churn_days": args.churn_days,
                        "frequently_changed_file": changes >= args.frequent_change_count if changes is not None else None,
                        "method_change_frequency": None, "historical_defects": "unknown; not inferred from coverage or commit titles",
                        "dependencies": dependencies, "dependency_granularity": "file-level heuristic",
                        "risk_explanation": notes})
    if not metrics:
        raise ValueError("SwiftLint 没有返回方法指标，请检查工具与配置")
    metrics.sort(key=lambda method: (method["crap"] is None, method["approximation"], -(method["crap"] or 0), -method["complexity"], method["file"], method["line"]))
    commit = subprocess.run(["git", "rev-parse", "HEAD"], cwd=project, text=True, capture_output=True)
    execution = {"status": "unknown", "reason": "未提供 XCTest 执行摘要"}
    if args.test_summary:
        data = json.loads(args.test_summary.read_text(encoding="utf-8"))
        execution = {key: data.get(key) for key in ("result", "passedTests", "failedTests", "skippedTests", "totalTestCount")}
        execution["source"] = str(args.test_summary)
        execution["failures"] = [{"test": item.get("testIdentifierString"), "target": item.get("targetName")} for item in data.get("testFailures", [])]
    return {"schema_version": 1, "project": str(project), "git_commit": commit.stdout.strip() if commit.returncode == 0 else None,
            "generated_at_utc": datetime.now(timezone.utc).isoformat(),
            "source_sha256": {str(path.relative_to(project)): hashlib.sha256(path.read_bytes()).hexdigest() for path in paths},
            "formula": FORMULA, "coverage": coverage_meta, "swiftlint_version": run([args.swiftlint, "version"]).strip(),
            "complexity_definition": "SwiftLint cyclomatic_complexity branch increment + 1 base path; includes if/guard/loops/catch/switch cases; does not count &&/||/ternary; includes closures, excludes nested functions",
            "scope": "Swift functions and initializers; computed properties/accessors/subscripts/deinit/SwiftUI body are not measured by this rule",
            "thresholds": args.thresholds, "thresholds_are_release_gate": False,
            "excluded": list(DEFAULT_EXCLUDES) + args.exclude, "source_file_count": len(paths),
            "method_count": len(metrics), "coverage_counts": dict(Counter("unknown" if method["coverage"] is None else "approximation" if method["approximation"] else "method_line" for method in metrics)),
            "test_inventory": {"declared_test_count": sum(item[2]["declared_tests"] for item in inventory),
                               "file_count": len(inventory), "attribution": "Related tests are file references, not executed per-method attribution"},
            "test_execution": execution,
            "methods": metrics}


def summary(report, args):
    visible = [item for item in report["methods"] if item["complexity"] >= args.min_complexity
               and (args.include_unknown or item["crap"] is not None)
               and (args.include_approximation or not item["approximation"])]
    lines = ["CRAP = " + FORMULA,
             "方法 %d；源码文件 %d；覆盖率分布 %s" % (report["method_count"], report["source_file_count"], report["coverage_counts"]),
             "阈值 %s 仅作初始工程排序，不是账号安全或发布验收标准。" % args.thresholds,
             "| 方法 | 位置 | C | 覆盖率/粒度 | CRAP |", "|---|---|---:|---|---:|"]
    for item in visible[:args.top]:
        cov = "unknown" if item["coverage"] is None else "%.1f%%/%s%s" % (item["coverage"] * 100, item["granularity"], "/approximation" if item["approximation"] else "")
        score = "unknown" if item["crap"] is None else "%.2f" % item["crap"]
        lines.append("| %s | %s:%d | %d | %s | %s |" % (item["method"], item["file"], item["line"], item["complexity"], cov, score))
    if any(item["crap"] is None for item in visible[:args.top]):
        lines.append("unknown 项按复杂度排序，不能称为 CRAP 分数排名。")
    lines.append("行覆盖不证明真实 OAuth、服务端额度/计费、系统权限、签名、公证、安装或发布可用性。")
    return "\n".join(lines) + "\n"


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--source-dir", action="append", default=[], help="项目内目录，可重复；默认 codexBar")
    parser.add_argument("--exclude", action="append", default=[], help="额外排除目录名或 glob，可重复")
    parser.add_argument("--coverage-report", type=Path, help="xccov JSON / .xccovreport / .xcresult")
    parser.add_argument("--coverage-target", default="codexbarTests.xctest", help="本项目源码编入独立测试 runner；显式选择目标避免混合未运行的 App target")
    parser.add_argument("--test-summary", type=Path, help="xcresulttool test-results summary JSON；只记录计数与测试名，不回显失败原文")
    parser.add_argument("--min-complexity", type=int, default=1)
    parser.add_argument("--top", type=int, default=10, help="人工摘要显示前 N；JSON 保留全部方法以便复评")
    parser.add_argument("--output", type=Path, required=True, help="JSON 报告路径")
    parser.add_argument("--summary-output", type=Path, help="可选 Markdown 摘要")
    parser.add_argument("--include-unknown", action=argparse.BooleanOptionalAction, default=True)
    parser.add_argument("--include-approximation", action=argparse.BooleanOptionalAction, default=False)
    parser.add_argument("--thresholds", type=lambda text: [float(value) for value in text.split(",")], default=[15, 30, 50])
    parser.add_argument("--churn-days", type=int, default=90)
    parser.add_argument("--frequent-change-count", type=int, default=5)
    parser.add_argument("--swiftlint", default="swiftlint")
    args = parser.parse_args(argv)
    if args.top < 1 or args.min_complexity < 1 or args.churn_days < 1 or args.frequent_change_count < 1:
        parser.error("top/min-complexity/churn-days/frequent-change-count 必须大于 0")
    if len(args.thresholds) != 3 or any(not math.isfinite(value) or value <= 0 for value in args.thresholds) or args.thresholds != sorted(set(args.thresholds)):
        parser.error("thresholds 必须是三个递增的正数")
    return args


def validate_report_paths(args, home=None):
    home = (home or Path.home()).resolve()
    paths = [path.resolve() for path in (args.coverage_report, args.test_summary, args.output, args.summary_output) if path is not None]
    if any(path.is_relative_to(home / root) for root in (".codex", ".codexbar") for path in paths):
        raise ValueError("报告输入/输出不能位于真实用户的认证或 Codexbar 配置目录")
    inputs = {path.resolve() for path in (args.coverage_report, args.test_summary) if path}
    outputs = [path.resolve() for path in (args.output, args.summary_output) if path]
    if inputs.intersection(outputs) or len(outputs) != len(set(outputs)):
        raise ValueError("报告输出不能覆盖测量输入或互相覆盖")


def main(argv=None):
    args = parse_args(argv)
    try:
        validate_report_paths(args)
        report = evaluate(args)
        human = summary(report, args)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2, allow_nan=False) + "\n", encoding="utf-8")
        if args.summary_output:
            args.summary_output.parent.mkdir(parents=True, exist_ok=True)
            args.summary_output.write_text(human, encoding="utf-8")
        print(human, end="")
    except (ValueError, OSError, KeyError) as error:
        raise SystemExit("CRAP 评估失败：" + str(error))


if __name__ == "__main__":
    main()
