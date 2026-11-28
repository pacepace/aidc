#!/usr/bin/env python3
"""Print the command words of bash code, one per line, sorted and unique.

Reads bash's own listing of functions (`declare -f`) on stdin: that is normalized code with no
comments, so what is left to tell apart is quoting, heredocs, substitutions and case patterns.
A word counts when it is in command position: at the start of a command (after a newline, ;, &,
|, &&, ||, (, $(, <(, `, {, or a keyword such as then, do, if or !), after any NAME=value
assignments. Quoted text, heredoc bodies, ${...}, $((...)), case patterns and the arguments of
a command are not command words; the $(...) inside a double-quoted string is code and is read.

Used by tests/unit/test-lib-self-contained.sh. Only names matter, so a word that starts with a
quote or $ (a command chosen at run time) is skipped.
"""
import re
import sys

KEYWORDS_CMD = {"then", "do", "else", "elif", "if", "while", "until", "!", "time", "{", "}",
                "fi", "done", "esac", "in", "coproc", "function"}
NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_.:-]*")


def scan(text):
    out = set()
    i, n = 0, len(text)
    # A stack of contexts: "code" (top level or inside $( or `), "paren" (a subshell or $( group:
    # its ")" closes it), "dq" (inside "..."), "case" (a case body: patterns, then commands).
    stack = ["code"]
    cmd = True           # the next word is in command position
    case_state = []       # per open case: [where ("subject", "pattern" or "body"), stack depth]
    heredocs = []         # pending delimiters (strip leading tabs?, word)

    def in_case(state):
        return bool(case_state) and case_state[-1][0] == state and case_state[-1][1] == len(stack)

    def skip_balanced(j, open_c, close_c):
        depth = 0
        while j < n:
            c = text[j]
            if c == "\\":
                j += 2
                continue
            if c == "'" and open_c != "{":
                k = text.find("'", j + 1)
                j = n if k < 0 else k + 1
                continue
            if c == open_c:
                depth += 1
            elif c == close_c:
                depth -= 1
                if depth == 0:
                    return j + 1
            j += 1
        return n

    while i < n:
        c = text[i]
        top = stack[-1]
        if top == "dq":
            if c == "\\":
                i += 2
            elif c == '"':
                stack.pop()
                i += 1
            elif text.startswith("$((", i):
                i = skip_balanced(i + 1, "(", ")")
            elif text.startswith("$(", i):
                stack.append("paren")
                cmd = True
                i += 2
            elif text.startswith("${", i):
                i = skip_balanced(i + 1, "{", "}")
            elif c == "`":
                stack.append("bq")
                cmd = True
                i += 1
            else:
                i += 1
            continue
        # code-like contexts: code, paren, bq
        if c == "\n":
            i += 1
            while heredocs:
                strip, word = heredocs.pop(0)
                while i < n:
                    j = text.find("\n", i)
                    line = text[i:] if j < 0 else text[i:j]
                    i = n if j < 0 else j + 1
                    if (line.lstrip("\t") if strip else line) == word:
                        break
            cmd = True
            continue
        if c in " \t":
            i += 1
            continue
        if c == "\\":
            i += 2
            continue
        if c == "'":
            k = text.find("'", i + 1)
            i = n if k < 0 else k + 1
            cmd = False
            continue
        if c == '"':
            stack.append("dq")
            i += 1
            cmd = False
            continue
        if c == "`":
            if top == "bq":
                stack.pop()
                cmd = False
            else:
                stack.append("bq")
                cmd = True
            i += 1
            continue
        if text.startswith("<<", i) and not text.startswith("<<<", i):
            m = re.match(r"<<(-?)\s*(['\"]?)([^\s'\";|&<>()]+)\2", text[i:])
            if m:
                heredocs.append((m.group(1) == "-", m.group(3)))
                i += m.end()
                continue
        if text.startswith("$((", i) or text.startswith("((", i):
            i = skip_balanced(i + (1 if c == "$" else 0), "(", ")")
            cmd = False
            continue
        if text.startswith("${", i):
            i = skip_balanced(i + 1, "{", "}")
            cmd = False
            continue
        if text.startswith("$(", i) or text.startswith("<(", i) or text.startswith(">(", i):
            stack.append("paren")
            cmd = True
            i += 2
            continue
        if c == "(":
            stack.append("paren")
            cmd = True
            i += 1
            continue
        if c == ")":
            if in_case("pattern"):
                case_state[-1][0] = "body"
                cmd = True
            elif top == "paren":
                stack.pop()
                cmd = False
            i += 1
            continue
        if text.startswith(";;", i) or (text.startswith(";&", i) and in_case("body")):
            if in_case("body"):
                case_state[-1][0] = "pattern"
            i += 3 if text.startswith(";;&", i) else 2
            cmd = True
            continue
        if c in ";|&":
            # >&2, <&0 and &> are redirections, not separators.
            if c == "&" and i > 0 and text[i - 1] in "<>":
                i += 1
                continue
            if c == "|" and in_case("pattern"):
                i += 1
                continue
            i += 1
            cmd = True
            continue
        if c in "<>":
            i += 1
            continue
        if c in "!{}" and text[i + 1:i + 2] in (" ", "\t", "\n", ""):
            # ! and { leave the next word in command position; } ends a group.
            cmd = c != "}"
            i += 1
            continue
        # A word.
        m = NAME.match(text, i)
        if not m:
            # Starts with $, a digit or punctuation: not a name; read past it as an argument.
            j = i
            while j < n and text[j] not in " \t\n;|&()<>\"'`" and not text.startswith("$(", j) \
                    and not text.startswith("${", j):
                j += 1
            i = j if j > i else i + 1
            cmd = False
            continue
        word = m.group(0)
        end = m.end()
        nxt = text[end:end + 1]
        if in_case("pattern"):
            if word == "esac":
                case_state.pop()
                cmd = False
            i = end
            continue
        if in_case("subject"):
            if word == "in":
                case_state[-1][0] = "pattern"
            i = end
            continue
        if nxt == "=" or text.startswith("+=", end) or nxt == "[":
            # NAME=value (or NAME[i]=value): an assignment; the command, if any, follows.
            i = end
            if not cmd:
                continue
            # Skip the value, which may be quoted; the scanner reads it as an argument would.
            i += 1 if nxt == "=" else 0
            if nxt == "[":
                i = skip_balanced(i, "[", "]")
                if text.startswith("+=", i):
                    i += 2
                elif text[i:i + 1] == "=":
                    i += 1
            # read the value word without ending command position
            while i < n and text[i] not in " \t\n;|&)":
                ch = text[i]
                if ch == "'":
                    k = text.find("'", i + 1)
                    i = n if k < 0 else k + 1
                elif ch == '"':
                    # a quoted value: let the dq context read it (its $(...) is code)
                    stack.append("dq")
                    i += 1
                    break
                elif text.startswith("$(", i):
                    stack.append("paren")
                    i += 2
                    break
                elif text.startswith("${", i):
                    i = skip_balanced(i + 1, "{", "}")
                elif ch == "(":
                    i = skip_balanced(i, "(", ")")
                else:
                    i += 1
            cmd = True
            continue
        if text.startswith(" ()", end) or text.startswith("()", end):
            # A function's own header in bash's listing: a definition, not a call.
            i = end
            continue
        if cmd:
            if word == "case":
                case_state.append(["subject", len(stack)])
                cmd = False
            elif word == "esac":
                if in_case("body"):
                    case_state.pop()
                cmd = False
            elif word in KEYWORDS_CMD:
                cmd = True
            elif word in ("for", "select"):
                cmd = False
            else:
                out.add(word)
                cmd = False
        i = end
    return out


if __name__ == "__main__":
    for w in sorted(scan(sys.stdin.read())):
        print(w)
