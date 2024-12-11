"""API for declaring a mypy lint aspect that visits py_library rules.

Typical usage:

First, fetch the mypy package via your standard requirements file and pip calls.

Then, declare a binary target for it, typically in `tools/lint/BUILD.bazel`:

```starlark
load("@rules_python//python/entry_points:py_console_script_binary.bzl", "py_console_script_binary")
py_console_script_binary(
    name = "mypy",
    pkg = "@pip//mypy:pkg",
)
```

Finally, create the linter aspect, typically in `tools/lint/linters.bzl`:

```starlark
load("@aspect_rules_lint//lint:mypy.bzl", "lint_mypy_aspect")

mypy = lint_mypy_aspect(
    binary = "@@//tools/lint:mypy",
    config = "@@//:.mypy",
)
```
"""

load("//lint/private:lint_aspect.bzl", "LintOptionsInfo", "filter_srcs", "noop_lint_action", "output_files", "should_visit")

_MNEMONIC = "AspectRulesLintmypy"

def mypy_action(ctx, executable, srcs, config, stdout, exit_code = None, options = []):
    """Run mypy as an action under Bazel.

    Based on https://mypy.pycqa.org/en/latest/user/invocation.html

    Args:
        ctx: Bazel Rule or Aspect evaluation context
        executable: label of the the mypy program
        srcs: python files to be linted
        config: label of the mypy config file (setup.cfg, tox.ini, or .mypy)
        stdout: output file containing stdout of mypy
        exit_code: output file containing exit code of mypy
            If None, then fail the build when mypy exits non-zero.
        options: additional command-line options, see https://mypy.pycqa.org/en/latest/user/options.html
    """
    inputs = srcs + [config]
    outputs = [stdout]

    # Wire command-line options, see
    # https://mypy.pycqa.org/en/latest/user/options.html
    args = ctx.actions.args()
    args.add_all(options)
    args.add_all(srcs)
    args.add(config, format = "--config=%s")

    if exit_code:
        command = "{mypy} $@ >{stdout}; echo $? > " + exit_code.path
        outputs.append(exit_code)
    else:
        # Create empty stdout file on success, as Bazel expects one
        command = "{mypy} $@ && touch {stdout}"

    ctx.actions.run_shell(
        inputs = inputs,
        outputs = outputs,
        tools = [executable],
        command = command.format(mypy = executable.path, stdout = stdout.path),
        arguments = [args],
        mnemonic = _MNEMONIC,
        progress_message = "Linting %{label} with mypy",
    )

# buildifier: disable=function-docstring
def _mypy_aspect_impl(target, ctx):
    # Note: we don't inspect whether PyInfo in target to avoid a dep on rules_python
    if not should_visit(ctx.rule, ctx.attr._rule_kinds):
        return []

    outputs, info = output_files(_MNEMONIC, target, ctx)

    files_to_lint = filter_srcs(ctx.rule)

    if len(files_to_lint) == 0:
        noop_lint_action(ctx, outputs)
        return [info]

    color_options = ["--color=always"] if ctx.attr._options[LintOptionsInfo].color else []
    mypy_action(ctx, ctx.executable._mypy, files_to_lint, ctx.file._config_file, outputs.human.out, outputs.human.exit_code, color_options)
    mypy_action(ctx, ctx.executable._mypy, files_to_lint, ctx.file._config_file, outputs.machine.out, outputs.machine.exit_code)
    return [info]

def lint_mypy_aspect(binary, config, rule_kinds = ["py_binary", "py_library"]):
    """A factory function to create a linter aspect.

    Attrs:
        binary: a mypy executable. Can be obtained from rules_python like so:

            load("@rules_python//python/entry_points:py_console_script_binary.bzl", "py_console_script_binary")

            py_console_script_binary(
                name = "mypy",
                pkg = "@pip//mypy:pkg",
            )

        config: the mypy config file (`setup.cfg`, `tox.ini`, or `.mypy`)
    """
    return aspect(
        implementation = _mypy_aspect_impl,
        # Edges we need to walk up the graph from the selected targets.
        # Needed for linters that need semantic information like transitive type declarations.
        # attr_aspects = ["deps"],
        attrs = {
            "_options": attr.label(
                default = "//lint:options",
                providers = [LintOptionsInfo],
            ),
            "_mypy": attr.label(
                default = binary,
                executable = True,
                cfg = "exec",
            ),
            "_config_file": attr.label(
                default = config,
                allow_single_file = True,
            ),
            "_rule_kinds": attr.string_list(
                default = rule_kinds,
            ),
        },
    )
